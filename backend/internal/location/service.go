package location

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line fields: enums and booleans only, never an area id (design section 5.5).
const (
	fieldOp      = "location_op"
	fieldOutcome = "outcome"
	fieldHasArea = "has_area"

	// LIMIT_REACHED metadata["limit"] and FAILED_PRECONDITION metadata["reason"] values (location.proto header).
	limitConsentChanges   = "location_consent_changes"
	reasonConsentRequired = "consent_required"

	// defaultConsentChangesPerDay is LOCATION_CONSENT_CHANGES_PER_DAY's default, used when Deps leaves it unset.
	defaultConsentChangesPerDay = 10

	// ListAreas limit clamp: 0 (or below) = defaultAreasLimit, above maxAreasLimit = maxAreasLimit.
	defaultAreasLimit = 200
	maxAreasLimit     = 500
)

// Limits are the configured location limits.
type Limits struct {
	// MinCopyVersion is LOCATION_CONSENT_MIN_COPY_VERSION (default 1): the oldest rationale copy a consent may be at.
	MinCopyVersion int
	// CurrentCopyVersion is LOCATION_CONSENT_COPY_VERSION (default 1, at least MinCopyVersion): the newest copy a grant
	// may carry.
	CurrentCopyVersion int
	// ConsentChangesPerDay is LOCATION_CONSENT_CHANGES_PER_DAY (default 10): consent records per user per IST day,
	// checked by SetArea when it grants. ClearArea is never limited by it.
	ConsentChangesPerDay int
}

// Deps wires the service.
type Deps struct {
	Repo      Repo
	Catalog   *StaticCatalog
	IDs       IDGenerator
	CursorKey []byte
	Limits    Limits
	Now       func() time.Time
}

// ConsentState is the latest consent (location.v1.ConsentState).
type ConsentState struct {
	// Action is "" when the user never consented.
	Action, Purpose  string
	CopyVersion      int
	At               time.Time
	AdultConfirmedAt time.Time
}

// Settings is the caller's location settings (location.v1.LocationSettings).
type Settings struct {
	// Area is nil when no area is set.
	Area                *Area
	Consent             ConsentState
	RequiredCopyVersion int
	CurrentCopyVersion  int
}

// SetAreaInput is a SetArea request.
type SetAreaInput struct {
	Key     string
	AreaID  string
	Consent *Grant
}

// ListAreasInput is a ListAreas request.
type ListAreasInput struct {
	Limit        int
	PageToken    string
	KnownVersion int64
}

// AreasPage is a ListAreas answer.
type AreasPage struct {
	Areas       []Area
	Next        string
	Version     int64
	NotModified bool
}

// Service is the LocationService business layer. The flag gates are the handler's (server.go), before this runs; every
// method validates its input before any Firestore access.
type Service interface {
	GetSettings(ctx context.Context, uid string) (Settings, error)
	SetArea(ctx context.Context, uid string, in SetAreaInput) (Settings, error)
	ClearArea(ctx context.Context, uid, key string) (Settings, error)
	ListAreas(ctx context.Context, uid string, in ListAreasInput) (AreasPage, error)
	Reader
}

type service struct {
	d   Deps
	now func() time.Time
}

// New builds the service.
func New(d Deps) Service {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	// Defensive defaults (config.Load already enforces them): a zero limit would refuse every grant.
	if d.Limits.MinCopyVersion < 1 {
		d.Limits.MinCopyVersion = 1
	}
	if d.Limits.CurrentCopyVersion < d.Limits.MinCopyVersion {
		d.Limits.CurrentCopyVersion = d.Limits.MinCopyVersion
	}
	if d.Limits.ConsentChangesPerDay < 1 {
		d.Limits.ConsentChangesPerDay = defaultConsentChangesPerDay
	}
	return &service{d: d, now: now}
}

var _ Service = (*service)(nil)

func validateKey(key string) error {
	if !idempotency.KeyFormatValid(key) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	return nil
}

// validateSet checks a SetArea request before any lookup; values are never echoed. A consent that is present is always
// validated (adult_confirmed true and MinCopyVersion <= copy_version <= CurrentCopyVersion), even when the caller's stored
// consent is current and the repo would ignore it: the check runs before the lookup that could tell.
func (s *service) validateSet(in SetAreaInput) error {
	if err := validateKey(in.Key); err != nil {
		return err
	}
	if !ValidIDFormat(in.AreaID) || !s.d.Catalog.Pickable(in.AreaID) {
		return apierr.Validation("area_id", "area_id must be a catalogue area that is not retired")
	}
	if c := in.Consent; c != nil && (!c.AdultConfirmed || c.CopyVersion < s.d.Limits.MinCopyVersion || c.CopyVersion > s.d.Limits.CurrentCopyVersion) {
		return apierr.Validation("consent", "consent needs adult_confirmed and a supported copy_version")
	}
	return nil
}

