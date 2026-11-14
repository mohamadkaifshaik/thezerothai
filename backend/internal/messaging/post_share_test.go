package messaging

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	postOrig    = "0000000000000000101" // by postAuthor, visible to everyone
	postRepost  = "0000000000000000102" // a REPOST of postOrig
	postHidden  = "0000000000000000103" // nobody may see it
	postProtect = "0000000000000000104" // by a protected author alice follows
	postByAlice = "0000000000000000105" // alice's own post
	postAuthor  = "uid-post-author"     // the author of postOrig
)

// fakePostShare is the apiserver adapter's behaviour over a fixed world.
type fakePostShare struct {
	mu    sync.Mutex
	calls int
	err   error
}

func (f *fakePostShare) CheckShare(_ context.Context, uid, postID string) (SharedPost, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()
	if f.err != nil {
		return SharedPost{}, f.err
	}
	switch postID {
	case postOrig, postRepost:
		return SharedPost{ID: postOrig, AuthorID: postAuthor}, nil
	case postByAlice:
		return SharedPost{ID: postByAlice, AuthorID: alice}, nil
	case postProtect:
		if uid != "uid-protected" {
			return SharedPost{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, "this account's posts are protected")
		}
	}
	return SharedPost{}, ErrPostNotVisible
}

// fakeCards shows the posts in visible[reader] as a live card.
type fakeCards struct {
	mu      sync.Mutex
	visible map[string]map[string]bool
	err     error
	calls   [][]string
}

func (f *fakeCards) Cards(_ context.Context, reader string, ids []string) (map[string]*postsv1.EmbeddedPost, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, append([]string(nil), ids...))
	if f.err != nil {
		return nil, f.err
	}
	out := map[string]*postsv1.EmbeddedPost{}
	for _, id := range ids {
		if f.visible[reader][id] {
			out[id] = &postsv1.EmbeddedPost{PostId: id, Text: "live " + id}
		}
	}
	return out, nil
}

// fakeShares records the share records.
type fakeShares struct {
	mu    sync.Mutex
	calls []string
	err   error
}

func (f *fakeShares) Record(_ context.Context, uid, postID string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, uid+"/"+postID)
	return f.err == nil, f.err
}

type shareRig struct {
	*rig
	check  *fakePostShare
	cards  *fakeCards
	shares *fakeShares
}

// newShareRig is newRig with the three post-share seams and a registry where messaging, posts and dm_post_share have the
// given modes (on unless mut changes reg).
func newShareRig(t *testing.T, specs ...flags.Spec) *shareRig {
	t.Helper()
	if len(specs) == 0 {
		specs = []flags.Spec{{Name: postsFlagName, Mode: flags.On}, {Name: PostShareFlagName, Mode: flags.On}}
	}
	sr := &shareRig{check: &fakePostShare{}, cards: &fakeCards{visible: map[string]map[string]bool{
		alice: {postOrig: true}, bob: {postOrig: true},
	}}, shares: &fakeShares{}}
	sr.rig = newRig(t, func(r *rig) {
		r.reg = flags.NewRegistry(append([]flags.Spec{{Name: FlagName, Mode: flags.On}}, specs...)...)
	})
	r := sr.rig
	r.svc = New(r.reg, Deps{
		Repo: r.repo, Social: r.social, TxSocial: r.txSocial, TxProfiles: r.txProfs, AllowAnonymous: r.allowAnon, Profiles: r.profs,
		Events: r.events, Badge: r.badge, Limits: r.limits, CursorKey: testCursorKey, Now: func() time.Time { return r.now },
		PostShare: sr.check, Cards: sr.cards, Shares: sr.shares,
	}).(*service)
	return sr
}

func sharing(key, to, text, postID string) *messagingv1.SendMessageRequest {
	req := toUser(key, to, text)
	req.SharedPostId = postID
	return req
}

// The flags and the id shape run before any lookup: FEATURE_POSTS and FEATURE_DM_POST_SHARE on for the caller, then
// VALIDATION shared_post_id. Every refusal reads and writes nothing.
func TestSendPost_GatesBeforeAnyRead(t *testing.T) {
	off := func(name string) []flags.Spec {
		out := []flags.Spec{{Name: postsFlagName, Mode: flags.On}, {Name: PostShareFlagName, Mode: flags.On}}
		for i := range out {
			if out[i].Name == name {
				out[i].Mode = flags.Off
			}
		}
		return out
	}
	tests := []struct {
		name   string
		specs  []flags.Spec
		postID string
		code   connect.Code
		reason commonv1.ErrorReason
		meta   map[string]string
	}{
		{"dm_post_share off", off(PostShareFlagName), postOrig, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": PostShareFlagName}},
		{"posts off", off(postsFlagName), postOrig, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": postsFlagName}},
		{"not 19 digits", nil, "123", connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "shared_post_id"}},
		{"not digits", nil, "000000000000000000x", connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "shared_post_id"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newShareRig(t, tt.specs...)
			_, err := r.svc.Send(verifiedCtx(), alice, sharing(key1, bob, "look", tt.postID))
			wantAPI(t, err, tt.code, tt.reason, tt.meta)
			if r.repo.gets+len(r.repo.sends)+r.social.calls+r.profs.calls+r.check.calls != 0 {
				t.Errorf("a refused share read or wrote: gets %d sends %d graph %d profiles %d checks %d", r.repo.gets, len(r.repo.sends), r.social.calls, r.profs.calls, r.check.calls)
			}
		})
	}
}

