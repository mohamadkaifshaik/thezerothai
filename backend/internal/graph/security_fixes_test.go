package graph

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// M1: a page whose last scanned edge is hidden by the block filter still carries a token, and that token must
// not reveal the hidden row's uid (raw or base64-decoded).
func TestListFollowers_TokenLeaksNoHiddenUID(t *testing.T) {
	repo, dir := followersFixture(4) // newest first: f04 f03 f02 f01
	repo.snapshots["uid-1"] = Snapshot{BlockedBy: map[string]bool{"f03": true}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{CursorKey: []byte("k")})

	token := ""
	for i := 0; i < 5; i++ {
		page, err := svc.ListFollowers(context.Background(), "uid-1", "uid-t", 1, token)
		if err != nil {
			t.Fatal(err)
		}
		if page.NextPageToken == "" {
			return
		}
		raw, err := base64.RawURLEncoding.DecodeString(page.NextPageToken)
		if err != nil {
			t.Fatal(err)
		}
		for _, hay := range []string{page.NextPageToken, string(raw)} {
			if strings.Contains(hay, "f03") || strings.Contains(hay, "uid-t") {
				t.Fatalf("token %q leaks a uid", page.NextPageToken)
			}
		}
		token = page.NextPageToken
	}
	t.Fatal("list never ended")
}

// L3 + ADR-0008 A3: a Firestore-reserved id (__x__) or any uid containing the `_` edge separator is
// INVALID_ARGUMENT/VALIDATION on every graph RPC, before any repo call.
func TestGraphRPCs_ReservedIDIsValidation(t *testing.T) {
	for _, bad := range []string{"__x__", "a_b", "_ab", "ab_"} {
		t.Run(bad, func(t *testing.T) { testGraphRPCsRejectID(t, bad) })
	}
}

func testGraphRPCsRejectID(t *testing.T, bad string) {
	t.Helper()
	ctx := context.Background()
	calls := map[string]func(*service) error{
		"Follow":   func(s *service) error { _, err := s.Follow(ctx, "uid-1", validKey, bad); return err },
		"Unfollow": func(s *service) error { _, err := s.Unfollow(ctx, "uid-1", validKey, bad); return err },
		"Block":    func(s *service) error { _, err := s.Block(ctx, "uid-1", validKey, bad); return err },
		"Unblock":  func(s *service) error { _, err := s.Unblock(ctx, "uid-1", validKey, bad); return err },
		"Mute":     func(s *service) error { _, err := s.Mute(ctx, "uid-1", validKey, bad); return err },
		"Unmute":   func(s *service) error { _, err := s.Unmute(ctx, "uid-1", validKey, bad); return err },
		"ListFollowers": func(s *service) error {
			_, err := s.ListFollowers(ctx, "uid-1", bad, 20, "")
			return err
		},
		"ListFollowing": func(s *service) error {
			_, err := s.ListFollowing(ctx, "uid-1", bad, 20, "")
			return err
		},
		"GetRelationships": func(s *service) error {
			_, err := s.GetRelationships(ctx, "uid-1", []string{"uid-2", bad})
			return err
		},
	}
	for name, call := range calls {
		t.Run(name, func(t *testing.T) {
			repo := newFakeRepo()
			svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
			assertAPIErr(t, call(svc), connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if repo.calls+repo.followCalls+repo.unfollowCalls+repo.blockCalls+repo.unblockCalls+repo.muteCalls+repo.unmuteCalls+repo.edgeCalls != 0 {
				t.Error("validation must run before any repo call")
			}
		})
	}
}

// L4: an unexpected repo error never carries a raw uid (or an "A -> B" pair) in the message mw logs.
func TestMutations_ErrorsCarryNoRawUIDs(t *testing.T) {
	const caller, target = "uid-a", "uid-victim"
	boom := fmt.Errorf("rpc error: document projects/p/databases/(default)/documents/graph/%s failed; follows/%s_%s", target, caller, target)
	ctx := context.Background()
	profiles := map[string]identity.Profile{caller: activeProfile(caller, time.Now()), target: activeProfile(target, time.Now())}

	calls := map[string]func(*fakeRepo, *service) error{
		"Follow": func(r *fakeRepo, s *service) error {
			r.followErr = boom
			_, err := s.Follow(ctx, caller, validKey, target)
			return err
		},
		"Unfollow": func(r *fakeRepo, s *service) error {
			r.unfollowErr = boom
			_, err := s.Unfollow(ctx, caller, validKey, target)
			return err
		},
		"Block": func(r *fakeRepo, s *service) error {
			r.blockErr = boom
			_, err := s.Block(ctx, caller, validKey, target)
			return err
		},
		"Unblock": func(r *fakeRepo, s *service) error {
			r.unblockErr = boom
			_, err := s.Unblock(ctx, caller, validKey, target)
			return err
		},
		"Mute": func(r *fakeRepo, s *service) error {
			r.muteErr = boom
			_, err := s.Mute(ctx, caller, validKey, target)
			return err
		},
		"Unmute": func(r *fakeRepo, s *service) error {
			r.unmuteErr = boom
			_, err := s.Unmute(ctx, caller, validKey, target)
			return err
		},
		"ListFollowers": func(r *fakeRepo, s *service) error {
			r.err = boom
			_, err := s.ListFollowers(ctx, caller, target, 20, "")
			return err
		},
	}
	for name, call := range calls {
		t.Run(name, func(t *testing.T) {
			repo := newFakeRepo()
			svc := newTestServiceWithDirectory(repo, &fakeDirectory{profiles: profiles}, Deps{})
			err := call(repo, svc)
			if err == nil {
				t.Fatal("expected error")
			}
			// The full message a log line would show: Error() plus any unwrapped cause.
			msg := err.Error()
			for cause := errors.Unwrap(err); cause != nil; cause = errors.Unwrap(cause) {
				msg += " " + cause.Error()
			}
			for _, raw := range []string{caller, target} {
				if strings.Contains(msg, raw) {
					t.Errorf("error message %q contains raw uid %q", msg, raw)
				}
			}
			if !errors.Is(err, boom) {
				t.Error("redaction must keep errors.Is reaching the original cause")
			}
		})
	}
}

// D1: a lost lock race (Aborted, or the repo's exhausted-retry sentinel) is the retryable UNAVAILABLE, never
// INTERNAL, on every mutation.
func TestMutations_ContentionIsUnavailable(t *testing.T) {
	ctx := context.Background()
	aborted := status.Error(codes.Aborted, "Transaction lock timeout")
	for _, cause := range []error{aborted, fmt.Errorf("%w: %v", ErrContention, aborted)} {
		repo := newFakeRepo()
		repo.unfollowErr = cause
		repo.followErr = cause
		repo.blockErr = cause
		svc := newTestServiceWithDirectory(repo, &fakeDirectory{profiles: map[string]identity.Profile{
			"uid-a": activeProfile("uid-a", time.Now()), "uid-b": activeProfile("uid-b", time.Now()),
		}}, Deps{})
		_, e1 := svc.Unfollow(ctx, "uid-a", validKey, "uid-b")
		_, e2 := svc.Follow(ctx, "uid-a", validKey, "uid-b")
		_, e3 := svc.Block(ctx, "uid-a", validKey, "uid-b")
		for i, err := range []error{e1, e2, e3} {
			assertAPIErr(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
			if err == nil {
				t.Fatalf("call %d: nil error", i)
			}
		}
	}
}
