package posts

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Ids of the replies fixtures. Zero-padded 19 digits so lexical order is chronological order.
const (
	rRoot   = "0000000000000000100" // by zed
	rReply1 = "0000000000000000101" // by carol, reply to rRoot
	rReply2 = "0000000000000000102" // by blocked, reply to rReply1
	rReply3 = "0000000000000000103" // by muted, reply to rReply1
	rReply4 = "0000000000000000104" // by alice (the caller), reply to rReply1
	rReply5 = "0000000000000000105" // by dave, reply to rReply4
	rReply6 = "0000000000000000106" // by dave, reply to rReply1
)

const (
	uZed     = "uid-zed"
	uCarol   = "uid-carol"
	uBlocked = "uid-blocked"
	uMuted   = "uid-muted"
	uDave    = "uid-dave"
)

func replyPost(id, author, handle, replyTo, conv string) *Post {
	p := post(id, author)
	p.Author = AuthorSnapshot{UserID: author, Handle: handle}
	p.ConversationID = conv
	if replyTo != "" {
		p.Kind, p.IsReply, p.ReplyToID = KindReply, true, replyTo
	}
	return p
}

// newThreadEnv seeds a small conversation under rRoot and gives the service a cursor key.
func newThreadEnv() *createEnv {
	e := newCreateEnv()
	for _, p := range []*Post{
		replyPost(rRoot, uZed, "zed", "", rRoot),
		replyPost(rReply1, uCarol, "carol", rRoot, rRoot),
		replyPost(rReply2, uBlocked, "blocked", rReply1, rRoot),
		replyPost(rReply3, uMuted, "muted", rReply1, rRoot),
		replyPost(rReply4, testUID, "Alice", rReply1, rRoot),
		replyPost(rReply5, uDave, "dave", rReply4, rRoot),
		replyPost(rReply6, uDave, "dave", rReply1, rRoot),
	} {
		e.repo.docs[p.ID] = p
	}
	for _, u := range []string{uZed, uCarol, uBlocked, uMuted, uDave} {
		e.dir.profiles[u] = identity.Profile{UserID: u, Handle: u, Status: identity.AccountStatusActive}
	}
	e.graph.snap = graph.Snapshot{Blocked: map[string]bool{uBlocked: true}, Muted: map[string]bool{uMuted: true}}
	now := time.Unix(1_700_000_000, 0)
	e.svc = New(Deps{
		Repo: e.repo, Cache: e.cache, Events: e.events, Directory: e.dir, Graph: e.graph,
		PostsPerDay: 100, NewAccountPostsPerDay: 20, NewAccountWindow: 24 * time.Hour,
		CursorKey: []byte("0123456789abcdef0123456789abcdef"), Now: func() time.Time { return now },
	}).(*service)
	return e
}

func (e *createEnv) thread(in ThreadInput) (*Thread, *budget.Counter, error) {
	ctx, c := budget.WithCounter(googleCtx(context.Background(), testUID))
	t, err := e.svc.GetThread(ctx, testUID, in)
	return t, c, err
}

func idsOf(ps []*Post) []string {
	out := []string{}
	for _, p := range ps {
		out = append(out, p.ID)
	}
	return out
}

// --- CreatePost: the reply path -------------------------------------------------------------------------

func TestCreateReply_StoresReplyShapeAndBumpsParent(t *testing.T) {
	e := newThreadEnv()
	e.cache.StoreAuthorRecent(testUID, nil, false, time.Now())
	root := e.repo.docs[rRoot]

	p, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "good point", ReplyToPostID: rRoot, RepliesEnabled: true})
	if err != nil {
		t.Fatal(err)
	}
	if p.Kind != KindReply || !p.IsReply || p.ReplyToID != rRoot || p.ReplyToHandle != "zed" || p.ConversationID != rRoot {
		t.Fatalf("reply shape: %+v", p)
	}
	if root.ReplyCount != 1 {
		t.Fatalf("parent replyCount = %d, want 1", root.ReplyCount)
	}
	// 5 writes: idempotency, post, users.postsCount, quotas, parent replyCount. Reads (fakes): parent 1, caller
	// graph 1, idempotency 1, quotas 1; the plan ceiling is 15 cold.
	if c.Writes() != 5 || c.Reads() > 15 {
		t.Fatalf("writes=%d reads=%d, want 5 writes and <= 15 reads", c.Writes(), c.Reads())
	}
	// A reply is never a timeline item: the author-recent (Posts tab / Home) entry stays empty.
	if r, ok := e.svc.AuthorRecent(testUID); !ok || len(r.Posts) != 0 {
		t.Fatalf("author-recent after a reply = %+v, %v; want empty", r, ok)
	}
	if len(e.events.created) != 1 || !e.events.created[0].IsReply {
		t.Fatal("PostEvents.Created must fire once with the reply")
	}
}

