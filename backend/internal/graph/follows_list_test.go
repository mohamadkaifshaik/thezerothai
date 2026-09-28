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

// followersFixture: target "uid-t" has n followers f01..fNN; fNN is the newest. Everyone is active.
func followersFixture(n int) (*fakeRepo, *fakeDirectory) {
	repo := newFakeRepo()
	dir := &fakeDirectory{profiles: map[string]identity.Profile{"uid-t": activeProfile("uid-t", time.Now())}}
	base := time.Now().Add(-time.Hour)
	for i := n; i >= 1; i-- {
		f := fmt.Sprintf("f%02d", i)
		dir.profiles[f] = activeProfile(f, time.Now())
		repo.edges = append(repo.edges, Edge{DocID: f + "_uid-t", FollowerID: f, FolloweeID: "uid-t", CreatedAt: base.Add(time.Duration(i) * time.Second)})
	}
	return repo, dir
}

func TestListFollowers_PagesCoverAllOnce(t *testing.T) {
	repo, dir := followersFixture(45)
	svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})
	var seen []string
	var sizes []int
	token := ""
	for {
		page, err := svc.ListFollowers(context.Background(), "uid-1", "uid-t", 20, token)
		if err != nil {
			t.Fatal(err)
		}
		sizes = append(sizes, len(page.Items))
		for _, it := range page.Items {
			if it.Since.IsZero() {
				t.Fatal("since must carry the edge createdAt")
			}
		}
		seen = append(seen, uidsOf(page)...)
		if page.NextPageToken == "" {
			break
		}
		token = page.NextPageToken
	}
	if fmt.Sprint(sizes) != "[20 20 5]" {
		t.Errorf("sizes = %v", sizes)
	}
	if len(seen) != 45 || seen[0] != "f45" || seen[44] != "f01" {
		t.Errorf("seen = %v", seen)
	}
	if repo.lastEdgeQuery.Limit != 21 {
		t.Errorf("edge query limit = %d, want page_size+1 = 21", repo.lastEdgeQuery.Limit)
	}
}

func TestListFollowers_PageSizeClamped(t *testing.T) {
	repo, dir := followersFixture(3)
	svc := newTestServiceWithDirectory(repo, dir, Deps{})
	if _, err := svc.ListFollowers(context.Background(), "uid-1", "uid-t", 100, ""); err != nil {
		t.Fatal(err)
	}
	if repo.lastEdgeQuery.Limit != 51 {
		t.Errorf("limit = %d, want 51 (50 clamped + 1)", repo.lastEdgeQuery.Limit)
	}
}

func TestListFollowing_UsesFolloweeAsRow(t *testing.T) {
	repo := newFakeRepo()
	dir := &fakeDirectory{profiles: map[string]identity.Profile{"uid-t": activeProfile("uid-t", time.Now()), "x": activeProfile("x", time.Now())}}
	repo.edges = []Edge{{DocID: "uid-t_x", FollowerID: "uid-t", FolloweeID: "x", CreatedAt: time.Now()}}
	repo.snapshots["uid-1"] = Snapshot{Following: map[string]bool{"x": true}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{})
	page, err := svc.ListFollowing(context.Background(), "uid-1", "uid-t", 20, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || page.Items[0].User.UserID != "x" || page.Items[0].Relationship.FollowState != FollowStateFollowing {
		t.Errorf("items = %+v", page.Items)
	}
	if repo.lastEdgeQuery.Followers {
		t.Error("ListFollowing must query by followerId")
	}
}

func TestListFollowers_TargetVisibility(t *testing.T) {
	tests := []struct {
		name  string
		setup func(*fakeRepo, *fakeDirectory)
	}{
		{"caller is blocked by target", func(r *fakeRepo, _ *fakeDirectory) {
			r.snapshots["uid-1"] = Snapshot{BlockedBy: map[string]bool{"uid-t": true}}
		}},
		{"overflow fallback finds the block", func(r *fakeRepo, _ *fakeDirectory) {
			r.snapshots["uid-1"] = Snapshot{BlockedByOverflow: true}
			r.snapshots["uid-t"] = Snapshot{Blocked: map[string]bool{"uid-1": true}}
		}},
		{"target missing", func(_ *fakeRepo, d *fakeDirectory) { delete(d.profiles, "uid-t") }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo, dir := followersFixture(3)
			tt.setup(repo, dir)
			svc := newTestServiceWithDirectory(repo, dir, Deps{})
			for _, call := range []func() (Page, error){
				func() (Page, error) { return svc.ListFollowers(context.Background(), "uid-1", "uid-t", 20, "") },
				func() (Page, error) { return svc.ListFollowing(context.Background(), "uid-1", "uid-t", 20, "") },
			} {
				_, err := call()
				assertAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
			}
			if repo.edgeCalls != 0 {
				t.Error("a hidden target must cost no edge reads")
			}
		})
	}
}

