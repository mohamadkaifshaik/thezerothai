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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
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

// W5-26b: the members-only reply rule over the real service (its 60 s member cache) and over a Reader that cannot answer a member lookup alone.
func TestPostGate_CanReply(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		status     Status
		member     MemberState
		wantReason string // "" = allowed
		wantState  bool
		wantReads  int64
	}{
		{"joined member", StatusActive, MemberJoined, "", false, 2},
		{"non-member", StatusActive, MemberNone, "not_member", false, 2},
		{"banned looks like a non-member", StatusActive, MemberBanned, "not_member", false, 2},
		{"archived", StatusArchived, MemberJoined, "", true, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			f.seed(Community{ID: testCID, Name: "Go", Status: tt.status})
			f.repo.members[testCID+"|u1"] = tt.member
			g := NewPostGate(f.svc, &gateMembers{}, nil)
			ctx, c := budget.WithCounter(context.Background())
			err := g.CanReply(ctx, "u1", testCID)
			switch {
			case tt.wantState:
				wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "reason", "community_archived")
			case tt.wantReason != "":
				wantErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", tt.wantReason)
			case err != nil:
				t.Fatal(err)
			}
			if c.Reads() != tt.wantReads {
				t.Fatalf("cold reads = %d, want %d", c.Reads(), tt.wantReads)
			}
			// Warm: +0 reads.
			ctx2, c2 := budget.WithCounter(context.Background())
			_ = g.CanReply(ctx2, "u1", testCID)
			if c2.Reads() != 0 {
				t.Fatalf("warm reads = %d, want 0", c2.Reads())
			}
		})
	}
	t.Run("missing and suspended are the one not found", func(t *testing.T) {
		t.Parallel()
		f := newFixture()
		f.seed(Community{ID: testCID, Status: StatusSuspended})
		g := NewPostGate(f.svc, &gateMembers{}, nil)
		wantErr(t, g.CanReply(context.Background(), "u1", testCID), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
		wantErr(t, g.CanReply(context.Background(), "u1", "1000000000000000099"), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	})
}

func TestPostGate_IsMember(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID})
	f.repo.members[testCID+"|u1"] = MemberJoined
	f.repo.members[testCID+"|u2"] = MemberBanned
	g := NewPostGate(f.svc, &gateMembers{}, nil)
	for uid, want := range map[string]bool{"u1": true, "u2": false, "u3": false} {
		ctx, c := budget.WithCounter(context.Background())
		got, err := g.IsMember(ctx, uid, testCID)
		if err != nil || got != want {
			t.Fatalf("%s: member=%v err=%v, want %v", uid, got, err, want)
		}
		if c.Reads() != 1 {
			t.Fatalf("%s: cold reads = %d, want 1 (the member doc only; the community is not loaded)", uid, c.Reads())
		}
	}
	// warm, and the community document was never read.
	ctx, c := budget.WithCounter(context.Background())
	if ok, _ := g.IsMember(ctx, "u1", testCID); !ok || c.Reads() != 0 || f.repo.gets != 0 {
		t.Fatalf("warm: ok=%v reads=%d community gets=%d", ok, c.Reads(), f.repo.gets)
	}
	t.Run("a Reader without member lookup falls back to Role", func(t *testing.T) {
		t.Parallel()
		ok, err := NewPostGate(roleReader{role: RoleModerator}, &gateMembers{}, nil).IsMember(context.Background(), "u", testCID)
		if err != nil || !ok {
			t.Fatalf("moderator: %v %v", ok, err)
		}
		ok, _ = NewPostGate(roleReader{role: RoleBanned}, &gateMembers{}, nil).IsMember(context.Background(), "u", testCID)
		if ok {
			t.Fatal("banned counted as a member")
		}
		if _, err = NewPostGate(roleReader{err: errors.New("boom")}, &gateMembers{}, nil).IsMember(context.Background(), "u", testCID); err == nil {
			t.Fatal("a read failure must be an error, not a refusal")
		}
	})
}

type roleReader struct {
	gateReader
	role Role
	err  error
}

func (r roleReader) Role(context.Context, string, string) (Role, error) { return r.role, r.err }
