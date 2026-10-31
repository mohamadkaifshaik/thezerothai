package lists

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line fields (ADR-0030 D12): counts and enums only, never a list id, name or description.
const (
	fieldOp      = "list_op"
	fieldOutcome = "outcome"

	outcomeDone       = "done"
	outcomeReplay     = "replay"
	outcomeNoop       = "noop"
	outcomeNotFound   = "rejected:not_found"
	outcomeContention = "contention"
)

// limitLists is the LIMIT_REACHED metadata["limit"] value of the per-owner cap (lists.proto).
const limitLists = "lists"

// limitListMembers is the LIMIT_REACHED metadata["limit"] value of the per-list member cap.
const limitListMembers = "list_members"

// notFoundText is the one message of every NOT_FOUND this module answers (ADR-0030 D3: byte-identical for every cause).
const notFoundText = "list not found"

// Limits are the caps and quota tiers the write path needs, from config (rule 11).
type Limits struct {
	// MaxPerUser is LISTS_MAX_PER_USER (20): the lists one owner may have.
	MaxPerUser int
	// CreatesPerDay and NewAccountCreatesPerDay are the quota.ListCreates daily limits (10, and 3 inside NewAccountWindow).
	CreatesPerDay           int64
	NewAccountCreatesPerDay int64
	NewAccountWindow        time.Duration
	// MaxMembers is LIST_MAX_MEMBERS (150); AddsPerDay and NewAccountAddsPerDay are the quota.ListAdds daily limits (300, and 50
	// inside NewAccountWindow). Used by AddMember (W5-6).
	MaxMembers                       int
	AddsPerDay, NewAccountAddsPerDay int64
	// CacheEntries is CACHE_LISTS_ENTRIES.
	CacheEntries int
}

// Deps is everything New needs. Pins may be nil (W5-9 wires it).
type Deps struct {
	Repo      Repo
	Directory identity.Directory
	IDs       IDSource
	Pins      Pins
	// Graph is the owner's social context (cache-first, 60 s): the block and follow checks of AddMember and the lazy drop (W5-6).
	Graph graph.Reader
	// CursorKey seals the page tokens of ListUserLists and ListListMembers (cfg.CursorHMACKey).
	CursorKey []byte
	Limits    Limits
	// Now is the clock for the new-account window; nil means time.Now.
	Now func() time.Time
}

type service struct {
	d     Deps
	cache *docCache
	now   func() time.Time
}

// New builds the lists service. It never touches Firestore itself; the flag gate is the handler's (Guard), before this runs.
func New(d Deps) Service {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	return &service{d: d, cache: newDocCache(d.Limits.CacheEntries), now: now}
}

var _ Service = (*service)(nil)

func notFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, notFoundText)
}

// canonical request bodies for IDEMPOTENCY_KEY_REUSED: every field as sent, an unset optional distinct from its zero value.
func optString(s *string) string {
	if s == nil {
		return "unset"
	}
	return strconv.Quote(*s)
}

func optBool(b *bool) string {
	if b == nil {
		return "unset"
	}
	return strconv.FormatBool(*b)
}

func createHash(name, description string, isPrivate *bool) string {
	return idempotency.HashRequest(fmt.Sprintf("name=%q|description=%q|is_private=%s", name, description, optBool(isPrivate)))
}

func updateHash(listID string, name, description *string, isPrivate *bool) string {
	return idempotency.HashRequest(fmt.Sprintf("list_id=%s|name=%s|description=%s|is_private=%s", listID, optString(name), optString(description), optBool(isPrivate)))
}

func deleteHash(listID string) string { return idempotency.HashRequest("list_id=" + listID) }

// validateKey and validateListID are the shared front checks: 0 reads, the field named in the VALIDATION metadata.
func validateKey(key string) error {
	if !idempotency.KeyFormatValid(key) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	return nil
}

func validateListID(id string) error {
	if !ids.ValidPostID(id) {
		return apierr.Validation("list_id", "list_id must be a 19-digit list id")
	}
	return nil
}

func validateName(s string) (string, error) {
	n, ok := identity.SingleLineText(s, MinNameRunes, MaxNameRunes)
	if !ok {
		return "", apierr.Validation("name", "name must be 1-25 characters on one line, with a visible character and without control, invisible or direction characters")
	}
	return n, nil
}

