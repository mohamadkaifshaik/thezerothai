//go:build integration

// people_integration_test.go: SearchPeople against the Firestore emulator with the real
// identity repo (SearchHandles) and the real graph service (Snapshot, Block, Follow): the filters on real documents.
package search_test

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/search"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

type alwaysOn struct{}

func (alwaysOn) Enabled(string, string) bool { return true }

func newClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int63()))
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

const key = "0123456789abcdef"

func TestSearchPeople_Integration(t *testing.T) {
	client := newClient(t)
	ctx := context.Background()

	graphRepo := graph.NewFirestoreRepo(client)
	identityRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(identityRepo)
	graphRepo.SetProfiles(identityRepo)
	graphSvc := graph.New(graph.Deps{
		Repo: graphRepo, Cache: graph.NewCache(time.Minute), Flags: alwaysOn{}, CursorKey: []byte("test-cursor-key"),
	})
	idSvc := identity.New(identityRepo, identity.NewCache(time.Minute), 7*24*time.Hour, identity.WithBlockChecker(graphSvc))
	dir := idSvc.(identity.Directory)
	graphSvc.SetDirectory(dir)

	mk := func(handle string) string {
		uid := "uid-" + handle
		if _, err := idSvc.CreateProfile(ctx, uid, key, handle, "Name "+handle); err != nil {
			t.Fatalf("CreateProfile(%s): %v", handle, err)
		}
		return uid
	}
	viewer := mk("viewer")
	other := mk("other") // a second viewer
	for _, h := range []string{"sam", "sam_a", "samantha", "sambo", "samuel", "samurai"} {
		mk(h)
	}
	suspended := mk("samsuspended")
	if _, err := identityRepo.UpdateProfile(ctx, suspended, func(p *identity.Profile) { p.Status = identity.AccountStatusSuspended }); err != nil {
		t.Fatal(err)
	}
	protected := mk("samprivate")
	if _, err := identityRepo.UpdateProfile(ctx, protected, func(p *identity.Profile) { p.IsPrivate = true }); err != nil {
		t.Fatal(err)
	}
	mk("nobody") // a viewer with no relationships and no cached snapshot
	for i := 0; i < 25; i++ {
		mk(fmt.Sprintf("zed%02d", i))
	}

	// Relationships: viewer follows sam, blocks samuel, mutes sambo; samurai blocked viewer.
	if _, err := graphSvc.Follow(ctx, viewer, key, "uid-sam"); err != nil {
		t.Fatal(err)
	}
	if _, err := graphSvc.Block(ctx, viewer, key, "uid-samuel"); err != nil {
		t.Fatal(err)
	}
	if _, err := graphSvc.Mute(ctx, viewer, key, "uid-sambo"); err != nil {
		t.Fatal(err)
	}
	if _, err := graphSvc.Block(ctx, "uid-samurai", key, viewer); err != nil {
		t.Fatal(err)
	}

	reg := flags.NewRegistry(flags.Spec{Name: search.FlagSearch, Mode: flags.On}, flags.Spec{Name: search.FlagTrends, Mode: flags.On})
	srv := search.NewServer(search.New(reg, search.WithPeople(search.PeopleDeps{Directory: dir, Graph: graphSvc, PrefixEntries: 100})))

	call := func(uid, query string, limit int32) (*searchv1.SearchPeopleResponse, error) {
		cctx := authn.WithClaims(ctx, authn.Claims{UID: uid})
		resp, err := srv.SearchPeople(cctx, connect.NewRequest(&searchv1.SearchPeopleRequest{Query: query, Limit: limit}))
		if err != nil {
			return nil, err
		}
		return resp.Msg, nil
	}
	handlesOf := func(r *searchv1.SearchPeopleResponse) string {
		var hs []string
		for _, u := range r.GetUsers() {
			hs = append(hs, u.GetUser().GetHandle())
		}
		return strings.Join(hs, ",")
	}

	// Cold, limit 5: the query returns the first 5 handles in order (sam, sam_a, samantha, sambo, samprivate).
	resp, err := call(viewer, "@SAM", 5)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := handlesOf(resp), "sam,sam_a,samantha,sambo,samprivate"; got != want {
		t.Fatalf("handles = %s, want %s", got, want)
	}
	for _, u := range resp.GetUsers() {
		switch u.GetUser().GetHandle() {
		case "sam":
			if u.GetRelationship().GetFollowState().String() != "FOLLOW_STATE_FOLLOWING" {
				t.Errorf("sam: %v, want FOLLOWING", u.GetRelationship().GetFollowState())
			}
		case "sambo":
			if !u.GetRelationship().GetMuting() {
				t.Error("sambo: muting not set")
			}
		case "samprivate":
			if !u.GetUser().GetIsPrivate() {
				t.Error("samprivate: is_private not set")
			}
		}
	}

	// Warm entry, warm snapshot: the same answer.
	if again, err := call(viewer, "sam", 5); err != nil || handlesOf(again) != "sam,sam_a,samantha,sambo,samprivate" {
		t.Fatalf("warm: %v, %v", handlesOf(again), err)
	}

	// Warm entry, another viewer's cold snapshot.
	resp, err = call(other, "sam", 5)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := handlesOf(resp), "sam,sam_a,samantha,sambo,samprivate"; got != want {
		t.Errorf("other viewer = %s, want %s", got, want)
	}

	// Limit 20 over the whole prefix: filters on real documents. samsuspended is gone, samurai blocked the viewer.
	resp, err = call(viewer, "sam", 20)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := handlesOf(resp), "sam,sam_a,samantha,sambo,samprivate,samuel"; got != want {
		t.Errorf("limit 20 = %s, want %s", got, want)
	}
	for _, u := range resp.GetUsers() {
		if u.GetUser().GetHandle() == "samuel" && !u.GetRelationship().GetBlocking() {
			t.Error("samuel: blocking not set")
		}
	}

	// A prefix with more than 20 matches is cut at the limit.
	resp, err = call("uid-nobody", "zed", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetUsers()) != 20 {
		t.Errorf("zed rows = %d, want 20", len(resp.GetUsers()))
	}

	// No match: an empty answer. (Validation and unsupported queries are checked in people_test.go against the fake
	// directory and graph call tallies.)
	resp, err = call(viewer, "qq", 5)
	if err != nil || len(resp.GetUsers()) != 0 {
		t.Fatalf("no match: %v %v", resp, err)
	}
}
