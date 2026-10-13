package moderation

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"connectrpc.com/connect"
	"golang.org/x/text/unicode/norm"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// FlagName is the wire name ModerationService RPCs check (FEATURE_REPORTS <-> "reports", ADR-0016 D1).
const FlagName = "reports"

// Request-log fields. Enums, counts and booleans only: never ids, handles, notes or evidence text.
const (
	fieldOp         = "moderation_op"
	fieldOutcome    = "outcome"
	fieldTargetType = "report_target"
	fieldReason     = "report_reason"
	fieldTxn        = "txn_attempts"
)

// postIDPattern is the post id shape (ADR-0010 D18).
var postIDPattern = regexp.MustCompile(`^[0-9]{19}$`)

// Deps is everything New needs.
type Deps struct {
	Repo      Repo
	Posts     PostViewer
	Accounts  AccountViewer
	Directory identity.Directory
	// ReportsPerDay is the daily quota (config.QuotaConfig); NewAccountReportsPerDay applies inside NewAccountWindow.
	ReportsPerDay           int64
	NewAccountReportsPerDay int64
	NewAccountWindow        time.Duration
	// AllowAnonymous is set only from config.AuthEmulator (the posts convention, ADR-0010 D5 A10).
	AllowAnonymous bool
	// Now is overridable for tests; nil means time.Now.
	Now func() time.Time
}

type service struct {
	d Deps
	// exhausted remembers, per instance, the uids whose reports quota was found spent, so a client that keeps
	// retrying an over-quota report costs 1 Firestore read (the replay lookup) until the IST day rolls over (ADR-0016 D2).
	exhausted *cache.LRU[string, exhaustion]
}

// exhaustion is one "reports quota spent" observation.
type exhaustion struct {
	// until is the next IST midnight, when the daily counter resets.
	until time.Time
	// windowEnds is when the new-account limit stops applying (zero when the spent limit was the normal one): the
	// limit rises then, so the observation no longer holds.
	windowEnds time.Time
}

// exhaustedCapacity bounds the instance memory of the exhaustion cache (a few dozen bytes per uid).
const exhaustedCapacity = 4096

// New builds the moderation service.
func New(d Deps) Service {
	if d.Now == nil {
		d.Now = time.Now
	}
	return &service{d: d, exhausted: cache.New[string, exhaustion](exhaustedCapacity, 24*time.Hour)}
}

var _ Service = (*service)(nil)

