package posts

import (
	"context"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// fakeGate is a CommunityGate for unit tests. Every field is read and written under mu: CI runs every Go test with -race.
type fakeGate struct {
	mu       sync.Mutex
	admitErr error
	name     string
	admits   int
	lastCID  string
	// The reply side. replyErr is what CanReply returns; member and memberErr answer IsMember.
	replyErr    error
	member      bool
	memberErr   error
	replyChecks int
	memberAsks  int
}

func (g *fakeGate) CanReply(context.Context, string, string) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.replyChecks++
	return g.replyErr
}

func (g *fakeGate) IsMember(context.Context, string, string) (bool, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.memberAsks++
	return g.member, g.memberErr
}

func (g *fakeGate) counts() (replyChecks, memberAsks int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.replyChecks, g.memberAsks
}

func (g *fakeGate) Admit(_ context.Context, cid string) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.admits++
	g.lastCID = cid
	return g.name, g.admitErr
}

func (g *fakeGate) CheckMember(context.Context, *firestore.Transaction, string, string) error {
	return nil
}

func (g *fakeGate) AllowPost(context.Context, string, string) error { return nil }

func (g *fakeGate) admitCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.admits
}

func (g *fakeGate) lastCommunity() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.lastCID
}

func gatedEnv(g *fakeGate) *createEnv {
	e := newCreateEnv()
	e.svc.community = g
	e.svc.communityPostsPerDay, e.svc.newAccountCommunityPostsPerDay = 50, 10
	return e
}

// TestCreate_CommunityShape: the 0-read refusals of a set community_id, with the flag on and a gate wired. None of them
// reaches the gate, the repo or Firestore.
func TestCreate_CommunityShape(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		in    CreateInput
		field string
	}{
		{"not 19 digits", CreateInput{CommunityID: "12345"}, "community_id"},
		{"a reply", CreateInput{CommunityID: testCommunityID, ReplyToPostID: rReply1, RepliesEnabled: true}, "community_id"},
		{"reply_policy FOLLOWING", CreateInput{CommunityID: testCommunityID, ReplyPolicy: 2, ReplyAudienceEnabled: true}, "reply_policy"},
		{"reply_policy MENTIONED_ONLY", CreateInput{CommunityID: testCommunityID, ReplyPolicy: 3, ReplyAudienceEnabled: true}, "reply_policy"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			g := &fakeGate{name: "Go"}
			e := gatedEnv(g)
			tt.in.IdempotencyKey, tt.in.Text, tt.in.CommunitiesEnabled = key1, "hello", true
			_, c, err := e.create(tt.in)
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != tt.field {
				t.Fatalf("field = %q, want %q", ae.Metadata["field"], tt.field)
			}
			if c.Reads() != 0 || c.Writes() != 0 || g.admitCount() != 0 || e.repo.createCalls != 0 {
				t.Fatalf("reads=%d writes=%d admits=%d creates=%d", c.Reads(), c.Writes(), g.admitCount(), e.repo.createCalls)
			}
		})
	}
	t.Run("reply_policy EVERYONE is accepted", func(t *testing.T) {
		t.Parallel()
		e := gatedEnv(&fakeGate{name: "Go"})
		_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi", CommunityID: testCommunityID, CommunitiesEnabled: true, ReplyPolicy: 1, ReplyAudienceEnabled: true})
		if err != nil {
			t.Fatal(err)
		}
	})
}

// TestCreate_CommunityGateOrder: protected caller first (0 reads, the gate is never asked), then the gate's own refusals pass through
// unchanged, 0 writes.
func TestCreate_CommunityGateOrder(t *testing.T) {
	t.Parallel()
	t.Run("protected caller", func(t *testing.T) {
		t.Parallel()
		g := &fakeGate{name: "Go"}
		e := gatedEnv(g)
		p := e.dir.profiles[testUID]
		p.IsPrivate = true
		e.dir.profiles[testUID] = p
		_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi", CommunityID: testCommunityID, CommunitiesEnabled: true})
		_ = wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT)
		if g.admitCount() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
			t.Fatalf("admits=%d writes=%d creates=%d", g.admitCount(), c.Writes(), e.repo.createCalls)
		}
	})
	t.Run("gate refusals pass through", func(t *testing.T) {
		t.Parallel()
		for _, want := range []*apierr.Error{
			apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "community not found"),
			apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "state").WithMeta("reason", "community_archived"),
		} {
			e := gatedEnv(&fakeGate{admitErr: want})
			_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi", CommunityID: testCommunityID, CommunitiesEnabled: true})
			_ = wantAPIError(t, err, want.Code, want.Reason)
			if c.Writes() != 0 || e.repo.createCalls != 0 {
				t.Fatalf("writes=%d creates=%d", c.Writes(), e.repo.createCalls)
			}
		}
	})
	t.Run("flag off with a gate wired never asks the gate", func(t *testing.T) {
		t.Parallel()
		g := &fakeGate{name: "Go"}
		e := gatedEnv(g)
		_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi", CommunityID: testCommunityID})
		ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		if ae.Metadata["feature"] != "communities" || g.admitCount() != 0 {
			t.Fatalf("feature=%q admits=%d", ae.Metadata["feature"], g.admitCount())
		}
	})
}