func validateDescription(s string) (string, error) {
	n, ok := identity.SingleLineText(s, 0, MaxDescriptionRunes)
	if !ok {
		return "", apierr.Validation("description", "description must be at most 100 characters on one line, without control, invisible or direction characters")
	}
	return n, nil
}

// profile is the caller's live row, cache-first (0 reads behind the account-status interceptor, which has just loaded it).
func (s *service) profile(ctx context.Context, uid string) (identity.Profile, error) {
	profiles, err := s.d.Directory.GetProfiles(ctx, []string{uid})
	if err != nil {
		return identity.Profile{}, logger.RedactErr(fmt.Errorf("lists: load profile: %w", err), uid)
	}
	p, ok := profiles[uid]
	if !ok {
		return identity.Profile{}, errNoProfile()
	}
	return p, nil
}

func errNoProfile() *apierr.Error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "create a profile first")
}

func (s *service) isNew(p identity.Profile) bool {
	return !p.CreatedAt.IsZero() && s.now().Sub(p.CreatedAt) < s.d.Limits.NewAccountWindow
}

// begin records the op on the request line and returns the deferred outcome note for a failed call.
func begin(ctx context.Context, op string) {
	logger.SetRequestField(ctx, fieldOp, op)
}

func noteOutcome(ctx context.Context, o Outcome) {
	switch o {
	case Written:
		logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	case Replayed:
		logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
	default:
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
	}
}

// mapErr turns a repository error into the handler's answer. Known sentinels and already shaped apierrs (the daily quota,
// validation) pass through; a client that left is CANCELED / DEADLINE_EXCEEDED; exhausted contention or the transaction's own
// timeout is a retryable UNAVAILABLE logged at WARN; anything else is a redacted internal error that reaches Error Reporting.
// The uid and list id are redacted from the chain: a Firestore error embeds document paths.
func mapErr(ctx context.Context, op, uid, listID string, err error) error {
	var ae *apierr.Error
	switch {
	case errors.Is(err, ErrNotFound):
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return notFound()
	case errors.Is(err, ErrListLimit):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:limit_reached")
		logger.SetRequestField(ctx, "limit", limitLists)
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED,
			"list limit reached").WithMeta("limit", limitLists)
	case errors.Is(err, ErrMemberLimit):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:limit_reached")
		logger.SetRequestField(ctx, "limit", limitListMembers)
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED,
			"list member limit reached").WithMeta("limit", limitListMembers)
	case errors.Is(err, ErrProtected):
		logger.SetRequestField(ctx, fieldOutcome, "rejected:protected_account")
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT,
			"this account is protected: follow it first")
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
		logger.SetRequestField(ctx, fieldOutcome, outcomeContention)
		slog.WarnContext(ctx, "lists_contention", fieldOp, op, "uid_hash", logger.HashUID(uid))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
			WithRetryAfter(time.Second)
	}
	return logger.RedactErr(fmt.Errorf("lists: %s: %w", op, err), uid, listID)
}

// CreateList implements Service (ADR-0030 D2, D3, D7). Validation first (0 reads), the caller's profile (cache-first; it
// decides the new-account quota tier and is the response's owner row), then one repository transaction. The new list's data
// fills the instance cache.
func (s *service) CreateList(ctx context.Context, uid string, in CreateInput) (View, error) {
	begin(ctx, "create")
	if err := validateKey(in.Key); err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	name, err := validateName(in.Name)
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	description, err := validateDescription(in.Description)
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	prof, err := s.profile(ctx, uid)
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	limit := s.d.Limits.CreatesPerDay
	if s.isNew(prof) {
		limit = s.d.Limits.NewAccountCreatesPerDay
	}
	res, err := s.d.Repo.Create(ctx, CreateParams{
		UID: uid, ID: s.d.IDs.Generate(), IdemKey: idempotency.Key(uid, rpcCreateList, in.Key),
		RequestHash: createHash(name, description, in.IsPrivate), Name: name, Description: description,
		IsPrivate:  in.IsPrivate == nil || *in.IsPrivate, // F3: absent = private, so an old or careless client fails closed
		MaxPerUser: s.d.Limits.MaxPerUser, QuotaLimit: limit,
	})
	if err != nil {
		return View{}, mapErr(ctx, "create", uid, "", err)
	}
	noteOutcome(ctx, res.Outcome)
	if res.List != nil {
		s.cache.put(*res.List)
	}
	return View{Header: res.Header, Owner: prof}, nil
}

