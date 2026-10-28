//go:build integration

package apiserver

// W3-40a (W3-36 L-1): UnlikePost and UndoRepost are no existence or counts oracle. Through the real Build chain, a
// stranger who liked and reposted P's post while it was public, after P protects, gets for P's post (by its own id and
// by X's REPOST id of it) the bytes a deleted post gets, apart from the echoed id; and the undo still lands.

import (
	"context"
	"fmt"
	"strings"
	"testing"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

func TestW340a_UndoRPCsAreNoOracleAndStillLand(t *testing.T) {
	w := newW335aWorld(t)
	ctx := context.Background()
	s := w.w.user(t) // the stranger: follows nobody
	// While P is public, S likes and reposts P's post.
	if _, err := w.w.eng.LikePost(ctx, authed(s.token, &engagementv1.LikePostRequest{IdempotencyKey: contractKey("w340a-lk"), PostId: w.pid})); err != nil {
		t.Fatalf("LikePost: %v", err)
	}
	if _, err := w.w.eng.RepostPost(ctx, authed(s.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w340a-rp"), PostId: w.pid})); err != nil {
		t.Fatalf("RepostPost: %v", err)
	}
	w.protect(t, true)

	const (
		unlike = "/dzeroth.engagement.v1.EngagementService/UnlikePost"
		undo   = "/dzeroth.engagement.v1.EngagementService/UndoRepost"
	)
	body := func(id string) string {
		return fmt.Sprintf(`{"idempotencyKey":%q,"postId":%q}`, contractKey("w340a-undo"), id)
	}
	// norm hides the echoed id, the one thing that legitimately differs between two posts.
	norm := func(b string, ids ...string) string {
		for _, id := range ids {
			b = strings.ReplaceAll(b, id, "<ID>")
		}
		return b
	}
	for _, proc := range []string{unlike, undo} {
		wst, wct, wb := w.w.rawRPC(t, s.token, proc, body(w.gone))
		if wst != 200 {
			t.Fatalf("%s of a deleted post = %d %s, want the 200 missing shape", proc, wst, wb)
		}
		for name, id := range map[string]string{"P's post": w.pid, "X's REPOST id of P's post": w.repostID} {
			st, ct, b := w.w.rawRPC(t, s.token, proc, body(id))
			if st != wst || ct != wct || norm(b, id, w.pid) != norm(wb, w.gone) {
				t.Errorf("%s of %s differs from a deleted post\n  deleted:   %d %s %s\n  protected: %d %s %s", proc, name, wst, wct, wb, st, ct, b)
			}
		}
	}
	// The writes landed: S's like and repost of P's post are gone although P is now invisible to S.
	if fsDocExists(t, w.w.fs, "likes/"+w.pid+"_"+s.uid) {
		t.Error("UnlikePost did not remove the like")
	}
	if fsDocExists(t, w.w.fs, "reposts/"+w.pid+"_"+s.uid) {
		t.Error("UndoRepost did not remove the repost")
	}
}

// W3-40b (the W3-40a residual): a stranger undoing X's REPOST id gets the same bytes whether the original behind it is
// deleted or hidden (protected, not followed), the echoed original id apart. Before, the hidden answer echoed the
// REPOST's own id and the deleted one the original's, which told the two apart.
func TestW340b_UndoOfRepostIDHiddenEqualsOriginalGone(t *testing.T) {
	w := newW335aWorld(t)
	ctx := context.Background()
	s := w.w.user(t)
	// A second post of P, reposted by X, then deleted by P: the REPOST doc stays until the post_delete job (not run here).
	p2 := w.post(t, w.p, &postsv1.CreatePostRequest{Text: "p2 goes away"})
	rp, err := w.w.eng.RepostPost(ctx, authed(w.x.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w340b-rp"), PostId: p2}))
	if err != nil {
		t.Fatalf("RepostPost: %v", err)
	}
	r2 := rp.Msg.GetRepostPostId()
	if _, err := w.w.posts.DeletePost(ctx, authed(w.p.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("w340b-del"), PostId: p2})); err != nil {
		t.Fatal(err)
	}
	w.protect(t, true)

	const (
		unlike = "/dzeroth.engagement.v1.EngagementService/UnlikePost"
		undo   = "/dzeroth.engagement.v1.EngagementService/UndoRepost"
	)
	body := func(id string) string {
		return fmt.Sprintf(`{"idempotencyKey":%q,"postId":%q}`, contractKey("w340b-undo"), id)
	}
	for _, proc := range []string{unlike, undo} {
		gst, gct, gb := w.w.rawRPC(t, s.token, proc, body(r2))
		hst, hct, hb := w.w.rawRPC(t, s.token, proc, body(w.repostID))
		// Only the original's id differs between the two posts; the REPOST ids are not normalised away.
		gb, hb = strings.ReplaceAll(gb, p2, "<ORIG>"), strings.ReplaceAll(hb, w.pid, "<ORIG>")
		if gst != 200 || hst != gst || hct != gct || hb != gb {
			t.Errorf("%s: hidden original differs from a deleted one\n  gone:   %d %s %s\n  hidden: %d %s %s", proc, gst, gct, gb, hst, hct, hb)
		}
		if strings.Contains(hb, w.repostID) || strings.Contains(gb, r2) {
			t.Errorf("%s: the answer echoes the REPOST's own id: gone %s hidden %s", proc, gb, hb)
		}
	}
}
