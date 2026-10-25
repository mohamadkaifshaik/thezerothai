// scheduled.go is the domain model of scheduled posts (ADR-0021 D4 and "Firestore model"): the document shape the
// repository stores at users/{uid}/scheduled/{scheduledId}, the deterministic document id, the path-shape check the
// publish sweep applies to collection-group results, and the opaque list cursor. It holds no request validation and
// no sweep logic: the Schedule/List/Cancel service and the sweep build on it in later changes.
package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
)

// ScheduledStatus is the lifecycle state of a scheduled post. The names are the stored strings and the proto enum
// names without the SCHEDULED_POST_STATUS_ prefix.
type ScheduledStatus string

const (
	ScheduledPending   ScheduledStatus = "PENDING"
	ScheduledPublished ScheduledStatus = "PUBLISHED"
	ScheduledCancelled ScheduledStatus = "CANCELLED"
	ScheduledFailed    ScheduledStatus = "FAILED"
)

// Valid reports whether s is one of the four stored statuses.
func (s ScheduledStatus) Valid() bool {
	switch s {
	case ScheduledPending, ScheduledPublished, ScheduledCancelled, ScheduledFailed:
		return true
	}
	return false
}

// ScheduledFailure is why an item is FAILED. The names are the stored strings and the proto enum names without the
// SCHEDULED_POST_FAILURE_ prefix.
type ScheduledFailure string

const (
	FailureMediaUnavailable  ScheduledFailure = "MEDIA_UNAVAILABLE"
	FailureQuotaExceeded     ScheduledFailure = "QUOTA_EXCEEDED"
	FailureAccountRestricted ScheduledFailure = "ACCOUNT_RESTRICTED"
	FailureInvalidContent    ScheduledFailure = "INVALID_CONTENT"
	FailureExpired           ScheduledFailure = "EXPIRED"
	FailureInternal          ScheduledFailure = "INTERNAL"
	FailureUnsupported       ScheduledFailure = "UNSUPPORTED"
)

// Valid reports whether f is one of the seven failure reasons.
func (f ScheduledFailure) Valid() bool {
	switch f {
	case FailureMediaUnavailable, FailureQuotaExceeded, FailureAccountRestricted, FailureInvalidContent,
		FailureExpired, FailureInternal, FailureUnsupported:
		return true
	}
	return false
}

const (
	// ScheduledSchemaVersion is the schemaVersion this revision writes. A sweep that reads a higher one fails the item
	// UNSUPPORTED instead of publishing a partial post, which keeps a revision rollback safe (ADR-0021 D4).
	ScheduledSchemaVersion = 1
	// ScheduledRPC scopes the document id (idempotency.Key(uid, ScheduledRPC, key)).
	ScheduledRPC = "SchedulePost"
	// ScheduledWindowRadius is the half-width of the per-author window cap: at most config.Scheduled.PerAuthorPerRun
	// PENDING items within +/-ScheduledWindowRadius of a new publish_at (review L-3; fixed by the ADR, not config).
	ScheduledWindowRadius = 4 * time.Minute
	// ScheduledDefaultPage and ScheduledMaxPage are the ListScheduledPosts page sizes (0 means the default; rule 5).
	ScheduledDefaultPage = 20
	ScheduledMaxPage     = MaxLimit
	// scheduledIDLen is the length of a scheduled id: 32 lower-case hex characters.
	scheduledIDLen = 32
)

// ScheduledDraft is the content to publish. It exists only while the item is PENDING: the transitions to PUBLISHED,
// CANCELLED and FAILED clear it (review L-2; founder decision 2026-10-24 for FAILED), so the post text lives in `posts`
// alone once published.
type ScheduledDraft struct {
	// Text is the normalised (NFC) post text.
	Text string
	// Media are the MediaRef copies from the media module with their alt texts; validated, not reserved.
	Media           []MediaRef
	ReplyPolicy     ReplyPolicy
	PaidPartnership bool
	MadeWithAI      bool
}

// ScheduledPost is one users/{uid}/scheduled/{id} document.
type ScheduledPost struct {
	// ID is the document id (32 hex); UID is the owner, taken from the path and never stored in the document.
	ID, UID       string
	SchemaVersion int
	// Draft is nil unless the item is PENDING (cleared on PUBLISHED, CANCELLED and FAILED).
	Draft *ScheduledDraft
	// PublishAt is UTC, truncated to the minute.
	PublishAt time.Time
	Status    ScheduledStatus
	// Failure is set when FAILED (and kept if a FAILED item is later dismissed).
	Failure ScheduledFailure
	// Attempts counts transient publish failures so far.
	Attempts int
	// PostID is set when PUBLISHED.
	PostID string
	// RequestHash is the one-way digest of the effective request, kept for replay detection.
	RequestHash string
	CreatedAt   time.Time
	UpdatedAt   time.Time
	// ExpireAt is the Firestore TTL deadline: nil while PENDING, otherwise the time the item left PENDING plus
	// SCHEDULED_TERMINAL_TTL.
	ExpireAt *time.Time
	// UpdateTime is the snapshot's last-update time, filled by reads. The sweep passes it back as the precondition of
	// a write outside the publish transaction; it is never stored.
	UpdateTime time.Time
}