func TestCreateReply_ToAReplyJoinsTheSameConversation(t *testing.T) {
	e := newThreadEnv()
	p, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "deeper", ReplyToPostID: rReply1, RepliesEnabled: true})
	if err != nil {
		t.Fatal(err)
	}
	if p.ReplyToID != rReply1 || p.ReplyToHandle != "carol" || p.ConversationID != rRoot {
		t.Fatalf("got reply_to=%s handle=%s conversation=%s", p.ReplyToID, p.ReplyToHandle, p.ConversationID)
	}
}

func TestCreateReply_FlagOffIsFeatureDisabledWithZeroReads(t *testing.T) {
	e := newThreadEnv()
	_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "x", ReplyToPostID: rRoot})
	ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if ae.Metadata["feature"] != "replies" || c.Reads() != 0 || c.Writes() != 0 {
		t.Fatalf("metadata=%v reads=%d writes=%d", ae.Metadata, c.Reads(), c.Writes())
	}
}

func TestCreateReply_NotFoundIsUniform(t *testing.T) {
	tests := []struct {
		name  string
		setup func(e *createEnv)
		to    string
	}{
		{"missing parent", func(*createEnv) {}, "0000000000000000999"},
		{"parent author blocks the caller", func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }, rRoot},
		{"parent author suspended or deleting", func(e *createEnv) { delete(e.dir.profiles, uZed) }, rRoot},
		{"parent not public", func(e *createEnv) { e.repo.docs[rRoot].Visibility = VisibilityFollowers }, rRoot},
		{"parent deleted before commit", func(e *createEnv) { e.repo.parentGone = true }, rRoot},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newThreadEnv()
			tc.setup(e)
			_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "x", ReplyToPostID: tc.to, RepliesEnabled: true})
			ae := wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
			if ae.Message != postNotFoundText {
				t.Fatalf("message = %q, want the one uniform answer", ae.Message)
			}
			if c.Writes() != 0 || e.repo.docs[rRoot] != nil && e.repo.docs[rRoot].ReplyCount != 0 {
				t.Fatalf("writes=%d, want 0 and no counter change", c.Writes())
			}
		})
	}
}

func TestCreateReply_InvalidParentID(t *testing.T) {
	e := newThreadEnv()
	_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "x", ReplyToPostID: "abc", RepliesEnabled: true})
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	if c.Reads() != 0 {
		t.Fatalf("reads = %d, want 0", c.Reads())
	}
}

func TestCreateReply_IdempotencyKeyBindsTheParent(t *testing.T) {
	e := newThreadEnv()
	first, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "same", ReplyToPostID: rRoot, RepliesEnabled: true})
	if err != nil {
		t.Fatal(err)
	}
	// Same key, same body: replay returns the first post and does not bump again.
	again, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "same", ReplyToPostID: rRoot, RepliesEnabled: true})
	if err != nil || again.ID != first.ID || c.Writes() != 0 || e.repo.docs[rRoot].ReplyCount != 1 {
		t.Fatalf("replay: id=%v err=%v writes=%d count=%d", again, err, c.Writes(), e.repo.docs[rRoot].ReplyCount)
	}
	// Same key and text, different parent: a different request.
	_, _, err = e.create(CreateInput{IdempotencyKey: key1, Text: "same", ReplyToPostID: rReply1, RepliesEnabled: true})
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
}

// --- DeletePost of a reply ------------------------------------------------------------------------------

