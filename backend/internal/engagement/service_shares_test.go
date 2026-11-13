package engagement

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// fakeShareRepo records the share calls; markers are "<postId>_<uid>".
type fakeShareRepo struct {
	mu        sync.Mutex
	markers   map[string]bool
	hasErr    error
	createOut ShareOutcome
	createErr error
	creates   int
	reads     int
}

func (f *fakeShareRepo) HasShare(_ context.Context, uid, postID string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads++
	return f.markers[postID+"_"+uid], f.hasErr
}

func (f *fakeShareRepo) CreateShare(_ context.Context, uid, postID string) (ShareOutcome, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.creates++
	if f.createErr != nil {
		return 0, f.createErr
	}
	if f.createOut == ShareCreated {
		if f.markers == nil {
			f.markers = map[string]bool{}
		}
		f.markers[postID+"_"+uid] = true
	}
	return f.createOut, nil
}

// shareFlags is a FlagChecker with the kill switch.
type shareFlags struct{ globallyOff bool }

func (shareFlags) Enabled(string, string) bool    { return true }
func (f shareFlags) GloballyOff(name string) bool { return f.globallyOff && name == ShareFlagName }
func newShareEnv(t *testing.T, flagsOff bool) (*env, *fakeShareRepo) {
	t.Helper()
	e := newEnv(t)
	sr := &fakeShareRepo{}
	e.posts.docs[pidA].ShareCount = 3
	m, err := New(Deps{
		Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{}, Events: e.events,
		AllowAnonymous: true, ShareRepo: sr, Flags: shareFlags{globallyOff: flagsOff},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.m = m
	return e, sr
}

func TestRecordShare(t *testing.T) {
	tests := []struct {
		name       string
		setup      func(e *env, sr *fakeShareRepo)
		uid, post  string
		key, chann string
		wantCode   connect.Code // 0 = success
		wantField  string       // VALIDATION metadata field
		counted    bool
		wantCount  int64
		wantCreate int
		wantReads  int
	}{
		{name: "first share counts once", uid: "viewer", post: pidA, counted: true, wantCount: 4, wantCreate: 1, wantReads: 1},
		{name: "a REPOST id records its original", uid: "viewer", post: pidRep, counted: true, wantCount: 4, wantCreate: 1, wantReads: 1},
		{name: "repeat share writes nothing", uid: "viewer", post: pidA, wantCount: 3, wantReads: 1,
			setup: func(_ *env, sr *fakeShareRepo) { sr.markers = map[string]bool{pidA + "_viewer": true} }},
		{name: "a concurrent first share won the Create", uid: "viewer", post: pidA, wantCount: 3, wantCreate: 1, wantReads: 1,
			setup: func(_ *env, sr *fakeShareRepo) { sr.createOut = ShareExists }},
		{name: "the author is never counted", uid: "author", post: pidA, wantCount: 3},
		{name: "a protected author's post is not counted", uid: "viewer", post: pidA, wantCount: 3,
			setup: func(e *env, _ *fakeShareRepo) { e.posts.shareRefused = map[string]bool{"author": true} }},
		{name: "hidden post is the one NOT_FOUND", uid: "viewer", post: pidA, wantCode: connect.CodeNotFound,
			setup: func(e *env, _ *fakeShareRepo) { e.posts.hidden[pidA] = true }},
		{name: "post deleted before the commit", uid: "viewer", post: pidA, wantCode: connect.CodeNotFound, wantCreate: 1, wantReads: 1,
			setup: func(_ *env, sr *fakeShareRepo) { sr.createOut = SharePostGone }},
		{name: "contention is UNAVAILABLE", uid: "viewer", post: pidA, wantCode: connect.CodeUnavailable, wantCreate: 1, wantReads: 1,
			setup: func(_ *env, sr *fakeShareRepo) { sr.createErr = store.ErrContended }},
		{name: "marker read failure is INTERNAL", uid: "viewer", post: pidA, wantCode: connect.CodeUnknown, wantReads: 1,
			setup: func(_ *env, sr *fakeShareRepo) { sr.hasErr = errors.New("boom") }},
		{name: "bad key", uid: "viewer", post: pidA, key: "short", wantCode: connect.CodeInvalidArgument, wantField: "idempotency_key"},
		{name: "bad post id", uid: "viewer", post: "123", wantCode: connect.CodeInvalidArgument, wantField: "post_id"},
		{name: "unspecified channel", uid: "viewer", post: pidA, chann: "-", wantCode: connect.CodeInvalidArgument, wantField: "channel"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e, sr := newShareEnv(t, false)
			if tt.setup != nil {
				tt.setup(e, sr)
			}
			key, ch := keyOK, "copy_link"
			if tt.key != "" {
				key = tt.key
			}
			if tt.chann == "-" {
				ch = ""
			}
			views := e.posts.viewCalls
			r, err := e.m.RecordShare(e.ctx, tt.uid, key, tt.post, ch)
			if tt.wantCode != 0 {
				if tt.wantCode == connect.CodeUnknown {
					if err == nil {
						t.Fatal("want an error")
					}
				} else {
					ae := requireCode(t, err, tt.wantCode)
					if tt.wantField != "" && ae.Metadata["field"] != tt.wantField {
						t.Fatalf("field = %q, want %q", ae.Metadata["field"], tt.wantField)
					}
				}
				if tt.wantField != "" && e.posts.viewCalls != views {
					t.Fatal("a shape refusal must come before any lookup")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				if r.PostID != pidA || r.Counted != tt.counted || r.ShareCount != tt.wantCount {
					t.Fatalf("result = %+v, want post %s counted=%v share_count=%d", r, pidA, tt.counted, tt.wantCount)
				}
			}
			if sr.creates != tt.wantCreate || sr.reads != tt.wantReads {
				t.Fatalf("creates=%d reads=%d, want %d and %d", sr.creates, sr.reads, tt.wantCreate, tt.wantReads)
			}
			wantShares := 0
			if tt.counted {
				wantShares = 1
			}
			if len(e.posts.shares) != wantShares {
				t.Fatalf("SharesChanged calls = %v, want %d", e.posts.shares, wantShares)
			}
		})
	}
}

// RecordShare refuses an unverified email before any lookup.
func TestRecordShare_VerifiedEmail(t *testing.T) {
	e, sr := newShareEnv(t, false)
	m, err := New(Deps{Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{}, ShareRepo: sr})
	if err != nil {
		t.Fatal(err)
	}
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "viewer", SignInProvider: "password"})
	_, err = m.RecordShare(ctx, "viewer", keyOK, pidA, "copy_link")
	ae := requireCode(t, err, connect.CodeFailedPrecondition)
	if ae.Reason != commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED || e.posts.viewCalls != 0 {
		t.Fatalf("reason=%v views=%d", ae.Reason, e.posts.viewCalls)
	}
}

