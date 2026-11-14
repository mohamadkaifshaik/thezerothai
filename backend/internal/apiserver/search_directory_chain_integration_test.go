//go:build integration

package apiserver

// SearchLists and SearchCommunities (F20, F21) over the real Build chain on the emulators: the flag order, the visibility and leak
// matrix through the real lists and communities modules, and the shared rate-limit bucket.

import (
	"context"
	"fmt"
	"math/rand/v2"
	"net/http"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

func directoryOn(c *config.Config) {
	c.FeatureSearchLists = flags.Spec{Name: "search_lists", Mode: flags.On}
	c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.On}
	c.FeatureCommunities = flags.Spec{Name: "communities", Mode: flags.On}
	c.FeatureListFollows = flags.Spec{Name: "list_follows", Mode: flags.On}
}

type dirChain struct {
	*searchChain
	lists listsv1connect.ListServiceClient
}

func newDirChain(t *testing.T, mutate func(*config.Config)) *dirChain {
	t.Helper()
	sc := newSearchChain(t, func(c *config.Config) {
		directoryOn(c)
		if mutate != nil {
			mutate(c)
		}
	})
	return &dirChain{searchChain: sc, lists: listsv1connect.NewListServiceClient(http.DefaultClient, sc.url)}
}

func (e *dirChain) createList(t *testing.T, who sUser, name string, private bool) string {
	t.Helper()
	resp, err := e.lists.CreateList(context.Background(), authed(who.token, &listsv1.CreateListRequest{
		IdempotencyKey: contractKey("srch-list"), Name: name, IsPrivate: &private,
	}))
	if err != nil {
		t.Fatalf("CreateList(%q): %v", name, err)
	}
	return resp.Msg.GetList().GetListId()
}

// seedCommunityDoc writes communities/{id} in the shape communities.FirestoreRepo reads, with its nameLower.
func (e *dirChain) seedCommunityDoc(t *testing.T, owner, name, status string) string {
	t.Helper()
	id := fmt.Sprintf("%019d", rand.Int64N(9_000_000_000_000_000_000)+1)
	now := time.Now().UTC()
	if _, err := e.fs.Collection("communities").Doc(id).Set(context.Background(), map[string]any{
		"name": name, namekey.Field: namekey.Fold(name), "description": "", "rules": []any{}, "ownerId": owner,
		"moderatorIds": []string{}, "memberCount": int64(1), "status": status, "visibility": "PUBLIC", "recentRemovals": []any{},
		"modlog": []any{}, "modlogSeq": int64(0), "createdAt": now, "updatedAt": now,
	}); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestSearchDirectoryChain_FlagOff(t *testing.T) {
	e := newDirChain(t, func(c *config.Config) { c.FeatureSearchLists = flags.Spec{Name: "search_lists", Mode: flags.Off} })
	u := e.user(t)
	ctx := context.Background()
	_, err := e.search.SearchLists(ctx, authed(u.token, &searchv1.SearchListsRequest{Query: "go"}))
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "search_lists")
	_, err = e.search.SearchCommunities(ctx, authed(u.token, &searchv1.SearchCommunitiesRequest{Query: "go"}))
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "search_lists")
}

func TestSearchDirectoryChain_ListsFlagOff(t *testing.T) {
	e := newDirChain(t, func(c *config.Config) { c.FeatureLists = flags.Spec{Name: "lists", Mode: flags.Off} })
	u := e.user(t)
	_, err := e.search.SearchLists(context.Background(), authed(u.token, &searchv1.SearchListsRequest{Query: "go"}))
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "lists")
}