// The visibility check answers GetPost's NOT_FOUND bytes for every cause, and a protected author's post sent by anyone
// else is PROTECTED_ACCOUNT; both write nothing and record nothing.
func TestSendPost_RefusalsWriteNothing(t *testing.T) {
	tests := []struct {
		name   string
		postID string
		err    error
		code   connect.Code
		reason commonv1.ErrorReason
	}{
		{"not visible", postHidden, nil, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED},
		{"protected author", postProtect, nil, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT},
		{"check fails", postOrig, errors.New("boom"), connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newShareRig(t)
			r.check.err = tt.err
			_, err := r.svc.Send(verifiedCtx(), alice, sharing(key1, bob, "look", tt.postID))
			if tt.code == connect.CodeInternal {
				if err == nil || errors.As(err, new(*apierr.Error)) {
					t.Fatalf("err = %v, want an internal error", err)
				}
			} else {
				wantAPI(t, err, tt.code, tt.reason, nil)
			}
			if tt.code == connect.CodeNotFound {
				ce := apierr.ToConnect(err)
				if ce.Message() != postNotFoundText {
					t.Fatalf("message = %q, want GetPost's %q", ce.Message(), postNotFoundText)
				}
			}
			if len(r.repo.sends) != 0 || len(r.shares.calls) != 0 {
				t.Fatalf("sends=%d records=%v, want none", len(r.repo.sends), r.shares.calls)
			}
		})
	}
}

// A share is a send: the stored id is the original's (a REPOST id resolves), the request digest binds shared_post_id as
// sent, the sender's response carries the card and the preview flag, and the share is recorded once after the commit.
func TestSendPost_StoresIDAndRecords(t *testing.T) {
	tests := []struct {
		name       string
		postID     string
		wantStored string
		wantRecord []string
	}{
		{"original", postOrig, postOrig, []string{alice + "/" + postOrig}},
		{"a REPOST id shares its original", postRepost, postOrig, []string{alice + "/" + postOrig}},
		{"the author's own post is not recorded", postByAlice, postByAlice, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newShareRig(t)
			resp, err := r.svc.Send(verifiedCtx(), alice, sharing(key1, bob, "https://dzeroth.app/post/x", tt.postID))
			if err != nil {
				t.Fatal(err)
			}
			p := r.repo.sends[0]
			if p.SharedPostID != tt.wantStored || p.RequestHash != requestHash(p.ConvID, "https://dzeroth.app/post/x", tt.postID) {
				t.Fatalf("stored %q hash %q, want %q bound to %q", p.SharedPostID, p.RequestHash, tt.wantStored, tt.postID)
			}
			if !resp.GetConversation().GetLastMessage().GetSharedPost() {
				t.Fatal("the preview must say shared_post")
			}
			if got := resp.GetMessage().GetSharedPost(); got.GetPostId() != tt.wantStored {
				t.Fatalf("card = %v, want post %s", got, tt.wantStored)
			}
			if len(r.shares.calls) != len(tt.wantRecord) || (len(tt.wantRecord) == 1 && r.shares.calls[0] != tt.wantRecord[0]) {
				t.Fatalf("records = %v, want %v", r.shares.calls, tt.wantRecord)
			}
		})
	}
}

// A replay records nothing; a failed record never fails the send; a message without a post reads no card and records
// nothing.
func TestSendPost_RecordIsBestEffort(t *testing.T) {
	t.Run("replay", func(t *testing.T) {
		r := newShareRig(t)
		r.repo.sendRes = SendResult{Replay: true, Msg: MsgDoc{SenderID: alice, Text: "x", State: msgVisible, SharedPostID: postOrig, CreatedAt: r.now}}
		if _, err := r.svc.Send(verifiedCtx(), alice, sharing(key1, bob, "x", postOrig)); err != nil {
			t.Fatal(err)
		}
		if len(r.shares.calls) != 0 {
			t.Fatalf("a replay recorded %v", r.shares.calls)
		}
	})
	t.Run("record fails", func(t *testing.T) {
		r := newShareRig(t)
		r.shares.err = errors.New("contended")
		if _, err := r.svc.Send(verifiedCtx(), alice, sharing(key1, bob, "x", postOrig)); err != nil {
			t.Fatalf("a failed record failed the send: %v", err)
		}
	})
	t.Run("no post", func(t *testing.T) {
		r := newShareRig(t)
		resp, err := r.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "hi"))
		if err != nil {
			t.Fatal(err)
		}
		if resp.GetMessage().GetSharedPost() != nil || resp.GetConversation().GetLastMessage().GetSharedPost() || len(r.cards.calls)+len(r.shares.calls)+r.check.calls != 0 {
			t.Fatalf("a plain message touched the share seams: cards %v records %v checks %d", r.cards.calls, r.shares.calls, r.check.calls)
		}
		if r.repo.sends[0].RequestHash != requestHash(r.repo.sends[0].ConvID, "hi", "") || r.repo.sends[0].SharedPostID != "" {
			t.Fatal("a plain message must keep the pre-shares digest and no post id")
		}
	})
}