func TestDeleteReply_ReleasesTheParentCounter(t *testing.T) {
	e := newThreadEnv()
	e.repo.docs[rRoot].ReplyCount = 1
	c, outcome, err := e.del(rReply4)
	if err != nil || outcome != outcomeDeleted {
		t.Fatalf("err=%v outcome=%s", err, outcome)
	}
	if e.repo.replyCountCalls != 1 || e.repo.docs[rReply1].ReplyCount != -1 {
		t.Fatalf("calls=%d parent count=%d", e.repo.replyCountCalls, e.repo.docs[rReply1].ReplyCount)
	}
	if c.Writes() != 2 || c.Deletes() != 1 { // postsCount + parent replyCount; 1 delete
		t.Fatalf("writes=%d deletes=%d, want 2/1", c.Writes(), c.Deletes())
	}

	// A failing counter update never fails the delete.
	e.repo.replyCountErr = errBoom
	if _, outcome, err = e.del(rReply5); err == nil && outcome != "noop:not_owner" {
		t.Fatalf("someone else's reply must be a no-op, got %s", outcome)
	}
	e.repo.docs[rReply4] = replyPost(rReply4, testUID, "Alice", rReply1, rRoot)
	e.cache.DeletePost(rReply4)
	if _, outcome, err = e.del(rReply4); err != nil || outcome != outcomeDeleted {
		t.Fatalf("counter failure must not fail the delete: err=%v outcome=%s", err, outcome)
	}
}

func TestDeleteRoot_DoesNotTouchAnyCounter(t *testing.T) {
	e := newThreadEnv()
	e.repo.docs[rRoot].AuthorID = testUID
	if _, outcome, err := e.del(rRoot); err != nil || outcome != outcomeDeleted {
		t.Fatalf("err=%v outcome=%s", err, outcome)
	}
	if e.repo.replyCountCalls != 0 {
		t.Fatalf("replyCountCalls = %d, want 0", e.repo.replyCountCalls)
	}
}

// --- GetThread ------------------------------------------------------------------------------------------

func TestGetThread_ChronologicalAndFiltered(t *testing.T) {
	e := newThreadEnv()
	th, c, err := e.thread(ThreadInput{PostID: rReply1})
	if err != nil {
		t.Fatal(err)
	}
	if th.Focal.ID != rReply1 || th.Parent == nil || th.Parent.ID != rRoot || th.Root == nil || th.Root.ID != rRoot {
		t.Fatalf("context: focal=%v parent=%v root=%v", th.Focal.ID, th.Parent, th.Root)
	}
	// 102 (blocked) and 103 (muted) are dropped, the rest is oldest first, focal/parent/root excluded.
	if got, want := idsOf(th.Replies), []string{rReply4, rReply5, rReply6}; !reflect.DeepEqual(got, want) {
		t.Fatalf("replies = %v, want %v", got, want)
	}
	if th.NextPageToken != "" || th.ParentUnavailable || th.RootUnavailable {
		t.Fatalf("token=%q parentUnavailable=%v rootUnavailable=%v", th.NextPageToken, th.ParentUnavailable, th.RootUnavailable)
	}
	if e.repo.lastLimit != ThreadDefaultPageSize {
		t.Fatalf("query limit = %d, want the first-page default %d", e.repo.lastLimit, ThreadDefaultPageSize)
	}
	if c.Reads() > 38 || c.Writes() != 0 {
		t.Fatalf("reads=%d writes=%d, want <= 38 and 0", c.Reads(), c.Writes())
	}
}

func TestGetThread_RootFocalHasNoParent(t *testing.T) {
	e := newThreadEnv()
	th, _, err := e.thread(ThreadInput{PostID: rRoot})
	if err != nil {
		t.Fatal(err)
	}
	if th.Parent != nil || th.Root != nil || th.ParentUnavailable || th.RootUnavailable {
		t.Fatalf("a root focal has no parent/root: %+v", th)
	}
	if got, want := idsOf(th.Replies), []string{rReply1, rReply4, rReply5, rReply6}; !reflect.DeepEqual(got, want) {
		t.Fatalf("replies = %v, want %v", got, want)
	}
	if e.repo.lastAfter == nil || e.repo.lastAfter.ID != rRoot {
		t.Fatalf("the conversation query must start after the root, got %+v", e.repo.lastAfter)
	}
}

func TestGetThread_PagingWithOpaqueCursor(t *testing.T) {
	e := newThreadEnv()
	var all []string
	token := ""
	for i := 0; i < 6; i++ {
		th, _, err := e.thread(ThreadInput{PostID: rRoot, PageSize: 2, PageToken: token})
		if err != nil {
			t.Fatal(err)
		}
		all = append(all, idsOf(th.Replies)...)
		token = th.NextPageToken
		if token == "" {
			break
		}
	}
	if want := []string{rReply1, rReply4, rReply5, rReply6}; !reflect.DeepEqual(all, want) {
		t.Fatalf("paged replies = %v, want %v", all, want)
	}
	if token != "" {
		t.Fatal("paging never ended")
	}
}

