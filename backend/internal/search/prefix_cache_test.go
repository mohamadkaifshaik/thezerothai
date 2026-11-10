package search

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"connectrpc.com/connect"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestPrefixCache_LookupCachesPerPrefixAndLimit (F36): one directory read per (prefix, limit) within the TTL, the hit
// flag reports it, an error is not cached, and SearchHandles is the same read without the flag.
func TestPrefixCache_LookupCachesPerPrefixAndLimit(t *testing.T) {
	dir := &fakeDir{}
	for _, h := range []string{"alice", "alina", "bob"} {
		dir.users = append(dir.users, user(h))
	}
	pc := NewPrefixCache(dir, 0)
	ctx := context.Background()
	for i, want := range []bool{false, true} {
		got, hit, err := pc.Lookup(ctx, "al", 20)
		if err != nil || hit != want || len(got) != 2 {
			t.Fatalf("lookup %d = %d rows, hit %v, %v; want 2, %v", i, len(got), hit, err, want)
		}
	}
	if _, hit, _ := pc.Lookup(ctx, "al", 5); hit {
		t.Error("another limit is another key")
	}
	if rows, err := pc.SearchHandles(ctx, "al", 20); err != nil || len(rows) != 2 {
		t.Errorf("SearchHandles = %d, %v", len(rows), err)
	}
	if fmt.Sprint(dir.calls) != "[al/20 al/5]" {
		t.Errorf("directory calls = %v", dir.calls)
	}
	dir.err = errors.New("down")
	if _, _, err := pc.Lookup(ctx, "bo", 20); err == nil {
		t.Fatal("no error")
	}
	dir.err = nil
	if _, hit, err := pc.Lookup(ctx, "bo", 20); err != nil || hit {
		t.Errorf("after an error: hit %v, %v; the failure must not be cached", hit, err)
	}
}

// TestPrefixCache_SharedWithSearchPeople (F36): with PeopleDeps.Prefixes set, SearchPeople fills the cache another module
// reads, so a member search after a people search with the same (prefix, limit) is a hit (one directory read in total).
func TestPrefixCache_SharedWithSearchPeople(t *testing.T) {
	dir := &fakeDir{}
	dir.users = append(dir.users, user("alice"))
	pc := NewPrefixCache(dir, 10)
	reg := flags.NewRegistry(flags.Spec{Name: FlagSearch, Mode: flags.On})
	srv := NewServer(New(reg, WithPeople(PeopleDeps{Directory: dir, Graph: &peopleFakeGraph{snaps: map[string]graph.Snapshot{}}, Prefixes: pc})))
	if _, err := srv.SearchPeople(signedIn("me"), connect.NewRequest(&searchv1.SearchPeopleRequest{Query: "al", Limit: 20})); err != nil {
		t.Fatal(err)
	}
	if _, hit, err := pc.Lookup(context.Background(), "al", 20); err != nil || !hit {
		t.Fatalf("hit %v, %v; want the entry SearchPeople filled", hit, err)
	}
	if len(dir.calls) != 1 {
		t.Errorf("directory calls = %v, want 1", dir.calls)
	}
}
