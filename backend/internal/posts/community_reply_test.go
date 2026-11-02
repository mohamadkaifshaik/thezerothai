package posts

import (
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func notMember() *apierr.Error {
	return apierr.New(connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "not a member").WithMeta("reason", "not_member")
}

// communityThreadEnv is newThreadEnv with the whole conversation under rRoot inside community testCommunityID (the root carries
// communityId and community; every reply inherits conversationCommunityId only).
func communityThreadEnv(g *fakeGate) *createEnv {
	e := newThreadEnv()
	for _, p := range e.repo.docs {
		p.ConversationCommunityID = testCommunityID
	}
	e.repo.docs[rRoot].CommunityID = testCommunityID
	e.repo.docs[rRoot].Community = &CommunityLabel{ID: testCommunityID, Name: "Go"}
	e.svc.community = g
	return e
}

// TestCreate_MembersOnlyReply: the rule keys on the parent's conversationCommunityId (W5-26b, ADR-0031 D5, F8).
func TestCreate_MembersOnlyReply(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		gate       *fakeGate
		parent     string
		mutate     func(e *createEnv)
		off        bool
		wantErr    string // "", "forbidden", "state"
		wantChecks int
	}{
		{"member replies to the root", &fakeGate{}, rRoot, nil, false, "", 1},
		{"member replies to a reply", &fakeGate{}, rReply1, nil, false, "", 1},
		{"non-member", &fakeGate{replyErr: notMember()}, rRoot, nil, false, "forbidden", 1},
		{"non-member, reply to a reply", &fakeGate{replyErr: notMember()}, rReply1, nil, false, "forbidden", 1},
		{"hidden root has no communityId and stays members only", &fakeGate{replyErr: notMember()}, rRoot, func(e *createEnv) {
			e.repo.docs[rRoot].CommunityID, e.repo.docs[rRoot].CommunityHidden = "", true
		}, false, "forbidden", 1},
		{"archived community", &fakeGate{replyErr: apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "archived")}, rRoot, nil, false, "state", 1},
		{"communities globally off: no gate", &fakeGate{replyErr: notMember()}, rRoot, nil, true, "", 0},
		{"not a community conversation: +0", &fakeGate{replyErr: notMember()}, rRoot, func(e *createEnv) {
			for _, p := range e.repo.docs {
				p.ConversationCommunityID = ""
			}
		}, false, "", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := communityThreadEnv(tt.gate)
			if tt.mutate != nil {
				tt.mutate(e)
			}
			_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "reply", ReplyToPostID: tt.parent, RepliesEnabled: true, CommunitiesGloballyOff: tt.off})
			switch tt.wantErr {
			case "":
				if err != nil {
					t.Fatal(err)
				}
			case "forbidden":
				ae := wantAPIError(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN)
				if ae.Metadata["reason"] != "not_member" {
					t.Fatalf("reason = %q", ae.Metadata["reason"])
				}
			case "state":
				wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE)
			}
			if tt.wantErr != "" && (c.Writes() != 0 || e.repo.createCalls != 0) {
				t.Fatalf("a refusal wrote: writes=%d creates=%d", c.Writes(), e.repo.createCalls)
			}
			if n, _ := tt.gate.counts(); n != tt.wantChecks {
				t.Fatalf("CanReply calls = %d, want %d", n, tt.wantChecks)
			}
		})
	}
}

// TestCreate_MembersOnlyReply_ErrorPath: a gate failure that is not a refusal is an internal error, not a leaked FORBIDDEN, and writes nothing.
func TestCreate_MembersOnlyReply_ErrorPath(t *testing.T) {
	t.Parallel()
	e := communityThreadEnv(&fakeGate{replyErr: errors.New("firestore unavailable")})
	_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "reply", ReplyToPostID: rRoot, RepliesEnabled: true})
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v, want a plain wrapped error", err)
	}
	if c.Writes() != 0 || e.repo.createCalls != 0 {
		t.Fatalf("writes=%d creates=%d", c.Writes(), e.repo.createCalls)
	}
}

// TestCreate_ReplyToPlainPostNeverAsksTheGate: the existing reply path is unchanged (+0 reads) even with a gate wired.
func TestCreate_ReplyToPlainPostNeverAsksTheGate(t *testing.T) {
	t.Parallel()
	g := &fakeGate{replyErr: notMember()}
	e := newThreadEnv()
	e.svc.community = g
	if _, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "reply", ReplyToPostID: rRoot, RepliesEnabled: true}); err != nil {
		t.Fatal(err)
	}
	if n, m := g.counts(); n != 0 || m != 0 {
		t.Fatalf("gate asked: %d %d", n, m)
	}
}

