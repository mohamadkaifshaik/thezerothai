//go:build integration

// block_integration_test.go exercises Block/Unblock/Mute/Unmute against the Firestore emulator (acceptance criteria).
package graph_test

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

func TestBlock_Integration_MutualFollow(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	ctx0 := context.Background()
	if _, err := w.graph.Follow(ctx0, "uid-a", key1, "uid-b"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Follow(ctx0, "uid-b", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	rel, err := w.graph.Block(ctx, "uid-a", key2, "uid-b")
	if err != nil {
		t.Fatalf("Block: %v", err)
	}
	if !rel.Blocking || rel.FollowState != graph.FollowStateNone {
		t.Errorf("rel = %+v", rel)
	}

	if docExists(t, w.client, "follows/uid-a_uid-b") || docExists(t, w.client, "follows/uid-b_uid-a") {
		t.Error("follows docs must both be deleted")
	}
	a, b := graphArrays(t, w.client, "uid-a"), graphArrays(t, w.client, "uid-b")
	if !contains(a["blocked"], "uid-b") || len(a["following"]) != 0 {
		t.Errorf("a = %v", a)
	}
	if !contains(b["blockedBy"], "uid-a") || len(b["following"]) != 0 || len(b["blocked"]) != 0 {
		t.Errorf("b = %v", b)
	}
	for _, uid := range []string{"uid-a", "uid-b"} {
		if fg, fr := counts(t, w, uid); fg != 0 || fr != 0 {
			t.Errorf("%s counters = %d/%d, want 0/0 (each decremented exactly once)", uid, fg, fr)
		}
	}

	// Replay: still blocking, and neither graph document changed.
	ctx2 := context.Background()
	rel, err = w.graph.Block(ctx2, "uid-a", key3, "uid-b")
	if err != nil || !rel.Blocking {
		t.Fatalf("replay = %+v, %v", rel, err)
	}
	if a2, b2 := graphArrays(t, w.client, "uid-a"), graphArrays(t, w.client, "uid-b"); !reflect.DeepEqual(a, a2) || !reflect.DeepEqual(b, b2) {
		t.Errorf("the replay changed the graphs: a %v -> %v, b %v -> %v", a, a2, b, b2)
	}
}

func TestBlock_Integration_Typical(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	ctx := context.Background()
	if _, err := w.graph.Block(ctx, "uid-a", key1, "uid-b"); err != nil {
		t.Fatal(err)
	}
	if a := graphArrays(t, w.client, "uid-a"); !contains(a["blocked"], "uid-b") {
		t.Errorf("a = %v, want blocked to name uid-b", a)
	}
	if b := graphArrays(t, w.client, "uid-b"); !contains(b["blockedBy"], "uid-a") {
		t.Errorf("b = %v, want blockedBy to name uid-a", b)
	}
}

func TestBlock_Integration_UnknownTargetAndSelf(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	_, err := w.graph.Block(context.Background(), "uid-a", key1, "ghost")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code.String() != "not_found" {
		t.Fatalf("err = %v, want not_found", err)
	}
	_, err = w.graph.Block(context.Background(), "uid-a", key1, "uid-a")
	if !errors.As(err, &ae) || ae.Code.String() != "invalid_argument" {
		t.Fatalf("err = %v, want invalid_argument", err)
	}
}

func TestUnblock_Integration_NoRestoreAndNoop(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	ctx0 := context.Background()
	if _, err := w.graph.Follow(ctx0, "uid-a", key1, "uid-b"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx0, "uid-a", key2, "uid-b"); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	rel, err := w.graph.Unblock(ctx, "uid-a", key3, "uid-b")
	if err != nil || rel.Blocking || rel.FollowState != graph.FollowStateNone {
		t.Fatalf("Unblock = %+v, %v", rel, err)
	}
	a, b := graphArrays(t, w.client, "uid-a"), graphArrays(t, w.client, "uid-b")
	if contains(a["blocked"], "uid-b") || contains(b["blockedBy"], "uid-a") || len(a["following"]) != 0 {
		t.Errorf("a=%v b=%v", a, b)
	}

	// Unblock of someone no longer blocked is a no-op: the graphs stay as they are.
	ctx2 := context.Background()
	if _, err := w.graph.Unblock(ctx2, "uid-a", "aaaaaaaaaaaaaaaa", "uid-b"); err != nil {
		t.Fatal(err)
	}
	if a2, b2 := graphArrays(t, w.client, "uid-a"), graphArrays(t, w.client, "uid-b"); !reflect.DeepEqual(a, a2) || !reflect.DeepEqual(b, b2) {
		t.Errorf("the no-op Unblock changed the graphs: a %v -> %v, b %v -> %v", a, a2, b, b2)
	}
}

func TestMute_Integration_OnlyCallerGraphChanges(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	ctx := context.Background()
	rel, err := w.graph.Mute(ctx, "uid-a", key1, "uid-b")
	if err != nil || !rel.Muting {
		t.Fatalf("Mute = %+v, %v", rel, err)
	}
	if a := graphArrays(t, w.client, "uid-a"); !contains(a["muted"], "uid-b") {
		t.Errorf("a = %v", a)
	}
	if b := graphArrays(t, w.client, "uid-b"); len(b["muted"])+len(b["blockedBy"])+len(b["blocked"]) != 0 {
		t.Errorf("target graph changed: %v", b)
	}

	// Replay: nothing changes.
	ctx2 := context.Background()
	before := graphArrays(t, w.client, "uid-a")
	if _, err := w.graph.Mute(ctx2, "uid-a", key2, "uid-b"); err != nil {
		t.Fatal(err)
	}
	if after := graphArrays(t, w.client, "uid-a"); !reflect.DeepEqual(before, after) {
		t.Errorf("the Mute replay changed the graph: %v -> %v", before, after)
	}

	ctx3 := context.Background()
	rel, err = w.graph.Unmute(ctx3, "uid-a", key3, "uid-b")
	if err != nil || rel.Muting {
		t.Fatalf("Unmute = %+v, %v", rel, err)
	}
	ctx4 := context.Background()
	before = graphArrays(t, w.client, "uid-a")
	if _, err := w.graph.Unmute(ctx4, "uid-a", "aaaaaaaaaaaaaaaa", "uid-b"); err != nil {
		t.Fatal(err)
	}
	if after := graphArrays(t, w.client, "uid-a"); !reflect.DeepEqual(before, after) {
		t.Errorf("the no-op Unmute changed the graph: %v -> %v", before, after)
	}
}

func TestBlock_Integration_CapsAndOverflow(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")

	pad := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = "pad-" + time.Duration(i).String()
		}
		return out
	}
	// Target at the blockedBy cap: caller's block still lands, blockedBy is skipped, overflow flag is set.
	seedGraphArrays(t, w.client, "uid-b", map[string]interface{}{"blockedBy": pad(10000)})
	if _, err := w.graph.Block(context.Background(), "uid-a", key1, "uid-b"); err != nil {
		t.Fatalf("Block at blockedBy cap: %v", err)
	}
	if a := graphArrays(t, w.client, "uid-a"); !contains(a["blocked"], "uid-b") {
		t.Errorf("a = %v", a)
	}
	if b := graphArrays(t, w.client, "uid-b"); contains(b["blockedBy"], "uid-a") || len(b["blockedBy"]) != 10000 {
		t.Error("blockedBy must not grow past its cap")
	}
	snap, err := w.client.Collection("graph").Doc("uid-b").Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := snap.DataAt("blockedByOverflow"); v != true {
		t.Errorf("blockedByOverflow = %v, want true", v)
	}

	// Caller at the blocked cap: LIMIT_REACHED.
	mustCreateProfile(t, w.identity, "uid-c", "userc")
	seedGraphArrays(t, w.client, "uid-c", map[string]interface{}{"blocked": pad(2000)})
	_, err = w.graph.Block(context.Background(), "uid-c", key1, "uid-b")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["limit"] != "blocked" {
		t.Errorf("err = %v, want LIMIT_REACHED blocked", err)
	}
}
