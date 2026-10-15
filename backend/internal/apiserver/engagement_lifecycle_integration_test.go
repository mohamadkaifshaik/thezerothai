//go:build integration

package apiserver

// P5 x account lifecycle (ADR-0018 D7, D14, ADR-0011): a user with likes, a self-like and a repost is exported and
// deleted while other users repost and quote their post. Asserts the surviving counters, that nothing of the user
// remains, and the export's engagement section.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

func TestEngagementLifecycle_DeleteAccountWithEngagement(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, engagementOn)
	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, e.url)
	a, b, c := e.newUser(t), e.newUser(t), e.newUser(t) // a is deleted

	mk := func(u testUser, key, text string) string {
		t.Helper()
		r, err := e.posts.CreatePost(ctx, authed(u.token, &postsv1.CreatePostRequest{IdempotencyKey: key, Text: text}))
		if err != nil {
			t.Fatalf("CreatePost %s: %v", key, err)
		}
		return r.Msg.GetPost().GetPost().GetPostId()
	}
	pA := mk(a, "elc-post-a-00000001", "a post")
	pB := mk(b, "elc-post-b-00000001", "b post")

	like := func(u testUser, key, pid string) {
		t.Helper()
		if _, err := eng.LikePost(ctx, authed(u.token, &engagementv1.LikePostRequest{IdempotencyKey: key, PostId: pid})); err != nil {
			t.Fatalf("LikePost %s: %v", key, err)
		}
	}
	like(a, "elc-like-a-pb-000001", pB) // a likes b's post
	like(a, "elc-like-a-pa-000001", pA) // self-like
	like(c, "elc-like-c-pb-000001", pB) // someone else's like survives
	like(c, "elc-like-c-pa-000001", pA) // another user's like on a's post (left behind by the purge, MAJOR 5)
	rpA, err := eng.RepostPost(ctx, authed(a.token, &engagementv1.RepostPostRequest{IdempotencyKey: "elc-repost-a-pb-0001", PostId: pB}))
	if err != nil {
		t.Fatalf("a reposts pB: %v", err)
	}
	aRepostID := rpA.Msg.GetRepostPostId()

	// Others copy a's post: b reposts it, c quotes it.
	rbp, err := eng.RepostPost(ctx, authed(b.token, &engagementv1.RepostPostRequest{IdempotencyKey: "elc-repost-b-pa-0001", PostId: pA}))
	if err != nil {
		t.Fatalf("b reposts pA: %v", err)
	}
	bRepostID := rbp.Msg.GetRepostPostId()
	q, err := e.posts.CreatePost(ctx, authed(c.token, &postsv1.CreatePostRequest{IdempotencyKey: "elc-quote-c-pa-00001", Text: "c take", QuoteOfPostId: pA}))
	if err != nil {
		t.Fatalf("c quotes pA: %v", err)
	}
	quoteID := q.Msg.GetPost().GetPost().GetPostId()

	if got := fsInt(t, e.fs, "posts/"+pB, "likeCount"); got != 2 {
		t.Fatalf("seed: pB likeCount = %d, want 2", got)
	}
	if got := fsInt(t, e.fs, "posts/"+pB, "repostCount"); got != 1 {
		t.Fatalf("seed: pB repostCount = %d, want 1", got)
	}
	bPostsBefore := fsInt(t, e.fs, "users/"+b.uid, "postsCount") // pB + the repost of pA

	// --- export: the engagement section lists a's likes and reposts ---
	exp, err := e.identity.RequestAccountExport(ctx, authed(a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "elc-export-key-00001"}))
	if err != nil {
		t.Fatalf("RequestAccountExport: %v", err)
	}
	for _, m := range e.pull(t) {
		if m["kind"] == "account_export" {
			if code := e.deliver(t, m); code != http.StatusNoContent {
				t.Fatalf("export delivery = %d", code)
			}
		}
	}
	rd, err := e.bucket.Object(exp.Msg.GetExportId() + ".json").NewReader(ctx)
	if err != nil {
		t.Fatalf("export object: %v", err)
	}
	raw, _ := io.ReadAll(rd)
	_ = rd.Close()
	var doc struct {
		Engagement struct {
			Likes   []map[string]any `json:"likes"`
			Reposts []map[string]any `json:"reposts"`
		} `json:"engagement"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("export JSON: %v", err)
	}
	ids := func(es []map[string]any) []string {
		var out []string
		for _, m := range es {
			s, _ := m["postId"].(string)
			if ts, _ := m["createdAt"].(string); ts == "" {
				t.Errorf("export entry without createdAt: %v", m)
			}
			if len(m) != 2 {
				t.Errorf("export entry = %v, want {postId, createdAt} only", m)
			}
			out = append(out, s)
		}
		sort.Strings(out)
		return out
	}
	wantLikes := []string{pA, pB}
	sort.Strings(wantLikes)
	if got := ids(doc.Engagement.Likes); len(got) != 2 || got[0] != wantLikes[0] || got[1] != wantLikes[1] {
		t.Errorf("export likes = %v, want %v", got, wantLikes)
	}
	if got := ids(doc.Engagement.Reposts); len(got) != 1 || got[0] != pB {
		t.Errorf("export reposts = %v, want [%s]", got, pB)
	}
	var whole, section map[string]json.RawMessage
	_ = json.Unmarshal(raw, &whole)
	_ = json.Unmarshal(whole["engagement"], &section)
	if len(section) != 2 {
		t.Errorf("engagement section = %s, want likes + reposts only", whole["engagement"])
	}

	// --- delete the account and run every delivery to completion ---
	e.pull(t)
	if _, err := e.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "elc-delete-key-00001"})); err != nil {
		t.Fatalf("DeleteAccount: %v", err)
	}
	if _, err := e.fs.Doc("users/"+a.uid).Update(ctx, []firestore.Update{{Path: "deletionRequestedAt", Value: time.Now().Add(-5 * time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	for round := 0; ; round++ {
		msgs := e.pull(t)
		if len(msgs) == 0 {
			break
		}
		if round > 10 {
			t.Fatal("the deletion job did not finish")
		}
		for _, m := range msgs {
			if code := e.deliver(t, m); code != http.StatusNoContent && code != http.StatusTooManyRequests {
				t.Fatalf("delivery = %d", code)
			}
		}
	}

	// --- result ---
	if fsDocExists(t, e.fs, "users/"+a.uid) {
		t.Fatal("users doc survived")
	}
	// a's like and repost of pB are gone and pB's counters are back to the other user's like only.
	if got := fsInt(t, e.fs, "posts/"+pB, "likeCount"); got != 1 {
		t.Errorf("pB likeCount = %d, want 1 (c's like)", got)
	}
	if got := fsInt(t, e.fs, "posts/"+pB, "repostCount"); got != 0 {
		t.Errorf("pB repostCount = %d, want 0", got)
	}
	requireEngagementInvariants(t, e.fs, pB)
	for _, path := range []string{
		"likes/" + pB + "_" + a.uid, "likes/" + pA + "_" + a.uid, "reposts/" + pB + "_" + a.uid,
		"userLikes/" + a.uid, "posts/" + aRepostID, "posts/" + pA,
	} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived the deletion", path)
		}
	}
	for _, q := range []struct{ col, field string }{
		{"likes", "uid"}, {"reposts", "uid"}, {"posts", "authorId"}, {"posts", "embeddedAuthorId"},
	} {
		if n := countWhere(t, e.fs, q.col, q.field, a.uid); n != 0 {
			t.Errorf("%s.%s == deleted uid: %d docs (residue)", q.col, q.field, n)
		}
	}
	// b's repost of a's post is removed with b's postsCount and its reposts doc.
	if fsDocExists(t, e.fs, "posts/"+bRepostID) || fsDocExists(t, e.fs, "reposts/"+pA+"_"+b.uid) {
		t.Error("b's repost of the deleted user's post survived")
	}
	if got := fsInt(t, e.fs, "users/"+b.uid, "postsCount"); got != bPostsBefore-1 {
		t.Errorf("b postsCount = %d, want %d", got, bPostsBefore-1)
	}
	// c's quote stays, with a tombstone instead of a's text.
	qs, err := e.fs.Doc("posts/" + quoteID).Get(ctx)
	if err != nil {
		t.Fatalf("c's quote is gone: %v", err)
	}
	emb, _ := qs.Data()["embedded"].(map[string]any)
	if un, _ := emb["unavailable"].(bool); !un || emb["text"] != nil {
		t.Errorf("c's quote embed = %v, want a tombstone", emb)
	}
	if qs.Data()["text"] != "c take" {
		t.Errorf("c's own quote text changed: %v", qs.Data()["text"])
	}
	// Likes OTHER users left on a's post are not touched by the purge (review MAJOR 5, a founder decision): they
	// name only the deleted post id, no PII of a. Logged so a change in behaviour is visible.
	t.Logf("likes by other users on the deleted post (orphans, no PII): %d", countWhere(t, e.fs, "likes", "postId", pA))
}
