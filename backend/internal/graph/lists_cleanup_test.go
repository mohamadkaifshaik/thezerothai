package graph

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// cleanupFixture: caller uid-1 has kind[] = [old, gone1, susp, live, gone2]: gone* have no profile, susp is
// SUSPENDED, the rest ACTIVE.
func cleanupFixture(kind string) (*fakeRepo, *fakeDirectory) {
	repo := newFakeRepo()
	arr := []string{"old", "gone1", "susp", "live", "gone2"}
	set := map[string]bool{}
	for _, u := range arr {
		set[u] = true
	}
	l := Lists{}
	if kind == "blocked" {
		l.Snapshot.Blocked, l.Blocked = set, arr
	} else {
		l.Snapshot.Muted, l.Muted = set, arr
	}
	repo.lists = map[string]Lists{"uid-1": l}
	dir := &fakeDirectory{profiles: map[string]identity.Profile{
		"old":  activeProfile("old", time.Now()),
		"live": activeProfile("live", time.Now()),
		"susp": {UserID: "susp", Status: identity.AccountStatusSuspended},
	}}
	return repo, dir
}

func TestListOwnArray_LazyCleanup(t *testing.T) {
	for _, kind := range []string{"blocked", "muted"} {
		t.Run(kind, func(t *testing.T) {
			repo, dir := cleanupFixture(kind)
			svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})
			list := svc.ListBlockedUsers
			if kind == "muted" {
				list = svc.ListMutedUsers
			}
			ctx, info := obsCtx()

			page, err := list(ctx, "uid-1", 50, "")
			if err != nil {
				t.Fatal(err)
			}
			if got, want := uidsOf(page), []string{"live", "old"}; !reflect.DeepEqual(got, want) {
				t.Errorf("page = %v, want %v (missing and suspended hidden)", got, want)
			}
			if len(repo.removeCalls) != 1 {
				t.Fatalf("remove calls = %d, want exactly 1", len(repo.removeCalls))
			}
			rc := repo.removeCalls[0]
			if rc.uid != "uid-1" || rc.kind != kind {
				t.Errorf("remove target = %s/%s, want own %s", rc.uid, rc.kind, kind)
			}
			if !reflect.DeepEqual(rc.uids, []string{"gone2", "gone1"}) && !reflect.DeepEqual(rc.uids, []string{"gone1", "gone2"}) {
				t.Errorf("removed = %v, want only the two deleted uids (never the SUSPENDED one)", rc.uids)
			}
			if field(info, fieldLazyGone) != int64(2) || field(info, fieldMisses) != int64(2) {
				t.Errorf("fields lazy_removed=%v hydration_misses=%v, want 2/2", field(info, fieldLazyGone), field(info, fieldMisses))
			}

			// Second call: the array is clean, so no write. The suspended entry is still there.
			ctx2, info2 := obsCtx()
			if _, err := list(ctx2, "uid-1", 50, ""); err != nil {
				t.Fatal(err)
			}
			if len(repo.removeCalls) != 1 {
				t.Errorf("second call wrote again: %d remove calls", len(repo.removeCalls))
			}
			if field(info2, fieldLazyGone) != int64(0) {
				t.Errorf("second call lazy_removed = %v, want 0", field(info2, fieldLazyGone))
			}
			arr := repo.lists["uid-1"].Blocked
			if kind == "muted" {
				arr = repo.lists["uid-1"].Muted
			}
			if !reflect.DeepEqual(arr, []string{"old", "susp", "live"}) {
				t.Errorf("array after clean-up = %v", arr)
			}
		})
	}
}