// setHash is the stored idempotency requestHash of a SetArea body. The client's idempotency key is mixed in: the catalogue
// is small, so a hash of the area id alone could be reversed by hashing every id, and the idempotency doc would then
// reveal the user's area for its 24 h (DPDP). With the key (16-64 random characters) the hash cannot be enumerated, and a
// replay with the same key and body still matches.
func setHash(in SetAreaInput) string {
	g := Grant{}
	if in.Consent != nil {
		g = *in.Consent
	}
	return idempotency.HashRequest(fmt.Sprintf("key=%s|area=%s|consent=%t|copy=%d|adult=%t", in.Key, in.AreaID, in.Consent != nil, g.CopyVersion, g.AdultConfirmed))
}

// settings renders a repo state. The area resolves through the catalogue (retired included); the consent comes from the
// area doc when set, else from the latest record.
func (s *service) settings(st State) Settings {
	out := Settings{RequiredCopyVersion: s.d.Limits.MinCopyVersion, CurrentCopyVersion: s.d.Limits.CurrentCopyVersion}
	switch {
	case st.Area != nil:
		if a, ok := s.d.Catalog.Lookup(st.Area.AreaID); ok {
			out.Area = &a
		}
		purpose := PurposePlansNearby
		if len(st.Area.Purposes) > 0 {
			purpose = st.Area.Purposes[0]
		}
		out.Consent = ConsentState{
			Action: ActionGranted, Purpose: purpose, CopyVersion: st.Area.ConsentCopyVersion,
			At: st.Area.ConsentedAt, AdultConfirmedAt: st.Area.AdultConfirmedAt,
		}
	case st.Latest != nil:
		out.Consent = ConsentState{Action: st.Latest.Action, Purpose: st.Latest.Purpose, CopyVersion: st.Latest.CopyVersion, At: st.Latest.At}
		if st.Latest.Action == ActionGranted && st.Latest.AdultConfirmed {
			out.Consent.AdultConfirmedAt = st.Latest.At
		}
	}
	return out
}

func begin(ctx context.Context, op string) { logger.SetRequestField(ctx, fieldOp, op) }

func noteResult(ctx context.Context, o Outcome, st State) {
	switch o {
	case Written:
		logger.SetRequestField(ctx, fieldOutcome, "done")
	case Replayed:
		logger.SetRequestField(ctx, fieldOutcome, "replay")
	default:
		logger.SetRequestField(ctx, fieldOutcome, "noop")
	}
	logger.SetRequestField(ctx, fieldHasArea, st.Area != nil)
}

// GetSettings answers the caller's area and latest consent: 1 read, +1 for the latest consent record when no area is set.
func (s *service) GetSettings(ctx context.Context, uid string) (Settings, error) {
	begin(ctx, "get")
	a, err := s.d.Repo.Area(ctx, uid)
	if err != nil {
		return Settings{}, s.mapErr(ctx, "get", uid, err)
	}
	st := State{Area: a}
	if a == nil {
		if st.Latest, err = s.d.Repo.LatestConsent(ctx, uid); err != nil {
			return Settings{}, s.mapErr(ctx, "get", uid, err)
		}
	}
	logger.SetRequestField(ctx, fieldHasArea, a != nil)
	return s.settings(st), nil
}

// MyArea implements Reader: 1 read. A stored area whose consent is below the current minimum copy version is not usable
// (ok false) until the user consents again, the same rule SetArea applies.
func (s *service) MyArea(ctx context.Context, uid string) (string, bool, error) {
	a, err := s.d.Repo.Area(ctx, uid)
	if err != nil {
		return "", false, logger.RedactErr(fmt.Errorf("location: my area: %w", err), uid)
	}
	if a == nil || a.ConsentCopyVersion < s.d.Limits.MinCopyVersion {
		return "", false, nil
	}
	return a.AreaID, true, nil
}

// SetArea validates, then runs the SetArea transaction (repo_firestore.go).
func (s *service) SetArea(ctx context.Context, uid string, in SetAreaInput) (Settings, error) {
	begin(ctx, "set")
	if err := s.validateSet(in); err != nil {
		return Settings{}, err
	}
	res, err := s.d.Repo.SetArea(ctx, SetParams{
		UID: uid, IdemKey: idempotency.Key(uid, rpcSetArea, in.Key), RequestHash: setHash(in), AreaID: in.AreaID,
		ConsentID: s.d.IDs.Generate(), Grant: in.Consent, MinCopyVersion: s.d.Limits.MinCopyVersion,
		ConsentsPerDay: s.d.Limits.ConsentChangesPerDay, Now: s.now(),
	})
	if err != nil {
		return Settings{}, s.mapErr(ctx, "set", uid, err, in.AreaID)
	}
	noteResult(ctx, res.Outcome, res.State)
	return s.settings(res.State), nil
}

