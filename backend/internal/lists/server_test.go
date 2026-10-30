package lists

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestServer_FlagGateOnEveryRPC: all seven ListService methods run the FEATURE_LISTS gate first, in every flag mode. Outside
// the flag the answer is FEATURE_DISABLED feature=lists; inside it the skeleton answers Unimplemented (the real service is
// W5-4 to W5-7); a request with no uid is Unauthenticated.
func TestServer_FlagGateOnEveryRPC(t *testing.T) {
	calls := map[string]func(s *Server, ctx context.Context) error{
		"CreateList": func(s *Server, ctx context.Context) error {
			_, err := s.CreateList(ctx, connect.NewRequest(&listsv1.CreateListRequest{}))
			return err
		},
		"UpdateList": func(s *Server, ctx context.Context) error {
			_, err := s.UpdateList(ctx, connect.NewRequest(&listsv1.UpdateListRequest{}))
			return err
		},
		"DeleteList": func(s *Server, ctx context.Context) error {
			_, err := s.DeleteList(ctx, connect.NewRequest(&listsv1.DeleteListRequest{}))
			return err
		},
		"GetList": func(s *Server, ctx context.Context) error {
			_, err := s.GetList(ctx, connect.NewRequest(&listsv1.GetListRequest{}))
			return err
		},
		"ListUserLists": func(s *Server, ctx context.Context) error {
			_, err := s.ListUserLists(ctx, connect.NewRequest(&listsv1.ListUserListsRequest{}))
			return err
		},
		"AddListMember": func(s *Server, ctx context.Context) error {
			_, err := s.AddListMember(ctx, connect.NewRequest(&listsv1.AddListMemberRequest{}))
			return err
		},
		"RemoveListMember": func(s *Server, ctx context.Context) error {
			_, err := s.RemoveListMember(ctx, connect.NewRequest(&listsv1.RemoveListMemberRequest{}))
			return err
		},
		"ListListMembers": func(s *Server, ctx context.Context) error {
			_, err := s.ListListMembers(ctx, connect.NewRequest(&listsv1.ListListMembersRequest{}))
			return err
		},
	}
	allow := map[string]struct{}{"in": {}}
	modes := []struct {
		name    string
		spec    flags.Spec
		uid     string
		wantOff bool
	}{
		{"off", flags.Spec{Name: FlagName, Mode: flags.Off, Allowlist: allow}, "in", true},
		{"allowlist, listed", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "in", false},
		{"allowlist, unlisted", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "out", true},
		{"percent 0", flags.Spec{Name: FlagName, Mode: flags.Percent}, "in", true},
		{"percent 100", flags.Spec{Name: FlagName, Mode: flags.Percent, Percent: 100}, "out", false},
		{"on", flags.Spec{Name: FlagName, Mode: flags.On}, "out", false},
	}
	for rpc, call := range calls {
		for _, m := range modes {
			t.Run(rpc+"/"+m.name, func(t *testing.T) {
				s := NewServer(flags.NewRegistry(m.spec))
				ctx := authn.WithClaims(context.Background(), authn.Claims{UID: m.uid})
				err := call(s, ctx)
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
			s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}))
			err := call(s, context.Background())
			var ce *connect.Error
			if !errors.As(err, &ce) || ce.Code() != connect.CodeUnauthenticated {
				t.Fatalf("err = %v, want Unauthenticated", err)
			}
		})
	}
}
