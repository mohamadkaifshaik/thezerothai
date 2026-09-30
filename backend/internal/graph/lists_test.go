package graph

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

func TestGetRelationships(t *testing.T) {
	snap := Snapshot{
		Following: map[string]bool{"uid-f": true},
		Blocked:   map[string]bool{"uid-x": true},
		Muted:     map[string]bool{"uid-m": true, "uid-f": true},
		BlockedBy: map[string]bool{"uid-b": true},
	}
	tests := []struct {
		name string
		ids  []string
		want []Relationship
	}{
		{"order preserved, dupes collapsed", []string{"uid-f", "uid-x", "uid-f", "uid-m"}, []Relationship{
			{UserID: "uid-f", FollowState: FollowStateFollowing, Muting: true},
			{UserID: "uid-x", FollowState: FollowStateNone, Blocking: true},
			{UserID: "uid-m", FollowState: FollowStateNone, Muting: true},
		}},
		{"blockedBy is invisible", []string{"uid-b", "uid-stranger"}, []Relationship{
			{UserID: "uid-b", FollowState: FollowStateNone},
			{UserID: "uid-stranger", FollowState: FollowStateNone},
		}},
		{"self is NONE", []string{"uid-1"}, []Relationship{{UserID: "uid-1", FollowState: FollowStateNone}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.snapshots["uid-1"] = snap
			svc := newTestServiceWithRepo(repo, true)
			got, err := svc.GetRelationships(context.Background(), "uid-1", tt.ids)
			if err != nil {
				t.Fatal(err)
			}
			if fmt.Sprint(got) != fmt.Sprint(tt.want) {
				t.Errorf("got %v, want %v", got, tt.want)
			}
			if _, err := svc.GetRelationships(context.Background(), "uid-1", tt.ids); err != nil || repo.calls != 1 {
				t.Errorf("second call: err=%v repo calls=%d, want 1 (cached)", err, repo.calls)
			}
		})
	}
}

func TestGetRelationships_Validation(t *testing.T) {
	fifty := make([]string, 50)
	for i := range fifty {
		fifty[i] = fmt.Sprintf("uid-%d", i+10)
	}
	tests := []struct {
		name    string
		ids     []string
		wantErr bool
	}{
		{"empty", nil, true},
		{"51 ids", append(append([]string{}, fifty...), "uid-extra"), true},
		{"bad id", []string{"bad id!"}, true},
		{"50 ids ok", fifty, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			svc := newTestServiceWithRepo(repo, true)
			_, err := svc.GetRelationships(context.Background(), "uid-1", tt.ids)
			if tt.wantErr {
				assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
				if repo.calls != 0 {
					t.Error("validation must run before any read")
				}
			} else if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestGetRelationships_RepoError(t *testing.T) {
	repo := newFakeRepo()
	repo.err = errors.New("boom")
	svc := newTestServiceWithRepo(repo, true)
	if _, err := svc.GetRelationships(context.Background(), "uid-1", []string{"uid-2"}); err == nil {
		t.Fatal("expected error")
	}
}

// ownListFixture builds a caller whose blocked[] is u01..uNN (u01 oldest) with every user active.
func ownListFixture(n int) (*fakeRepo, *fakeDirectory) {
	repo := newFakeRepo()
	dir := &fakeDirectory{profiles: map[string]identity.Profile{}}
	var blocked []string
	set := map[string]bool{}
	for i := 1; i <= n; i++ {
		uid := fmt.Sprintf("u%02d", i)
		blocked = append(blocked, uid)
		set[uid] = true
		dir.profiles[uid] = activeProfile(uid, time.Now())
	}
	repo.lists = map[string]Lists{"uid-1": {Snapshot: Snapshot{Blocked: set}, Blocked: blocked}}
	return repo, dir
}

func uidsOf(p Page) []string {
	out := make([]string, len(p.Items))
	for i, it := range p.Items {
		out[i] = it.User.UserID
	}
	return out
}

func TestListBlockedUsers_Pagination(t *testing.T) {
	repo, dir := ownListFixture(45)
	svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})
	ctx := context.Background()

	var seen []string
	token := ""
	var sizes []int
	for {
		page, err := svc.ListBlockedUsers(ctx, "uid-1", 20, token)
		if err != nil {
			t.Fatal(err)
		}
		sizes = append(sizes, len(page.Items))
		seen = append(seen, uidsOf(page)...)
		for _, it := range page.Items {
			if !it.Relationship.Blocking || !it.Since.IsZero() {
				t.Fatalf("row = %+v", it)
			}
		}
		if page.NextPageToken == "" {
			break
		}
		token = page.NextPageToken
	}
	if fmt.Sprint(sizes) != "[20 20 5]" {
		t.Errorf("page sizes = %v, want [20 20 5]", sizes)
	}
	if len(seen) != 45 || seen[0] != "u45" || seen[44] != "u01" {
		t.Errorf("order = %v, want newest first covering all 45", seen)
	}
	if repo.listCalls != 3 {
		t.Errorf("graph doc reads = %d, want 1 per page", repo.listCalls)
	}
}

func TestListBlockedUsers_RemovedBetweenPages(t *testing.T) {
	tests := []struct {
		name   string
		remove string
		want   string // first uid of page 2
	}{
		{"cursor uid removed", "u26", "u25"},
		{"older item removed", "u10", "u25"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo, dir := ownListFixture(30)
			svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})
			p1, err := svc.ListBlockedUsers(context.Background(), "uid-1", 5, "")
			if err != nil || len(p1.Items) != 5 || p1.Items[4].User.UserID != "u26" {
				t.Fatalf("page 1 = %v, %v", uidsOf(p1), err)
			}
			l := repo.lists["uid-1"]
			var kept []string
			for _, u := range l.Blocked {
				if u != tt.remove {
					kept = append(kept, u)
				}
			}
			l.Blocked = kept
			repo.lists["uid-1"] = l

			p2, err := svc.ListBlockedUsers(context.Background(), "uid-1", 5, p1.NextPageToken)
			if err != nil {
				t.Fatal(err)
			}
			if got := uidsOf(p2)[0]; got != tt.want {
				t.Errorf("page 2 starts at %s, want %s", got, tt.want)
			}
		})
	}
}

