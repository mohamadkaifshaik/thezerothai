package search

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// rpcs calls each of the three RPCs through the Server and returns {name, flag, err}.
type rpcCase struct {
	name string
	flag string
	call func(*Server, context.Context) error
}

var rpcCases = []rpcCase{
	{"SearchPeople", FlagSearch, func(s *Server, ctx context.Context) error {
		_, err := s.SearchPeople(ctx, connect.NewRequest(&searchv1.SearchPeopleRequest{Query: "ab"}))
		return err
	}},
	{"SearchPosts", FlagSearch, func(s *Server, ctx context.Context) error {
		_, err := s.SearchPosts(ctx, connect.NewRequest(&searchv1.SearchPostsRequest{Query: "go"}))
		return err
	}},
	{"GetTrends", FlagTrends, func(s *Server, ctx context.Context) error {
		_, err := s.GetTrends(ctx, connect.NewRequest(&searchv1.GetTrendsRequest{}))
		return err
	}},
}

func signedIn(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid})
}

func apiErr(t *testing.T, err error) *apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want an *apierr.Error", err)
	}
	return ae
}

// TestFlagModes: each RPC is FEATURE_DISABLED (FAILED_PRECONDITION, metadata feature=<its flag>) unless its own flag is on
// for the caller, in every mode (off, allowlist, percent, on); an enabled caller gets Unimplemented until the RPC is built.
// A flag never opens the other flag's RPCs. The registry holds no store, so no case can read Firestore.
func TestFlagModes(t *testing.T) {
	const in, out = "uid-in", "uid-out"
	// Percent 100 puts every uid in; Percent 0 puts only allowlisted uids in.
	modes := []struct {
		name    string
		spec    func(flag string) flags.Spec
		wantIn  bool
		wantOut bool
	}{
		{"off", func(f string) flags.Spec { return flags.Spec{Name: f, Mode: flags.Off} }, false, false},
		{"allowlist", func(f string) flags.Spec {
			return flags.Spec{Name: f, Mode: flags.Allowlist, Allowlist: map[string]struct{}{in: {}}}
		}, true, false},
		{"percent 0 + allowlist", func(f string) flags.Spec {
			return flags.Spec{Name: f, Mode: flags.Percent, Percent: 0, Allowlist: map[string]struct{}{in: {}}}
		}, true, false},
		{"percent 100", func(f string) flags.Spec { return flags.Spec{Name: f, Mode: flags.Percent, Percent: 100} }, true, true},
		{"on", func(f string) flags.Spec { return flags.Spec{Name: f, Mode: flags.On} }, true, true},
	}
	for _, rpc := range rpcCases {
		other := FlagSearch
		if rpc.flag == FlagSearch {
			other = FlagTrends
		}
		for _, m := range modes {
			t.Run(rpc.name+"/"+m.name, func(t *testing.T) {
				// Only the RPC's own flag carries the mode; the other flag is on, to prove it opens nothing here.
				reg := flags.NewRegistry(m.spec(rpc.flag), flags.Spec{Name: other, Mode: flags.On})
				srv := NewServer(New(reg, WithTrends(&fakeTrendsStore{}, nil)))
				for uid, wantOn := range map[string]bool{in: m.wantIn, out: m.wantOut} {
					err := rpc.call(srv, signedIn(uid))
					if wantOn && rpc.name == "GetTrends" {
						if err != nil {
							t.Errorf("%s: GetTrends err = %v, want nil (built in W4-10)", uid, err)
						}
						continue
					}
					ae := apiErr(t, err)
					if wantOn {
						if ae.Code != connect.CodeUnimplemented {
							t.Errorf("%s: code = %v, want Unimplemented (skeleton)", uid, ae.Code)
						}
						continue
					}
					if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
						t.Errorf("%s: %v / %v, want FAILED_PRECONDITION FEATURE_DISABLED", uid, ae.Code, ae.Reason)
					}
					if got := ae.Metadata["feature"]; got != rpc.flag {
						t.Errorf("%s: metadata feature = %q, want %q", uid, got, rpc.flag)
					}
				}
			})
		}
	}
}

// TestNilFlagsIsOff: a Service built without a flag checker refuses everyone (fail closed), and an unauthenticated call is
// Unauthenticated before the flag is consulted.
func TestNilFlagsIsOff(t *testing.T) {
	srv := NewServer(New(nil))
	for _, rpc := range rpcCases {
		t.Run(rpc.name, func(t *testing.T) {
			ae := apiErr(t, rpc.call(srv, signedIn("uid-a")))
			if ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != rpc.flag {
				t.Errorf("nil checker: %v feature=%q, want FEATURE_DISABLED feature=%s", ae.Reason, ae.Metadata["feature"], rpc.flag)
			}
			if ae := apiErr(t, rpc.call(srv, context.Background())); ae.Code != connect.CodeUnauthenticated {
				t.Errorf("no caller: code = %v, want Unauthenticated", ae.Code)
			}
		})
	}
}
