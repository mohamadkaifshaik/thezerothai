//go:build integration

package apiserver

// W3-20: posts.hasMedia (ADR-0024 D4) through the real Build chain. Two things the posts package tests prove at the
// repository level are proven again where the profile tab reads them:
//   - every create path writes the explicit bool in the same write, with profile_tabs and profile_extras both OFF (the
//     field is "never flag-gated"), and the Media tab holds exactly the posts that stored it true (a REPOST never);
//   - a legacy post (no hasMedia key) is NOT on the Media tab until `opsctl backfill-has-media` has visited it; a dry run
//     writes nothing; the real run writes only the missing keys; a rerun writes exactly 0.
// "Rerun = 0 writes" is also asserted on a private project by posts.TestBackfillHasMedia_Integration_WritesOnlyMissingAndRerunWritesZero
// and by cmd/opsctl; the chain test here shares one emulator project with every other test, so it starts the scan just
// below its own first post (the checkpoint is exactly what `--after` is for) and asserts on that range only.

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"testing"

	"cloud.google.com/go/firestore"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w320StoredBool reads posts/{id}.hasMedia: (value, present-as-bool).
func (e *bmChain) w320StoredBool(t *testing.T, id string) (val, present bool) {
	t.Helper()
	snap, err := e.fs.Doc("posts/" + id).Get(context.Background())
	if err != nil {
		t.Fatalf("get posts/%s: %v", id, err)
	}
	v, ok := snap.Data()["hasMedia"].(bool)
	return v, ok
}

// w320StripHasMedia turns a post into the pre-W3 shape: no hasMedia key at all.
func (e *bmChain) w320StripHasMedia(t *testing.T, id string) {
	t.Helper()
	if _, err := e.fs.Doc("posts/"+id).Update(context.Background(), []firestore.Update{{Path: "hasMedia", Value: firestore.Delete}}); err != nil {
		t.Fatalf("strip hasMedia: %v", err)
	}
}

// w320IDBelow is the largest post id strictly below id (ids are 19-digit zero-padded decimals, ADR-0003 rule 1).
func w320IDBelow(t *testing.T, id string) string {
	t.Helper()
	n, err := strconv.ParseInt(id, 10, 64)
	if err != nil {
		t.Fatalf("post id %q: %v", id, err)
	}
	return fmt.Sprintf("%019d", n-1)
}

