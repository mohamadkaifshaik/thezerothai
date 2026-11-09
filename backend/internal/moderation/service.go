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

// FlagName is the wire name ModerationService RPCs check (FEATURE_REPORTS <-> "reports").
const FlagName = "reports"

// Request-log fields. Enums, counts and booleans only: never ids, handles, notes or evidence text.
const (
	fieldOp         = "moderation_op"
	fieldOutcome    = "outcome"
	fieldTargetType = "report_target"
	fieldReason     = "report_reason"
	fieldTxn        = "txn_attempts"
)

// postIDPattern is the post id shape.
var postIDPattern = regexp.MustCompile(`^[0-9]{19}$`)

// Deps is everything New needs.
type Deps struct {
	Repo      Repo
	Posts     PostViewer
	Accounts  AccountViewer
	Directory identity.Directory
	// Messages resolves a MESSAGE target; nil makes a message report an internal error.
	Messages MessageLookup
	// Lists resolves a LIST target; nil makes a list report an internal error.
	Lists ListLookup
	// Communities resolves a COMMUNITY target; nil makes a community report an internal error.
	Communities CommunityLookup
	// Beacons resolves a BEACON target; nil makes a beacon report an internal error.
	Beacons BeaconLookup
	// Articles snapshots the article behind a reported article root post; nil keeps only the post's frozen preview.
	Articles ArticleLookup
	// ReportsPerDay is the daily quota (config.QuotaConfig); NewAccountReportsPerDay applies inside NewAccountWindow.
	ReportsPerDay           int64
	NewAccountReportsPerDay int64
	NewAccountWindow        time.Duration
	// AllowAnonymous is set only from config.AuthEmulator (the posts convention).
	AllowAnonymous bool
	// Now is overridable for tests; nil means time.Now.
	Now func() time.Time
}