func TestListMutedUsers_DropsMissingUsers(t *testing.T) {
	repo := newFakeRepo()
	repo.lists = map[string]Lists{"uid-1": {Snapshot: Snapshot{Muted: map[string]bool{"uid-a": true, "uid-gone": true}}, Muted: []string{"uid-gone", "uid-a"}}}
	dir := &fakeDirectory{profiles: map[string]identity.Profile{"uid-a": activeProfile("uid-a", time.Now())}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{})
	page, err := svc.ListMutedUsers(context.Background(), "uid-1", 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || page.Items[0].User.UserID != "uid-a" || !page.Items[0].Relationship.Muting {
		t.Errorf("items = %+v", page.Items)
	}
	if page.NextPageToken != "" {
		t.Error("unexpected next token")
	}
}

func TestListOwnArray_Errors(t *testing.T) {
	t.Run("tampered token", func(t *testing.T) {
		repo, dir := ownListFixture(30)
		svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})
		_, err := svc.ListBlockedUsers(context.Background(), "uid-1", 5, "garbage")
		assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		if repo.listCalls != 0 {
			t.Error("token must be validated before any read")
		}
	})
	t.Run("token signed with another key", func(t *testing.T) {
		repo, dir := ownListFixture(30)
		other := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("other")})
		p, _ := other.ListBlockedUsers(context.Background(), "uid-1", 5, "")
		svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})
		_, err := svc.ListBlockedUsers(context.Background(), "uid-1", 5, p.NextPageToken)
		assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	})
	t.Run("token issued to another caller / another list", func(t *testing.T) {
		repo, dir := ownListFixture(30)
		repo.lists["uid-2"] = repo.lists["uid-1"]
		svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k"),
			Flags: &fakeFlags{on: map[string]bool{"uid-1:graph": true, "uid-2:graph": true}}})
		p, err := svc.ListBlockedUsers(context.Background(), "uid-1", 5, "")
		if err != nil || p.NextPageToken == "" {
			t.Fatalf("page = %+v, %v", p, err)
		}
		_, err = svc.ListBlockedUsers(context.Background(), "uid-2", 5, p.NextPageToken)
		assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		_, err = svc.ListMutedUsers(context.Background(), "uid-1", 5, p.NextPageToken)
		assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		if _, err = svc.ListBlockedUsers(context.Background(), "uid-1", 5, p.NextPageToken); err != nil {
			t.Fatalf("the owner's own token must still work: %v", err)
		}
	})
	t.Run("repo error", func(t *testing.T) {
		repo, dir := ownListFixture(3)
		repo.err = errors.New("boom")
		svc := newTestServiceWithDirectory(repo, dir, Deps{})
		if _, err := svc.ListBlockedUsers(context.Background(), "uid-1", 5, ""); err == nil {
			t.Fatal("expected error")
		}
	})
	t.Run("directory error", func(t *testing.T) {
		repo, dir := ownListFixture(3)
		dir.err = errors.New("boom")
		svc := newTestServiceWithDirectory(repo, dir, Deps{})
		if _, err := svc.ListBlockedUsers(context.Background(), "uid-1", 5, ""); err == nil {
			t.Fatal("expected error")
		}
	})
	t.Run("empty list", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
		p, err := svc.ListMutedUsers(context.Background(), "uid-1", 5, "")
		if err != nil || len(p.Items) != 0 || p.NextPageToken != "" {
			t.Errorf("page = %+v, %v", p, err)
		}
	})
}

func TestPageNewestFirst_ClampsOutOfRangePosition(t *testing.T) {
	// Recorded position beyond the array (many removals): resume from the newest end, no panic.
	uids, hasMore, _ := pageNewestFirst([]string{"a", "b"}, cursorAt(99, "gone"), 5)
	if fmt.Sprint(uids) != "[b a]" || hasMore {
		t.Errorf("uids = %v hasMore = %v", uids, hasMore)
	}
}

func cursorAt(pos int64, uid string) cursor.Cursor {
	return cursor.Cursor{CreatedAt: time.UnixMicro(pos).UTC(), DocID: uid}
}

// ADR-0008 D9 (own lists): users in caller.blockedBy are hidden, never hydrated, and the page still paginates.
func TestListOwnArray_HidesBlockedByUsers(t *testing.T) {
	repo, dir := ownListFixture(6)
	l := repo.lists["uid-1"]
	l.Snapshot.BlockedBy = map[string]bool{"u06": true, "u05": true}
	repo.lists["uid-1"] = l
	svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})

	p1, err := svc.ListBlockedUsers(context.Background(), "uid-1", 2, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p1.Items) != 0 || p1.NextPageToken == "" {
		t.Fatalf("p1 = %v token=%q, want an empty page that still continues", uidsOf(p1), p1.NextPageToken)
	}
	p2, err := svc.ListBlockedUsers(context.Background(), "uid-1", 2, p1.NextPageToken)
	if err != nil || fmt.Sprint(uidsOf(p2)) != "[u04 u03]" {
		t.Fatalf("p2 = %v, %v", uidsOf(p2), err)
	}
}
