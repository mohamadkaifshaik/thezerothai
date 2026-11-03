package communities

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
)

// call adapts a Server method expression to a call with an empty request.
func call[Q, R any](m func(*Server, context.Context, *connect.Request[Q]) (*connect.Response[R], error)) func(*Server, context.Context) error {
	return func(s *Server, ctx context.Context) error {
		_, err := m(s, ctx, connect.NewRequest(new(Q)))
		return err
	}
}

// TestServer_FlagGateOnEveryRPC: all twelve CommunityService methods run the FEATURE_COMMUNITIES gate first, in every flag mode.
// Outside the flag the answer is FEATURE_DISABLED feature=communities (0 reads: the skeleton holds no repository); inside it with no Service wired the
// skeleton answers Unimplemented (the real service comes later); a request with no uid is Unauthenticated.
func TestServer_FlagGateOnEveryRPC(t *testing.T) {
	calls := map[string]func(*Server, context.Context) error{
		"CreateCommunity":      call((*Server).CreateCommunity),
		"UpdateCommunity":      call((*Server).UpdateCommunity),
		"GetCommunity":         call((*Server).GetCommunity),
		"ListCommunities":      call((*Server).ListCommunities),
		"ListMyCommunities":    call((*Server).ListMyCommunities),
		"JoinCommunity":        call((*Server).JoinCommunity),
		"LeaveCommunity":       call((*Server).LeaveCommunity),
		"ListCommunityMembers": call((*Server).ListCommunityMembers),
		"HideCommunityPost":    call((*Server).HideCommunityPost),
		"RestoreCommunityPost": call((*Server).RestoreCommunityPost),
		"SetMemberRole":        call((*Server).SetMemberRole),
		"ListModerationLog":    call((*Server).ListModerationLog),
	}
	if len(calls) != 12 {
		t.Fatalf("table has %d RPCs, want the 12 of CommunityService", len(calls))
	}
	for rpc, c := range calls {
		for _, m := range flagModes() {
			t.Run(rpc+"/"+m.name, func(t *testing.T) {
				s := NewServer(flags.NewRegistry(m.spec), nil)
				ctx := authn.WithClaims(context.Background(), authn.Claims{UID: m.uid})
				err := c(s, ctx)
				if m.wantOff {
					assertDisabled(t, err)
					return
				}
				if connect.CodeOf(err) != connect.CodeUnimplemented {
					t.Fatalf("err = %v, want Unimplemented (flag on, skeleton)", err)
				}
			})
		}
		t.Run(rpc+"/no uid", func(t *testing.T) {
			s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), nil)
			err := c(s, context.Background())
			var ce *connect.Error
			if !errors.As(err, &ce) || ce.Code() != connect.CodeUnauthenticated {
				t.Fatalf("err = %v, want Unauthenticated", err)
			}
		})
		t.Run(rpc+"/nil checker", func(t *testing.T) {
			s := NewServer(nil, nil)
			assertDisabled(t, c(s, authn.WithClaims(context.Background(), authn.Claims{UID: "in"})))
		})
	}
}

// TestServer_AllRoutesAreMounted: the generated handler carries exactly the twelve procedures this skeleton gates, so a new
// proto RPC without a gate shows up here.
func TestServer_AllRoutesAreMounted(t *testing.T) {
	desc := communitiesv1.File_dzeroth_communities_v1_communities_proto.Services().ByName("CommunityService")
	if desc == nil || desc.Methods().Len() != 12 {
		t.Fatalf("CommunityService has %v methods, want 12 (add the gate for a new RPC)", desc)
	}
}
