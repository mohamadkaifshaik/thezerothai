package communities

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor/cursortest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

func named(id, name string, st Status) Community {
	c := dirCommunity(id, 1, st)
	c.Name, c.NameLower = name, namekey.Fold(name)
	return c
}

func seedSearch(f *fixture, cs ...Community) {
	if f.repo.docs == nil {
		f.repo.docs = map[string]Community{}
	}
	for _, c := range cs {
		f.repo.docs[c.ID] = c
	}
}

func searchIDs(p SearchPage) []string {
	out := make([]string, len(p.Views))
	for i, v := range p.Views {
		out[i] = v.Community.ID
	}
	return out
}

// TestSearchCommunities_StatusAndRoles: only ACTIVE communities match (SUSPENDED and ARCHIVED never), in folded-name order, with
// the directory's viewer_role.
func TestSearchCommunities_StatusAndRoles(t *testing.T) {
	f := newListFixture()
	seedSearch(f,
		named("0000000000000000701", "Go Devs", StatusActive),
		named("0000000000000000702", "go suspended", StatusSuspended),
		named("0000000000000000703", "Go archived", StatusArchived),
		named("0000000000000000704", "Gophers", StatusActive),
		named("0000000000000000705", "Rust", StatusActive),
	)
	f.repo.mships = map[string]Memberships{"u1": {Joined: []string{"0000000000000000704"}, Banned: []string{"0000000000000000701"}}}
	page, err := f.svc.SearchCommunities(context.Background(), "u1", "go", 0, "")
	if err != nil {
		t.Fatal(err)
	}
	got := searchIDs(page)
	if len(got) != 2 || got[0] != "0000000000000000701" || got[1] != "0000000000000000704" {
		t.Fatalf("got %v", got)
	}
	if page.Views[0].Role != RoleBanned || page.Views[1].Role != RoleMember || page.NextPageToken != "" {
		t.Fatalf("roles %v %v token %q", page.Views[0].Role, page.Views[1].Role, page.NextPageToken)
	}
	if w := WireCommunity(page.Views[1]); w.GetName() != "Gophers" || w.GetCommunityId() != "0000000000000000704" {
		t.Fatalf("wire = %v", w)
	}
}

func TestSearchCommunities_PagingAndTokens(t *testing.T) {
	f := newListFixture()
	seedSearch(f,
		named("0000000000000000711", "Go a", StatusActive),
		named("0000000000000000712", "Go b", StatusActive),
		named("0000000000000000713", "Go c", StatusActive),
	)
	ctx := context.Background()
	p1, err := f.svc.SearchCommunities(ctx, "u1", "go", 2, "")
	if err != nil || len(p1.Views) != 2 || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %v %q %v", searchIDs(p1), p1.NextPageToken, err)
	}
	p2, err := f.svc.SearchCommunities(ctx, "u1", "go", 2, p1.NextPageToken)
	if err != nil || len(p2.Views) != 1 || p2.Views[0].Community.ID != "0000000000000000713" || p2.NextPageToken != "" {
		t.Fatalf("page 2 = %v %q %v", searchIDs(p2), p2.NextPageToken, err)
	}
	for name, call := range map[string]func() error{
		"other prefix": func() error { _, err := f.svc.SearchCommunities(ctx, "u1", "g", 2, p1.NextPageToken); return err },
		"other caller": func() error { _, err := f.svc.SearchCommunities(ctx, "u2", "go", 2, p1.NextPageToken); return err },
		"tampered": func() error {
			_, err := f.svc.SearchCommunities(ctx, "u1", "go", 2, cursortest.Tamper(p1.NextPageToken))
			return err
		},
	} {
		err := call()
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Code != connect.CodeInvalidArgument {
			t.Fatalf("%s: err = %v, want VALIDATION page_token", name, err)
		}
	}
}

func TestSearchCommunities_RefusesUnfoldedPrefix(t *testing.T) {
	f := newListFixture()
	for _, p := range []string{"", "Go"} {
		if _, err := f.svc.SearchCommunities(context.Background(), "u1", p, 0, ""); err == nil {
			t.Fatalf("prefix %q accepted", p)
		}
	}
}

func TestSearchPageSize(t *testing.T) {
	for in, want := range map[int32]int{-3: 20, 0: 20, 5: 5, 20: 20, 99: 20} {
		if got := SearchPageSize(in); got != want {
			t.Fatalf("SearchPageSize(%d) = %d", in, got)
		}
	}
}
