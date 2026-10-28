package posts

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// fakeSet is the protected set of a test (the W3-26a loader is built in parallel).
type fakeSet map[string]bool

func (s fakeSet) Has(uid string) bool { return s[uid] }
func (s fakeSet) CanSee(viewer, author string, following bool) bool {
	return viewer == author || !s[author] || following
}

type fakeProtected struct {
	set   fakeSet
	err   error
	calls int
}

func (f *fakeProtected) Current(context.Context) (identity.ProtectedSet, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	return f.set, nil
}

var _ identity.ProtectedAuthors = (*fakeProtected)(nil)

// protect wires a loader whose set holds uids into e's service.
func (e *createEnv) protect(uids ...string) *fakeProtected {
	f := &fakeProtected{set: fakeSet{}}
	for _, u := range uids {
		f.set[u] = true
	}
	e.svc.protected = f
	e.svc.aud = newAudience(f, e.svc.blockedBy)
	return f
}

func following(uids ...string) graph.Snapshot {
	s := graph.Snapshot{Following: map[string]bool{}}
	for _, u := range uids {
		s.Following[u] = true
	}
	return s
}

func noBlockOverflow(_ context.Context, s graph.Snapshot, _, o string) (bool, error) {
	return s.BlockedBy[o], nil
}

func TestAudienceDecide(t *testing.T) {
	const viewer, prot, other = "uid-viewer", "uid-prot", "uid-other"
	root := func(author string) *Post { return post("1", author) }
	quoteOf := func(author, embedded string) *Post {
		p := post("2", author)
		p.Kind, p.QuoteOfID, p.EmbeddedAuthorID = KindQuote, "1", embedded
		p.Embedded = &Embedded{PostID: "1", Author: AuthorSnapshot{UserID: embedded, Handle: "h"}, Text: "secret"}
		return p
	}
	repostOf := func(author, embedded string) *Post {
		p := quoteOf(author, embedded)
		p.Kind = KindRepost
		return p
	}
	moderated := func(m Moderation) *Post { p := root(other); p.Moderation = m; return p }
	none, prt := postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED
	tests := []struct {
		name    string
		p       *Post
		snap    graph.Snapshot
		surf    Surface
		setErr  error
		wantV   Verdict
		wantE   postsv1.EmbedViewerState
		wantErr bool
	}{
		{"self", root(viewer), graph.Snapshot{}, SurfaceDirect, nil, Show, none, false},
		{"follower of P", root(prot), following(prot), SurfaceDirect, nil, Show, none, false},
		{"non-follower of P", root(prot), graph.Snapshot{}, SurfaceDirect, nil, NotFound, none, false},
		{"non-follower of P, list", root(prot), graph.Snapshot{}, SurfaceList, nil, Drop, none, false},
		{"public author, non-follower", root(other), graph.Snapshot{}, SurfaceDirect, nil, Show, none, false},
		{"P blocks viewer", root(prot), graph.Snapshot{BlockedBy: map[string]bool{prot: true}, Following: map[string]bool{prot: true}}, SurfaceDirect, nil, NotFound, none, false},
		{"viewer blocks author, direct", root(other), graph.Snapshot{Blocked: map[string]bool{other: true}}, SurfaceDirect, nil, Show, none, false},
		{"viewer blocks author, list", root(other), graph.Snapshot{Blocked: map[string]bool{other: true}}, SurfaceList, nil, Drop, none, false},
		{"viewer mutes author, direct", root(other), graph.Snapshot{Muted: map[string]bool{other: true}}, SurfaceDirect, nil, Show, none, false},
		{"viewer mutes author, list", root(other), graph.Snapshot{Muted: map[string]bool{other: true}}, SurfaceList, nil, Drop, none, false},
		{"taken down", moderated(ModerationTakenDown), graph.Snapshot{}, SurfaceDirect, nil, NotFound, none, false},
		{"suspended author post, list", moderated(ModerationSuspendedAuthor), graph.Snapshot{}, SurfaceList, nil, Drop, none, false},
		{"set unavailable, unfollowed author", root(other), graph.Snapshot{}, SurfaceDirect, errBoom, 0, none, true},
		{"set unavailable, own post needs no set", root(viewer), graph.Snapshot{}, SurfaceDirect, errBoom, Show, none, false},
		{"set unavailable, followed author needs no set", root(other), following(other), SurfaceDirect, errBoom, Show, none, false},
		{"quote of P, unapproved: shown, PROTECTED", quoteOf(other, prot), graph.Snapshot{}, SurfaceDirect, nil, Show, prt, false},
		{"quote of P, approved", quoteOf(other, prot), following(prot), SurfaceDirect, nil, Show, none, false},
		{"repost of P, unapproved, direct", repostOf(other, prot), graph.Snapshot{}, SurfaceDirect, nil, NotFound, none, false},
		{"repost of P, unapproved, list", repostOf(other, prot), graph.Snapshot{}, SurfaceList, nil, Drop, none, false},
		{"repost of P, approved", repostOf(other, prot), following(prot), SurfaceList, nil, Show, none, false},
		{"viewer's own quote of P after unfollowing", quoteOf(viewer, prot), graph.Snapshot{}, SurfaceDirect, nil, Show, prt, false},
		{"viewer's own repost of P after unfollowing", repostOf(viewer, prot), graph.Snapshot{}, SurfaceDirect, nil, NotFound, none, false},
		{"P quotes own post", quoteOf(prot, prot), following(prot), SurfaceDirect, nil, Show, none, false},
		{"quote of P, set unavailable", quoteOf(other, prot), graph.Snapshot{}, SurfaceDirect, errBoom, 0, none, true},
		{"embedded author blocks viewer", quoteOf(other, "uid-b"), graph.Snapshot{BlockedBy: map[string]bool{"uid-b": true}}, SurfaceDirect, nil, NotFound, none, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := &fakeProtected{set: fakeSet{prot: true}, err: tt.setErr}
			a := newAudience(f, noBlockOverflow)
			d, err := a.Decide(context.Background(), viewer, tt.snap, tt.p, tt.surf)
			if tt.wantErr {
				wantAPIError(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if d.Verdict != tt.wantV || d.Embed != tt.wantE {
				t.Fatalf("got %+v, want verdict %v embed %v", d, tt.wantV, tt.wantE)
			}
		})
	}
}

func TestAudienceNoLoaderMeansNobodyProtected(t *testing.T) {
	a := newAudience(nil, noBlockOverflow)
	d, err := a.Decide(context.Background(), "v", graph.Snapshot{}, post("1", "p"), SurfaceDirect)
	if err != nil || d.Verdict != Show {
		t.Fatalf("d=%+v err=%v", d, err)
	}
	if a.ProtectedAuthor(context.Background(), "p") {
		t.Fatal("no loader: nobody is protected")
	}
	if err := a.RefuseShare(context.Background(), "v", post("1", "p")); err != nil {
		t.Fatal(err)
	}
}

func TestAudienceRefuseShare(t *testing.T) {
	tests := []struct {
		name    string
		caller  string
		author  string
		setErr  error
		wantErr bool
		code    connect.Code
		reason  commonv1.ErrorReason
	}{
		{"approved caller, protected author", "a", "p", nil, true, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT},
		{"P shares own post", "p", "p", nil, false, 0, 0},
		{"public author", "a", "q", nil, false, 0, 0},
		{"set unavailable", "a", "q", errBoom, true, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a := newAudience(&fakeProtected{set: fakeSet{"p": true}, err: tt.setErr}, nil)
			err := a.RefuseShare(context.Background(), tt.caller, post("1", tt.author))
			if !tt.wantErr {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			wantAPIError(t, err, tt.code, tt.reason)
		})
	}
}

func TestApplyEmbedStateStripsProtectedCopy(t *testing.T) {
	p := post("2", "x")
	p.Kind = KindQuote
	p.Embedded = &Embedded{PostID: "1", Author: AuthorSnapshot{UserID: "p", Handle: "ph"}, Text: "secret",
		Media: []MediaRef{{ID: "9", URL: "https://x/m/9.jpg", ThumbURL: "https://x/m/9_t.jpg", AltText: "alt"}}, PaidPartnership: true}
	v := ToView(p, ViewerSet{}, "v")
	ApplyEmbedState(v, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED)
	e := v.Post.Embedded
	if e.PostId != "1" || e.Author.GetHandle() != "ph" {
		t.Fatalf("must keep post_id and the author: %+v", e)
	}
	if e.Text != "" || len(e.Media) != 0 || e.PaidPartnership || e.CreatedAt != nil {
		t.Fatalf("copy not stripped: %+v", e)
	}
	v2 := ToView(p, ViewerSet{}, "v")
	ApplyEmbedState(v2, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_MUTED)
	if v2.Post.Embedded.Text != "secret" || len(v2.Post.Embedded.Media) != 1 {
		t.Fatal("MUTED must not strip")
	}
	ApplyEmbedState(ToView(post("3", "x"), ViewerSet{}, "v"), postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED)
}

func TestApplyWireVisibility(t *testing.T) {
	v := ToView(post("1", "p"), ViewerSet{}, "v")
	ApplyWireVisibility(v, false)
	if v.Post.Visibility != postsv1.Visibility_VISIBILITY_PUBLIC {
		t.Fatal("public author stays PUBLIC")
	}
	ApplyWireVisibility(v, true)
	if v.Post.Visibility != postsv1.Visibility_VISIBILITY_FOLLOWERS {
		t.Fatal("protected author is FOLLOWERS on the wire")
	}
}

// The service wiring: GetForViewer answers P's post with the byte-identical NOT_FOUND of a missing post, and an
// unknown set is UNAVAILABLE, never NOT_FOUND and never "public".
func TestGetForViewerProtectedMatchesDeleted(t *testing.T) {
	e := newDeleteEnv()
	f := e.protect(otherUID)
	_, _, errProt := e.get(pidOther)
	wantPostNotFound(t, errProt)
	_, _, errGone := newDeleteEnv().get("0000000000000000999")
	if errProt.Error() != errGone.Error() {
		t.Fatalf("protected %q vs deleted %q", errProt, errGone)
	}
	if f.calls != 1 {
		t.Fatalf("set loaded %d times, want 1", f.calls)
	}

	e3 := newDeleteEnv()
	e3.protect(otherUID).err = errBoom
	_, _, err := e3.get(pidOther)
	wantAPIError(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
}

func TestEmbedViewerStateProtected(t *testing.T) {
	e := restrictedEnv("")
	e.protect(uZed)
	e.graph.snap = graph.Snapshot{}
	got := e.svc.EmbedViewerState(context.Background(), testUID, e.repo.docs[rPolRepost])
	if got != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED {
		t.Fatalf("got %v, want PROTECTED", got)
	}
	e.graph.snap = following(uZed)
	if got := e.svc.EmbedViewerState(context.Background(), testUID, e.repo.docs[rPolRepost]); got != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED {
		t.Fatalf("approved viewer got %v", got)
	}
	e.protect(uZed).err = errBoom
	e.graph.snap = graph.Snapshot{}
	if got := e.svc.EmbedViewerState(context.Background(), testUID, e.repo.docs[rPolRepost]); got != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED {
		t.Fatalf("unknown set must fail closed, got %v", got)
	}
}

func TestServer_GetPost_ProtectedStripAndVisibility(t *testing.T) {
	// A quote by a public author of P's post: an unapproved viewer sees the row with the copy stripped.
	e := restrictedEnv("")
	e.protect(uZed)
	e.repo.docs[rPolRepost].Kind = KindQuote
	e.repo.docs[rPolRepost].Embedded.Text = "secret"
	e.repo.docs[rPolRepost].Embedded.Media = []MediaRef{{ID: "9", URL: "https://x/m/9.jpg", ThumbURL: "https://x/m/9_t.jpg"}}
	srv := NewServer(e.svc, replyAudienceRegistry(flags.Spec{Mode: flags.Off}))
	got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: rPolRepost}))
	if err != nil {
		t.Fatal(err)
	}
	v := got.Msg.GetPost()
	if v.GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED {
		t.Fatalf("state = %v", v.GetEmbedViewerState())
	}
	if emb := v.GetPost().GetEmbedded(); emb.GetText() != "" || len(emb.GetMedia()) != 0 || emb.GetPostId() != rRoot || emb.GetAuthor().GetHandle() != "zed" {
		t.Fatalf("embed not stripped to post_id + author: %+v", emb)
	}

	// An approved follower reads P's own post with the computed FOLLOWERS visibility; the stored doc stays PUBLIC.
	e.graph.snap = following(uZed)
	got, err = srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: rRoot}))
	if err != nil {
		t.Fatal(err)
	}
	if got.Msg.GetPost().GetPost().GetVisibility() != postsv1.Visibility_VISIBILITY_FOLLOWERS {
		t.Fatalf("wire visibility = %v", got.Msg.GetPost().GetPost().GetVisibility())
	}
	if e.repo.docs[rRoot].Visibility != VisibilityPublic {
		t.Fatal("stored visibility must stay PUBLIC")
	}
}

func TestCreateQuoteOfProtectedPost(t *testing.T) {
	// Unapproved: NOT_FOUND; approved non-author: PROTECTED_ACCOUNT with 0 writes; the author may quote.
	e := newDeleteEnv()
	e.protect(otherUID)
	_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "t", QuoteOfPostID: pidOther, QuotesEnabled: true})
	wantPostNotFound(t, err)
	if c.Writes() != 0 {
		t.Fatalf("writes = %d", c.Writes())
	}

	e.graph.snaps = map[string]graph.Snapshot{testUID: following(otherUID)}
	_, c, err = e.create(CreateInput{IdempotencyKey: key1, Text: "t", QuoteOfPostID: pidOther, QuotesEnabled: true})
	wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT)
	if c.Writes() != 0 {
		t.Fatalf("writes = %d", c.Writes())
	}

	// The caller quoting their own post is fine even when they are in the set.
	e.protect(testUID)
	if _, _, err = e.create(CreateInput{IdempotencyKey: key2, Text: "t", QuoteOfPostID: pidMine, QuotesEnabled: true}); err != nil {
		t.Fatalf("own quote: %v", err)
	}
}