// Record is the direct-message seam: best effort, never for the author, nothing while share_count is globally off.
func TestRecordDMShare(t *testing.T) {
	tests := []struct {
		name       string
		flagsOff   bool
		uid, post  string
		setup      func(sr *fakeShareRepo)
		counted    bool
		wantErr    bool
		wantCreate int
	}{
		{name: "first share", uid: "viewer", post: pidA, counted: true, wantCreate: 1},
		{name: "repeat", uid: "viewer", post: pidA, setup: func(sr *fakeShareRepo) { sr.markers = map[string]bool{pidA + "_viewer": true} }},
		{name: "author", uid: "author", post: pidA},
		{name: "globally off", flagsOff: true, uid: "viewer", post: pidA},
		{name: "post gone", uid: "viewer", post: "0000000000000000999"},
		{name: "a REPOST id is never counted", uid: "viewer", post: pidRep},
		{name: "post deleted before the commit", uid: "viewer", post: pidA, wantCreate: 1, setup: func(sr *fakeShareRepo) { sr.createOut = SharePostGone }},
		{name: "contention is returned for the caller to log", uid: "viewer", post: pidA, wantCreate: 1, wantErr: true,
			setup: func(sr *fakeShareRepo) { sr.createErr = store.ErrContended }},
		{name: "invalid id", uid: "viewer", post: "x", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e, sr := newShareEnv(t, tt.flagsOff)
			if tt.setup != nil {
				tt.setup(sr)
			}
			got, err := e.m.Record(e.ctx, tt.uid, tt.post)
			if (err != nil) != tt.wantErr || got != tt.counted || sr.creates != tt.wantCreate {
				t.Fatalf("counted=%v err=%v creates=%d, want %v err=%v creates=%d", got, err, sr.creates, tt.counted, tt.wantErr, tt.wantCreate)
			}
			if err != nil && strings.Contains(err.Error(), "viewer") {
				t.Fatalf("error carries a plain uid: %v", err)
			}
		})
	}
}

