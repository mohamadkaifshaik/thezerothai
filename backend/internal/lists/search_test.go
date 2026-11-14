package lists

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor/cursortest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

// searchRepoFake answers SearchByName from rows (already in folded-name order, as the index returns them) with the prefix range
// and the anchor applied in memory, and FollowedAmong from followed.
type searchRepoFake struct {
	*fakeRepo
	rows     []List
	followed map[string]bool
	prefixes []string
	anchors  []*NameAnchor
}

func (f *searchRepoFake) SearchByName(_ context.Context, prefix string, after *NameAnchor, limit int) ([]List, error) {
	f.prefixes = append(f.prefixes, prefix)
	f.anchors = append(f.anchors, after)
	var out []List
	for _, l := range f.rows {
		if !namekey.HasPrefix(l.NameLower, prefix) {
			continue
		}
		if after != nil && (l.NameLower < after.NameLower || (l.NameLower == after.NameLower && l.ID <= after.ListID)) {
			continue
		}
		out = append(out, l)
		if len(out) == limit {
			break
		}
	}
	return out, nil
}

func (f *searchRepoFake) FollowedAmong(_ context.Context, _ string, ids []string) (map[string]bool, error) {
	out := map[string]bool{}
	for _, id := range ids {
		out[id] = f.followed[id]
	}
	return out, nil
}

const (
	srchViewer  = "viewer-s"
	srchOwner   = "owner-s"
	srchPrivOwn = "owner-p" // protected owner
	srchGone    = "owner-g" // not ACTIVE
	srchBlocker = "owner-b" // blocks the viewer
	srchBlocked = "owner-x" // the viewer blocks them
)

func srchList(id, owner, name string) List {
	return List{ID: id, OwnerID: owner, Name: name, NameLower: namekey.Fold(name), CreatedAt: testNow}
}

func searchEnv(t *testing.T, rows []List, viewerSnap graph.Snapshot) (*service, *searchRepoFake) {
	t.Helper()
	repo := &searchRepoFake{fakeRepo: &fakeRepo{docs: map[string]List{}}, rows: rows, followed: map[string]bool{}}
	gone := active(srchGone, false)
	gone.Status = identity.AccountStatusSuspended
	profiles := map[string]identity.Profile{
		srchViewer: active(srchViewer, false), srchOwner: active(srchOwner, false), srchPrivOwn: active(srchPrivOwn, true),
		srchGone: gone, srchBlocker: active(srchBlocker, false), srchBlocked: active(srchBlocked, false),
	}
	g := &fakeGraph{snaps: map[string]graph.Snapshot{
		srchViewer:  viewerSnap,
		srchBlocker: {Blocked: set(srchViewer)},
	}}
	s := New(Deps{
		Repo: repo, Directory: fakeDirectory{profiles: profiles}, Graph: g, IDs: fixedIDs{}, Now: func() time.Time { return testNow },
		Limits:    Limits{MaxPerUser: 20, MaxMembers: 150, CacheEntries: 50},
		CursorKey: []byte("0123456789abcdef0123456789abcdef"),
	}).(*service)
	return s, repo
}

func ids19(n int) string {
	return "00000000000000001" + string(rune('0'+n/10)) + string(rune('0'+n%10))
}

func viewIDs(p SearchListsPage) []string {
	out := make([]string, len(p.Views))
	for i, v := range p.Views {
		out[i] = v.Header.ID
	}
	return out
}