// Ref returns the handle a precondition write needs.
func (p *ScheduledPost) Ref() ScheduledRef {
	return ScheduledRef{UID: p.UID, ID: p.ID, UpdateTime: p.UpdateTime}
}

// ScheduledRef identifies one scheduled doc together with the snapshot version a write is conditional on.
type ScheduledRef struct {
	UID, ID string
	// UpdateTime is the doc's last-update time as read; a write using it fails when the doc changed or vanished.
	UpdateTime time.Time
}

// ErrInvalidScheduledID is returned for a uid or idempotency key that cannot be part of a scheduled id.
var ErrInvalidScheduledID = errors.New("posts: invalid scheduled id input")

// ScheduledID derives the document id of a SchedulePost call: the first 32 hex characters of
// SHA-256(uid|"SchedulePost"|idempotency_key), the same natural-key pattern as reports/* (ADR-0021 D4, review L-6).
//
// The separator is safe by construction: a uid matches ^[A-Za-z0-9-]{1,128}$ and a key ^[A-Za-z0-9_-]{16,64}$, so
// neither can contain "|" and two different (uid, key) pairs never share a preimage. Anything else is refused here
// rather than hashed, so no caller can build a colliding id by skipping validation.
func ScheduledID(uid, key string) (string, error) {
	if !ids.ValidUID(uid) || !idempotency.KeyFormatValid(key) {
		return "", ErrInvalidScheduledID
	}
	return idempotency.Key(uid, ScheduledRPC, key)[:scheduledIDLen], nil
}

// ValidScheduledID reports whether id has the shape ^[0-9a-f]{32}$. RPC handlers answer VALIDATION for anything else
// before a read, and the sweep skips documents whose id does not match.
func ValidScheduledID(id string) bool {
	if len(id) != scheduledIDLen {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// ErrInvalidScheduledToken is returned for a malformed, expired, tampered or foreign page token. The service maps it
// to VALIDATION field=page_token.
var ErrInvalidScheduledToken = errors.New("posts: invalid scheduled page token")

// scheduledBinding is the context a ListScheduledPosts page token is bound to: "scheduled|<uid>" (ADR-0021 D4), so a
// token issued to one user opens nothing for another.
func scheduledBinding(uid string) string { return "scheduled|" + uid }

// EncodeScheduledPageToken seals the position after last (its publishAt and id) into an opaque token bound to uid.
func EncodeScheduledPageToken(key []byte, uid string, last *ScheduledPost, now time.Time) string {
	return cursor.EncodeAt(key, scheduledBinding(uid), cursor.Cursor{CreatedAt: last.PublishAt, DocID: last.ID}, now)
}

// DecodeScheduledPageToken opens token for uid. An empty token is the first page (nil position, nil error); a token
// issued for another uid, expired, tampered with or carrying a malformed id is ErrInvalidScheduledToken. Pure: 0 reads.
func DecodeScheduledPageToken(key []byte, uid, token string, now time.Time) (*Position, error) {
	cur, err := cursor.DecodeAt(key, scheduledBinding(uid), token, now)
	if err != nil || (token != "" && (cursor.IsFirstPage(cur) || !ValidScheduledID(cur.DocID))) {
		return nil, ErrInvalidScheduledToken
	}
	if token == "" {
		return nil, nil
	}
	return &Position{CreatedAt: cur.CreatedAt, ID: cur.DocID}, nil
}

// ScheduledLister is the read side of the user's list: status in [PENDING, FAILED], ordered by publishAt then id.
type ScheduledLister interface {
	// ListScheduled returns uid's PENDING and FAILED items strictly after `after` (nil = from the start), oldest
	// publishAt first, at most limit (1..MaxLimit). Reads: len(result), minimum 1.
	ListScheduled(ctx context.Context, uid string, after *Position, limit int) ([]*ScheduledPost, error)
}

// ScheduledPage is one page of ListScheduledPosts.
type ScheduledPage struct {
	Items         []*ScheduledPost
	NextPageToken string
}

// ScheduledPageSize applies the page-size rule: 0 (or less) means ScheduledDefaultPage, more than ScheduledMaxPage
// is clamped.
func ScheduledPageSize(n int) int {
	switch {
	case n <= 0:
		return ScheduledDefaultPage
	case n > ScheduledMaxPage:
		return ScheduledMaxPage
	}
	return n
}

// ListScheduledPage is the list read of ListScheduledPosts without the handler concerns: it opens the HMAC-bound
// token for uid, reads one page and seals the next token when the page was full. A short page has no next token.
// Reads: len(items), minimum 1; writes 0. A foreign or malformed token is rejected before any read.
func ListScheduledPage(ctx context.Context, repo ScheduledLister, key []byte, uid string, pageSize int, token string, now time.Time) (ScheduledPage, error) {
	after, err := DecodeScheduledPageToken(key, uid, token, now)
	if err != nil {
		return ScheduledPage{}, err
	}
	limit := ScheduledPageSize(pageSize)
	items, err := repo.ListScheduled(ctx, uid, after, limit)
	if err != nil {
		return ScheduledPage{}, fmt.Errorf("posts: list scheduled: %w", err)
	}
	page := ScheduledPage{Items: items}
	if len(items) >= limit {
		page.NextPageToken = EncodeScheduledPageToken(key, uid, items[len(items)-1], now)
	}
	return page, nil
}
