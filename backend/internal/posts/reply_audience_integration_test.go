//go:build integration

package posts

import (
	"context"
	"strings"
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// TestReplyAudience_Integration against the Firestore emulator:
//   - the field is stored as `replyPolicy` (absent for EVERYONE), inherited by replies and copied into embeds;
//   - a reply in a restricted conversation is enforced from cold caches and from a warm instance alike;
//   - a refusal writes nothing and stores nothing under the idempotency key.
//
// Every check runs on a fresh instance (new caches) over the same database, because a warm cache would hide a
// missing cold-path lookup.
func TestReplyAudience_Integration(t *testing.T) {
	client := newTestClient(t)
	seed := newCreateInstance(t, client, time.Nanosecond)
	for _, u := range []string{"alice", "bob", "carol", "dave"} {
		seed.signUp(t, "uid-"+u, u)
	}
	// alice follows bob (and not dave): the FOLLOWING conversations let bob in and keep dave out.
	seedGraphDoc(t, client, "uid-alice", map[string]any{"following": []string{"uid-bob", "uid-carol"}})

	fresh := func() *createInstance {
		in := newCreateInstance(t, client, time.Nanosecond)
		in.skipInvariantSweep("measurement instance; the seed instance runs the sweep")
		return in
	}
	ctxFor := func(uid string) context.Context {
		return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
	}
	// root creates alice's root post with the given policy.
	root := func(in *createInstance, key, text string, policy postsv1.ReplyPolicy) *Post {
		t.Helper()
		if _, err := in.svc.directory.GetProfiles(context.Background(), []string{"uid-alice"}); err != nil {
			t.Fatal(err)
		}
		p, err := in.svc.Create(ctxFor("uid-alice"), "uid-alice", CreateInput{IdempotencyKey: key, Text: text,
			ReplyPolicy: int32(policy), ReplyAudienceEnabled: true})
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	rawDoc := func(id string) map[string]any {
		t.Helper()
		snap, err := client.Collection(postsCollection).Doc(id).Get(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		return snap.Data()
	}

	// --- setting a policy: the raw field name, legacy-compatible absence ---
	plain := root(seed, key(1), "plain root", postsv1.ReplyPolicy_REPLY_POLICY_UNSPECIFIED)
	everyone := root(seed, key(2), "everyone root", postsv1.ReplyPolicy_REPLY_POLICY_EVERYONE)
	mentioned := root(seed, key(3), "only for @bob", postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY)
	following := root(seed, key(4), "only my follows", postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING)
	for id, want := range map[string]any{plain.ID: nil, everyone.ID: nil, mentioned.ID: "MENTIONED_ONLY", following.ID: "FOLLOWING"} {
		got, ok := rawDoc(id)["replyPolicy"]
		if want == nil {
			if ok {
				t.Fatalf("an EVERYONE root must not write replyPolicy, got %v", got)
			}
			continue
		}
		if got != want {
			t.Fatalf("raw replyPolicy = %v, want %v", got, want)
		}
	}
	if len(mentioned.Mentions) != 1 || mentioned.Mentions[0].UserID != "uid-bob" {
		t.Fatalf("MENTIONED_ONLY root mentions = %+v, want bob", mentioned.Mentions)
	}

	// --- a reply to each root by bob (allowed: mentioned / followed) seeds the deeper level ---
	type conv struct {
		name  string
		root  *Post
		reply *Post // bob's reply to the root, the parent of the deep reply
	}
	convs := []*conv{{name: "EVERYONE", root: plain}, {name: "MENTIONED_ONLY", root: mentioned}, {name: "FOLLOWING", root: following}}
	for i, cv := range convs {
		r, err := seed.reply(t, "uid-bob", key(10+i), "bob replies", cv.root.ID)
		if err != nil {
			t.Fatalf("%s: seed reply: %v", cv.name, err)
		}
		cv.reply = r
		if got := rawDoc(r.ID)["replyPolicy"]; got != rawDoc(cv.root.ID)["replyPolicy"] {
			t.Fatalf("%s: reply replyPolicy = %v, root = %v, want inherited", cv.name, got, rawDoc(cv.root.ID)["replyPolicy"])
		}
		// No uid is copied: the reply stores no mention of its own.
		if v, ok := rawDoc(r.ID)["mentions"].([]any); ok && len(v) != 0 {
			t.Fatalf("%s: reply doc mentions = %v, want none", cv.name, v)
		}
	}
	// replyFresh runs one reply on a fresh, cold instance.
	replyFresh := func(uid, key, parent string) error {
		_, err := fresh().reply(t, uid, key, "fresh instance", parent)
		return err
	}

	// --- allowed on a cold instance: direct (parent = root) and deep (the caller wrote the parent, and R's author
	// differs from the parent's author) ---
	for i, cv := range convs {
		if err := replyFresh("uid-bob", key(20+i), cv.root.ID); err != nil {
			t.Fatalf("%s direct reply: %v", cv.name, err)
		}
		if err := replyFresh("uid-bob", key(30+i), cv.reply.ID); err != nil {
			t.Fatalf("%s deep reply: %v", cv.name, err)
		}
	}

	// --- warm instance: a second reply to the same parent is allowed too ---
	for i, cv := range convs {
		in := fresh()
		if _, err := in.reply(t, "uid-bob", key(40+2*i), "first", cv.reply.ID); err != nil {
			t.Fatalf("%s first warm reply: %v", cv.name, err)
		}
		if _, err := in.reply(t, "uid-bob", key(41+2*i), "second", cv.reply.ID); err != nil {
			t.Fatalf("%s second warm reply: %v", cv.name, err)
		}
	}

	// --- refusal: dave is neither mentioned nor followed ---
	for _, tc := range []struct {
		name, parent, policy string
	}{
		{"MENTIONED_ONLY direct", convs[1].root.ID, "mentioned_only"},
		{"FOLLOWING direct", convs[2].root.ID, "following"},
	} {
		before := countDocs(t, client, "idempotency")
		postsBefore := countDocs(t, client, postsCollection)
		replies := replyCount(t, seed, tc.parent)
		in := fresh()
		_, err := in.reply(t, "uid-dave", key(50), "nope", tc.parent)
		wantReplyNotAllowed(t, err, tc.policy)
		if got := countDocs(t, client, "idempotency"); got != before {
			t.Fatalf("%s: idempotency docs %d -> %d, a refusal must store nothing under the key", tc.name, before, got)
		}
		if got := countDocs(t, client, postsCollection); got != postsBefore || replyCount(t, seed, tc.parent) != replies {
			t.Fatalf("%s: a refusal changed posts or the parent counter", tc.name)
		}
	}

	// The unmentioned / unfollowed stranger is refused in the deep case too (and blocked-or-hidden roots answer
	// NOT_FOUND, covered by the unit matrix).
	wantReplyNotAllowed(t, replyFresh("uid-dave", key(51), convs[2].reply.ID), "following")

	// The root author may always reply, even though alice is not in her own mentions or follows.
	if err := replyFresh("uid-alice", key(52), convs[1].reply.ID); err != nil {
		t.Fatalf("the root author's reply: %v", err)
	}

	// --- a quote of a restricted root freezes the policy in the stored embed; the tombstone removes it ---
	in := fresh()
	if _, err := in.svc.directory.GetProfiles(context.Background(), []string{"uid-carol"}); err != nil {
		t.Fatal(err)
	}
	quote, err := in.svc.Create(ctxFor("uid-carol"), "uid-carol", CreateInput{IdempotencyKey: key(60), Text: "quoting",
		QuoteOfPostID: following.ID, QuotesEnabled: true, ReplyPolicy: int32(postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY), ReplyAudienceEnabled: true})
	if err != nil {
		t.Fatal(err)
	}
	qd := rawDoc(quote.ID)
	emb, _ := qd["embedded"].(map[string]any)
	if qd["replyPolicy"] != "MENTIONED_ONLY" || emb["replyPolicy"] != "FOLLOWING" {
		t.Fatalf("quote replyPolicy = %v, embedded.replyPolicy = %v; want its own MENTIONED_ONLY and the quoted FOLLOWING", qd["replyPolicy"], emb["replyPolicy"])
	}
	if changed, _, err := in.repo.TombstoneQuotes(context.Background(), following.ID, 10); err != nil || changed != 1 {
		t.Fatalf("TombstoneQuotes changed=%d err=%v", changed, err)
	}
	emb, _ = rawDoc(quote.ID)["embedded"].(map[string]any)
	if _, ok := emb["replyPolicy"]; ok || emb["unavailable"] != true {
		t.Fatalf("tombstoned embed = %v, want unavailable with no replyPolicy", emb)
	}

	// --- the export of the author's posts names the policy ---
	assertExportHasPolicy(t, seed, "uid-alice")

	// --- GetPost hint: bob may reply to every root ---
	for _, r := range []*Post{plain, mentioned, following} {
		in := fresh()
		p, err := in.get("uid-bob", r.ID)
		if err != nil {
			t.Fatal(err)
		}
		if got := in.svc.ReplyPermission(ctxFor("uid-bob"), "uid-bob", p); got != postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED {
			t.Fatalf("hint on root %s = %v, want ALLOWED for bob", r.ID, got)
		}
	}

	// --- GetThread: the hint in an EVERYONE and a FOLLOWING conversation ---
	for _, c := range []*conv{convs[0], convs[2]} {
		th, err := fresh().thread(t, "uid-bob", ThreadInput{PostID: c.reply.ID, PageSize: 1})
		if err != nil {
			t.Fatal(err)
		}
		if th.ReplyPermission != postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED {
			t.Fatalf("%s thread hint = %v, want ALLOWED for bob", c.name, th.ReplyPermission)
		}
	}
}

// assertExportHasPolicy streams the export and expects at least one post with a replyPolicy.
func assertExportHasPolicy(t *testing.T, in *createInstance, uid string) {
	t.Helper()
	var buf strings.Builder
	if err := in.repo.ExportUser(context.Background(), uid, &buf); err != nil {
		t.Fatal(err)
	}
	if out := buf.String(); !strings.Contains(out, `"replyPolicy":"MENTIONED_ONLY"`) || !strings.Contains(out, `"replyPolicy":"FOLLOWING"`) {
		t.Fatalf("export lacks the reply policies: %s", buf.String())
	}
}