// TestSearchListsChain_LeakMatrix: a stranger finds only the public list of an ACTIVE, unblocked, public owner. The private list,
// a list whose owner blocks the viewer, a list of an owner the viewer blocks, and the viewer's own list stay out; a query
// error is VALIDATION before any read.
func TestSearchListsChain_LeakMatrix(t *testing.T) {
	e := newDirChain(t, nil)
	ctx := context.Background()
	viewer, owner, blocker, blocked := e.user(t), e.user(t), e.user(t), e.user(t)
	p := "zq" + randLetters(8) // a prefix no other test shares
	public := e.createList(t, owner, p+" public", false)
	e.createList(t, owner, p+" private", true)
	e.createList(t, blocker, p+" blocker", false)
	e.createList(t, blocked, p+" blocked", false)
	e.createList(t, viewer, p+" mine", false)
	if _, err := e.graph.Block(ctx, authed(blocker.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("srch-blk"), UserId: viewer.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := e.graph.Block(ctx, authed(viewer.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("srch-blk"), UserId: blocked.uid})); err != nil {
		t.Fatal(err)
	}
	resp, err := e.search.SearchLists(ctx, authed(viewer.token, &searchv1.SearchListsRequest{Query: " " + p + " "}))
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.Msg.GetLists(); len(got) != 1 || got[0].GetListId() != public || got[0].GetIsPrivate() {
		t.Fatalf("lists = %v", got)
	}
	// The owner does not see their own lists here (the Lists tab has them), private or not.
	own, err := e.search.SearchLists(ctx, authed(owner.token, &searchv1.SearchListsRequest{Query: p + " p"}))
	if err != nil || len(own.Msg.GetLists()) != 0 {
		t.Fatalf("owner search = %v, %v", own.Msg.GetLists(), err)
	}
	_, err = e.search.SearchLists(ctx, authed(viewer.token, &searchv1.SearchListsRequest{Query: "a\u202eb"}))
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "query")
}

// TestSearchCommunitiesChain_StatusMatrix: ACTIVE communities only (SUSPENDED and ARCHIVED never), paged by a sealed token.
func TestSearchCommunitiesChain_StatusMatrix(t *testing.T) {
	e := newDirChain(t, nil)
	ctx := context.Background()
	viewer, owner := e.user(t), e.user(t)
	p := "zq" + randLetters(8)
	a := e.seedCommunityDoc(t, owner.uid, p+" a", "ACTIVE")
	e.seedCommunityDoc(t, owner.uid, p+" b", "SUSPENDED")
	e.seedCommunityDoc(t, owner.uid, p+" c", "ARCHIVED")
	d := e.seedCommunityDoc(t, owner.uid, p+" d", "ACTIVE")
	first, err := e.search.SearchCommunities(ctx, authed(viewer.token, &searchv1.SearchCommunitiesRequest{Query: p, PageSize: 1}))
	if err != nil || len(first.Msg.GetCommunities()) != 1 || first.Msg.GetCommunities()[0].GetCommunityId() != a || first.Msg.GetNextPageToken() == "" {
		t.Fatalf("page 1 = %v, %v", first.Msg, err)
	}
	second, err := e.search.SearchCommunities(ctx, authed(viewer.token, &searchv1.SearchCommunitiesRequest{Query: p, PageSize: 1, PageToken: first.Msg.GetNextPageToken()}))
	if err != nil || len(second.Msg.GetCommunities()) != 1 || second.Msg.GetCommunities()[0].GetCommunityId() != d {
		t.Fatalf("page 2 = %v, %v", second.Msg, err)
	}
	_, err = e.search.SearchCommunities(ctx, authed(viewer.token, &searchv1.SearchCommunitiesRequest{Query: p + "x", PageToken: first.Msg.GetNextPageToken()}))
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "page_token")
}

// TestSearchDirectoryChain_SharedBucket: SearchLists and SearchCommunities draw on one bucket.
func TestSearchDirectoryChain_SharedBucket(t *testing.T) {
	e := newDirChain(t, func(c *config.Config) { c.RateLimit.SearchDirectoryPerUserPerMinute = 2 })
	u := e.user(t)
	ctx := context.Background()
	if _, err := e.search.SearchLists(ctx, authed(u.token, &searchv1.SearchListsRequest{Query: "zz"})); err != nil {
		t.Fatal(err)
	}
	if _, err := e.search.SearchCommunities(ctx, authed(u.token, &searchv1.SearchCommunitiesRequest{Query: "zz"})); err != nil {
		t.Fatal(err)
	}
	_, err := e.search.SearchLists(ctx, authed(u.token, &searchv1.SearchListsRequest{Query: "zz"}))
	wantReason(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "", "")
}