// ListMessages decides each card for the reader: one batch over the page's distinct ids, the unavailable form for
// anything the reader may not see, for every message while dm_post_share is globally off or the batch fails, and no card on
// a tombstone. A page without a shared post makes no card call.
func TestListMessages_SharedPostCards(t *testing.T) {
	tests := []struct {
		name      string
		reader    string
		specs     []flags.Spec
		cardsErr  error
		wantCalls int
		want      map[string]*postsv1.EmbeddedPost // by message id
	}{
		{name: "reader sees the post", reader: bob, wantCalls: 1, want: map[string]*postsv1.EmbeddedPost{
			id(1): {PostId: postOrig, Text: "live " + postOrig}, id(2): {PostId: postHidden, Unavailable: true}, id(3): {PostId: postOrig, Text: "live " + postOrig},
		}},
		{name: "globally off", reader: bob, specs: []flags.Spec{{Name: postsFlagName, Mode: flags.On}, {Name: PostShareFlagName, Mode: flags.Off}}, want: map[string]*postsv1.EmbeddedPost{
			id(1): {PostId: postOrig, Unavailable: true}, id(2): {PostId: postHidden, Unavailable: true}, id(3): {PostId: postOrig, Unavailable: true},
		}},
		{name: "batch fails", reader: alice, cardsErr: errors.New("boom"), wantCalls: 1, want: map[string]*postsv1.EmbeddedPost{
			id(1): {PostId: postOrig, Unavailable: true}, id(2): {PostId: postHidden, Unavailable: true}, id(3): {PostId: postOrig, Unavailable: true},
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newShareRig(t, tt.specs...)
			r.cards.err = tt.cardsErr
			rows := r.putThread(5, nil)
			rows[0].SharedPostID = postOrig
			rows[1].SharedPostID = postHidden
			rows[2].SharedPostID = postOrig
			rows[3].SharedPostID, rows[3].State, rows[3].Text = postOrig, msgRemoved, "" // a tombstone keeps no card
			r.repo.msgs[aliceBobConv] = rows
			resp := r.listMsgs(t, tt.reader, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
			if len(r.cards.calls) != tt.wantCalls || (tt.wantCalls == 1 && len(r.cards.calls[0]) != 2) {
				t.Fatalf("card calls = %v, want %d call(s) over the 2 distinct ids", r.cards.calls, tt.wantCalls)
			}
			for _, m := range resp.GetMessages() {
				want := tt.want[m.GetId()]
				if !proto.Equal(m.GetSharedPost(), want) {
					t.Errorf("message %s card = %v, want %v", m.GetId(), m.GetSharedPost(), want)
				}
			}
		})
	}
	t.Run("no shared post, no card read", func(t *testing.T) {
		r := newShareRig(t)
		r.putThread(3, nil)
		r.listMsgs(t, bob, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
		if len(r.cards.calls) != 0 {
			t.Fatalf("card calls = %v, want none", r.cards.calls)
		}
	})
}

// id is the message id putThread gives its i-th row (1-based).
func id(i int) string { return fmt.Sprintf("%032x", i) }

// The inbox preview carries shared_post only on a VISIBLE message; a tombstone's preview never does.
func TestPreviewOf_SharedPost(t *testing.T) {
	tests := []struct {
		state string
		want  bool
	}{{msgVisible, true}, {msgRemoved, false}, {msgDeletedAccount, false}}
	for _, tt := range tests {
		t.Run(tt.state, func(t *testing.T) {
			p := previewOf(EntryRow{EntryDoc: EntryDoc{Last: LastDoc{State: tt.state, SharedPost: true, Snippet: "s"}}})
			if p.GetSharedPost() != tt.want {
				t.Fatalf("shared_post = %v, want %v", p.GetSharedPost(), tt.want)
			}
		})
	}
}

// LastDoc.fields always writes sharedPost: the entry is written with MergeAll, so a leaf left out would survive from the
// previous message.
func TestLastDocFields_AlwaysWritesSharedPost(t *testing.T) {
	fields := LastDoc{}.fields()
	if v, ok := fields["sharedPost"]; !ok || v != false {
		t.Fatalf("fields = %v, want sharedPost=false written", fields)
	}
}