func TestGetThread_PageTokenIsBoundAndValidated(t *testing.T) {
	e := newThreadEnv()
	th, _, err := e.thread(ThreadInput{PostID: rRoot, PageSize: 1})
	if err != nil || th.NextPageToken == "" {
		t.Fatalf("err=%v token=%q", err, th.NextPageToken)
	}
	// Another thread: rejected at 0 reads.
	_, c, err := e.thread(ThreadInput{PostID: rReply1, PageToken: th.NextPageToken})
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	if c.Reads() != 0 {
		t.Fatalf("reads = %d, want 0", c.Reads())
	}
	_, _, err = e.thread(ThreadInput{PostID: rRoot, PageToken: "garbage"})
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	_, _, err = e.thread(ThreadInput{PostID: "nope"})
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
}

func TestGetThread_PageSizeIsClamped(t *testing.T) {
	e := newThreadEnv()
	if _, _, err := e.thread(ThreadInput{PostID: rRoot, PageSize: 500}); err != nil {
		t.Fatal(err)
	}
	if e.repo.lastLimit != ThreadMaxPageSize {
		t.Fatalf("limit = %d, want %d", e.repo.lastLimit, ThreadMaxPageSize)
	}
}

func TestGetThread_DeletedParentRendersATombstone(t *testing.T) {
	e := newThreadEnv()
	delete(e.repo.docs, rRoot) // the root (also the parent of rReply1) is gone
	th, _, err := e.thread(ThreadInput{PostID: rReply1})
	if err != nil {
		t.Fatal(err)
	}
	if th.Parent != nil || !th.ParentUnavailable || th.Root != nil || !th.RootUnavailable {
		t.Fatalf("want tombstones for parent and root: %+v", th)
	}
	if got, want := idsOf(th.Replies), []string{rReply4, rReply5, rReply6}; !reflect.DeepEqual(got, want) {
		t.Fatalf("the replies must survive the root: %v, want %v", got, want)
	}
	// A reply whose direct parent is deleted but whose root is alive.
	e.repo.docs[rRoot] = replyPost(rRoot, uZed, "zed", "", rRoot)
	delete(e.repo.docs, rReply4)
	e.cache.DeletePost(rReply4)
	th, _, err = e.thread(ThreadInput{PostID: rReply5})
	if err != nil {
		t.Fatal(err)
	}
	if th.Parent != nil || !th.ParentUnavailable || th.Root == nil || th.RootUnavailable {
		t.Fatalf("parent tombstone only: %+v", th)
	}
}

func TestGetThread_ContextByABlockedOrBlockingAuthorIsATombstone(t *testing.T) {
	e := newThreadEnv()
	e.graph.snap.BlockedBy = map[string]bool{uCarol: true} // carol (rReply1's author) blocks the caller
	th, _, err := e.thread(ThreadInput{PostID: rReply4})
	if err != nil {
		t.Fatal(err)
	}
	if th.Parent != nil || !th.ParentUnavailable || th.Root == nil {
		t.Fatalf("a blocking parent author must be a tombstone: %+v", th)
	}
	// The same call for the focal post itself is the uniform NOT_FOUND.
	_, _, err = e.thread(ThreadInput{PostID: rReply1})
	if ae := wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED); ae.Message != postNotFoundText {
		t.Fatalf("message = %q", ae.Message)
	}
	// The caller blocking the parent's author hides the context row as well.
	e = newThreadEnv()
	e.graph.snap.Blocked[uCarol] = true
	th, _, err = e.thread(ThreadInput{PostID: rReply4})
	if err != nil || !th.ParentUnavailable {
		t.Fatalf("err=%v thread=%+v", err, th)
	}
}

func TestGetThread_BlockedByOverflowFailsClosedWithoutExtraReads(t *testing.T) {
	e := newThreadEnv()
	e.graph.snap.BlockedByOverflow = true
	e.graph.snaps = map[string]graph.Snapshot{uCarol: {}} // the focal author's own graph: no block
	th, c, err := e.thread(ThreadInput{PostID: rReply4})
	if err != nil {
		t.Fatal(err)
	}
	if !th.ParentUnavailable || th.Focal.ID != rReply4 {
		t.Fatalf("context under overflow must fail closed: %+v", th)
	}
	if c.Reads() > 38 {
		t.Fatalf("reads = %d", c.Reads())
	}
}