// A Flags checker without GloballyOff (or none) records nothing: a wiring gap never counts everything.
func TestRecordDMShare_NoKillSwitchRecordsNothing(t *testing.T) {
	e := newEnv(t)
	sr := &fakeShareRepo{}
	m, err := New(Deps{Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{}, ShareRepo: sr})
	if err != nil {
		t.Fatal(err)
	}
	if got, err := m.Record(e.ctx, "viewer", pidA); got || err != nil || sr.reads != 0 {
		t.Fatalf("counted=%v err=%v reads=%d", got, err, sr.reads)
	}
}

// onlyFlags enables exactly the listed wire names for every caller.
type onlyFlags map[string]bool

func (f onlyFlags) Enabled(_, name string) bool { return f[name] }

// The handler: FEATURE_POSTS then FEATURE_SHARE_COUNT on for the caller (feature=share_count), FEATURE_ENGAGEMENT is not
// needed, the channel maps to its log value, and share_count and counted reach the wire.
func TestServer_RecordPostShare(t *testing.T) {
	e, _ := newShareEnv(t, false)
	req := func(c engagementv1.ShareChannel) *connect.Request[engagementv1.RecordPostShareRequest] {
		return connect.NewRequest(&engagementv1.RecordPostShareRequest{IdempotencyKey: keyOK, PostId: pidA, Channel: c})
	}
	tests := []struct {
		name    string
		flags   onlyFlags
		channel engagementv1.ShareChannel
		code    connect.Code
		feature string
	}{
		{"posts off", onlyFlags{ShareFlagName: true}, engagementv1.ShareChannel_SHARE_CHANNEL_COPY_LINK, connect.CodeFailedPrecondition, ""},
		{"share_count off", onlyFlags{posts.FlagName: true, FlagName: true}, engagementv1.ShareChannel_SHARE_CHANNEL_COPY_LINK, connect.CodeFailedPrecondition, ShareFlagName},
		{"unspecified channel", onlyFlags{posts.FlagName: true, ShareFlagName: true}, engagementv1.ShareChannel_SHARE_CHANNEL_UNSPECIFIED, connect.CodeInvalidArgument, ""},
		{"counted without engagement", onlyFlags{posts.FlagName: true, ShareFlagName: true}, engagementv1.ShareChannel_SHARE_CHANNEL_SHARE_SHEET, 0, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := NewServer(e.m, tt.flags)
			resp, err := srv.RecordPostShare(e.ctx, req(tt.channel))
			if tt.code != 0 {
				ae := requireCode(t, err, tt.code)
				if tt.feature != "" && ae.Metadata["feature"] != tt.feature {
					t.Fatalf("feature = %q, want %q", ae.Metadata["feature"], tt.feature)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !resp.Msg.GetCounted() || resp.Msg.GetEngagement().GetShareCount() != 4 || resp.Msg.GetEngagement().GetPostId() != pidA {
				t.Fatalf("response = %v", resp.Msg)
			}
		})
	}
	// Without a PostShares implementation the RPC is Unimplemented after the gate.
	srv := NewServer(nopService{}, onlyFlags{posts.FlagName: true, ShareFlagName: true})
	if _, err := srv.RecordPostShare(e.ctx, req(engagementv1.ShareChannel_SHARE_CHANNEL_COPY_LINK)); connect.CodeOf(err) != connect.CodeUnimplemented {
		t.Fatalf("err = %v, want Unimplemented", err)
	}
}

// nopService implements Service only.
type nopService struct{}

func (nopService) Like(context.Context, string, string, string) (Result, error) { return Result{}, nil }
func (nopService) Unlike(context.Context, string, string, string) (Result, error) {
	return Result{}, nil
}
func (nopService) Repost(context.Context, string, string, string) (Result, error) {
	return Result{}, nil
}
func (nopService) UndoRepost(context.Context, string, string, string) (Result, error) {
	return Result{}, nil
}
