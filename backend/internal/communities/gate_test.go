package communities

import (
	"context"
	"errors"
	"sync"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

type gateReader struct {
	c   Community
	err error
}

func (g gateReader) Get(context.Context, string) (Community, error) { return g.c, g.err }
func (gateReader) Role(context.Context, string, string) (Role, error) {
	return RoleNone, nil
}
func (gateReader) Memberships(context.Context, string) (Memberships, error) {
	return Memberships{}, nil
}

// gateMembers is a TxMemberReader; mu guards state because tests may call it from several goroutines under -race.
type gateMembers struct {
	mu    sync.Mutex
	state MemberState
	err   error
	calls int
}

func (m *gateMembers) MemberInTx(context.Context, *firestore.Transaction, string, string) (MemberState, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls++
	return m.state, m.err
}

func wantErr(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, meta, val string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != code || ae.Reason != reason {
		t.Fatalf("err = %v, want %v / %v", err, code, reason)
	}
	if meta != "" && ae.Metadata[meta] != val {
		t.Fatalf("metadata[%s] = %q, want %q", meta, ae.Metadata[meta], val)
	}
}

func TestPostGate_Admit(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		r        gateReader
		wantName string
		wantFn   func(t *testing.T, err error)
	}{
		{"active", gateReader{c: Community{Name: "Go", Status: StatusActive}}, "Go", nil},
		{"missing", gateReader{err: ErrNotFound}, "", func(t *testing.T, err error) {
			wantErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
		}},
		{"suspended is the same not found", gateReader{c: Community{Status: StatusSuspended}}, "", func(t *testing.T, err error) {
			wantErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
			if err.Error() != NotFoundError().Error() {
				t.Fatalf("suspended message differs from missing: %v", err)
			}
		}},
		{"archived", gateReader{c: Community{Status: StatusArchived}}, "", func(t *testing.T, err error) {
			wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "reason", "community_archived")
		}},
		{"read error is internal, not a refusal", gateReader{err: errors.New("boom")}, "", func(t *testing.T, err error) {
			var ae *apierr.Error
			if err == nil || errors.As(err, &ae) {
				t.Fatalf("err = %v, want a plain wrapped error", err)
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			name, err := NewPostGate(tt.r, &gateMembers{}, nil).Admit(context.Background(), testCID)
			if tt.wantFn == nil {
				if err != nil || name != tt.wantName {
					t.Fatalf("name=%q err=%v", name, err)
				}
				return
			}
			tt.wantFn(t, err)
		})
	}
}

func TestPostGate_CheckMember(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		state MemberState
		fn    func(t *testing.T, err error)
	}{
		{"joined", MemberJoined, func(t *testing.T, err error) {
			if err != nil {
				t.Fatal(err)
			}
		}},
		{"banned", MemberBanned, func(t *testing.T, err error) {
			wantErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "banned")
		}},
		{"no member doc", MemberNone, func(t *testing.T, err error) {
			wantErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "not_member")
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			m := &gateMembers{state: tt.state}
			tt.fn(t, NewPostGate(gateReader{}, m, nil).CheckMember(context.Background(), nil, testCID, "u1"))
			if m.calls != 1 {
				t.Fatalf("member reads = %d, want 1", m.calls)
			}
		})
	}
	t.Run("read error passes through", func(t *testing.T) {
		t.Parallel()
		boom := errors.New("boom")
		err := NewPostGate(gateReader{}, &gateMembers{err: boom}, nil).CheckMember(context.Background(), nil, testCID, "u1")
		if !errors.Is(err, boom) {
			t.Fatalf("err = %v", err)
		}
	})
}

// TestPostGate_AllowPost: the cap is keyed uid|cid, so one user's other community and another user are untouched.
func TestPostGate_AllowPost(t *testing.T) {
	t.Parallel()
	g := NewPostGate(gateReader{}, &gateMembers{}, ratelimit.NewDailyCap(2))
	ctx := context.Background()
	for i := 0; i < 2; i++ {
		if err := g.AllowPost(ctx, "u1", testCID); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	wantErr(t, g.AllowPost(ctx, "u1", testCID), connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "limit", LimitPostsPerCommunityDaily)
	if err := g.AllowPost(ctx, "u1", "9999999999999999999"); err != nil {
		t.Fatalf("another community: %v", err)
	}
	if err := g.AllowPost(ctx, "u2", testCID); err != nil {
		t.Fatalf("another user: %v", err)
	}
	if err := NewPostGate(gateReader{}, &gateMembers{}, nil).AllowPost(ctx, "u1", testCID); err != nil {
		t.Fatalf("nil cap: %v", err)
	}
}
