package graph

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-25b (ADR-0025 D12): ListFollowRequests and RespondToFollowRequest need FEATURE_GRAPH for the caller, then
// private_accounts not globally off or the caller protected now; past the gate they are Unimplemented until W3-28a.

func TestFollowRequestsGate_FlagModes(t *testing.T) {
	const uid = "uid-a"
	graphOn := flags.Spec{Name: graphFlagName, Mode: flags.On}
	pa := func(m flags.Mode, allow ...string) flags.Spec {
		set := map[string]struct{}{}
		for _, u := range allow {
			set[u] = struct{}{}
		}
		return flags.Spec{Name: PrivateAccountsFlagName, Mode: m, Allowlist: set}
	}
	tests := []struct {
		name        string
		specs       []flags.Spec
		protected   bool
		wantPass    bool   // the gate passes, so the RPC answers Unimplemented
		wantFeature string // metadata feature on a refusal ("" = FEATURE_GRAPH is off, the whole service)
		wantDirGets int    // identity.Directory lookups: only while private_accounts is globally off
	}{
		{"graph off", []flags.Spec{{Name: graphFlagName, Mode: flags.Off}, pa(flags.On)}, true, false, "", 0},
		{"private_accounts off, caller public", []flags.Spec{graphOn, pa(flags.Off)}, false, false, "private_accounts", 1},
		{"private_accounts off, caller protected now", []flags.Spec{graphOn, pa(flags.Off)}, true, true, "", 1},
		{"private_accounts not registered, caller public", []flags.Spec{graphOn}, false, false, "private_accounts", 1},
		{"allowlist without the caller is a rollout, not the kill switch", []flags.Spec{graphOn, pa(flags.Allowlist, "other")}, false, true, "", 0},
		{"allowlist with the caller", []flags.Spec{graphOn, pa(flags.Allowlist, uid)}, false, true, "", 0},
		{"percent 0 is a rollout too", []flags.Spec{graphOn, {Name: PrivateAccountsFlagName, Mode: flags.Percent}}, false, true, "", 0},
		{"on", []flags.Spec{graphOn, pa(flags.On)}, false, true, "", 0},
	}
	rpcs := map[string]func(context.Context, *Server) error{
		"ListFollowRequests": func(ctx context.Context, s *Server) error {
			_, err := s.ListFollowRequests(ctx, connect.NewRequest(&graphv1.ListFollowRequestsRequest{}))
			return err
		},
		"RespondToFollowRequest": func(ctx context.Context, s *Server) error {
			_, err := s.RespondToFollowRequest(ctx, connect.NewRequest(&graphv1.RespondToFollowRequestRequest{}))
			return err
		},
	}
	for _, tt := range tests {
		for name, call := range rpcs {
			t.Run(tt.name+"/"+name, func(t *testing.T) {
				repo := newFakeRepo()
				svc := New(Deps{Repo: repo, Cache: NewCache(time.Minute), Flags: flags.NewRegistry(tt.specs...)})
				dir := &countingDirectory{Directory: &fakeDirectory{profiles: map[string]identity.Profile{
					uid: {UserID: uid, Status: identity.AccountStatusActive, IsPrivate: tt.protected},
				}}}
				svc.SetDirectory(dir)
				ctx, counter := budget.WithCounter(w3Ctx(uid))

				err := call(ctx, NewServer(svc))
				if tt.wantPass {
					if connect.CodeOf(err) != connect.CodeUnimplemented {
						t.Errorf("err = %v, want Unimplemented past the gate", err)
					}
				} else if ae := featureDisabled(err); ae == nil || ae.Metadata["feature"] != tt.wantFeature {
					t.Errorf("err = %#v, want FEATURE_DISABLED feature=%q", err, tt.wantFeature)
				}
				if dir.gets != tt.wantDirGets || repo.calls != 0 {
					t.Errorf("directory gets = %d (want %d), graph snapshot reads = %d (want 0)", dir.gets, tt.wantDirGets, repo.calls)
				}
				if counter.Reads() != 0 || counter.Writes() != 0 {
					t.Errorf("charged reads=%d writes=%d, want 0", counter.Reads(), counter.Writes())
				}
			})
		}
	}
}