func TestGetThread_FocalNotFoundCases(t *testing.T) {
	e := newThreadEnv()
	_, _, err := e.thread(ThreadInput{PostID: "0000000000000000999"})
	_ = wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	delete(e.dir.profiles, uZed)
	_, _, err = e.thread(ThreadInput{PostID: rRoot})
	_ = wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
}

func TestGetThread_RepoFailureIsInternalNotNotFound(t *testing.T) {
	e := newThreadEnv()
	e.repo.conversationErr = errBoom
	_, _, err := e.thread(ThreadInput{PostID: rRoot})
	if err == nil || errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v", err)
	}
	var ae *apierr.Error
	if errors.As(err, &ae) && ae.Code == connect.CodeNotFound {
		t.Fatal("a repo failure must not be NOT_FOUND")
	}
}

func TestGetThread_LogsCountsOnly(t *testing.T) {
	e := newThreadEnv()
	ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), testUID))
	ctx, _ = budget.WithCounter(ctx)
	if _, err := e.svc.GetThread(ctx, testUID, ThreadInput{PostID: rReply1}); err != nil {
		t.Fatal(err)
	}
	if v, _ := info.Get(fieldThreadReturned); fmt.Sprint(v) != "3" {
		t.Fatalf("returned = %v", v)
	}
	if v, _ := info.Get(fieldThreadDropped); fmt.Sprint(v) != "2" {
		t.Fatalf("dropped = %v", v)
	}
}

// --- the Connect handler --------------------------------------------------------------------------------

// namedFlags enables exactly the named flags.
type namedFlags map[string]bool

func (f namedFlags) Enabled(_ string, name string) bool { return f[name] }

func TestServer_GetThreadNeedsBothFlags(t *testing.T) {
	e := newThreadEnv()
	for name, fl := range map[string]namedFlags{
		"posts only":   {"posts": true},
		"replies only": {"replies": true},
	} {
		t.Run(name, func(t *testing.T) {
			srv := NewServer(e.svc, fl)
			ctx, c := budget.WithCounter(callerCtx(testUID))
			_, err := srv.GetThread(ctx, connect.NewRequest(&postsv1.GetThreadRequest{PostId: rRoot}))
			_ = wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if c.Reads() != 0 {
				t.Fatalf("reads = %d, want 0", c.Reads())
			}
		})
	}
}

func TestServer_GetThreadAndReplyMapping(t *testing.T) {
	e := newThreadEnv()
	srv := NewServer(e.svc, namedFlags{"posts": true, "replies": true})
	resp, err := srv.GetThread(googleCtx(context.Background(), testUID), connect.NewRequest(&postsv1.GetThreadRequest{PostId: rReply1}))
	if err != nil {
		t.Fatal(err)
	}
	m := resp.Msg
	if m.GetFocal().GetPost().GetPostId() != rReply1 || m.GetParent().GetPost().GetPostId() != rRoot ||
		m.GetRoot().GetPost().GetPostId() != rRoot || len(m.GetReplies()) != 3 || m.GetParentUnavailable() {
		t.Fatalf("response = %v", m)
	}

	cr, err := srv.CreatePost(googleCtx(context.Background(), testUID), connect.NewRequest(&postsv1.CreatePostRequest{
		IdempotencyKey: key1, Text: "hello", ReplyToPostId: rRoot,
	}))
	if err != nil {
		t.Fatal(err)
	}
	p := cr.Msg.GetPost().GetPost()
	if p.GetKind() != postsv1.PostKind_POST_KIND_REPLY || p.GetReplyToPostId() != rRoot || p.GetReplyToHandle() != "zed" || p.GetConversationId() != rRoot {
		t.Fatalf("reply = %v", p)
	}

	// Flag off for replies: the root-post path still works, the reply path is FEATURE_DISABLED/replies.
	off := NewServer(e.svc, namedFlags{"posts": true})
	_, err = off.CreatePost(googleCtx(context.Background(), testUID), connect.NewRequest(&postsv1.CreatePostRequest{
		IdempotencyKey: key2, Text: "hello", ReplyToPostId: rRoot,
	}))
	ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if ae.Metadata["feature"] != "replies" {
		t.Fatalf("metadata = %v", ae.Metadata)
	}
	if _, err := off.CreatePost(googleCtx(context.Background(), testUID), connect.NewRequest(&postsv1.CreatePostRequest{
		IdempotencyKey: key2, Text: "a root post",
	})); err != nil {
		t.Fatalf("root posts must not depend on FEATURE_REPLIES: %v", err)
	}
}
