//go:build integration

package posts

import (
	"context"
	"strings"
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// TestReplyAudience_Integration (ADR-0021 D2, CMP-B2/B4) against the Firestore emulator:
//   - the field is stored as `replyPolicy` (absent for EVERYONE), inherited by replies and copied into embeds;
//   - setting a policy costs exactly what a plain create costs (delta 0, asserted equal, not <= a ceiling);
//   - the extra reads of a reply in a restricted conversation match the ADR cost table from cold caches, and a
//     warm instance pays +0;
//   - a refusal writes nothing, stores nothing under the idempotency key and reads exactly the allowed path minus
//     the transaction's two reads.
//
// Every measurement runs on a fresh instance (new caches) over the same database, because a warm cache would hide
// the cold cost the ADR documents.
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
	// root creates alice's root post with the given policy; the cost is returned for the delta-0 assertion.
	root := func(in *createInstance, key, text string, policy postsv1.ReplyPolicy) (*Post, *budget.Counter) {
		t.Helper()
		if _, err := in.svc.directory.GetProfiles(context.Background(), []string{"uid-alice"}); err != nil {
			t.Fatal(err)
		}
		ctx, c := budget.WithCounter(ctxFor("uid-alice"))
		p, err := in.svc.Create(ctx, "uid-alice", CreateInput{IdempotencyKey: key, Text: text,
			ReplyPolicy: int32(policy), ReplyAudienceEnabled: true})
		if err != nil {
			t.Fatal(err)
		}
		return p, c
	}
	rawDoc := func(id string) map[string]any {
		t.Helper()
		snap, err := client.Collection(postsCollection).Doc(id).Get(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		return snap.Data()
	}

	// --- setting a policy: delta 0, the raw field name, legacy-compatible absence ---
	plain, plainCost := root(seed, key(1), "plain root", postsv1.ReplyPolicy_REPLY_POLICY_UNSPECIFIED)
	everyone, everyoneCost := root(seed, key(2), "everyone root", postsv1.ReplyPolicy_REPLY_POLICY_EVERYONE)
	mentioned, mentionedCost := root(seed, key(3), "only for @bob", postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY)
	following, followingCost := root(seed, key(4), "only my follows", postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING)
	budgettest.Assert(t, "CreatePost root", plainCost, budgettest.Budget{Reads: 2, Writes: 4})
	for name, c := range map[string]*budget.Counter{"EVERYONE": everyoneCost, "MENTIONED_ONLY": mentionedCost, "FOLLOWING": followingCost} {
		if c.Reads() != plainCost.Reads() || c.Writes() != plainCost.Writes() {
			t.Fatalf("%s create reads/writes = %d/%d, plain = %d/%d, want equal (delta 0)", name, c.Reads(), c.Writes(), plainCost.Reads(), plainCost.Writes())
		}
	}
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
		r, _, err := seed.reply(t, "uid-bob", key(10+i), "bob replies", cv.root.ID)
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
	base := convs[0]

	// measure runs one reply on a fresh instance and returns its cost.
	measure := func(uid, key, parent string) (*Post, *budget.Counter, error) {
		in := fresh()
		return in.reply(t, uid, key, "measured", parent)
	}

	// --- direct reply (parent = root), cold: MENTIONED_ONLY +0, FOLLOWING +1 ---
	_, baseDirect, err := measure("uid-bob", key(20), base.root.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, mDirect, err := measure("uid-bob", key(21), convs[1].root.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, fDirect, err := measure("uid-bob", key(22), convs[2].root.ID)
	if err != nil {
		t.Fatal(err)
	}
	assertDelta(t, "direct MENTIONED_ONLY", mDirect, baseDirect, 0)
	assertDelta(t, "direct FOLLOWING", fDirect, baseDirect, 1)

	// --- deep reply, cold, the caller wrote the parent and R's author differs from the parent's author ---
	_, baseDeep, err := measure("uid-bob", key(30), base.reply.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, mDeep, err := measure("uid-bob", key(31), convs[1].reply.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, fDeep, err := measure("uid-bob", key(32), convs[2].reply.ID)
	if err != nil {
		t.Fatal(err)
	}
	assertDelta(t, "deep MENTIONED_ONLY", mDeep, baseDeep, 3)
	assertDelta(t, "deep FOLLOWING", fDeep, baseDeep, 4)
	for name, c := range map[string]*budget.Counter{"deep MENTIONED_ONLY": mDeep, "deep FOLLOWING": fDeep} {
		if c.Writes() != baseDeep.Writes() {
			t.Fatalf("%s writes = %d, want %d (same as a plain reply)", name, c.Writes(), baseDeep.Writes())
		}
	}

	// --- warm instance: the second reply to the same parent pays +0 over an EVERYONE conversation ---
	second := func(parent, k1, k2 string) *budget.Counter {
		in := fresh()
		if _, _, err := in.reply(t, "uid-bob", k1, "first", parent); err != nil {
			t.Fatal(err)
		}
		_, c, err := in.reply(t, "uid-bob", k2, "second", parent)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	warmBase := second(base.reply.ID, key(40), key(41))
	assertDelta(t, "warm deep MENTIONED_ONLY", second(convs[1].reply.ID, key(42), key(43)), warmBase, 0)
	assertDelta(t, "warm deep FOLLOWING", second(convs[2].reply.ID, key(44), key(45)), warmBase, 0)

	// --- refusal: dave is neither mentioned nor followed ---
	for _, tc := range []struct {
		name, parent, policy string
		allowed              *budget.Counter
	}{
		{"MENTIONED_ONLY direct", convs[1].root.ID, "mentioned_only", mDirect},
		{"FOLLOWING direct", convs[2].root.ID, "following", fDirect},
	} {
		before := countDocs(t, client, "idempotency")
		posts := countDocs(t, client, postsCollection)
		replies := replyCount(t, seed, tc.parent)
		in := fresh()
		_, c, err := in.reply(t, "uid-dave", key(50), "nope", tc.parent)
		wantReplyNotAllowed(t, err, tc.policy)
		if c.Writes() != 0 || c.Deletes() != 0 {
			t.Fatalf("%s: refusal writes=%d deletes=%d, want 0", tc.name, c.Writes(), c.Deletes())
		}
		// The allowed path also reads the idempotency doc and the quotas doc in its transaction.
		if c.Reads()+2 != tc.allowed.Reads() {
			t.Fatalf("%s: refusal reads = %d, allowed path = %d, want allowed - 2 (transaction reads)", tc.name, c.Reads(), tc.allowed.Reads())
		}
		if got := countDocs(t, client, "idempotency"); got != before {
			t.Fatalf("%s: idempotency docs %d -> %d, a refusal must store nothing under the key", tc.name, before, got)
		}
		if got := countDocs(t, client, postsCollection); got != posts || replyCount(t, seed, tc.parent) != replies {
			t.Fatalf("%s: a refusal changed posts or the parent counter", tc.name)
		}
	}

	// The unmentioned / unfollowed stranger is refused in the deep case too (and blocked-or-hidden roots answer
	// NOT_FOUND, covered by the unit matrix).
	_, _, err = measure("uid-dave", key(51), convs[2].reply.ID)
	wantReplyNotAllowed(t, err, "following")

	// The root author may always reply, even though alice is not in her own mentions or follows.
	if _, _, err := measure("uid-alice", key(52), convs[1].reply.ID); err != nil {
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

	// --- GetPost hint: a FOLLOWING root costs at most +1 read cold over the plain GetPost, 0 warm ---
	hintCost := func(rootID string) int64 {
		in := fresh()
		_, p, err := in.get("uid-bob", rootID) // GetPost's visibility check caches the viewer's graph
		if err != nil {
			t.Fatal(err)
		}
		ctx, hc := budget.WithCounter(ctxFor("uid-bob"))
		_ = in.svc.ReplyPermission(ctx, "uid-bob", p)
		return hc.Reads()
	}
	if r := hintCost(plain.ID); r != 0 {
		t.Fatalf("hint on an EVERYONE root read %d, want 0", r)
	}
	if r := hintCost(mentioned.ID); r != 0 {
		t.Fatalf("hint on a MENTIONED_ONLY root read %d, want 0 (the viewer's graph is cached by GetPost)", r)
	}
	if r := hintCost(following.ID); r != 1 {
		t.Fatalf("hint on a FOLLOWING root read %d, want 1 (R's author graph, cold)", r)
	}
}

// assertDelta fails unless got.Reads() == base.Reads()+want.
func assertDelta(t *testing.T, name string, got, base *budget.Counter, want int64) {
	t.Helper()
	if d := got.Reads() - base.Reads(); d != want {
		t.Fatalf("%s: reads %d vs plain reply %d = delta %d, want exactly +%d", name, got.Reads(), base.Reads(), d, want)
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