func TestListOwnArray_LazyCleanup_OnlyHydratedPage(t *testing.T) {
	// A missing uid on a page that was not requested is untouched (bounded by page size).
	repo := newFakeRepo()
	repo.lists = map[string]Lists{"uid-1": {Muted: []string{"gone-old", "a", "b"}, Snapshot: Snapshot{Muted: map[string]bool{"gone-old": true, "a": true, "b": true}}}}
	dir := &fakeDirectory{profiles: map[string]identity.Profile{"a": activeProfile("a", time.Now()), "b": activeProfile("b", time.Now())}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})
	page, err := svc.ListMutedUsers(context.Background(), "uid-1", 2, "")
	if err != nil {
		t.Fatal(err)
	}
	if page.NextPageToken == "" || len(repo.removeCalls) != 0 {
		t.Fatalf("token=%q removes=%d, want a next page and 0 writes", page.NextPageToken, len(repo.removeCalls))
	}
	if _, err := svc.ListMutedUsers(context.Background(), "uid-1", 2, page.NextPageToken); err != nil {
		t.Fatal(err)
	}
	if len(repo.removeCalls) != 1 || !reflect.DeepEqual(repo.removeCalls[0].uids, []string{"gone-old"}) {
		t.Errorf("remove calls = %+v", repo.removeCalls)
	}
}

// Removing entries found on page 1 must not make page 2 skip or repeat anyone.
func TestListOwnArray_LazyCleanup_PaginationStable(t *testing.T) {
	repo := newFakeRepo()
	var arr []string
	set := map[string]bool{}
	dir := &fakeDirectory{profiles: map[string]identity.Profile{}}
	for _, u := range []string{"a", "b", "c", "d", "e", "f", "g", "h"} {
		arr = append(arr, u)
		set[u] = true
		dir.profiles[u] = activeProfile(u, time.Now())
	}
	delete(dir.profiles, "h") // newest, on page 1, deleted
	delete(dir.profiles, "g") // last of page 1 (limit 2): the token's own uid disappears
	repo.lists = map[string]Lists{"uid-1": {Muted: arr, Snapshot: Snapshot{Muted: set}}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})
	ctx := context.Background()

	p1, err := svc.ListMutedUsers(ctx, "uid-1", 2, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p1.Items) != 0 || p1.NextPageToken == "" || len(repo.removeCalls) != 1 {
		t.Fatalf("page1 items=%d token=%q removes=%d", len(p1.Items), p1.NextPageToken, len(repo.removeCalls))
	}
	var seen []string
	token := p1.NextPageToken
	for token != "" {
		p, err := svc.ListMutedUsers(ctx, "uid-1", 3, token)
		if err != nil {
			t.Fatal(err)
		}
		seen = append(seen, uidsOf(p)...)
		token = p.NextPageToken
	}
	if want := []string{"f", "e", "d", "c", "b", "a"}; !reflect.DeepEqual(seen, want) {
		t.Errorf("walk after clean-up = %v, want %v", seen, want)
	}
}

func TestListOwnArray_LazyCleanup_FailureIsBestEffort(t *testing.T) {
	repo, dir := cleanupFixture("muted")
	repo.removeErr = errors.New("boom: gone1 uid-1")
	svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})

	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	defer slog.SetDefault(old)

	ctx, info := obsCtx()
	page, err := svc.ListMutedUsers(ctx, "uid-1", 50, "")
	if err != nil {
		t.Fatalf("list must succeed when clean-up fails: %v", err)
	}
	if len(page.Items) != 2 {
		t.Errorf("items = %d, want 2", len(page.Items))
	}
	if field(info, fieldLazyGone) != int64(0) {
		t.Errorf("lazy_removed = %v, want 0 on failure", field(info, fieldLazyGone))
	}
	out := buf.String()
	if !strings.Contains(out, "graph_lazy_cleanup_failed") {
		t.Errorf("expected WARN graph_lazy_cleanup_failed, got %q", out)
	}
	for _, raw := range []string{"gone1", "gone2", "uid-1"} {
		if strings.Contains(out, raw) {
			t.Errorf("log leaks raw uid %q: %s", raw, out)
		}
	}
}

func TestListOwnArray_NoCleanupOnDirectoryError(t *testing.T) {
	repo, _ := cleanupFixture("muted")
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{err: errors.New("down")}, Deps{CursorKey: []byte("k")})
	if _, err := svc.ListMutedUsers(context.Background(), "uid-1", 50, ""); err == nil {
		t.Fatal("expected error")
	}
	if len(repo.removeCalls) != 0 {
		t.Error("must not clean up when hydration failed")
	}
}