// ClearArea validates the key, then runs the ClearArea transaction. Not limited by the daily consent cap.
func (s *service) ClearArea(ctx context.Context, uid, key string) (Settings, error) {
	begin(ctx, "clear")
	if err := validateKey(key); err != nil {
		return Settings{}, err
	}
	res, err := s.d.Repo.ClearArea(ctx, ClearParams{
		UID: uid, IdemKey: idempotency.Key(uid, rpcClearArea, key), RequestHash: idempotency.HashRequest("clear"),
		ConsentID: s.d.IDs.Generate(), Now: s.now(),
	})
	if err != nil {
		return Settings{}, s.mapErr(ctx, "clear", uid, err)
	}
	noteResult(ctx, res.Outcome, res.State)
	return s.settings(res.State), nil
}

// areasBinding binds a ListAreas token to the caller and the catalogue version: a deploy that changes the catalogue
// mid-paging makes the token fail to open (VALIDATION "page_token", the client restarts).
func areasBinding(uid string, version int64) string {
	return "location_areas|" + uid + "|v" + strconv.FormatInt(version, 10)
}

// ListAreas pages the embedded catalogue (0 reads): known_version equal to the server's answers not_modified with no
// areas; otherwise up to limit areas after the token's position, in id order, retired included.
func (s *service) ListAreas(_ context.Context, uid string, in ListAreasInput) (AreasPage, error) {
	c := s.d.Catalog
	page := AreasPage{Version: c.Version()}
	limit := in.Limit
	switch {
	case limit <= 0:
		limit = defaultAreasLimit
	case limit > maxAreasLimit:
		limit = maxAreasLimit
	}
	binding := areasBinding(uid, c.Version())
	cur, err := cursor.DecodeAt(s.d.CursorKey, binding, in.PageToken, s.now())
	if err != nil || (!cursor.IsFirstPage(cur) && !ValidIDFormat(cur.DocID)) {
		return AreasPage{}, apierr.Validation("page_token", "page_token is invalid or expired; restart the list")
	}
	if in.KnownVersion == c.Version() {
		page.NotModified, page.Areas = true, []Area{}
		return page, nil
	}
	areas, more := c.Page(cur.DocID, limit)
	page.Areas = areas
	if more && len(areas) > 0 {
		page.Next = cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: time.Unix(0, 0).UTC(), DocID: areas[len(areas)-1].ID}, s.now())
	}
	return page, nil
}

// areaPlaceholder replaces an area id in an error message. Not HashUID: the catalogue is small, so a hash of an area id
// is reversed by hashing every id.
const areaPlaceholder = "<area>"

// areaRedactedError is an error whose message has the area ids replaced by areaPlaceholder. Like logger.RedactErr's type it
// has no Unwrap (the error log walks the Unwrap chain and would re-append the raw text); errors.Is/As still reach the cause.
type areaRedactedError struct {
	msg   string
	cause error
}

func (e *areaRedactedError) Error() string        { return e.msg }
func (e *areaRedactedError) Is(target error) bool { return errors.Is(e.cause, target) }
func (e *areaRedactedError) As(target any) bool   { return errors.As(e.cause, target) }

// redactAreas replaces every occurrence of each area id in err's full cause chain with areaPlaceholder.
func redactAreas(err error, areaIDs ...string) error {
	msg := logger.CauseChain(err)
	for _, id := range areaIDs {
		if id != "" {
			msg = strings.ReplaceAll(msg, id, areaPlaceholder)
		}
	}
	return &areaRedactedError{msg: msg, cause: err}
}

// mapErr turns a repository or rule error into the handler's answer. Known sentinels and shaped apierrs pass through; a
// client that left is CANCELED / DEADLINE_EXCEEDED; contention is a retryable UNAVAILABLE; anything else is a redacted
// internal error: the uid is replaced by its hash and every area id in areaIDs by "<area>".
func (s *service) mapErr(ctx context.Context, op, uid string, err error, areaIDs ...string) error {
	var ae *apierr.Error
	switch {
	case errors.Is(err, ErrConsentRequired):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:"+reasonConsentRequired)
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "consent is required to set an area").
			WithMeta("reason", reasonConsentRequired)
	case errors.Is(err, ErrConsentLimit):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:limit_reached")
		logger.SetRequestField(ctx, "limit", limitConsentChanges)
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "too many location consent changes today").
			WithMeta("limit", limitConsentChanges)
	case errors.Is(err, ErrKeyReused):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:key_reused")
		return apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED,
			"this idempotency_key was already used for a different request")
	case errors.As(err, &ae):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:"+ae.Code.String())
		return err
	}
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	case store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		logger.SetRequestField(ctx, fieldOutcome, "contention")
		slog.WarnContext(ctx, "location_contention", fieldOp, op, "uid_hash", logger.HashUID(uid))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
			WithRetryAfter(time.Second)
	}
	return logger.RedactErr(redactAreas(fmt.Errorf("location: %s: %w", op, err), areaIDs...), uid)
}
