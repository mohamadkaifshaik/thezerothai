//go:build integration

package posts

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// TestCreate_Integration_Disclosure (ADR-0021 D3, CMP-C2): the labels land on the post doc under their documented
// names, only when set (absent = false, no backfill) and the call stays inside the CreatePost budget (delta 0).
func TestCreate_Integration_Disclosure(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")

	create := func(key, text string, pp, ai bool) (*Post, *budget.Counter) {
		t.Helper()
		if _, err := in.svc.directory.GetProfiles(context.Background(), []string{"uid-alice"}); err != nil {
			t.Fatal(err)
		}
		ctx, c := budget.WithCounter(googleCtx(context.Background(), "uid-alice"))
		p, err := in.svc.Create(ctx, "uid-alice", CreateInput{
			IdempotencyKey: key, Text: text, PaidPartnership: pp, MadeWithAI: ai, DisclosureEnabled: true})
		if err != nil {
			t.Fatal(err)
		}
		return p, c
	}

	both, c := create(key(1), "labelled", true, true)
	budgettest.Assert(t, "CreatePost with disclosure", c, budgettest.Budget{Reads: 2, Writes: 4})
	plain, pc := create(key(2), "plain", false, false)
	// Delta 0 (ADR-0021 D3): the labelled create costs exactly what the plain one does, not merely "within a ceiling".
	if c.Reads() != pc.Reads() || c.Writes() != pc.Writes() {
		t.Fatalf("labelled create reads/writes = %d/%d, plain = %d/%d, want equal", c.Reads(), c.Writes(), pc.Reads(), pc.Writes())
	}

	raw := func(id string) map[string]any {
		t.Helper()
		snap, err := client.Collection(postsCollection).Doc(id).Get(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		return snap.Data()
	}
	d := raw(both.ID)
	if d["paidPartnership"] != true || d["madeWithAi"] != true {
		t.Fatalf("labelled doc fields = %v / %v, want true / true", d["paidPartnership"], d["madeWithAi"])
	}
	pd := raw(plain.ID)
	if _, ok := pd["paidPartnership"]; ok {
		t.Fatal("an unlabelled post must not write paidPartnership")
	}
	if _, ok := pd["madeWithAi"]; ok {
		t.Fatal("an unlabelled post must not write madeWithAi")
	}

	read, err := in.repo.GetAll(context.Background(), []string{both.ID, plain.ID})
	if err != nil {
		t.Fatal(err)
	}
	if g := read[both.ID]; g == nil || !g.PaidPartnership || !g.MadeWithAI {
		t.Fatalf("labelled read = %+v", g)
	}
	if g := read[plain.ID]; g == nil || g.PaidPartnership || g.MadeWithAI {
		t.Fatalf("unlabelled read = %+v", g)
	}

	// A quote of the labelled post freezes both labels into the stored embed under the real Firestore field names
	// (a tag typo in embeddedDoc fails here), and the quote tombstone removes them from the raw doc.
	in.signUp(t, "uid-bob", "bob")
	ctx := googleCtx(context.Background(), "uid-bob")
	if _, err := in.svc.directory.GetProfiles(context.Background(), []string{"uid-bob"}); err != nil {
		t.Fatal(err)
	}
	quote, err := in.svc.Create(ctx, "uid-bob", CreateInput{
		IdempotencyKey: key(3), Text: "quoting", QuoteOfPostID: both.ID, QuotesEnabled: true})
	if err != nil {
		t.Fatal(err)
	}
	emb, _ := raw(quote.ID)["embedded"].(map[string]any)
	if emb["paidPartnership"] != true || emb["madeWithAi"] != true {
		t.Fatalf("stored embedded = %v, want paidPartnership and madeWithAi true", emb)
	}
	changed, _, err := in.repo.TombstoneQuotes(context.Background(), both.ID, 10)
	if err != nil || changed != 1 {
		t.Fatalf("TombstoneQuotes changed=%d err=%v, want 1", changed, err)
	}
	emb, _ = raw(quote.ID)["embedded"].(map[string]any)
	if _, ok := emb["paidPartnership"]; ok {
		t.Fatalf("tombstoned embed still has paidPartnership: %v", emb)
	}
	if _, ok := emb["madeWithAi"]; ok {
		t.Fatalf("tombstoned embed still has madeWithAi: %v", emb)
	}
	if emb["unavailable"] != true {
		t.Fatalf("tombstoned embed = %v, want unavailable", emb)
	}
}