// Report implements Service (ADR-0016 D1).
func (s *service) Report(ctx context.Context, uid string, in ReportInput) (res ReportResult, err error) {
	logger.SetRequestField(ctx, fieldOp, "report")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()

	if !idempotency.KeyFormatValid(in.IdempotencyKey) {
		return ReportResult{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	switch in.TargetType {
	case TargetPost, TargetAccount:
	default:
		return ReportResult{}, apierr.Validation("target_type", "target_type must be POST or ACCOUNT")
	}
	if in.Reason == "" {
		return ReportResult{}, apierr.Validation("reason", "choose a reason")
	}
	switch in.TargetType {
	case TargetPost:
		if !postIDPattern.MatchString(in.TargetID) {
			return ReportResult{}, apierr.Validation("target_id", "target_id must be a 19-digit post id")
		}
	case TargetAccount:
		if !identity.ValidUserID(in.TargetID) {
			return ReportResult{}, apierr.Validation("target_id", "target_id must be a user id")
		}
		if in.TargetID == uid {
			return ReportResult{}, apierr.Validation("target_id", "you cannot report your own account")
		}
	}
	note, err := normalizeNote(in.Note)
	if err != nil {
		return ReportResult{}, err
	}
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "reporting"); err != nil {
		return ReportResult{}, err
	}
	logger.SetRequestField(ctx, fieldTargetType, string(in.TargetType))
	logger.SetRequestField(ctx, fieldReason, string(in.Reason))
	// A uid already known to be out of quota skips the profile, post and transaction reads. The report id needs no
	// read, so one point read tells a replay of a report that is already OPEN (AlreadyReported, rule 4: it was
	// written and needs no quota) from a genuinely new or reopened report, which is QUOTA_EXCEEDED. 1 read.
	if e, ok := s.exhausted.Get(uid); ok {
		now := s.d.Now()
		if now.Before(e.until) && (e.windowEnds.IsZero() || now.Before(e.windowEnds)) {
			id := ReportID(uid, in.TargetType, in.TargetID)
			open, err := s.d.Repo.IsOpen(ctx, id)
			if err != nil {
				return ReportResult{}, logger.RedactErr(fmt.Errorf("moderation: report replay lookup: %w", err), uid)
			}
			if open {
				logger.SetRequestField(ctx, fieldOutcome, "duplicate")
				return ReportResult{ReportID: id, AlreadyReported: true}, nil
			}
			return ReportResult{}, quota.ExceededError(quota.Reports, now)
		}
		s.exhausted.Delete(uid)
	}

	// The reporter's own profile (cache-first; the interceptor just warmed it) decides the new-account quota.
	profiles, err := s.d.Directory.GetProfiles(ctx, []string{uid})
	if err != nil {
		return ReportResult{}, logger.RedactErr(fmt.Errorf("moderation: load reporter: %w", err), uid)
	}
	me, ok := profiles[uid]
	if !ok {
		return ReportResult{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "create a profile first")
	}

	rep := Report{
		ID: ReportID(uid, in.TargetType, in.TargetID), ReporterID: uid, TargetType: in.TargetType, TargetID: in.TargetID,
		Reason: in.Reason, Note: note, Status: StatusOpen, CreatedAt: s.d.Now().UTC(),
	}
	switch in.TargetType {
	case TargetPost:
		// GetForViewer applies ADR-0010 D6 (missing, deleted, hidden, blocked author, non-ACTIVE author => the one
		// NOT_FOUND), so a reporter cannot probe for any of those.
		p, err := s.d.Posts.GetForViewer(ctx, uid, in.TargetID)
		if err != nil {
			return ReportResult{}, err
		}
		if p.AuthorID == uid {
			return ReportResult{}, apierr.Validation("target_id", "you cannot report your own post")
		}
		rep.TargetOwnerID = p.AuthorID
		rep.Evidence = &Evidence{Text: p.Text, AuthorHandle: p.Author.Handle, PostCreatedAt: p.CreatedAt, MediaIDs: mediaIDs(p.Media)}
	case TargetAccount:
		prof, err := s.d.Accounts.GetProfile(ctx, uid, identity.ProfileTarget{UserID: in.TargetID})
		if err != nil {
			return ReportResult{}, err
		}
		rep.TargetOwnerID = prof.UserID
	}

	limit := s.d.ReportsPerDay
	var windowEnds time.Time
	if !me.CreatedAt.IsZero() && s.d.Now().Sub(me.CreatedAt) < s.d.NewAccountWindow {
		limit = s.d.NewAccountReportsPerDay
		windowEnds = me.CreatedAt.Add(s.d.NewAccountWindow)
	}
	cr, err := s.d.Repo.Create(ctx, CreateParams{Report: rep, QuotaLimit: limit})
	logger.SetRequestField(ctx, fieldTxn, cr.Attempts)
	if err != nil {
		var ae *apierr.Error
		if errors.As(err, &ae) {
			if ae.Reason == commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED {
				now := s.d.Now()
				s.exhausted.Set(uid, exhaustion{until: now.Add(quota.UntilNextDay(now)), windowEnds: windowEnds})
			}
			return ReportResult{}, err // quota exceeded and other already-shaped errors
		}
		return ReportResult{}, logger.RedactErr(fmt.Errorf("moderation: report: %w", err), uid)
	}
	switch {
	case cr.Existing:
		logger.SetRequestField(ctx, fieldOutcome, "duplicate")
	case cr.Reopened:
		logger.SetRequestField(ctx, fieldOutcome, "reopened")
	default:
		logger.SetRequestField(ctx, fieldOutcome, "created")
	}
	return ReportResult{ReportID: rep.ID, AlreadyReported: cr.Existing}, nil
}

// mediaIDs are the ids of the post's images (0 reads: the post is already loaded), nil for a text-only post.
func mediaIDs(m []posts.MediaRef) []string {
	if len(m) == 0 {
		return nil
	}
	ids := make([]string, len(m))
	for i, r := range m {
		ids[i] = r.ID
	}
	return ids
}

// normalizeNote is the note rule from the proto: CRLF/CR -> LF, NFC, trim, <= MaxNoteRunes code points, no
// control characters other than LF, no bidi formatting controls. An empty note is allowed.
func normalizeNote(raw string) (string, error) {
	if !utf8.ValidString(raw) {
		return "", apierr.Validation("note", "note must be valid UTF-8")
	}
	s := strings.ReplaceAll(raw, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	s = strings.ReplaceAll(s, "\t", " ")
	s = strings.TrimSpace(norm.NFC.String(s))
	for _, r := range s {
		if r != '\n' && (unicode.Is(unicode.Cc, r) || isBidiControl(r)) {
			return "", apierr.Validation("note", "note contains a disallowed control character")
		}
	}
	if utf8.RuneCountInString(s) > MaxNoteRunes {
		return "", apierr.Validation("note", "note must be at most 500 characters")
	}
	return s, nil
}

func isBidiControl(r rune) bool {
	return (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069)
}

// noteRejected records outcome=rejected:<reason> for an error returned by an RPC.
func noteRejected(ctx context.Context, err error) {
	reason := "error"
	var ae *apierr.Error
	if errors.As(err, &ae) {
		switch {
		case ae.Reason == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED:
			reason = "feature_disabled"
			logger.SetRequestField(ctx, "feature_disabled", true)
		case ae.Reason == commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED:
			reason = "quota_exceeded"
		case ae.Reason == commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED:
			reason = "email_not_verified"
		case ae.Code == connect.CodeInvalidArgument:
			reason = "invalid"
		case ae.Code == connect.CodeNotFound:
			reason = "not_found"
		}
	}
	logger.SetRequestField(ctx, fieldOutcome, "rejected:"+reason)
}
