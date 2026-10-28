//go:build integration

package posts

import (
	"context"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// protectIn wires a fake protected set holding uids into a real-Firestore instance (the W3-26a loader is built in
// parallel; the stored posts.visibility stays PUBLIC either way).
func (in *createInstance) protectIn(uids ...string) *fakeProtected {
	f := &fakeProtected{set: fakeSet{}}
	for _, u := range uids {
		f.set[u] = true
	}
	in.svc.protected = f
	in.svc.aud = newAudience(f, in.svc.blockedBy)
	return f
}

// TestAudience_Integration_GetPostQuoteAndRefusals (W3-29a): over real Firestore, GetPost of a protected author's post
// is byte-identical to a deleted post at the unchanged 3 cold reads (4 per request with the interceptor); a follower
// reads it at the same cost; quoting it is NOT_FOUND for a stranger and PROTECTED_ACCOUNT for a follower, 0 writes; a
// quote made while the author was public is stripped for an unapproved viewer; and the stored doc stays PUBLIC.
func TestAudience_Integration_GetPostQuoteAndRefusals(t *testing.T) {
	client := newTestClient(t)
	setup := newCreateInstance(t, client, time.Nanosecond)
	for _, u := range []string{"alice", "bob", "carol"} {
		setup.signUp(t, "uid-"+u, u)
	}
	bobPost, _, err := setup.create(t, "uid-bob", key(1), "from bob")
	if err != nil {
		t.Fatal(err)
	}
	// Carol quotes bob while bob is public.
	cctx := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-carol", SignInProvider: authn.SignInProviderGoogle})
	if _, err := setup.svc.directory.GetProfiles(context.Background(), []string{"uid-carol"}); err != nil {
		t.Fatal(err)
	}
	quote, err := setup.svc.Create(cctx, "uid-carol", CreateInput{IdempotencyKey: key(2), Text: "my take", QuoteOfPostID: bobPost.ID, QuotesEnabled: true})
	if err != nil {
		t.Fatalf("quote while public: %v", err)
	}

	// Bob protects. Alice is a stranger.
	in := newCreateInstance(t, client, time.Nanosecond)
	set := in.protectIn("uid-bob")
	c, _, err := in.get("uid-alice", bobPost.ID)
	wantPostNotFound(t, err)
	budgettest.Assert(t, "GetPost of a protected post, stranger", c, budgettest.Budget{Reads: 3})
	_, _, missing := in.get("uid-alice", pid(777))
	if err.Error() != missing.Error() {
		t.Fatalf("not byte-identical to a deleted post: %q vs %q", err, missing)
	}
	if set.calls == 0 {
		t.Fatal("the set was never consulted for a non-followed author")
	}

	// A quote target refusal for the stranger is the same NOT_FOUND, 0 writes.
	actx := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-alice", SignInProvider: authn.SignInProviderGoogle})
	actx, wc := budget.WithCounter(actx)
	_, err = in.svc.Create(actx, "uid-alice", CreateInput{IdempotencyKey: key(3), Text: "q", QuoteOfPostID: bobPost.ID, QuotesEnabled: true})
	wantPostNotFound(t, err)
	if wc.Writes() != 0 {
		t.Fatalf("refused quote wrote %d", wc.Writes())
	}

	// The strip: alice reads carol's pre-existing quote of bob.
	srv := NewServer(in.svc, replyAudienceRegistry(flags.Spec{Mode: flags.Off}))
	got, err := srv.GetPost(actx, connect.NewRequest(&postsv1.GetPostRequest{PostId: quote.ID}))
	if err != nil {
		t.Fatalf("carol's quote: %v", err)
	}
	v := got.Msg.GetPost()
	if v.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED {
		t.Fatalf("embed state = %v", v.GetEmbedViewerState())
	}
	if e := v.GetPost().GetEmbedded(); e.GetText() != "" || len(e.GetMedia()) != 0 || e.GetPostId() != bobPost.ID || e.GetAuthor().GetHandle() != "bob" {
		t.Fatalf("embed not stripped: %+v", e)
	}

	// Alice follows bob: reads the post at the same cost; wire visibility is FOLLOWERS; quote is PROTECTED_ACCOUNT.
	setGraph(t, client, "uid-alice", []firestore.Update{{Path: "following", Value: firestore.ArrayUnion("uid-bob")}})
	in2 := newCreateInstance(t, client, time.Nanosecond)
	in2.protectIn("uid-bob")
	c, p, err := in2.get("uid-alice", bobPost.ID)
	if err != nil {
		t.Fatalf("follower: %v", err)
	}
	budgettest.Assert(t, "GetPost of a protected post, follower", c, budgettest.Budget{Reads: 3})
	if p.Visibility != VisibilityPublic {
		t.Fatal("stored visibility must stay PUBLIC")
	}
	actx2, wc2 := budget.WithCounter(authn.WithClaims(context.Background(), authn.Claims{UID: "uid-alice", SignInProvider: authn.SignInProviderGoogle}))
	_, err = in2.svc.Create(actx2, "uid-alice", CreateInput{IdempotencyKey: key(4), Text: "q", QuoteOfPostID: bobPost.ID, QuotesEnabled: true})
	wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT)
	if wc2.Writes() != 0 {
		t.Fatalf("PROTECTED_ACCOUNT quote wrote %d", wc2.Writes())
	}

	// Bob may quote his own post.
	bctx := authn.WithClaims(context.Background(), authn.Claims{UID: "uid-bob", SignInProvider: authn.SignInProviderGoogle})
	if _, err := in2.svc.directory.GetProfiles(context.Background(), []string{"uid-bob"}); err != nil {
		t.Fatal(err)
	}
	if _, err := in2.svc.Create(bctx, "uid-bob", CreateInput{IdempotencyKey: key(5), Text: "self quote", QuoteOfPostID: bobPost.ID, QuotesEnabled: true}); err != nil {
		t.Fatalf("author quotes own post: %v", err)
	}
}