// TestW320_HasMediaOnEveryCreatePathAndTheMediaTab: with profile_tabs and profile_extras OFF in the writing instance.
func TestW320_HasMediaOnEveryCreatePathAndTheMediaTab(t *testing.T) {
	ctx := context.Background()
	e, w := newW320Life(t, func(c *config.Config) {
		c.FeatureProfileTabs = flags.Spec{Name: "profile_tabs", Mode: flags.Off}
		c.FeatureProfileExtras = flags.Spec{Name: "profile_extras", Mode: flags.Off}
	})
	a, b := w.user(t), w.user(t)
	m1, m2, m3 := e.seedMedia(t, a.uid, media.PurposePost), e.seedMedia(t, a.uid, media.PurposePost), e.seedMedia(t, a.uid, media.PurposePost)
	bs := w.post(t, b, "b's text post")
	create := func(req *postsv1.CreatePostRequest) string {
		req.IdempotencyKey = contractKey("w320-cp")
		r, err := w.posts.CreatePost(ctx, authed(a.token, req))
		if err != nil {
			t.Fatalf("CreatePost: %v", err)
		}
		return r.Msg.GetPost().GetPost().GetPostId()
	}
	root := create(&postsv1.CreatePostRequest{Text: "root with an image", MediaIds: []string{m1}})
	reply := create(&postsv1.CreatePostRequest{Text: "reply with an image", ReplyToPostId: bs, MediaIds: []string{m2}})
	quote := create(&postsv1.CreatePostRequest{Text: "quote with an image", QuoteOfPostId: bs, MediaIds: []string{m3}})
	text := create(&postsv1.CreatePostRequest{Text: "text only"})
	textReply := create(&postsv1.CreatePostRequest{Text: "reply, text only", ReplyToPostId: bs})
	rp, err := w.eng.RepostPost(ctx, authed(b.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w320-rp"), PostId: root}))
	if err != nil {
		t.Fatalf("RepostPost: %v", err)
	}
	repost := rp.Msg.GetRepostPostId()

	for name, want := range map[string]bool{root: true, reply: true, quote: true, text: false, textReply: false, repost: false} {
		got, present := w.w320StoredBool(t, name)
		if !present || got != want {
			t.Errorf("posts/%s hasMedia = %v (present as bool: %v), want an explicit %v", name, got, present, want)
		}
	}

	// A reader with profile_tabs ON sees exactly the image posts of A, newest first, and the REPOST only on B's Reposts tab.
	r := newW320Chain(t, w320TabsOn)
	viewer := r.user(t)
	resp, err := r.w320TabCall(viewer, a.uid, tabMediaPB, false, 20, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if got := tabPostIDs(resp); !slices.Equal(got, []string{quote, reply, root}) {
		t.Errorf("A's Media tab = %v, want [quote reply root] %v", got, []string{quote, reply, root})
	}
	rb, err := r.w320TabCall(viewer, b.uid, tabMediaPB, false, 20, "", "")
	if err != nil || slices.Contains(tabPostIDs(rb), repost) {
		t.Errorf("B's Media tab holds the REPOST of an image post (it must not): %v, %v", tabPostIDs(rb), err)
	}
	reps, err := r.w320TabCall(viewer, b.uid, tabRepostsPB, false, 20, "", "")
	if err != nil || !slices.Equal(tabPostIDs(reps), []string{repost}) {
		t.Errorf("B's Reposts tab = %v, %v; want [%s]", tabPostIDs(reps), err, repost)
	}
}

// TestW320_LegacyPostIsOffTheMediaTabUntilBackfilled: see the file comment.
func TestW320_LegacyPostIsOffTheMediaTabUntilBackfilled(t *testing.T) {
	ctx := context.Background()
	e, w := newW320Life(t, nil)
	a, viewer := w.user(t), w.user(t)
	m1, m2 := e.seedMedia(t, a.uid, media.PurposePost), e.seedMedia(t, a.uid, media.PurposePost)
	create := func(text string, ids ...string) string {
		r, err := w.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w320-cp"), Text: text, MediaIds: ids}))
		if err != nil {
			t.Fatalf("CreatePost: %v", err)
		}
		return r.Msg.GetPost().GetPost().GetPostId()
	}
	legacyImage := create("legacy post with an image", m1)
	legacyText := create("legacy text post")
	fresh := create("post written after W3-7", m2)
	w.w320StripHasMedia(t, legacyImage)
	w.w320StripHasMedia(t, legacyText)
	for _, id := range []string{legacyImage, legacyText} {
		if _, present := w.w320StoredBool(t, id); present {
			t.Fatalf("posts/%s still has hasMedia after the strip", id)
		}
	}

	mediaTab := func() []string {
		r := newW320Chain(t, w320TabsOn) // cold: no cached author page
		resp, err := r.w320TabCall(viewer, a.uid, tabMediaPB, false, 20, "", "")
		if err != nil {
			t.Fatalf("Media tab: %v", err)
		}
		return tabPostIDs(resp)
	}
	if got := mediaTab(); !slices.Equal(got, []string{fresh}) {
		t.Fatalf("before the backfill the Media tab = %v, want only the post that stores hasMedia %v", got, []string{fresh})
	}

	repo := posts.NewFirestoreRepo(w.fs)
	start := posts.BackfillCheckpoint{After: w320IDBelow(t, legacyImage)}
	run := func(opts posts.BackfillOptions) (posts.BackfillCheckpoint, *budget.Counter) {
		t.Helper()
		bctx, c := budget.WithCounter(ctx)
		cp := start
		for calls := 0; calls < 1000; calls++ {
			next, state, err := repo.BackfillHasMedia(bctx, cp, opts)
			if err != nil {
				t.Fatalf("BackfillHasMedia: %v", err)
			}
			cp = next
			if state != posts.BackfillMore {
				return cp, c
			}
		}
		t.Fatal("the backfill did not finish")
		return cp, c
	}

	// Dry run: counts, writes nothing, the tab is unchanged.
	cp, c := run(posts.BackfillOptions{PageSize: 50, DryRun: true})
	if c.Writes() != 0 || cp.Updated != 0 || cp.Missing < 2 {
		t.Errorf("dry run: writes=%d updated=%d missing=%d, want 0 writes and at least our 2 missing", c.Writes(), cp.Updated, cp.Missing)
	}
	if got := mediaTab(); !slices.Equal(got, []string{fresh}) {
		t.Errorf("after a dry run the Media tab = %v", got)
	}

	// Real run: writes the missing keys only (one per missing document, never more).
	cp, c = run(posts.BackfillOptions{PageSize: 50})
	t.Logf("W320BUDGET backfill-has-media real run: scanned=%d missing=%d updated=%d reads=%d writes=%d", cp.Scanned, cp.Missing, cp.Updated, c.Reads(), c.Writes())
	if cp.Updated != cp.Missing || c.Writes() != int64(cp.Updated) || cp.Updated < 2 {
		t.Errorf("real run: updated=%d missing=%d writes=%d, want one write per missing document (at least our 2)", cp.Updated, cp.Missing, c.Writes())
	}
	if got, ok := w.w320StoredBool(t, legacyImage); !ok || !got {
		t.Errorf("legacy image post hasMedia = %v/%v, want true", got, ok)
	}
	if got, ok := w.w320StoredBool(t, legacyText); !ok || got {
		t.Errorf("legacy text post hasMedia = %v/%v, want an explicit false", got, ok)
	}
	if got, ok := w.w320StoredBool(t, fresh); !ok || !got {
		t.Errorf("the post that already stored hasMedia changed: %v/%v", got, ok)
	}
	if got := mediaTab(); !slices.Equal(got, []string{fresh, legacyImage}) {
		t.Errorf("after the backfill the Media tab = %v, want newest first [fresh legacyImage] %v", got, []string{fresh, legacyImage})
	}

	// Rerun: nothing is missing any more, so nothing is written; every post is read once.
	cp, c = run(posts.BackfillOptions{PageSize: 50})
	if c.Writes() != 0 || cp.Updated != 0 || cp.Missing != 0 {
		t.Errorf("rerun: writes=%d updated=%d missing=%d, want 0/0/0", c.Writes(), cp.Updated, cp.Missing)
	}
	if c.Reads() < 3 {
		t.Errorf("rerun read %d documents, want at least our 3 posts", c.Reads())
	}
	t.Logf("W320BUDGET backfill-has-media rerun: scanned=%d reads=%d writes=%d", cp.Scanned, c.Reads(), c.Writes())
}
