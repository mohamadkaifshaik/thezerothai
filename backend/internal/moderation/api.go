// Package moderation owns reports/{reportId} (ADR-0016, plan docs/plans/reports.md). It exposes Service (the
// Connect handler's dependency: ReportContent), Ops (the moderator-facing list/show/resolve that opsctl uses; there
// are no moderator RPCs at Stage 0) and the Eraser/Exporter seams the account-lifecycle job joins.
//
// moderation depends on posts and identity only through the small consumer-side interfaces below
// (posts.Service.GetForViewer and identity.Service.GetProfile satisfy them), so it re-uses their visibility and
// block rules instead of repeating them (reuse-first, ADR-0002).
package moderation

import (
	"context"
	"errors"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// TargetType is what a report is about. The doc stores the upper-case name.
type TargetType string

const (
	TargetPost    TargetType = "POST"
	TargetAccount TargetType = "ACCOUNT"
)

// Reason mirrors moderationv1.ReportReason without its prefix.
type Reason string

const (
	ReasonSpam          Reason = "SPAM"
	ReasonHarassment    Reason = "HARASSMENT"
	ReasonHate          Reason = "HATE"
	ReasonViolence      Reason = "VIOLENCE"
	ReasonSexual        Reason = "SEXUAL"
	ReasonSelfHarm      Reason = "SELF_HARM"
	ReasonIllegal       Reason = "ILLEGAL"
	ReasonImpersonation Reason = "IMPERSONATION"
	ReasonOther         Reason = "OTHER"
)

// Status of a report.
type Status string

const (
	StatusOpen     Status = "OPEN"
	StatusResolved Status = "RESOLVED"
)

// Resolution is how a moderator closed a report.
type Resolution string

const (
	ResolutionNoAction  Resolution = "NO_ACTION"
	ResolutionDismissed Resolution = "DISMISSED"
	ResolutionTakedown  Resolution = "TAKEDOWN"
	ResolutionSuspended Resolution = "SUSPENDED"
	// ResolutionProfileCleared closes a report about an account whose profile fields an operator cleared with `opsctl
	// clear-profile-fields --report` (ADR-0024 Amendment 1 A3). A Go and Firestore string only; no proto carries it.
	ResolutionProfileCleared Resolution = "PROFILE_CLEARED"
)

// Valid reports whether r is one of the five resolutions.
func (r Resolution) Valid() bool {
	switch r {
	case ResolutionNoAction, ResolutionDismissed, ResolutionTakedown, ResolutionSuspended, ResolutionProfileCleared:
		return true
	}
	return false
}

// Limits.
const (
	// MaxNoteRunes is the longest report note, in code points (ADR-0016 D1).
	MaxNoteRunes = 500
	// Retention is how long a resolved report is kept before the Firestore TTL deletes it (ADR-0016 D5).
	Retention = 90 * 24 * time.Hour
	// MessageEvidenceRetention is how long the copied text of a MESSAGE report is kept (ADR-0016 note 2026-10-30, security
	// L-6, W7-36): the child document reports/{id}/evidence/message carries expireAt = filing + 180 days and a Firestore TTL
	// deletes it, open or not; resolving the report shortens it to at most resolvedAt + Retention. The report itself stays.
	MessageEvidenceRetention = 180 * 24 * time.Hour
	// MaxListLimit is the largest page of Ops.List (CLAUDE.md rule 5: every query Limit <= 50).
	MaxListLimit = 50
	// DefaultListLimit is the default page of Ops.List.
	DefaultListLimit = 20
)

// Evidence is the copy of the reported post (or, for an ACCOUNT report, of the reported profile) taken at report time, so
// a later author delete or edit does not destroy it. MediaIDs are the ids of the post's images at report time (0 reads:
// they ride on the post the report already read). Deleting the post deletes the objects (P4's post_delete job), so this keeps the ids only; see
// docs/runbooks/moderation.md for what a takedown does and does not preserve.
//
// A MESSAGE report (ADR-0027 D12) keeps that one message: Text is its text (private content, ADR-0016 note 2026-10-28),
// AuthorHandle the sender's handle ("" when the sender is no longer ACTIVE), PostCreatedAt the time it was sent (the
// stored field keeps its name; no new field). MediaIDs is empty. Nothing else of the conversation is copied.
type Evidence struct {
	Text          string
	AuthorHandle  string
	MediaIDs      []string
	PostCreatedAt time.Time
	// OriginalPostID is set only when the reported post was a REPOST: the fields above then describe the ORIGINAL
	// post (from the repost's frozen Embedded snapshot, 0 extra reads) and this is its id, the id takedown-post
	// takes. "" for every other report. TargetOwnerID still names the reposter.
	OriginalPostID string
	// ACCOUNT reports only (ADR-0024 Amendment 1 A3(b)): the reported profile as the reporter saw it (the presented view,
	// so no website while FEATURE_PROFILE_EXTRAS is globally off), copied from the profile the report already loaded (0
	// extra reads). AuthorHandle above holds the handle; Text, MediaIDs and PostCreatedAt stay empty. None of these
	// holds a uid (media URLs are m/{mediaId}). Empty for every POST report.
	DisplayName string
	Bio         string
	Location    string
	Website     string
	AvatarURL   string
	BannerURL   string
	// PollChoices are the labels of the reported post's poll (ADR-0029 D8), empty for a post without one; for a REPOST report they are
	// the original's (from its frozen embed). Labels only: no counts, no voters.
	PollChoices []string
	// TextExpired is set only by Ops.Get on a MESSAGE report whose child evidence document is gone (its TTL ran, W7-36):
	// Text is then empty because the copy was deleted, not because the message was empty. Never stored.
	TextExpired bool
}

// Report is the domain form of reports/{reportId}. ReporterID is "" after the reporter's account was deleted.
type Report struct {
	ID             string
	ReporterID     string
	TargetType     TargetType
	TargetID       string
	TargetOwnerID  string
	Reason         Reason
	Note           string
	Status         Status
	Evidence       *Evidence
	CreatedAt      time.Time
	ResolvedAt     time.Time
	Resolution     Resolution
	ResolutionNote string
	ExpireAt       time.Time
}

// ReportInput is the ReportContent request at the domain layer (server.go converts from the proto).
type ReportInput struct {
	IdempotencyKey string
	TargetType     TargetType
	TargetID       string
	Reason         Reason
	Note           string
}

// ReportResult is the ReportContent outcome.
type ReportResult struct {
	ReportID        string
	AlreadyReported bool
}

// Service is the Connect handler's dependency.
type Service interface {
	// Report records uid's report of one post, account or message. Firestore, worst case: caller profile (cached) 0-1,
	// POST: post 1 + author users 1 + caller graph 1 cold; ACCOUNT: target users 1 cold (+ graph); MESSAGE (ADR-0027 D12):
	// conversation 1 + message 1 + sender users 1 cold, so 3 reads of the lookup cold and 1 warm (the message is never
	// cached); then the transaction: report doc 1 + quotas 1. With the interceptor's own read the whole call is 6 reads
	// cold and 3 warm for a MESSAGE. Writes 2 (report, quotas); a repeat writes 0.
	Report(ctx context.Context, uid string, in ReportInput) (ReportResult, error)
}

// PostViewer is posts.Service's GetForViewer (ADR-0010 D6): the post as the caller sees it, or the one
// "post not found" error.
type PostViewer interface {
	GetForViewer(ctx context.Context, callerUID, postID string) (*posts.Post, error)
}

// AccountViewer is identity.Service's GetProfile (ADR-0008 D9): the profile as the caller sees it, or NOT_FOUND
// for a missing, non-ACTIVE or caller-blocking account.
type AccountViewer interface {
	GetProfile(ctx context.Context, callerUID string, target identity.ProfileTarget) (identity.Profile, error)
}

// ErrNotFound is returned by Ops.Get and Ops.Resolve for a missing report.
var ErrNotFound = errors.New("moderation: report not found")

// Ops is the moderator-side seam opsctl uses (ADR-0016 D4).
type Ops interface {
	// List returns reports with the given status, oldest first, at most limit (clamped to 1..MaxListLimit).
	// Reads: len(result), minimum 1.
	List(ctx context.Context, status Status, limit int) ([]Report, error)
	// Get returns one report (ErrNotFound when missing). Reads 1; a MESSAGE report reads its evidence child too (2), and
	// Evidence.TextExpired says the child is gone (W7-36).
	Get(ctx context.Context, id string) (Report, error)
	// Resolve closes a report. Resolving an already RESOLVED report is a no-op that returns it unchanged
	// (0 writes). Reads 1, writes 1. A re-report after RESOLVED reopens the same document (Repo.Create).
	Resolve(ctx context.Context, id string, res Resolution, note string, now time.Time) (Report, error)
}

// Checkpoint resumes Eraser.PurgeReporter. Progress only: the purge is self-resuming because a cleared report no
// longer matches the query.
type Checkpoint struct {
	// Cleared counts reports anonymised so far across calls.
	Cleared int
}

// Eraser is moderation's step in the account-deletion cascade (ADR-0011 Q1, ADR-0016 D5). It anonymises the
// reports the account FILED (reporterId := ""); the reports stay as safety evidence about third-party content.
// Reports ABOUT the account are retained until resolved + 90 days and are a documented Q10 residue.
type Eraser interface {
	PurgeReporter(ctx context.Context, uid string, cp Checkpoint) (next Checkpoint, done bool, err error)
}

// Exporter writes the reports uid filed as one JSON object (never reports about the user: they would reveal
// their reporters).
type Exporter interface {
	ExportUser(ctx context.Context, uid string, w io.Writer) error
}
