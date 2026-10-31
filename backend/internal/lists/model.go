package lists

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// Field limits of a list (ADR-0030 D2), in code points after trim and NFC.
const (
	MinNameRunes        = 1
	MaxNameRunes        = 25
	MaxDescriptionRunes = 100
)

// List is one lists/{listId} document as the module sees it (ADR-0030 D2). MemberIDs is in add order and has at most
// LIST_MAX_MEMBERS entries; there is no stored count (memberCount is len(MemberIDs)).
type List struct {
	ID          string
	OwnerID     string
	Name        string
	Description string
	IsPrivate   bool
	MemberIDs   []string
	// Hidden is the platform hide (opsctl, W5-29): absent in storage means false. The owner still sees a hidden list.
	Hidden    bool
	CreatedAt time.Time
	UpdatedAt time.Time
}

// Header is what a mutation's idempotency record keeps of a list, and so what a replay answers with: the fields of
// ListInfo that are the list's own (the owner row is read live, pinned_by_viewer is the caller's state now).
type Header struct {
	ID          string
	Name        string
	Description string
	IsPrivate   bool
	MemberCount int
}

// View is one list as the caller may see it: the header, the owner's live profile row (identity.Directory, cache-first)
// and whether the caller has it pinned as a Home tab.
type View struct {
	Header         Header
	Owner          identity.Profile
	PinnedByViewer bool
}

// CreateInput is a CreateList request after the transport layer: Key is the idempotency_key, IsPrivate nil means "not
// sent", which is private (F3).
type CreateInput struct {
	Key         string
	Name        string
	Description string
	IsPrivate   *bool
}

// UpdateInput is an UpdateList request: a nil field is unchanged.
type UpdateInput struct {
	Key         string
	ListID      string
	Name        *string
	Description *string
	IsPrivate   *bool
}

// Service is the write path of ListService that the handlers call (ADR-0030 D1, seam: handlers call only this). Later
// tickets add the member writes (W5-6) and the reads (W5-7) next to it.
type Service interface {
	// CreateList creates a list owned by uid. Firestore: reads 4 cold (interceptor, idempotency, quotas, count()) / 3
	// warm; writes 3 (list, idempotency, quotas); replay reads 2, writes 0; at the cap or the quota 0 writes.
	CreateList(ctx context.Context, uid string, in CreateInput) (View, error)
	// UpdateList changes the set fields of one of uid's lists; any other caller, a missing or a deleted list is the one
	// NOT_FOUND. Firestore: reads 3 cold / 2 warm (interceptor, idempotency, list), +1 when a pinned list is renamed
	// (Pins); writes 2 (list, idempotency), 1 when nothing changes; replay reads 2, writes 0.
	UpdateList(ctx context.Context, uid string, in UpdateInput) (View, error)
	// DeleteList deletes one of uid's lists; a list that is not uid's or does not exist is success with no effect.
	// Firestore: reads 3 (interceptor, idempotency, list), +1 when pinned (Pins); writes 1 (idempotency) + 1 when
	// pinned; deletes 1 (the list, Exists precondition); replay reads 2, writes 0.
	DeleteList(ctx context.Context, uid, key, listID string) error
}

// Pins is the consumer-side seam to the owner's pinned Home tabs on users/{uid}.homeTabs (ADR-0030 D1, D6). Identity
// implements it (W5-9) over the same adapter as timeline.HomeTabsStore; until then the service runs with a nil Pins and a
// pinned tab is cleaned up lazily by GetMe. Both calls run after the list's own commit and are best effort: a failure is
// logged and never fails the RPC. Neither signature names a timeline or lists type, so identity imports neither.
type Pins interface {
	// Unpin removes listID from uid's homeTabs (a field-level update, only when pinned; +1 read, +1 write when it is).
	Unpin(ctx context.Context, uid, listID string) error
	// Retitle sets the stored title of uid's pinned tab for listID to name and reports whether the list was pinned (+1
	// read, +1 write only when it is).
	Retitle(ctx context.Context, uid, listID, name string) (pinned bool, err error)
}

// IDSource issues list ids (a Snowflake node, rule 1). *snowflake.Node satisfies it.
type IDSource interface {
	Generate() string
}

// Outcome is how a repository write ended; the service logs it and decides whether to touch the cache.
type Outcome int

const (
	// Written: the documents changed.
	Written Outcome = iota
	// Replayed: the idempotency record already existed and answered; nothing was written.
	Replayed
	// Unchanged: only the idempotency document was written (nothing to change, a list that is not the caller's).
	Unchanged
)

// Errors of the repository, mapped to Connect codes by the service only.
var (
	// ErrNotFound is the one cause-blind answer for a list the caller cannot act on.
	ErrNotFound = errors.New("lists: list not found")
	// ErrListLimit: the owner is at LISTS_MAX_PER_USER lists.
	ErrListLimit = errors.New("lists: list limit reached")
	// ErrKeyReused: the idempotency key was used for a different request body.
	ErrKeyReused = errors.New("lists: idempotency key reused")
)

// CreateParams is one CreateList write.
type CreateParams struct {
	UID, ID, IdemKey, RequestHash string
	Name, Description             string
	IsPrivate                     bool
	MaxPerUser                    int
	QuotaLimit                    int64
}

// CreateResult is what Repo.Create answers. List is nil on a replay.
type CreateResult struct {
	Outcome Outcome
	Header  Header
	List    *List
}

// UpdateParams is one UpdateList write.
type UpdateParams struct {
	UID, ListID, IdemKey, RequestHash string
	Name, Description                 *string
	IsPrivate                         *bool
}

// UpdateResult is what Repo.Update answers. List is the stored list after the write and is nil on a replay.
type UpdateResult struct {
	Outcome     Outcome
	Header      Header
	List        *List
	NameChanged bool
}

// DeleteParams is one DeleteList write.
type DeleteParams struct {
	UID, ListID, IdemKey, RequestHash string
}

// DeleteResult is what Repo.Delete answers. Deleted is true only when this call removed the list.
type DeleteResult struct {
	Outcome Outcome
	Deleted bool
}

// Repo is the storage of the write path (FirestoreRepo in production). Every method is one transaction that reads the
// idempotency document first (a replay returns there) and writes it last.
type Repo interface {
	Create(ctx context.Context, p CreateParams) (CreateResult, error)
	Update(ctx context.Context, p UpdateParams) (UpdateResult, error)
	Delete(ctx context.Context, p DeleteParams) (DeleteResult, error)
}