type service struct {
	d Deps
	// exhausted remembers, per instance, the uids whose reports quota was found spent, so a client that keeps
	// retrying an over-quota report costs only the replay lookup until the IST day rolls over.
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

// Report implements Service.
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
	case TargetPost, TargetAccount, TargetMessage, TargetList, TargetCommunity, TargetBeacon:
	default:
		return ReportResult{}, apierr.Validation("target_type", "target_type must be POST, ACCOUNT, MESSAGE, LIST, COMMUNITY or BEACON")
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
	case TargetMessage:
		if _, _, ok := ParseMessageTarget(in.TargetID); !ok {
			return ReportResult{}, apierr.Validation("target_id", "target_id must be a conversation id and a message id joined by a colon")
		}
	case TargetList:
		if !postIDPattern.MatchString(in.TargetID) { // a list id is a Snowflake, the same 19 digits as a post id
			return ReportResult{}, apierr.Validation("target_id", "target_id must be a 19-digit list id")
		}
	case TargetCommunity:
		if !postIDPattern.MatchString(in.TargetID) { // a community id is a Snowflake, the same 19 digits as a post id
			return ReportResult{}, apierr.Validation("target_id", "target_id must be a 19-digit community id")
		}
	case TargetBeacon:
		if !postIDPattern.MatchString(in.TargetID) { // a beacon id is a Snowflake, the same 19 digits as a post id
			return ReportResult{}, apierr.Validation("target_id", "target_id must be a 19-digit beacon id")
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
	// written and needs no quota) from a genuinely new or reopened report, which is QUOTA_EXCEEDED.
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
		// GetForViewer applies the post visibility rules (missing, deleted, hidden, blocked author, non-ACTIVE author => the one
		// NOT_FOUND), so a reporter cannot probe for any of those.
		p, err := s.d.Posts.GetForViewer(ctx, uid, in.TargetID)
		if err != nil {
			return ReportResult{}, err
		}
		if p.AuthorID == uid {
			return ReportResult{}, apierr.Validation("target_id", "you cannot report your own post")
		}
		rep.TargetOwnerID = p.AuthorID
		rep.Evidence = &Evidence{Text: p.Text, AuthorHandle: p.Author.Handle, PostCreatedAt: p.CreatedAt, MediaIDs: mediaIDs(p.Media), PollChoices: pollChoices(p.Poll)}
		// A REPOST carries no content of its own: the evidence is the original it embeds (already loaded).
		// TargetOwnerID stays the reposter. A tombstone or missing snapshot keeps the empty evidence above.
		if e := p.Embedded; p.Kind == posts.KindRepost && e != nil && !e.Unavailable && e.PostID != "" {
			rep.Evidence = &Evidence{Text: e.Text, AuthorHandle: e.Author.Handle, PostCreatedAt: e.CreatedAt,
				MediaIDs: mediaIDs(e.Media), OriginalPostID: e.PostID, PollChoices: embeddedPollChoices(e.Poll)}
		}
		if err := s.articleEvidence(ctx, uid, p, rep.Evidence); err != nil {
			return ReportResult{}, err
		}
	case TargetAccount:
		prof, err := s.d.Accounts.GetProfile(ctx, uid, identity.ProfileTarget{UserID: in.TargetID})
		if err != nil {
			return ReportResult{}, err
		}
		rep.TargetOwnerID = prof.UserID
		// Keep what the reporter saw, so the profile cannot be swapped before triage. prof is
		// already loaded (0 extra reads, the same single report write) and is the PRESENTED profile, so while
		// profile_extras is globally off it holds no website. No field here holds a uid (media URLs are m/{mediaId}).
		rep.Evidence = &Evidence{AuthorHandle: prof.Handle, DisplayName: prof.DisplayName, Bio: prof.Bio,
			Location: prof.Location, Website: prof.Website, AvatarURL: prof.AvatarURL, BannerURL: prof.BannerURL}
	case TargetMessage:
		m, err := s.reportedMessage(ctx, uid, in.TargetID)
		if err != nil {
			return ReportResult{}, err
		}
		// The evidence is that one message's text, the sender's handle and its time, and nothing else of
		// the conversation. The text is private content; it is never logged.
		rep.TargetOwnerID = m.SenderUID
		rep.Evidence = &Evidence{Text: m.Text, AuthorHandle: m.SenderHandle, PostCreatedAt: m.CreatedAt}
	case TargetList:
		l, err := s.reportedList(ctx, uid, in.TargetID)
		if err != nil {
			return ReportResult{}, err
		}
		// The list as the reporter saw it, so the owner cannot rename or empty it before triage. Name and description are public
		// text once the list is public (never a private list: the lookup refuses those), so they live in the report document
		// like an ACCOUNT report's profile and follow its retention. No member id is copied.
		rep.TargetOwnerID = l.OwnerUID
		rep.Evidence = &Evidence{AuthorHandle: l.OwnerHandle, ListName: l.Name, ListDescription: l.Description, PostCreatedAt: l.CreatedAt}
	case TargetCommunity:
		c, err := s.reportedCommunity(ctx, uid, in.TargetID)
		if err != nil {
			return ReportResult{}, err
		}
		// The community as the reporter saw it, so the owner cannot rename it or rewrite its rules before triage (D14). Public text, kept in
		// the report document like a LIST report; no member id, no moderator id, no child document. OwnerUID is "" for an ARCHIVED one.
		rep.TargetOwnerID = c.OwnerUID
		rules := make([]CommunityRule, len(c.Rules))
		copy(rules, c.Rules)
		rep.Evidence = &Evidence{AuthorHandle: c.OwnerHandle, CommunityName: c.Name, CommunityDescription: c.Description, CommunityRules: rules, PostCreatedAt: c.CreatedAt}
	case TargetBeacon:
		b, err := s.reportedBeacon(ctx, uid, in.TargetID)
		if err != nil {
			return ReportResult{}, err
		}
		// The beacon as the reporter saw it, so the organiser cannot rewrite it before triage (R16). Public text within the
		// beacon's audience, kept in the report document like a LIST report; no participant, no community id.
		rep.TargetOwnerID = b.OrganiserUID
		rep.Evidence = &Evidence{AuthorHandle: b.OrganiserHandle, BeaconTitle: b.Title, BeaconDetails: b.Details, BeaconVenue: b.Venue, PostCreatedAt: b.CreatedAt}
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

// reportedMessage asks the MessageLookup for the message of a MESSAGE target (already shape-checked). Every
// "unreportable" cause is the one NOT_FOUND built here, so the bytes never say which rule refused; the caller's own
// message is the VALIDATION target_id. Anything else is an internal error whose ids are redacted.
func (s *service) reportedMessage(ctx context.Context, uid, targetID string) (ReportedMessage, error) {
	if s.d.Messages == nil {
		return ReportedMessage{}, errors.New("moderation: message reports are not wired")
	}
	convID, msgID, _ := ParseMessageTarget(targetID)
	m, err := s.d.Messages.ReportableMessage(ctx, uid, convID, msgID)
	switch {
	case errors.Is(err, ErrOwnMessage):
		return ReportedMessage{}, apierr.Validation("target_id", "you cannot report your own message")
	case errors.Is(err, ErrMessageNotFound):
		return ReportedMessage{}, messageNotFound()
	case err != nil:
		return ReportedMessage{}, logger.RedactErrKeyed(fmt.Errorf("moderation: load message: %w", err), []string{convID, msgID}, uid) // the conversation id is guessable from a uid pair: keyed hash, never the plain one (L-7)
	}
	return m, nil
}

// mediaIDs are the ids of the post's images (the post is already loaded), nil for a text-only post.
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

// pollChoices are the labels of the reported post's poll (the post is loaded), nil without a poll.
func pollChoices(p *posts.Poll) []string {
	if p == nil {
		return nil
	}
	return append([]string(nil), p.Options...)
}

// embeddedPollChoices are the labels of a reposted post's frozen poll definition, nil without one.
func embeddedPollChoices(p *posts.EmbeddedPoll) []string {
	if p == nil {
		return nil
	}
	return append([]string(nil), p.Options...)
}

// reportedList asks the ListLookup for the list of a LIST target (already shape-checked). Every "unreportable" cause is the
// one NOT_FOUND built here (a private list the caller cannot see answers like a missing one); the caller's own list is the
// VALIDATION target_id. Anything else is an internal error whose ids are redacted.
func (s *service) reportedList(ctx context.Context, uid, listID string) (ReportedList, error) {
	if s.d.Lists == nil {
		return ReportedList{}, errors.New("moderation: list reports are not wired")
	}
	l, err := s.d.Lists.ReportableList(ctx, uid, listID)
	return mapTargetLookup(l, err, uid, listID, "list", ErrOwnList, ErrListNotFound, listNotFound)
}

// reportedCommunity asks the CommunityLookup for the community of a COMMUNITY target (already shape-checked). A missing and a SUSPENDED
// community are the one NOT_FOUND built here; the caller's own community is the VALIDATION target_id. Anything else is an internal
// error whose ids are redacted.
func (s *service) reportedCommunity(ctx context.Context, uid, communityID string) (ReportedCommunity, error) {
	if s.d.Communities == nil {
		return ReportedCommunity{}, errors.New("moderation: community reports are not wired")
	}
	c, err := s.d.Communities.ReportableCommunity(ctx, uid, communityID)
	return mapTargetLookup(c, err, uid, communityID, "community", ErrOwnCommunity, ErrCommunityNotFound, communityNotFound)
}

// reportedBeacon asks the BeaconLookup for the beacon of a BEACON target (already shape-checked). Every "unreportable" cause is
// the one NOT_FOUND built here; the caller's own beacon is the VALIDATION target_id. Anything else is an internal error whose
// ids are redacted.
func (s *service) reportedBeacon(ctx context.Context, uid, beaconID string) (ReportedBeacon, error) {
	if s.d.Beacons == nil {
		return ReportedBeacon{}, errors.New("moderation: beacon reports are not wired")
	}
	b, err := s.d.Beacons.ReportableBeacon(ctx, uid, beaconID)
	return mapTargetLookup(b, err, uid, beaconID, "beacon", ErrOwnBeacon, ErrBeaconNotFound, beaconNotFound)
}

// mapTargetLookup is the one answer table of a LIST, COMMUNITY or BEACON lookup: the caller's own target is VALIDATION target_id, every
// "unreportable" cause the one NOT_FOUND notFound builds, anything else an internal error with the ids redacted.
func mapTargetLookup[T any](v T, err error, uid, id, what string, errOwn, errNotFound error, notFound func() *apierr.Error) (T, error) {
	var zero T
	switch {
	case err == nil:
		return v, nil
	case errors.Is(err, errOwn):
		return zero, apierr.Validation("target_id", "you cannot report your own "+what)
	case errors.Is(err, errNotFound):
		return zero, notFound()
	}
	return zero, logger.RedactErr(fmt.Errorf("moderation: load %s: %w", what, err), id, uid)
}