func TestListFollowers_FiltersRows(t *testing.T) {
	repo, dir := followersFixture(4)
	delete(dir.profiles, "f01") // deleted
	dir.profiles["f02"] = identity.Profile{UserID: "f02", Status: identity.AccountStatusSuspended}
	repo.snapshots["uid-1"] = Snapshot{
		BlockedBy: map[string]bool{"f03": true}, // f03 blocked the caller
		Blocked:   map[string]bool{"f04": true}, // caller blocked f04
	}
	svc := newTestServiceWithDirectory(repo, dir, Deps{})
	page, err := svc.ListFollowers(context.Background(), "uid-1", "uid-t", 20, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 0 {
		t.Errorf("items = %v, want every row filtered", uidsOf(page))
	}
}

func TestListFollowers_ShortPageStillPaginates(t *testing.T) {
	repo, dir := followersFixture(6)
	delete(dir.profiles, "f06")
	svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})
	page, err := svc.ListFollowers(context.Background(), "uid-1", "uid-t", 2, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || page.NextPageToken == "" {
		t.Errorf("items = %v token = %q, want a short page with a continuation", uidsOf(page), page.NextPageToken)
	}
}

func TestListFollowers_Errors(t *testing.T) {
	key := []byte("k")
	badBinding := cursor.Encode(key, cursor.Cursor{CreatedAt: time.Now(), DocID: "f01_someone-else"})
	tests := []struct {
		name   string
		target string
		token  string
		mut    func(*fakeRepo, *fakeDirectory)
		valid  bool
	}{
		{"bad target id", "bad id!", "", nil, true},
		{"garbage token", "uid-t", "garbage", nil, true},
		{"token from another list", "uid-t", badBinding, nil, true},
		{"repo error", "uid-t", "", func(r *fakeRepo, _ *fakeDirectory) { r.err = errors.New("boom") }, false},
		{"directory error", "uid-t", "", func(_ *fakeRepo, d *fakeDirectory) { d.err = errors.New("boom") }, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo, dir := followersFixture(2)
			if tt.mut != nil {
				tt.mut(repo, dir)
			}
			svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: key})
			_, err := svc.ListFollowers(context.Background(), "uid-1", tt.target, 20, tt.token)
			if err == nil {
				t.Fatal("expected error")
			}
			if tt.valid {
				assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			}
		})
	}
}

func TestListFollowers_EmptyAndFlagOff(t *testing.T) {
	repo, dir := followersFixture(0)
	svc := newTestServiceWithDirectory(repo, dir, Deps{})
	page, err := svc.ListFollowers(context.Background(), "uid-1", "uid-t", 20, "")
	if err != nil || len(page.Items) != 0 || page.NextPageToken != "" {
		t.Errorf("page = %+v, %v", page, err)
	}
	off := newTestServiceWithRepo(repo, false)
	if _, err := off.ListFollowing(context.Background(), "uid-1", "uid-t", 20, ""); err == nil {
		t.Error("expected FEATURE_DISABLED")
	}
}