func TestToView_CommunityLabel(t *testing.T) {
	t.Parallel()
	label := &CommunityLabel{ID: testCommunityID, Name: "Go"}
	tests := []struct {
		name string
		p    *Post
		vs   ViewerSet
		want bool
	}{
		{"community post", &Post{Community: label}, ViewerSet{}, true},
		{"hidden", &Post{Community: label, CommunityHidden: true}, ViewerSet{}, false},
		{"globally off", &Post{Community: label}, ViewerSet{}.WithCommunitiesGloballyOff(), false},
		{"globally off survives BookmarksOnly", &Post{Community: label}, ViewerSet{}.WithCommunitiesGloballyOff().BookmarksOnly(), false},
		{"plain post", &Post{}, ViewerSet{}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			tt.p.ID, tt.p.Kind = rRoot, KindPost
			got := ToView(tt.p, tt.vs, "viewer").GetPost().GetCommunity()
			if (got != nil) != tt.want {
				t.Fatalf("community = %v, want present=%v", got, tt.want)
			}
			if tt.want && (got.GetId() != testCommunityID || got.GetName() != "Go") {
				t.Fatalf("community = %v", got)
			}
		})
	}
}

func TestHydrateViewer_CommunitiesGloballyOff(t *testing.T) {
	t.Parallel()
	reg := func(m flags.Mode) *flags.Registry {
		return flags.NewRegistry(flags.Spec{Name: CommunitiesFlagName, Mode: m})
	}
	for _, tt := range []struct {
		name string
		fc   FlagChecker
		want bool
	}{
		{"off", reg(flags.Off), true},
		{"allowlist with nobody is a rollout, not the kill switch", reg(flags.Allowlist), false},
		{"on", reg(flags.On), false},
	} {
		if got := HydrateViewer(t.Context(), tt.fc, nil, "u").communitiesOff; got != tt.want {
			t.Errorf("%s: communitiesOff = %v, want %v", tt.name, got, tt.want)
		}
	}
}

// TestServer_CommunityLabelAndReplyHint drives the real handlers (GetPost, GetThread) over the real service: the label, the kill
// switch, a hidden post, and the members-only viewer_reply_permission (A7).
func TestServer_CommunityLabelAndReplyHint(t *testing.T) {
	t.Parallel()
	registry := func(m flags.Mode) *flags.Registry {
		return flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: RepliesFlagName, Mode: flags.On}, flags.Spec{Name: CommunitiesFlagName, Mode: m})
	}
	tests := []struct {
		name      string
		mode      flags.Mode
		member    bool
		memberErr error
		hidden    bool
		wantLabel bool
		wantPerm  postsv1.ReplyPermission
		wantAsks  int
	}{
		{"member sees the label, may reply", flags.On, true, nil, false, true, postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED, 1},
		{"non-member: NOT_ALLOWED", flags.On, false, nil, false, true, postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED, 1},
		{"lookup failure keeps the advisory answer", flags.On, false, errors.New("boom"), false, true, postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED, 1},
		{"hidden: no label, still members only", flags.On, false, nil, true, false, postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED, 1},
		{"globally off: no label, no member read, ALLOWED", flags.Off, false, nil, false, false, postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			g := &fakeGate{member: tt.member, memberErr: tt.memberErr}
			e := communityThreadEnv(g)
			if tt.hidden {
				e.repo.docs[rRoot].CommunityID, e.repo.docs[rRoot].CommunityHidden = "", true
			}
			srv := NewServer(e.svc, registry(tt.mode))
			ctx := callerCtx(testUID)

			got, err := srv.GetPost(ctx, connect.NewRequest(&postsv1.GetPostRequest{PostId: rRoot}))
			if err != nil {
				t.Fatal(err)
			}
			if has := got.Msg.GetPost().GetPost().GetCommunity() != nil; has != tt.wantLabel {
				t.Fatalf("GetPost label = %v, want %v", has, tt.wantLabel)
			}
			if p := got.Msg.GetPost().GetViewerReplyPermission(); p != tt.wantPerm {
				t.Fatalf("GetPost perm = %v, want %v", p, tt.wantPerm)
			}

			th, err := srv.GetThread(ctx, connect.NewRequest(&postsv1.GetThreadRequest{PostId: rReply1}))
			if err != nil {
				t.Fatal(err)
			}
			if p := th.Msg.GetFocal().GetViewerReplyPermission(); p != tt.wantPerm {
				t.Fatalf("GetThread perm = %v, want %v", p, tt.wantPerm)
			}
			views := append([]*postsv1.PostView{th.Msg.GetFocal(), th.Msg.GetParent(), th.Msg.GetRoot()}, th.Msg.GetReplies()...)
			for _, v := range views {
				if v.GetPost().GetCommunity() != nil && (!tt.wantLabel || v.GetPost().GetPostId() != rRoot) {
					t.Fatalf("unexpected label on %s", v.GetPost().GetPostId())
				}
			}
			if _, asks := g.counts(); asks != 2*tt.wantAsks {
				t.Fatalf("IsMember calls = %d, want %d", asks, 2*tt.wantAsks)
			}
		})
	}
}

// TestCreatePost_ResponseCarriesTheLabel: the creator's own response shows the community they posted into.
func TestCreatePost_ResponseCarriesTheLabel(t *testing.T) {
	t.Parallel()
	e := gatedEnv(&fakeGate{name: "Go"})
	reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: CommunitiesFlagName, Mode: flags.On})
	resp, err := NewServer(e.svc, reg).CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key1, Text: "hi", CommunityId: testCommunityID}))
	if err != nil {
		t.Fatal(err)
	}
	if c := resp.Msg.GetPost().GetPost().GetCommunity(); c.GetId() != testCommunityID || c.GetName() != "Go" {
		t.Fatalf("community = %v", c)
	}
}