// UpdateList implements Service. A replay answers with the stored header and leaves the cache alone (the list may have
// changed since). A write that makes the list private evicts it; any other write refreshes the entry from the written data.
// A rename of a pinned list refreshes the stored tab title through Pins, after the commit and best effort.
func (s *service) UpdateList(ctx context.Context, uid string, in UpdateInput) (View, error) {
	begin(ctx, "update")
	if err := validateKey(in.Key); err != nil {
		return View{}, mapErr(ctx, "update", uid, in.ListID, err)
	}
	if err := validateListID(in.ListID); err != nil {
		return View{}, mapErr(ctx, "update", uid, in.ListID, err)
	}
	var name, description *string
	if in.Name != nil {
		n, err := validateName(*in.Name)
		if err != nil {
			return View{}, mapErr(ctx, "update", uid, in.ListID, err)
		}
		name = &n
	}
	if in.Description != nil {
		d, err := validateDescription(*in.Description)
		if err != nil {
			return View{}, mapErr(ctx, "update", uid, in.ListID, err)
		}
		description = &d
	}
	res, err := s.d.Repo.Update(ctx, UpdateParams{
		UID: uid, ListID: in.ListID, IdemKey: idempotency.Key(uid, rpcUpdateList, in.Key),
		RequestHash: updateHash(in.ListID, name, description, in.IsPrivate), Name: name, Description: description, IsPrivate: in.IsPrivate,
	})
	if err != nil {
		return View{}, mapErr(ctx, "update", uid, in.ListID, err)
	}
	noteOutcome(ctx, res.Outcome)
	prof, err := s.profile(ctx, uid)
	if err != nil {
		return View{}, mapErr(ctx, "update", uid, in.ListID, err)
	}
	view := View{Header: res.Header, Owner: prof}
	if res.List != nil && res.Outcome != Replayed {
		if res.List.IsPrivate {
			s.cache.evict(res.List.ID)
		} else {
			s.cache.put(*res.List)
		}
	}
	if res.NameChanged && s.d.Pins != nil {
		pinned, perr := s.d.Pins.Retitle(ctx, uid, in.ListID, res.Header.Name)
		if perr != nil {
			slog.WarnContext(ctx, "lists_retitle_failed", "uid_hash", logger.HashUID(uid), "err", logger.RedactErr(perr, uid, in.ListID))
		}
		view.PinnedByViewer = pinned
	}
	return view, nil
}

// DeleteList implements Service. Deleting a list that is not the caller's, or is already gone, is success with no effect
// (the client may be retrying after a lost response). When this call removed the list, the owner's own pin goes through
// Pins after the commit (best effort: a failure leaves a dangling tab that GetMe drops lazily, W5-9).
func (s *service) DeleteList(ctx context.Context, uid, key, listID string) error {
	begin(ctx, "delete")
	if err := validateKey(key); err != nil {
		return mapErr(ctx, "delete", uid, listID, err)
	}
	if err := validateListID(listID); err != nil {
		return mapErr(ctx, "delete", uid, listID, err)
	}
	res, err := s.d.Repo.Delete(ctx, DeleteParams{
		UID: uid, ListID: listID, IdemKey: idempotency.Key(uid, rpcDeleteList, key), RequestHash: deleteHash(listID),
	})
	if err != nil {
		return mapErr(ctx, "delete", uid, listID, err)
	}
	noteOutcome(ctx, res.Outcome)
	if res.Deleted {
		s.cache.evict(listID)
		if s.d.Pins != nil {
			if perr := s.d.Pins.Unpin(ctx, uid, listID); perr != nil {
				slog.WarnContext(ctx, "lists_unpin_failed", "uid_hash", logger.HashUID(uid), "err", logger.RedactErr(perr, uid, listID))
			}
		}
	}
	return nil
}
