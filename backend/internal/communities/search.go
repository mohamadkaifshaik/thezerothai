package communities

// search.go is the communities half of SearchCommunities (F21, FEATURE_SEARCH_LISTS): ACTIVE communities whose folded name starts
// with a folded prefix. The search module owns the RPC, its flags and the query grammar and reaches this file only through
// Service.SearchCommunities. The rows follow the directory rules (ListCommunities): ACTIVE only (the query has
// status == ACTIVE, so a SUSPENDED or ARCHIVED community is never read), no block filtering (D7), the caller's role per row.

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

const (
	// SearchPageDefault and SearchPageMax bound one SearchCommunities page (page_size 0 => 20, clamped to 20).
	SearchPageDefault = 20
	SearchPageMax     = 20

	searchTokenVersion = "v1"
)

// NameAnchor is the position after which a SearchCommunities page starts: the last community of the previous page.
type NameAnchor struct {
	NameLower   string
	CommunityID string
}

// SearchPage is one SearchCommunities page in folded-name order.
type SearchPage struct {
	Views         []View
	NextPageToken string
}

// SearchPageSize clamps a page size: anything below 1 => SearchPageDefault, above SearchPageMax => SearchPageMax.
func SearchPageSize(n int32) int {
	switch {
	case n <= 0:
		return SearchPageDefault
	case n > SearchPageMax:
		return SearchPageMax
	}
	return int(n)
}

func searchBinding(uid, prefix string) string {
	sum := sha256.Sum256([]byte(prefix))
	return "communities|search|" + uid + "|" + hex.EncodeToString(sum[:16])
}

func searchTokenDoc(a NameAnchor) string {
	return searchTokenVersion + ":" + base64.RawURLEncoding.EncodeToString([]byte(a.NameLower)) + ":" + a.CommunityID
}

func decodeNameAnchor(key []byte, binding, token string, now func() time.Time) (*NameAnchor, error) {
	if token == "" {
		return nil, nil
	}
	cur, err := cursor.DecodeAt(key, binding, token, now())
	if err != nil || cursor.IsFirstPage(cur) {
		return nil, errPageToken()
	}
	parts := strings.Split(cur.DocID, ":")
	if len(parts) != 3 || parts[0] != searchTokenVersion || !ids.ValidPostID(parts[2]) {
		return nil, errPageToken()
	}
	name, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errPageToken()
	}
	return &NameAnchor{NameLower: string(name), CommunityID: parts[2]}, nil
}

// SearchCommunities implements Service. Order: the sealed token (before any read), one query of at most SearchPageSize ACTIVE
// communities in [prefix, prefix+U+10FFFF), then the caller's memberships (cached 60 s) for viewer_role. A row that is not ACTIVE
// (a fake, or a status change racing the query) is dropped. The token is issued whenever the query returned a full page.
//
// prefix must already be folded and validated (namekey.Query); an empty or unfolded prefix is refused.
func (s *service) SearchCommunities(ctx context.Context, uid, prefix string, pageSize int32, token string) (SearchPage, error) {
	begin(ctx, "search")
	if len(s.d.CursorKey) == 0 {
		return SearchPage{}, mapErr(ctx, "search", uid, "", errors.New("communities: page tokens are not wired (no CursorKey)"))
	}
	if prefix == "" || prefix != namekey.Fold(prefix) {
		return SearchPage{}, mapErr(ctx, "search", uid, "", errors.New("communities: search prefix is not a folded, non-empty query"))
	}
	binding := searchBinding(uid, prefix)
	anchor, err := decodeNameAnchor(s.d.CursorKey, binding, token, s.now)
	if err != nil {
		return SearchPage{}, mapErr(ctx, "search", uid, "", err)
	}
	limit := SearchPageSize(pageSize)
	rows, err := s.d.Repo.SearchByName(ctx, prefix, anchor, limit)
	if err != nil {
		return SearchPage{}, mapErr(ctx, "search", uid, "", err)
	}
	var page SearchPage
	if len(rows) > 0 {
		ms, err := s.membershipsCached(ctx, uid)
		if err != nil {
			return SearchPage{}, mapErr(ctx, "search", uid, "", err)
		}
		joined, banned := setOf(ms.Joined), setOf(ms.Banned)
		for _, c := range rows {
			if c.Status != StatusActive {
				continue
			}
			page.Views = append(page.Views, View{Community: c, Role: viewerRole(c, uid, joined, banned)})
		}
	}
	logger.SetRequestField(ctx, "rows", len(page.Views))
	if len(rows) == limit {
		last := rows[len(rows)-1]
		a := NameAnchor{NameLower: last.NameLower, CommunityID: last.ID}
		if a.NameLower == "" {
			a.NameLower = namekey.Fold(last.Name)
		}
		now := s.now()
		page.NextPageToken = cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: now, DocID: searchTokenDoc(a)}, now)
	}
	return page, nil
}

// viewerRole is the directory's role rule: OWNER and MODERATOR from the community document, else BANNED or MEMBER from the
// caller's memberships, else none.
func viewerRole(c Community, uid string, joined, banned map[string]bool) Role {
	role := c.RoleOf(uid)
	switch {
	case role != RoleNone:
	case banned[c.ID]:
		role = RoleBanned
	case joined[c.ID]:
		role = RoleMember
	}
	return role
}

// WireCommunity renders a View as the light Community header for another module's handler (search.SearchCommunities).
func WireCommunity(v View) *communitiesv1.Community { return toProtoCommunity(v) }
