package communities

import (
	"context"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// Directory is the listing seam of ListCommunities: the ranked list of ACTIVE communities, most members first, shared by
// every viewer of this instance. The Stage 0 implementation is one Firestore query behind a 5 minute instance entry; the W4 discovery
// engine replaces it behind this interface without touching the handler or the viewer-role logic.
type Directory interface {
	// Top returns at most DirectoryMax ACTIVE communities, memberCount descending, with whether the entry was already warm. The
	// slice is the caller's to keep. Staleness bound: DirectoryTTL (5 minutes), so a suspension, an archive or a new community reaches the
	// list within 5 minutes on every instance.
	Top(ctx context.Context) (ranked []Community, warm bool, err error)
}

// DirectoryMax is the Limit of the directory query (50, the platform maximum).
const DirectoryMax = 50

// DirectoryTTL is the staleness bound of the shared directory entry.
const DirectoryTTL = 5 * time.Minute

// MemberFilter selects the rows of ListCommunityMembers (named after the member doc's state, not a role).
type MemberFilter int

const (
	// FilterJoined lists JOINED members, the owner and moderators included (the proto's UNSPECIFIED and JOINED).
	FilterJoined MemberFilter = iota
	// FilterBanned lists BANNED users; the owner and moderators only.
	FilterBanned
	// FilterModerators lists the owner and the moderators (the community document's roles, F24); the owner and moderators
	// only.
	FilterModerators
)

// String is the filter's name in a cursor binding and a log line.
func (f MemberFilter) String() string {
	switch f {
	case FilterBanned:
		return "banned"
	case FilterModerators:
		return "moderators"
	}
	return "joined"
}

// MemberEntry is one member doc as the batch read sees it: its state and the time of that state (joinedAt for JOINED,
// bannedAt for BANNED).
type MemberEntry struct {
	State MemberState
	At    time.Time
}

// MembersInput is a ListCommunityMembers request after the transport layer. PageSize 0 is the default (20), over 50 is clamped.
type MembersInput struct {
	CommunityID string
	Filter      MemberFilter
	PageSize    int32
	PageToken   string
}

// MemberItem is one row of a member page: the live profile, the caller's relationship, the row's role and since (joinedAt, or bannedAt
// on the banned page).
type MemberItem struct {
	Profile      identity.Profile
	Since        time.Time
	Relationship graph.Relationship
	Role         Role
}

// MembersPage is one page of ListCommunityMembers. A page may be short (dropped rows) while NextPageToken is set.
type MembersPage struct {
	Items         []MemberItem
	NextPageToken string
}

// MemberRow is one communityMembers document as the member page query returns it: the uid (the doc id) and joinedAt or bannedAt.
type MemberRow struct {
	UID string
	At  time.Time
}

// MembersQuery is one member page query (`ORDER BY joinedAt|bannedAt DESC, __name__ DESC LIMIT n`). After is the last row of the
// previous page (At, UID); nil is the first page.
type MembersQuery struct {
	CommunityID string
	Banned      bool
	Limit       int
	After       *cursor.Cursor
}
