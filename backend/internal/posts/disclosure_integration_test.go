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
	plain, _ := create(key(2), "plain", false, false)

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
}
