package lists

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// Field limits of a list, in code points after trim and NFC.
const (
	MinNameRunes        = 1
	MaxNameRunes        = 25
	MaxDescriptionRunes = 100
)

// List is one lists/{listId} document as the module sees it. MemberIDs is in add order and has at most
// LIST_MAX_MEMBERS entries; there is no stored count (memberCount is len(MemberIDs)).
type List struct {
	ID          string
	OwnerID     string
	Name        string
	Description string
	IsPrivate   bool
	MemberIDs   []string
	// Hidden is the platform hide (opsctl): absent in storage means false. The owner still sees a hidden list.
	Hidden bool
	// FollowerCount is lists/{id}.followerCount: the follow markers (listFollows) of this list, kept by the same transaction
	// that writes or removes a marker. Absent in storage means 0.
	FollowerCount int
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// Header is what a mutation's idempotency record keeps of a list, and so what a replay answers with: the fields of
// ListInfo that are the list's own (the owner row is read live, pinned_by_viewer is the caller's state now).
type Header struct {
	ID          string
	Name        string
	Description string
	IsPrivate   bool
	MemberCount int
	// FollowerCount is the stored follower count. A caller who may not see the count (FEATURE_LIST_FOLLOWS off) is answered 0 by
	// the handler, never here.
	FollowerCount int
}

// View is one list as the caller may see it: the header, the owner's live profile row (identity.Directory, cache-first)
// and whether the caller has it pinned as a Home tab.
type View struct {
	Header         Header
	Owner          identity.Profile
	PinnedByViewer bool
	// FollowedByViewer is whether the caller has a follow marker on the list. Set only by the reads that compute it
	// (GetList, ListUserLists, FollowList, ListFollowedLists, DiscoverLists); false otherwise.
	FollowedByViewer bool
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

// Service is everything the ListService handlers call (seam: handlers call only this): the write path
// and the reads. *service also implements Reader, the seam other modules use.
type Service interface {
	// CreateList creates a list owned by uid. A replay and a list at the cap write nothing.
	CreateList(ctx context.Context, uid string, in CreateInput) (View, error)
	// UpdateList changes the set fields of one of uid's lists; any other caller, a missing or a deleted list is the one
	// NOT_FOUND. A pinned list that is renamed is retitled (Pins). A request that changes nothing writes only the idempotency
	// document; a replay writes nothing.
	UpdateList(ctx context.Context, uid string, in UpdateInput) (View, error)
	// DeleteList deletes one of uid's lists; a list that is not uid's or does not exist is success with no effect.
	// A pinned list is also unpinned (Pins). The list is deleted with an Exists precondition; a replay writes nothing.
	DeleteList(ctx context.Context, uid, key, listID string) error
	// AddMember adds userID to one of uid's lists; any other caller or list is the one NOT_FOUND. The target checks
	// (ACTIVE, block either way, protected and not followed) run before the transaction from cache-first reads and are applied
	// only after the idempotency lookup misses, so a replay answers with the stored outcome. Already a member writes only the
	// idempotency document; a replay and a refused request write nothing.
	AddMember(ctx context.Context, uid, key, listID, userID string) (View, error)
	// RemoveMember removes userID from one of uid's lists; any other caller or list is the one NOT_FOUND. Not a member is
	// success with the idempotency document only. The caller graph is read (cache-first) only when a member is actually removed;
	// a replay writes nothing.
	RemoveMember(ctx context.Context, uid, key, listID, userID string) (View, error)
	// GetList returns one list as viewer may see it; any other case is the one NOT_FOUND. pinned_by_viewer is false until Pins
	// supplies the pin check.
	GetList(ctx context.Context, viewer, listID string) (View, error)
	// ListUserLists returns an owner's lists, oldest first: all of the caller's own, only public non-hidden ones of anyone else.
	ListUserLists(ctx context.Context, viewer string, in UserListsInput) (UserLists, error)
	// ListListMembers returns a page of the list's members, newest added first.
	ListListMembers(ctx context.Context, viewer, listID string, pageSize int32, pageToken string) (MembersPage, error)
	// FollowList follows a public list (FEATURE_LIST_FOLLOWS): NOT_FOUND for every invisible list, LIMIT_REACHED at the cap.
	FollowList(ctx context.Context, uid, key, listID string) (View, error)
	// UnfollowList removes the caller's follow; any list, visible or not. A list never followed is success.
	UnfollowList(ctx context.Context, uid, key, listID string) error
	// ListFollowedLists is the viewer's followed lists, newest follow first, skipping the ones the viewer can no longer see.
	ListFollowedLists(ctx context.Context, viewer string, pageSize int32, pageToken string) (FollowedListsPage, error)
	// DiscoverLists is public lists by follower count, most followed first.
	DiscoverLists(ctx context.Context, viewer string, pageSize int32, pageToken string) (DiscoverListsPage, error)
	// ListSuggestedMembers suggests people for a list the caller owns (FEATURE_LIST_SUGGESTIONS); owner only.
	ListSuggestedMembers(ctx context.Context, uid, listID string, maxResults int32) ([]identity.Profile, error)
	// FollowedAmong reports which of listIDs the viewer follows (one batched read).
	FollowedAmong(ctx context.Context, viewer string, listIDs []string) (map[string]bool, error)
}

// Pins is the consumer-side seam to the owner's pinned Home tabs on users/{uid}.homeTabs. Identity
// implements it over the same adapter as timeline.HomeTabsStore; without it the service runs with a nil Pins and a
// pinned tab is cleaned up lazily by GetMe. Both calls run after the list's own commit and are best effort: a failure is
// logged and never fails the RPC. Neither signature names a timeline or lists type, so identity imports neither.
type Pins interface {
	// Unpin removes listID from uid's homeTabs (a field-level update, only when pinned).
	Unpin(ctx context.Context, uid, listID string) error
	// Retitle sets the stored title of uid's pinned tab for listID to name and reports whether the list was pinned (it writes
	// only when it is).
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
	AddMember(ctx context.Context, p AddMemberParams) (MemberResult, error)
	RemoveMember(ctx context.Context, p RemoveMemberParams) (MemberResult, error)
	// Get reads lists/{id} outside any transaction: ErrNotFound when it does not exist. It does
	// not decide who may see the list; the service applies the list visibility rules.
	Get(ctx context.Context, id string) (List, error)
	// ListByOwner reads ownerId == owner ordered by list id, after the id `after` ("" = from the start), at most limit docs
	// (reads = docs returned, minimum 1). Private and hidden lists are returned; filtering is the service's.
	ListByOwner(ctx context.Context, owner, after string, limit int) ([]List, error)
	// Follow, Unfollow: one transaction each, see repo_follows.go.
	Follow(ctx context.Context, p FollowParams) (FollowResult, error)
	Unfollow(ctx context.Context, p UnfollowParams) (UnfollowResult, error)
	// FollowedPage reads uid's follow markers newest first, strictly older than before when it is set, at most limit.
	FollowedPage(ctx context.Context, viewer string, before *FollowAnchor, limit int) ([]FollowRow, error)
	// DiscoverPage reads public lists by follower count, most followed first, strictly after the anchor when set.
	DiscoverPage(ctx context.Context, after *DiscoverAnchor, limit int) ([]List, error)
	// FollowedAmong reads the viewer's markers for listIDs in one batched read.
	FollowedAmong(ctx context.Context, viewer string, listIDs []string) (map[string]bool, error)
}

// ErrMemberLimit and ErrProtected are the repository's refusals of AddMember (mapped to LIMIT_REACHED "list_members" and
// PROTECTED_ACCOUNT by the service). ErrNotFound doubles as the refusal for a target that is missing, not ACTIVE or in a block
// relationship with the owner: one answer for every cause, so the call is no block oracle.
var (
	ErrMemberLimit = errors.New("lists: member limit reached")
	ErrProtected   = errors.New("lists: protected account not followed")
)

// AddMemberParams is one AddListMember write. Refusal is the service's verdict on the target (nil, ErrNotFound or
// ErrProtected), computed before the transaction and applied after the idempotency lookup and the ownership check, so a replay
// still answers and a foreign list is NOT_FOUND whatever the target is. BlockedBy is the owner's blockedBy set (read-only) for
// the lazy drop of members who block the owner (F4).
type AddMemberParams struct {
	UID, ListID, TargetID, IdemKey, RequestHash string
	Refusal                                     error
	MaxMembers                                  int
	BlockedBy                                   map[string]bool
}

// RemoveMemberParams is one RemoveListMember write. BlockedBy loads the owner's blockedBy set for the lazy drop; the repository
// calls it only when it is going to write the list (a no-op remove and a replay never load it). A nil func or a nil set drops
// nobody.
type RemoveMemberParams struct {
	UID, ListID, TargetID, IdemKey, RequestHash string
	BlockedBy                                   func(ctx context.Context) map[string]bool
}

// MemberResult is what Repo.AddMember and Repo.RemoveMember answer. List is the stored list after the call (nil on a replay);
// Dropped counts members removed by the lazy drop in the same write.
type MemberResult struct {
	Outcome Outcome
	Header  Header
	List    *List
	Dropped int
}

// ListView is what lists.Reader.Get answers: the same shape as View (header, owner row). PinnedByViewer is always false from
// the Reader (only the GetList handler path fills it; see service.pinned).
type ListView = View

// ListMembers is what lists.Reader.Members answers: the header, the owner's live profile and the member uids after the
// owner-level drop (members who block the owner are gone for every viewer). Per-viewer drops (members the viewer blocks or
// mutes, who block the viewer, protected and not approved) are the caller's job, as on Home. MemberIDs is in add order
// (oldest first), a fresh slice the caller may keep.
type ListMembers struct {
	Header    Header
	Owner     identity.Profile
	MemberIDs []string
	// PinnedByViewer is whether the viewer has the list pinned as a Home tab (cache-first; the interceptor has usually loaded the viewer).
	PinnedByViewer bool
}

// Reader is the only way another module reads a list (timeline uses it). Every method applies the D3
// visibility rules for viewer and answers ErrNotFound (one sentinel, every cause) when viewer may not see the list.
// *service implements it; apiserver passes `listsSvc.(lists.Reader)`.
type Reader interface {
	// Get returns the list as viewer may see it. The list doc is cache-first (60 s); a non-owner
	// viewer also reads the caller's graph, the owner's profile and the owner's graph (each cache-first).
	Get(ctx context.Context, viewer, listID string) (ListView, error)
	// Members returns the member uids viewer may build a feed from, after the owner-level drop. Same lookups as Get plus the
	// owner viewer's own graph (cache-first).
	Members(ctx context.Context, viewer, listID string) (ListMembers, error)
	// OwnedBy returns uid's own lists (private ones included), oldest first, at most LISTS_MAX_PER_USER. One uncached query.
	OwnedBy(ctx context.Context, uid string) ([]List, error)
}

// UserListsInput is a ListUserLists request after the transport layer. OwnerID "" means the caller.
type UserListsInput struct {
	OwnerID, ContainsUserID string
	PageSize                int32
	PageToken               string
}

// UserLists is one page of an owner's lists: the views oldest first, the ids among them whose members include
// ContainsUserID (own lists only), and the opaque next token ("" = no more).
type UserLists struct {
	Lists         []View
	ContainingIDs []string
	NextPageToken string
}

// MembersPage is one page of ListListMembers: the rows newest added first, each with the viewer's relationship, and the
// opaque next token ("" = no more; a page may be short while it is set).
type MembersPage struct {
	Items         []graph.ListItem
	NextPageToken string
}
