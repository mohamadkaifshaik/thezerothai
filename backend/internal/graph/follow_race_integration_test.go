//go:build integration

package graph

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// TestFollow_Integration_ProtectRacingWithFollowIsSerialized (ADR-0025 D6, W3-27 acceptance "a protect committed while
// Follow is in flight commits as a request, never as an edge"). Because Follow reads the target's users doc INSIDE its
// transaction, the doc is locked from that read to Follow's commit: a concurrent protect cannot commit in between (the
// emulator and Firestore make the writer wait, or abort it with "Transaction lock timeout" when it waits too long). So
// every interleaving ends in one of two consistent states:
//
//   - the protect committed first: the Follow commits as a request (no edge, I-X);
//   - the Follow committed first: it is an edge, and the protect lands after it (a follower the account already had).
//
// A half state (an edge for a target that was protected before the Follow read it, a request without its `requested`
// entry, an edge together with a request) is the bug. The hook fires right after the target read on attempt 1, so the
// protect is issued while the transaction holds the lock; it retries on lock timeouts until it commits.
func TestFollow_Integration_ProtectRacingWithFollowIsSerialized(t *testing.T) {
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	ctx := context.Background()
	client, err := firestore.NewClient(ctx, fmt.Sprintf("demo-test-%d", rand.Int63()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })

	repo := NewFirestoreRepo(client)
	idRepo := identity.NewFirestoreRepo(client, repo)
	repo.SetCounters(idRepo)
	svc := identity.New(idRepo, identity.NewCache(time.Minute), 7*24*time.Hour)

	const rounds = 6
	sawEdge, sawRequest := 0, 0
	for i := 0; i < rounds; i++ {
		follower, target := fmt.Sprintf("uid-f%d", i), fmt.Sprintf("uid-t%d", i)
		for _, u := range []string{follower, target} {
			if _, err := svc.CreateProfile(ctx, u, "0123456789abcdef", "user_"+u[4:], "Name"); err != nil {
				t.Fatal(err)
			}
		}

		var wg sync.WaitGroup
		protectErrs := make(chan error, 1)
		var once sync.Once
		repo.hooks.afterTargetRead = func(_ context.Context, attempt int) {
			if attempt != 1 {
				return
			}
			once.Do(func() {
				wg.Add(1)
				go func() {
					defer wg.Done()
					var last error
					for try := 0; try < 10; try++ {
						wctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
						_, last = client.Collection("users").Doc(target).Update(wctx, []firestore.Update{{Path: "isPrivate", Value: true}})
						cancel()
						if last == nil {
							protectErrs <- nil
							return
						}
					}
					protectErrs <- last
				}()
			})
		}

		cctx, counter := budget.WithCounter(ctx)
		rel, _, err := repo.Follow(cctx, follower, target, 200, time.Now())
		if err != nil {
			wg.Wait()
			t.Fatalf("round %d: Follow: %v", i, err)
		}
		wg.Wait()
		if perr := <-protectErrs; perr != nil {
			t.Fatalf("round %d: the racing protect never committed: %v", i, perr)
		}

		_, edgeErr := client.Doc("follows/" + follower + "_" + target).Get(ctx)
		_, reqErr := client.Doc("followRequests/" + follower + "_" + target).Get(ctx)
		hasEdge, hasReq := edgeErr == nil, reqErr == nil
		t.Logf("round %d: state %v, edge=%v request=%v, reads=%d writes=%d", i, rel.FollowState, hasEdge, hasReq, counter.Reads(), counter.Writes())
		switch rel.FollowState {
		case FollowStateFollowing:
			sawEdge++
			if !hasEdge || hasReq {
				t.Errorf("round %d: FOLLOWING but edge=%v request=%v", i, hasEdge, hasReq)
			}
		case FollowStateRequested:
			sawRequest++
			if hasEdge || !hasReq {
				t.Errorf("round %d: REQUESTED but edge=%v request=%v (I-X / I-R)", i, hasEdge, hasReq)
			}
		default:
			t.Errorf("round %d: FollowState = %v", i, rel.FollowState)
		}
		g, err := client.Collection("graph").Doc(follower).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var gd doc
		if err := g.DataTo(&gd); err != nil {
			t.Fatal(err)
		}
		if gd.hasFollowing(target) != hasEdge || gd.hasRequested(target) != hasReq {
			t.Errorf("round %d: graph arrays (following=%v requested=%v) disagree with the docs (edge=%v request=%v)",
				i, gd.hasFollowing(target), gd.hasRequested(target), hasEdge, hasReq)
		}
		if snap, err := client.Collection("users").Doc(target).Get(ctx); err != nil {
			t.Fatal(err)
		} else if v, _ := snap.DataAt("isPrivate"); v != true {
			t.Errorf("round %d: the racing protect did not land (isPrivate = %v)", i, v)
		}
	}
	t.Logf("%d rounds: %d committed first as an edge, %d saw the protect and became a request", rounds, sawEdge, sawRequest)

	// The ordering the lock cannot make ambiguous: a protect that committed BEFORE the Follow read it is a request,
	// whatever the instance caches say.
	for _, u := range []string{"uid-fa", "uid-ta"} {
		if _, err := svc.CreateProfile(ctx, u, "0123456789abcdef", "user_"+u[4:], "Name"); err != nil {
			t.Fatal(err)
		}
	}
	repo.hooks.afterTargetRead = nil
	if _, err := client.Collection("users").Doc("uid-ta").Update(ctx, []firestore.Update{{Path: "isPrivate", Value: true}}); err != nil {
		t.Fatal(err)
	}
	rel, _, err := repo.Follow(ctx, "uid-fa", "uid-ta", 200, time.Now())
	if err != nil || rel.FollowState != FollowStateRequested {
		t.Fatalf("Follow after a committed protect = %v, %v; want REQUESTED", rel.FollowState, err)
	}
}
