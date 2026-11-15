//go:build integration

package posts

import (
	"context"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// statsEngagements sums uid's dailyStats engagements over every shard doc.
func statsEngagements(t *testing.T, in *createInstance, uid string) int64 {
	t.Helper()
	ds, err := in.repo.client.Collection("users").Doc(uid).Collection(identity.DailyStatsSubcollection).Limit(50).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	var sum int64
	for _, d := range ds {
		v, _ := d.DataAt("engagements")
		n, _ := v.(int64)
		sum += n
	}
	return sum
}

// TestIntegration_CreatorStatsHotSelfReply (F2): with HOT_COUNTER_THRESHOLD 1, the author's own reply on their hot post
// counts in replyCount after the fold but not in their engagements (the self field), while another account's hot
// reply counts in both; the self field is drained, never written onto the post, and a second fold moves nothing.
func TestIntegration_CreatorStatsHotSelfReply(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.repo.SetHotCounterThreshold(1)
	in.repo.now = func() time.Time { return time.Now().Add(-time.Hour) } // the markers' window is already foldable
	in.repo.w.Stats = identity.NewDailyStatsRepo(client, nil)
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")
	root, err := in.create(t, "uid-alice", key(1), "root post")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := in.reply(t, "uid-bob", key(2), "first (cold)", root.ID); err != nil {
		t.Fatal(err)
	}
	if n := statsEngagements(t, in, "uid-alice"); n != 1 {
		t.Fatalf("cold reply: engagements %d, want 1", n)
	}
	for i, uid := range []string{"uid-alice", "uid-bob"} { // both hot now (the parent reads 1)
		in.cache.DeletePost(root.ID)
		if _, err := in.reply(t, uid, key(3+i), "hot reply", root.ID); err != nil {
			t.Fatal(err)
		}
	}
	for range 2 { // the second tick is a redelivery
		runCounterRollup(t, in.repo)
	}
	if r, _ := counts(t, client, root.ID); r != 3 {
		t.Fatalf("replyCount = %d, want 3 (the author's own reply is a reply)", r)
	}
	if n := statsEngagements(t, in, "uid-alice"); n != 2 {
		t.Fatalf("engagements = %d, want 2 (bob's two replies; alice's own is left out)", n)
	}
	snap, err := client.Doc(postsCollection + "/" + root.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := snap.DataAt("selfReplyCount"); err == nil {
		t.Fatal("the self field was written onto the post")
	}
	tot, err := viewShards.Read(context.Background(), client, []*firestore.DocumentRef{in.repo.ref(root.ID)}, selfReplyCountField)
	if err != nil || tot[0].Get(selfReplyCountField) != 0 {
		t.Fatalf("self field left on the shards: %v %v", tot, err)
	}
}
