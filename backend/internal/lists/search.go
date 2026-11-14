package lists

// search.go is the lists half of SearchLists (F20, FEATURE_SEARCH_LISTS): public lists whose folded name starts with a folded
// prefix. The search module owns the RPC, its flags and the query grammar; it reaches this file only through Service.SearchLists,
// never the lists collection. The rows are the DiscoverLists rows: the query reads isPrivate == false only (a private list is
// never read), and resolveList applies the GetList rules per row with the viewer's own lists left out.

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

const (
	// SearchPageDefault and SearchPageMax bound one SearchLists page (page_size 0 => 20, clamped to 20).
	SearchPageDefault = 20
	SearchPageMax     = 20

	fieldSearchRows    = "rows"
	fieldSearchDropped = "rows_dropped"
)

// NameAnchor is the position after which a SearchLists page starts: the last list the previous page's query returned.
type NameAnchor struct {
	NameLower string
	ListID    string
}

// SearchListsPage is one SearchLists page in folded-name order. A page may be short while NextPageToken is set (rows the viewer
// may not see are skipped, never replaced).
type SearchListsPage struct {
	Views         []View
	NextPageToken string
}

// SearchPageSize clamps a page size: 0 (and anything below 1) => SearchPageDefault, above SearchPageMax => SearchPageMax. A
// negative size is the caller's VALIDATION, decided before this.
func SearchPageSize(n int32) int {
	switch {
	case n <= 0:
		return SearchPageDefault
	case n > SearchPageMax:
		return SearchPageMax
	}
	return int(n)
}

// searchBinding ties a page token to the viewer and the folded prefix. The prefix is hashed so a name holding '|' can never
// make two bindings equal.
func searchBinding(viewer, prefix string) string {
	sum := sha256.Sum256([]byte(prefix))
	return "lists|search|" + viewer + "|" + hex.EncodeToString(sum[:16])
}

// searchTokenDoc is the token payload: version, the base64url folded name (a name may hold ':' or '|'), the list id.
func searchTokenDoc(a NameAnchor) string {
	return tokenVersion + ":" + base64.RawURLEncoding.EncodeToString([]byte(a.NameLower)) + ":" + a.ListID
}

func (s *service) decodeNameAnchor(binding, token string) (*NameAnchor, error) {
	cur, ok, err := s.openToken(binding, token)
	if err != nil || !ok {
		return nil, err
	}
	parts := strings.Split(cur.DocID, ":")
	if len(parts) != 3 || parts[0] != tokenVersion || !ids.ValidPostID(parts[2]) {
		return nil, errPageToken()
	}
	name, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errPageToken()
	}
	return &NameAnchor{NameLower: string(name), ListID: parts[2]}, nil
}

// SearchLists implements Service. Order: the sealed token (before any read; a token for another viewer or prefix fails to open),
// one query of at most SearchPageSize public lists in [prefix, prefix+U+10FFFF), then resolveList per row (the owner's profile and
// graph, cache-first; the viewer's graph once, cached) with the DiscoverLists drops (every GetList refusal, the viewer's own
// lists, an owner the viewer blocks), then one batched follow-marker read for the kept rows. The token is issued from the last
// QUERIED row whenever the query returned a full page, so a dropped row never stalls the chain.
//
// prefix must already be folded and validated (namekey.Query): an empty prefix is refused here too, so no caller can turn this
// into a scan of every public list.
func (s *service) SearchLists(ctx context.Context, viewer, prefix string, pageSize int32, token string) (SearchListsPage, error) {
	begin(ctx, "search")
	if err := s.sealed(); err != nil {
		return SearchListsPage{}, mapErr(ctx, "search", viewer, "", err)
	}
	if prefix == "" || prefix != namekey.Fold(prefix) {
		return SearchListsPage{}, mapErr(ctx, "search", viewer, "", errors.New("lists: search prefix is not a folded, non-empty query"))
	}
	binding := searchBinding(viewer, prefix)
	anchor, err := s.decodeNameAnchor(binding, token)
	if err != nil {
		return SearchListsPage{}, mapErr(ctx, "search", viewer, "", err)
	}
	limit := SearchPageSize(pageSize)
	rows, err := s.d.Repo.SearchByName(ctx, prefix, anchor, limit)
	if err != nil {
		return SearchListsPage{}, mapErr(ctx, "search", viewer, "", err)
	}
	var page SearchListsPage
	var visible []string
	for _, l := range rows {
		if l.IsPrivate { // the query excludes them; a fake or a race must never leak one
			continue
		}
		a, err := s.resolveList(ctx, viewer, l, true)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return SearchListsPage{}, mapErr(ctx, "search", viewer, l.ID, err)
		}
		if a.isOwner || a.viewerSnap.Blocked[a.list.OwnerID] {
			continue
		}
		page.Views = append(page.Views, a.view())
		visible = append(visible, l.ID)
	}
	logger.SetRequestField(ctx, fieldSearchRows, len(page.Views))
	logger.SetRequestField(ctx, fieldSearchDropped, len(rows)-len(page.Views))
	if len(visible) > 0 {
		followed, err := s.FollowedAmong(ctx, viewer, visible)
		if err != nil {
			return SearchListsPage{}, mapErr(ctx, "search", viewer, "", err)
		}
		for i := range page.Views {
			page.Views[i].FollowedByViewer = followed[page.Views[i].Header.ID]
		}
	}
	if len(rows) == limit {
		last := rows[len(rows)-1]
		a := NameAnchor{NameLower: namekey.Fold(last.Name), ListID: last.ID}
		if last.NameLower != "" {
			a.NameLower = last.NameLower
		}
		page.NextPageToken = cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: s.now(), DocID: searchTokenDoc(a)}, s.now())
	}
	return page, nil
}