// TestSearchLists_VisibilityMatrix: every DiscoverLists drop applies, a private row never leaks even if the repository returned
// one, and the kept rows carry followed_by_viewer.
func TestSearchLists_VisibilityMatrix(t *testing.T) {
	hidden := srchList(ids19(2), srchOwner, "Go hidden")
	hidden.Hidden = true
	private := srchList(ids19(3), srchOwner, "Go private")
	private.IsPrivate = true
	rows := []List{
		srchList(ids19(1), srchOwner, "Go devs"),
		hidden,
		private,
		srchList(ids19(4), srchPrivOwn, "Go protected"),
		srchList(ids19(5), srchGone, "Go gone"),
		srchList(ids19(6), srchBlocker, "Go blocker"),
		srchList(ids19(7), srchBlocked, "Go blocked"),
		srchList(ids19(8), srchViewer, "Go mine"),
		srchList(ids19(9), srchOwner, "Rust"),
	}
	tests := []struct {
		name string
		snap graph.Snapshot
		want []string
	}{
		{"stranger", graph.Snapshot{Blocked: set(srchBlocked)}, []string{ids19(1)}},
		{"follows the protected owner", graph.Snapshot{Blocked: set(srchBlocked), Following: set(srchPrivOwn)}, []string{ids19(1), ids19(4)}},
		{"blocked by the owner via viewer snapshot", graph.Snapshot{Blocked: set(srchBlocked), BlockedBy: set(srchOwner)}, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, repo := searchEnv(t, rows, tc.snap)
			repo.followed[ids19(1)] = true
			page, err := s.SearchLists(context.Background(), srchViewer, "go", 0, "")
			if err != nil {
				t.Fatal(err)
			}
			got := viewIDs(page)
			if len(got) != len(tc.want) {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("got %v, want %v", got, tc.want)
				}
			}
			if len(page.Views) > 0 && !page.Views[0].FollowedByViewer {
				t.Fatal("followed_by_viewer not set on a followed row")
			}
			if page.NextPageToken != "" {
				t.Fatal("a short query must not issue a token")
			}
		})
	}
}

// TestSearchLists_PagingAndTokens: a full query page issues a token from the last QUERIED row (dropped or not), the token resumes
// strictly after it, and a token is bound to the viewer and the prefix.
func TestSearchLists_PagingAndTokens(t *testing.T) {
	var rows []List
	for i := 1; i <= 5; i++ {
		rows = append(rows, srchList(ids19(i), srchOwner, "Go "+string(rune('a'+i))))
	}
	rows[1].Hidden = true // dropped but still the resume point when last
	s, repo := searchEnv(t, rows, graph.Snapshot{})
	ctx := context.Background()
	p1, err := s.SearchLists(ctx, srchViewer, "go", 2, "")
	if err != nil || len(p1.Views) != 1 || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %v, %q, %v", viewIDs(p1), p1.NextPageToken, err)
	}
	p2, err := s.SearchLists(ctx, srchViewer, "go", 2, p1.NextPageToken)
	if err != nil || len(p2.Views) != 2 || p2.Views[0].Header.ID != ids19(3) {
		t.Fatalf("page 2 = %v, %v", viewIDs(p2), err)
	}
	if a := repo.anchors[1]; a == nil || a.ListID != ids19(2) || a.NameLower != rows[1].NameLower {
		t.Fatalf("anchor = %+v", a)
	}
	for name, call := range map[string]func() error{
		"other prefix": func() error { _, err := s.SearchLists(ctx, srchViewer, "g", 2, p1.NextPageToken); return err },
		"other viewer": func() error { _, err := s.SearchLists(ctx, srchOwner, "go", 2, p1.NextPageToken); return err },
		"tampered": func() error {
			_, err := s.SearchLists(ctx, srchViewer, "go", 2, cursortest.Tamper(p1.NextPageToken))
			return err
		},
	} {
		if codeOf(call()) != connect.CodeInvalidArgument {
			t.Fatalf("%s: want VALIDATION page_token", name)
		}
	}
}

func TestSearchLists_RefusesAnUnfoldedPrefix(t *testing.T) {
	s, repo := searchEnv(t, nil, graph.Snapshot{})
	for _, p := range []string{"", "Go", " go"} {
		if _, err := s.SearchLists(context.Background(), srchViewer, p, 0, ""); err == nil {
			t.Fatalf("prefix %q accepted", p)
		}
	}
	if len(repo.prefixes) != 0 {
		t.Fatal("an unfolded prefix reached the repository")
	}
}

func TestSearchPageSize(t *testing.T) {
	for in, want := range map[int32]int{-1: 20, 0: 20, 1: 1, 20: 20, 21: 20} {
		if got := SearchPageSize(in); got != want {
			t.Fatalf("SearchPageSize(%d) = %d, want %d", in, got, want)
		}
	}
}

func TestWireInfo_FollowFieldsOnlyWhenOn(t *testing.T) {
	v := View{Header: Header{ID: testListID, FollowerCount: 7}, FollowedByViewer: true}
	if off := WireInfo(v, false); off.GetFollowerCount() != 0 || off.GetFollowedByViewer() {
		t.Fatal("follow fields leaked with follows off")
	}
	if on := WireInfo(v, true); on.GetFollowerCount() != 7 || !on.GetFollowedByViewer() {
		t.Fatal("follow fields missing with follows on")
	}
}
