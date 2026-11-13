package posts

import (
	"context"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// ViewableMany is Viewable over a batch (the direct-message post cards): one GetAll for the cold posts, and each id judged
// by the one viewable predicate. Hidden, missing, protected-not-followed and REPOST ids are absent; a refusal of one id
// never fails the batch.
func TestViewableMany(t *testing.T) {
	const (
		pidHidden = "0000000000000000301"
		pidRep    = "0000000000000000302"
		pidProt   = "0000000000000000303"
		pidGone   = "0000000000000000399"
	)
	e := newDeleteEnv()
	hidden := post(pidHidden, otherUID)
	hidden.Moderation = ModerationTakenDown
	rep := post(pidRep, otherUID)
	rep.Kind, rep.RepostOfID = KindRepost, pidOther
	rep.Embedded = &Embedded{PostID: pidOther, Author: AuthorSnapshot{UserID: otherUID}}
	rep.EmbeddedAuthorID = otherUID
	prot := post(pidProt, "uid-prot")
	e.repo.docs[pidHidden], e.repo.docs[pidRep], e.repo.docs[pidProt] = hidden, rep, prot
	e.dir.profiles["uid-prot"] = e.dir.profiles[otherUID]
	e.protect("uid-prot")

	got, err := e.svc.ViewableMany(context.Background(), testUID, []string{pidMine, pidOther, pidHidden, pidRep, pidProt, pidGone})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[pidMine] == nil || got[pidOther] == nil {
		t.Fatalf("visible = %v, want exactly %s and %s", keysOf(got), pidMine, pidOther)
	}
	if e.repo.getAllCalls != 1 {
		t.Fatalf("GetAll calls = %d, want one batch", e.repo.getAllCalls)
	}
	if got, err := e.svc.ViewableMany(context.Background(), testUID, nil); err != nil || len(got) != 0 {
		t.Fatalf("empty batch = %v, %v", got, err)
	}
	many := make([]string, MaxGetMany+1)
	for i := range many {
		many[i] = pidMine
	}
	if _, err := e.svc.ViewableMany(context.Background(), testUID, many); err == nil {
		t.Fatal("a batch over MaxGetMany must fail")
	}
}

// An unknown protected set is an error for the batch (never "public"), like Viewable's UNAVAILABLE.
func TestViewableMany_ProtectedSetUnknown(t *testing.T) {
	e := newDeleteEnv()
	e.protect(otherUID).err = errBoom
	_, err := e.svc.ViewableMany(context.Background(), testUID, []string{pidOther})
	if err == nil {
		t.Fatal("want an error, never a public answer")
	}
}

func keysOf(m map[string]*Post) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// A card is unavailable for a block either way (design D2), so ViewableMany also drops a post whose author the caller
// blocked, which GetPost shows; one graph snapshot serves the batch, and the caller's own post is never dropped.
func TestViewableMany_CallerBlockedAuthor(t *testing.T) {
	e := newDeleteEnv()
	e.graph.snap = graph.Snapshot{Blocked: map[string]bool{otherUID: true}}
	if _, err := e.svc.Viewable(context.Background(), testUID, pidOther); err != nil {
		t.Fatalf("GetPost rules show it: %v", err)
	}
	got, err := e.svc.ViewableMany(context.Background(), testUID, []string{pidMine, pidOther})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[pidMine] == nil {
		t.Fatalf("visible = %v, want only %s", keysOf(got), pidMine)
	}
	e.graph.errs = map[string]error{testUID: errBoom}
	if _, err := e.svc.ViewableMany(context.Background(), testUID, []string{pidOther}); err == nil {
		t.Fatal("an unknown block set must fail the batch, never show the card")
	}
}
