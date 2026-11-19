//go:build integration

package moderation

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// An encrypted message's report keeps the disclosed text, the shared post id and the verdict in the evidence child (same
// retention), nothing of them in the parent; Get reads them back; a reopen replaces the child whole, so a verified
// verdict never outlives a later unverified filing.
func TestRepo_EncryptedMessageEvidenceChild(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	ctx := context.Background()
	t0 := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	file := func(at time.Time, text string, verified bool) Report {
		r := sampleReport("u-rep", TargetMessage, "c9:m9", "u-bob", at)
		r.Evidence = &Evidence{Text: text, AuthorHandle: "bob", PostCreatedAt: at, MessageEncrypted: true, MessageVerified: verified, SharedPostID: "1234567890123456789"}
		return r
	}
	first := file(t0, "disclosed words", true)
	if _, err := repo.Create(ctx, CreateParams{Report: first, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	parent, err := client.Collection("reports").Doc(first.ID).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ev, _ := parent.Data()["evidence"].(map[string]any)
	for _, k := range []string{"text", "sharedPostId", "verified", "encrypted"} {
		if v, ok := ev[k]; ok && v != "" {
			t.Errorf("parent evidence.%s = %v, want it only in the child", k, v)
		}
	}
	child := client.Collection("reports").Doc(first.ID).Collection("evidence").Doc("message")
	cs, err := child.Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"text": "disclosed words", "expireAt": t0.Add(MessageEvidenceRetention), "encrypted": true, "verified": true, "sharedPostId": "1234567890123456789"}
	got := cs.Data()
	if exp, ok := got["expireAt"].(time.Time); ok {
		got["expireAt"] = exp.UTC()
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("child = %v, want exactly %v", got, want)
	}
	r, err := repo.Get(ctx, first.ID)
	if err != nil || r.Evidence.Text != "disclosed words" || !r.Evidence.MessageEncrypted || !r.Evidence.MessageVerified || r.Evidence.SharedPostID != "1234567890123456789" {
		t.Fatalf("get = %+v err=%v", r.Evidence, err)
	}

	if _, err := repo.Resolve(ctx, first.ID, ResolutionNoAction, "", t0.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	again := file(t0.Add(48*time.Hour), "other words", false)
	if cr, err := repo.Create(ctx, CreateParams{Report: again, QuotaLimit: 5}); err != nil || !cr.Reopened {
		t.Fatalf("reopen: %+v err=%v", cr, err)
	}
	cs, err = child.Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := cs.Data()["verified"]; ok {
		t.Errorf("reopened child = %v, the old verified verdict survived", cs.Data())
	}
	r, err = repo.Get(ctx, first.ID)
	if err != nil || r.Evidence.Text != "other words" || !r.Evidence.MessageEncrypted || r.Evidence.MessageVerified {
		t.Fatalf("reopened get = %+v err=%v", r.Evidence, err)
	}
}

// A plaintext message's child keeps its two fields: no verdict, no encrypted marker.
func TestRepo_PlaintextMessageEvidenceChildIsUnchanged(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	ctx := context.Background()
	t0 := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	r := sampleReport("u-rep", TargetMessage, "c8:m8", "u-bob", t0)
	r.Evidence = &Evidence{Text: "plain", AuthorHandle: "bob", PostCreatedAt: t0}
	if _, err := repo.Create(ctx, CreateParams{Report: r, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	cs, err := client.Collection("reports").Doc(r.ID).Collection("evidence").Doc("message").Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if got := cs.Data(); len(got) != 2 || got["text"] != "plain" {
		t.Errorf("plaintext child = %v, want only text and expireAt", got)
	}
}