// TestCreate_CommunityPostFields: the draft the repo gets carries the feed key, the label snapshot, the conversation community and the
// right quota tier; a plain post carries none of it.
func TestCreate_CommunityPostFields(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		newAcct   bool
		wantLimit int64
	}{
		{"established account", false, 50},
		{"new account", true, 10},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			g := &fakeGate{name: "Go Lang"}
			e := gatedEnv(g)
			if tt.newAcct {
				p := e.dir.profiles[testUID]
				p.CreatedAt = time.Unix(1_700_000_000, 0).Add(-time.Hour)
				e.dir.profiles[testUID] = p
			}
			p, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi", CommunityID: testCommunityID, CommunitiesEnabled: true})
			if err != nil {
				t.Fatal(err)
			}
			if p.CommunityID != testCommunityID || p.ConversationCommunityID != testCommunityID || p.Community == nil || *p.Community != (CommunityLabel{ID: testCommunityID, Name: "Go Lang"}) {
				t.Fatalf("post = %+v", p)
			}
			cp := e.repo.lastCreate.Community
			if cp == nil || cp.QuotaLimit != tt.wantLimit || cp.Gate == nil {
				t.Fatalf("CreateParams.Community = %+v, want limit %d", cp, tt.wantLimit)
			}
			if g.admitCount() != 1 || g.lastCommunity() != testCommunityID {
				t.Fatalf("admits=%d cid=%q", g.admitCount(), g.lastCommunity())
			}
		})
	}
	t.Run("plain post has no community", func(t *testing.T) {
		t.Parallel()
		e := gatedEnv(&fakeGate{})
		p, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi", CommunitiesEnabled: true})
		if err != nil || p.CommunityID != "" || p.Community != nil || p.ConversationCommunityID != "" || e.repo.lastCreate.Community != nil {
			t.Fatalf("post = %+v err = %v", p, err)
		}
	})
}

// TestCreate_CommunityRequestHash: community_id is part of the hash only when set, so a plain retry hashes as before and the same key
// with another community is IDEMPOTENCY_KEY_REUSED.
func TestCreate_CommunityRequestHash(t *testing.T) {
	t.Parallel()
	e := gatedEnv(&fakeGate{name: "Go"})
	plain := CreateInput{IdempotencyKey: key1, Text: "hi", CommunitiesEnabled: true}
	if _, _, err := e.create(plain); err != nil {
		t.Fatal(err)
	}
	if want := requestHashWithPoll("hi", "", "", nil, nil, ReplyPolicyEveryone, false, false, nil); e.repo.lastCreate.RequestHash != want {
		t.Fatalf("plain hash changed: %q vs %q", e.repo.lastCreate.RequestHash, want)
	}
	in := plain
	in.CommunityID = testCommunityID
	_, _, err := e.create(in) // same key, now with a community
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)

	in.IdempotencyKey = key2
	if _, _, err := e.create(in); err != nil {
		t.Fatal(err)
	}
	in.CommunityID = "9234567890123456789"
	_, _, err = e.create(in)
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
}

// TestApplyReply_InheritsConversationCommunity: +0 reads; a parent without one changes nothing.
func TestApplyReply_InheritsConversationCommunity(t *testing.T) {
	t.Parallel()
	var p CreateParams
	applyReply(&p, &Post{ID: "1", ConversationID: "1", ConversationCommunityID: testCommunityID})
	if p.Draft.ConversationCommunityID != testCommunityID || p.Draft.CommunityID != "" || p.Draft.Community != nil {
		t.Fatalf("draft = %+v", p.Draft)
	}
	var q CreateParams
	applyReply(&q, &Post{ID: "1", ConversationID: "1"})
	if q.Draft.ConversationCommunityID != "" {
		t.Fatalf("draft = %+v", q.Draft)
	}
}

// TestCommunityBoundsOf: Window to id bounds, including the settle sentinel: After{W, zeroID} is the inclusive EndAt of
// the smallest Snowflake of millisecond W, so a post created in W itself is never hidden.
func TestCommunityBoundsOf(t *testing.T) {
	t.Parallel()
	w := time.Date(2026, 3, 4, 5, 6, 7, 89_000_000, time.UTC)
	wantMin := snowflake.MinID(w)
	id19 := "0123456789012345678"
	tests := []struct {
		name string
		in   Window
		want communityBounds
	}{
		{"no window", Window{}, communityBounds{}},
		{"before", Window{Before: &Position{CreatedAt: w, ID: id19}}, communityBounds{startAfter: id19}},
		{"after a real id", Window{After: &Position{CreatedAt: w, ID: id19}}, communityBounds{endBefore: id19}},
		{"after the sentinel", Window{After: &Position{CreatedAt: w, ID: zeroPostID}}, communityBounds{endAt: wantMin}},
		{"gap window", Window{Before: &Position{CreatedAt: w, ID: id19}, After: &Position{CreatedAt: w, ID: zeroPostID}}, communityBounds{startAfter: id19, endAt: wantMin}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := communityBoundsOf(tt.in); got != tt.want {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
		})
	}
	// In id order the sentinel bound is what "createdAt >= W" is in time order.
	if wantMin >= snowflake.MinID(w.Add(time.Millisecond)) || snowflake.MinID(w.Add(-time.Millisecond)) >= wantMin {
		t.Fatalf("MinID is not monotonic around W")
	}
}
