//go:build integration

package communities

import (
	"context"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// Hide and Restore also take a reply whose conversationCommunityId is the community. A reply has no
// communityId: hidden = communityHidden + communityHiddenAt, no recentRemovals entry, a modlog entry as for a root.

const (
	rplA     = "0000000000000000821" // reply by "member" in the community conversation
	rplB     = "0000000000000000822"
	rplOther = "0000000000000000829" // reply in another community conversation
	rplNone  = "0000000000000000828" // reply in a conversation with no community
	rplRepo  = "0000000000000000830" // a REPOST carrying the community conversation key
)

func (e *env) seedReply(t *testing.T, id, author, convCommunity string) {
	t.Helper()
	d := map[string]any{"authorId": author, "kind": "REPLY", "isReply": true, "text": "re", "createdAt": time.Now().UTC(), "replyToId": modPostA, "conversationId": modPostA}
	if convCommunity != "" {
		d["conversationCommunityId"] = convCommunity
	}
	if _, err := e.client.Collection("posts").Doc(id).Set(context.Background(), d); err != nil {
		t.Fatal(err)
	}
}

func (e *env) replyState(t *testing.T, id string) (hidden, hasAt, hasCommunityID bool) {
	t.Helper()
	d, ok := e.data(t, "posts/"+id)
	if !ok {
		t.Fatalf("reply %s is gone", id)
	}
	hidden, _ = d["communityHidden"].(bool)
	_, hasAt = d["communityHiddenAt"]
	_, hasCommunityID = d["communityId"]
	return
}

func newReplyEnv(t *testing.T) *env {
	t.Helper()
	e := newModEnv(t)
	e.seedReply(t, rplA, "member", modCID)
	e.seedReply(t, rplB, "member", modCID)
	e.seedReply(t, rplOther, "member", "0000000000000000899")
	e.seedReply(t, rplNone, "member", "")
	return e
}

func TestHideRestoreReply_EffectsAndReplay(t *testing.T) {
	e := newReplyEnv(t)
	ctx := context.Background()

	if err := e.hide(context.Background(), "mod1", 1, rplA); err != nil {
		t.Fatal(err)
	}
	if hidden, hasAt, hasCID := e.replyState(t, rplA); !hidden || !hasAt || hasCID {
		t.Errorf("after the hide: hidden=%v hiddenAt=%v communityId=%v", hidden, hasAt, hasCID)
	}
	c := e.community(t, modCID)
	if len(c.RecentRemovals) != 0 || !c.RemovalsTruncatedAt.IsZero() {
		t.Errorf("a reply hide wrote recentRemovals: %+v truncated %v", c.RecentRemovals, c.RemovalsTruncatedAt)
	}
	if len(c.Modlog) != 1 || c.Modlog[0].Action != ActionHide || c.Modlog[0].PostID != rplA || c.Modlog[0].Actor != "mod1" || c.Modlog[0].Target != "" {
		t.Errorf("modlog = %+v", c.Modlog)
	}

	// a second reply by the same moderator
	if err := e.hide(context.Background(), "mod1", 2, rplB); err != nil {
		t.Fatal(err)
	}
	// an already hidden reply: nothing more is logged
	if err := e.hide(context.Background(), "owner", 3, rplA); err != nil {
		t.Fatal(err)
	}
	if c = e.community(t, modCID); len(c.Modlog) != 2 {
		t.Errorf("modlog = %d after a repeated hide, want 2", len(c.Modlog))
	}

	if err := e.restore(context.Background(), "owner", 4, rplA); err != nil {
		t.Fatal(err)
	}
	if hidden, hasAt, _ := e.replyState(t, rplA); hidden || hasAt {
		t.Errorf("after the restore: hidden=%v hiddenAt=%v", hidden, hasAt)
	}
	if c = e.community(t, modCID); len(c.RecentRemovals) != 0 || len(c.Modlog) != 3 || c.Modlog[2].Action != ActionRestore || c.Modlog[2].PostID != rplA {
		t.Errorf("after the restore: removals %+v modlog %+v", c.RecentRemovals, c.Modlog)
	}
	if err := e.restore(context.Background(), "mod1", 5, rplA); err != nil {
		t.Fatal(err)
	}
	if c = e.community(t, modCID); len(c.Modlog) != 3 {
		t.Errorf("restoring a listed reply logged: modlog = %d, want 3", len(c.Modlog))
	}
	// A13: the first hide key replayed after the restore writes nothing
	if err := e.hide(context.Background(), "mod1", 1, rplA); err != nil {
		t.Fatal(err)
	}
	if hidden, _, _ := e.replyState(t, rplA); hidden {
		t.Error("the replay re-hid the reply")
	}
	// a new key after a restore hides again
	if err := e.hide(ctx, "mod1", 6, rplA); err != nil {
		t.Fatal(err)
	}
	if hidden, _, _ := e.replyState(t, rplA); !hidden {
		t.Error("a new key after a restore did not hide")
	}
}

func TestHideRestoreReply_RolesAndTargets(t *testing.T) {
	e := newReplyEnv(t)
	ctx := context.Background()
	n := 100
	for _, tc := range []struct {
		actor  string
		wantOK bool
	}{{"owner", true}, {"mod1", true}, {"member", false}, {"banned", false}, {"stranger", false}} {
		for _, restore := range []bool{false, true} {
			n++
			var err error
			if restore {
				err = e.restore(ctx, tc.actor, n, rplB)
			} else {
				err = e.hide(ctx, tc.actor, n, rplB)
			}
			if tc.wantOK {
				if err != nil {
					t.Errorf("%s restore=%v: %v", tc.actor, restore, err)
				}
				continue
			}
			wantReason(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "not_moderator")
		}
	}
	// a reply of another community conversation or of none, a missing reply: the one NOT_FOUND, no write
	before := e.community(t, modCID)
	for i, id := range []string{rplOther, rplNone, "0000000000000000899"} {
		wantAPIErr(t, e.hide(ctx, "owner", 200+i, id), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		wantAPIErr(t, e.restore(ctx, "owner", 210+i, id), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	}
	for _, id := range []string{rplOther, rplNone} {
		if hidden, hasAt, _ := e.replyState(t, id); hidden || hasAt {
			t.Errorf("reply %s changed", id)
		}
	}
	if after := e.community(t, modCID); len(after.Modlog) != len(before.Modlog) {
		t.Error("a NOT_FOUND wrote a modlog entry")
	}
	// a REPOST carrying the conversation key never qualifies
	if _, err := e.client.Collection("posts").Doc(rplRepo).Set(ctx, map[string]any{
		"authorId": "member", "kind": "REPOST", "conversationCommunityId": modCID, "createdAt": time.Now().UTC(),
	}); err != nil {
		t.Fatal(err)
	}
	wantAPIErr(t, e.hide(ctx, "owner", 230, rplRepo), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	// L-2: a reply with moderation set is NOT_FOUND for a hide and a restore
	e.setPostField(t, rplA, "moderation", "TAKEN_DOWN")
	wantAPIErr(t, e.hide(ctx, "owner", 231, rplA), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	wantAPIErr(t, e.restore(ctx, "owner", 232, rplA), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	if hidden, hasAt, _ := e.replyState(t, rplA); hidden || hasAt {
		t.Error("a moderated reply was changed")
	}
}

// F16 on replies (the rules, unchanged later) and the attack points of the review.
func TestHideRestoreReply_F16(t *testing.T) {
	ctx := context.Background()
	t.Run("a moderator cannot hide or restore the owner or another moderator reply", func(t *testing.T) {
		e := newReplyEnv(t)
		for i, author := range []string{"owner", "mod2"} {
			e.setPostField(t, rplA, "authorId", author)
			wantReason(t, e.hide(ctx, "mod1", 300+i, rplA), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "not_owner")
			wantReason(t, e.restore(ctx, "mod1", 310+i, rplA), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "not_owner")
			if hidden, _, _ := e.replyState(t, rplA); hidden {
				t.Error("a refused hide changed the reply")
			}
		}
		if c := e.community(t, modCID); len(c.Modlog) != 0 {
			t.Errorf("a refusal wrote the modlog: %+v", c.Modlog)
		}
	})
	t.Run("a refusal writes nothing", func(t *testing.T) {
		e := newReplyEnv(t)
		e.setPostField(t, rplA, "authorId", "owner")
		wantReason(t, e.hide(context.Background(), "mod1", 320, rplA), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "not_owner")
		if _, ok := e.data(t, "idempotency/"+idempotency.Key("mod1", "HideCommunityPost", key(320))); ok {
			t.Error("a refusal left an idempotency record")
		}
	})
	t.Run("owner hides a moderator reply, another moderator restores it: refused; the author may", func(t *testing.T) {
		e := newReplyEnv(t)
		e.setPostField(t, rplA, "authorId", "mod2")
		if err := e.hide(ctx, "owner", 330, rplA); err != nil {
			t.Fatal(err)
		}
		wantReason(t, e.restore(ctx, "mod1", 331, rplA), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "not_owner")
		if hidden, _, _ := e.replyState(t, rplA); !hidden {
			t.Error("the refused restore changed the reply")
		}
		if err := e.restore(ctx, "mod2", 332, rplA); err != nil {
			t.Fatalf("a moderator restoring their own reply: %v", err)
		}
	})
	t.Run("an empty authorId is a plain author", func(t *testing.T) {
		e := newReplyEnv(t)
		e.setPostField(t, rplA, "authorId", "")
		if err := e.hide(ctx, "mod1", 340, rplA); err != nil {
			t.Fatalf("hide of a reply with no author: %v", err)
		}
		if err := e.restore(ctx, "mod1", 341, rplA); err != nil {
			t.Fatalf("restore: %v", err)
		}
	})
	t.Run("replay after the author became a moderator is a replay, a new key is refused", func(t *testing.T) {
		e := newReplyEnv(t)
		if err := e.hide(ctx, "mod1", 350, rplA); err != nil {
			t.Fatal(err)
		}
		if _, err := e.repo.ref(modCID).Update(ctx, []firestore.Update{{Path: "moderatorIds", Value: []string{"mod1", "mod2", "member"}}}); err != nil {
			t.Fatal(err)
		}
		if err := e.hide(context.Background(), "mod1", 350, rplA); err != nil {
			t.Fatalf("replay: %v", err)
		}
		wantReason(t, e.restore(ctx, "mod1", 351, rplA), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "not_owner")
		if err := e.restore(ctx, "owner", 352, rplA); err != nil {
			t.Fatalf("owner restore: %v", err)
		}
	})
	t.Run("a moderator demoted between the actions is refused on the fresh community", func(t *testing.T) {
		e := newReplyEnv(t)
		if err := e.hide(ctx, "mod1", 360, rplA); err != nil {
			t.Fatal(err)
		}
		if _, err := e.repo.ref(modCID).Update(ctx, []firestore.Update{{Path: "moderatorIds", Value: []string{"mod2"}}}); err != nil {
			t.Fatal(err)
		}
		// no cache-first read: the cached community still lists mod1
		wantReason(t, e.restore(ctx, "mod1", 361, rplA), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "not_moderator")
		if hidden, _, _ := e.replyState(t, rplA); !hidden {
			t.Error("a demoted moderator restored a reply")
		}
	})
}

// A root hide also sets communityHiddenAt, and the restore deletes it.
func TestHideRestoreRoot_WritesHiddenAt(t *testing.T) {
	e := newModEnv(t)
	ctx := context.Background()
	if err := e.hide(ctx, "mod1", 1, modPostA); err != nil {
		t.Fatal(err)
	}
	d, _ := e.data(t, "posts/"+modPostA)
	if at, ok := d["communityHiddenAt"].(time.Time); !ok || at.IsZero() || d["communityHidden"] != true {
		t.Errorf("after a root hide: %v", d)
	}
	if err := e.restore(ctx, "mod1", 2, modPostA); err != nil {
		t.Fatal(err)
	}
	d, _ = e.data(t, "posts/"+modPostA)
	if _, ok := d["communityHiddenAt"]; ok || d["communityId"] != modCID {
		t.Errorf("after a root restore: %v", d)
	}
}
