package lists

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// followStubs satisfies the follow methods of Repo, PagePurger and Service for test fakes that do not exercise following.
// A test that does exercise following uses a fake with those methods written out.
type followStubs struct{}

var errStubNotUsed = errors.New("follow stub not used by this test")

func (followStubs) Follow(context.Context, FollowParams) (FollowResult, error) {
	return FollowResult{}, errStubNotUsed
}

func (followStubs) Unfollow(context.Context, UnfollowParams) (UnfollowResult, error) {
	return UnfollowResult{}, errStubNotUsed
}

func (followStubs) FollowedPage(context.Context, string, *FollowAnchor, int) ([]FollowRow, error) {
	return nil, errStubNotUsed
}

func (followStubs) DiscoverPage(context.Context, *DiscoverAnchor, int) ([]List, error) {
	return nil, errStubNotUsed
}

func (followStubs) FollowedAmong(context.Context, string, []string) (map[string]bool, error) {
	return nil, errStubNotUsed
}

func (followStubs) PurgeFollowerPage(context.Context, string) (MemberPage, error) {
	return MemberPage{}, errStubNotUsed
}

func (followStubs) FollowList(context.Context, string, string, string) (View, error) {
	return View{}, errStubNotUsed
}

func (followStubs) UnfollowList(context.Context, string, string, string) error {
	return errStubNotUsed
}

func (followStubs) ListFollowedLists(context.Context, string, int32, string) (FollowedListsPage, error) {
	return FollowedListsPage{}, errStubNotUsed
}

func (followStubs) DiscoverLists(context.Context, string, int32, string) (DiscoverListsPage, error) {
	return DiscoverListsPage{}, errStubNotUsed
}

func (followStubs) ListSuggestedMembers(context.Context, string, string, int32) ([]identity.Profile, error) {
	return nil, errStubNotUsed
}
