package lists

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

const (
	followViewer = "viewer-1"
	followMember = "member-a"
	followSugg1  = "sugg-b"
	followBlocks = "blocker-c"
	followSugg2  = "sugg-d"
)

// followRepoFake records the follow writes; the rest of the read side is the shared fakeRepo.
type followRepoFake struct {
	*fakeRepo
	followErr     error
	followCalls   int
	unfollowCalls int
}

func (f *followRepoFake) Follow(_ context.Context, _ FollowParams) (FollowResult, error) {
	f.followCalls++
	if f.followErr != nil {
		return FollowResult{}, f.followErr
	}
	return FollowResult{Outcome: Written, Header: Header{ID: testListID, FollowerCount: 1}}, nil
}

func (f *followRepoFake) Unfollow(_ context.Context, _ UnfollowParams) (UnfollowResult, error) {
	f.unfollowCalls++
	return UnfollowResult{Outcome: Written}, nil
}

// followEnv builds a service over one public list owned by testUID with the given viewer snapshot and list.
func followEnv(t *testing.T, list List, viewerSnap graph.Snapshot, ownerSnap graph.Snapshot) (*service, *followRepoFake) {
	t.Helper()
	repo := &followRepoFake{fakeRepo: &fakeRepo{docs: map[string]List{list.ID: list}}}
	profiles := map[string]identity.Profile{
		testUID:      active(testUID, false),
		followViewer: active(followViewer, false),
		followMember: active(followMember, false),
		followSugg1:  active(followSugg1, false),
		followBlocks: active(followBlocks, false),
		followSugg2:  active(followSugg2, false),
	}
	g := &fakeGraph{snaps: map[string]graph.Snapshot{followViewer: viewerSnap, testUID: ownerSnap}}
	s := New(Deps{
		Repo: repo, Directory: fakeDirectory{profiles: profiles}, Graph: g, IDs: fixedIDs{}, Now: func() time.Time { return testNow },
		Limits:    Limits{MaxPerUser: 20, MaxMembers: 150, CacheEntries: 50},
		CursorKey: []byte("0123456789abcdef0123456789abcdef"),
	}).(*service)
	return s, repo
}

func publicList(members ...string) List {
	return List{ID: testListID, OwnerID: testUID, Name: "Friends", MemberIDs: members, CreatedAt: testNow}
}

func notFoundErr(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeNotFound {
		t.Fatalf("err = %v, want NOT_FOUND", err)
	}
}

func TestFollowList_Visibility(t *testing.T) {
	private := publicList()
	private.IsPrivate = true
	tests := []struct {
		name       string
		list       List
		viewerSnap graph.Snapshot
		wantErr    bool
		wantWrite  bool
	}{
		{name: "public list, no block: follows", list: publicList(), wantWrite: true},
		{name: "private list is NOT_FOUND", list: private, wantErr: true},
		{
			name: "caller blocks the owner: NOT_FOUND, nothing written", list: publicList(),
			viewerSnap: graph.Snapshot{Blocked: set(testUID)}, wantErr: true,
		},
		{
			name: "owner blocks the caller: NOT_FOUND", list: publicList(),
			viewerSnap: graph.Snapshot{BlockedBy: set(testUID)}, wantErr: true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, repo := followEnv(t, tc.list, tc.viewerSnap, graph.Snapshot{})
			v, err := s.FollowList(context.Background(), followViewer, "key-0123456789abcd", testListID)
			if tc.wantErr {
				notFoundErr(t, err)
			} else if err != nil || !v.FollowedByViewer {
				t.Fatalf("FollowList: view %+v err %v", v, err)
			}
			if got := repo.followCalls == 1; got != tc.wantWrite {
				t.Fatalf("repo.Follow called %d times, want write=%v", repo.followCalls, tc.wantWrite)
			}
		})
	}
}

func TestFollowList_OwnerIsNoOp(t *testing.T) {
	s, repo := followEnv(t, publicList(), graph.Snapshot{}, graph.Snapshot{})
	if _, err := s.FollowList(context.Background(), testUID, "key-0123456789abcd", testListID); err != nil {
		t.Fatalf("owner follow: %v", err)
	}
	if repo.followCalls != 0 {
		t.Fatalf("owner follow wrote %d times, want 0", repo.followCalls)
	}
}

func TestFollowList_LimitReached(t *testing.T) {
	s, repo := followEnv(t, publicList(), graph.Snapshot{}, graph.Snapshot{})
	repo.followErr = ErrFollowLimit
	_, err := s.FollowList(context.Background(), followViewer, "key-0123456789abcd", testListID)
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "list_follows"})
}

func TestUnfollowList_NoVisibilityCheck(t *testing.T) {
	private := publicList()
	private.IsPrivate = true
	s, repo := followEnv(t, private, graph.Snapshot{}, graph.Snapshot{})
	if err := s.UnfollowList(context.Background(), followViewer, "key-0123456789abcd", testListID); err != nil {
		t.Fatalf("unfollow of a private list: %v", err)
	}
	if repo.unfollowCalls != 1 {
		t.Fatalf("unfollow calls = %d, want 1", repo.unfollowCalls)
	}
}

func TestListSuggestedMembers(t *testing.T) {
	// The owner follows, newest first: a current member, the owner, a blocked-by-owner account, two good candidates.
	ownerSnap := graph.Snapshot{RecentFollowing: []string{followMember, testUID, followBlocks, followSugg1, followSugg2}, Blocked: set(followBlocks)}
	tests := []struct {
		name    string
		viewer  string
		max     int32
		want    []string
		wantErr bool
	}{
		{name: "owner gets the followed, eligible candidates in follow order", viewer: testUID, want: []string{followSugg1, followSugg2}},
		{name: "max_results caps the page", viewer: testUID, max: 1, want: []string{followSugg1}},
		{name: "a non-owner is NOT_FOUND", viewer: followViewer, wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, _ := followEnv(t, publicList(followMember), graph.Snapshot{}, ownerSnap)
			ps, err := s.ListSuggestedMembers(context.Background(), tc.viewer, testListID, tc.max)
			if tc.wantErr {
				notFoundErr(t, err)
				return
			}
			if err != nil {
				t.Fatalf("ListSuggestedMembers: %v", err)
			}
			var got []string
			for _, p := range ps {
				got = append(got, p.UserID)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("suggestions = %v, want %v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("suggestions = %v, want %v", got, tc.want)
				}
			}
		})
	}
}
