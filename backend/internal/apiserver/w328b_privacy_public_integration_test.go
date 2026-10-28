//go:build integration

package apiserver

// W3-28b (ADR-0025 D8, AQ1) through the real Build chain on the emulators, with the real UpdateProfile(is_private)
// toggle, the real PrivacyListener publishing to the jobs topic, and the real /internal/pubsub/jobs push endpoint
// (FEATURE_PRIVATE_ACCOUNTS on):
//   - P protects, 130 users request (two pages of the job), P unprotects: one privacy_public message is published, its
//     delivery accepts every request (edges, both counters, I-R and I-X, one follow_accepted event each), at the documented
//     budget;
//   - a redelivery is a no-op (done, 0 writes, nothing doubled);
//   - a re-protect before the delivery makes the job accept nothing; a forged message for a protected account (no
//     unprotect behind it) accepts nothing; a malformed or invalid message is acked and dropped.
// The re-protect in the middle of a run (between two pages) is graph's TestPrivacyPublic_Integration_ReprotectedMidRun:
// the chain cannot interleave a toggle with one delivery.

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"testing"
	"time"

	"google.golang.org/api/pubsub/v1"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w328bCfg turns the flags on and publishes notification events to a real topic (the inline emitter is a local-dev
// shortcut with 8 slots and would drop most of 130 events), with the per-actor recipient cap lifted: P is a new account
// and the production cap (50 per day for a new actor, 200 otherwise) would silently drop the surplus (runbook).
func w328bCfg(topic string) func(*config.Config) {
	return func(c *config.Config) {
		relaxLimits(c)
		c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
		c.FeaturePrivateAccounts = flags.Spec{Name: "private_accounts", Mode: flags.On}
		c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
		c.NotificationsDelivery = "pubsub"
		c.NotificationsTopic = topic
		c.RateLimit.NotificationRecipientsPerActorPerDay = 1_000_000
		c.RateLimit.NotificationRecipientsPerNewActorPerDay = 1_000_000
	}
}

func (e *lifecycleEnv) w328bToggle(t *testing.T, u testUser, key string, private bool) {
	t.Helper()
	if _, err := e.identity.UpdateProfile(context.Background(), authed(u.token, &identityv1.UpdateProfileRequest{IdempotencyKey: key, IsPrivate: &private})); err != nil {
		t.Fatalf("UpdateProfile(is_private=%v): %v", private, err)
	}
}

func (e *lifecycleEnv) w328bRequest(t *testing.T, from testUser, to string) {
	t.Helper()
	r, err := e.graph.Follow(context.Background(), authed(from.token, &graphv1.FollowRequest{IdempotencyKey: contractKey("w328b-f"), UserId: to}))
	if err != nil || r.Msg.GetRelationship().GetFollowState() != graphv1.FollowState_FOLLOW_STATE_REQUESTED {
		t.Fatalf("Follow of a protected account = %v, %v, want REQUESTED", r, err)
	}
}

// lastJob is the last privacy_public delivery line.
func (e *lifecycleEnv) w328bLastJob(t *testing.T) map[string]any {
	t.Helper()
	var last map[string]any
	for _, l := range e.jobLines() {
		if l["account_job"] == "privacy_public" {
			last = l
		}
	}
	if last == nil {
		t.Fatal("no privacy_public delivery line")
	}
	return last
}

func (e *lifecycleEnv) w328bUserField(t *testing.T, uid, field string) int64 {
	t.Helper()
	snap, err := e.fs.Doc("users/" + uid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	v, _ := snap.Data()[field].(int64)
	return v
}

func TestW328b_PrivacyPublicThroughTheChain(t *testing.T) {
	const n = 130 // two pages: 100 + 30
	topic := fmt.Sprintf("notif-%d", rand.Int63())
	e := newLifecycleEnvCfg(t, nil, w328bCfg(topic))
	notifSub := e.w328bSubscribe(t, topic)
	p := e.newUser(t)
	other := e.newUser(t)
	e.w328bToggle(t, p, "w328b-protect-000001", true)
	e.w328bToggle(t, other, "w328b-protect-000002", true)
	reqs := make([]testUser, n)
	for i := range reqs {
		reqs[i] = e.newUser(t)
		e.w328bRequest(t, reqs[i], p.uid)
	}
	e.w328bRequest(t, reqs[0], other.uid)
	e.pull(t)                   // drain the jobs subscription
	e.w328bPullSub(t, notifSub) // and the follow_request events of the setup

	// --- unprotect publishes exactly one privacy_public message and costs the toggle nothing extra ---
	e.w328bToggle(t, p, "w328b-unprotect-00001", false)
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "privacy_public" || msgs[0]["uid"] != p.uid {
		t.Fatalf("messages after unprotect = %v, want one privacy_public for P", msgs)
	}
	for _, r := range reqs {
		if !fsDocExists(t, e.fs, "followRequests/"+r.uid+"_"+p.uid) {
			t.Fatal("the unprotect itself must not touch the requests (the job does)")
		}
	}

	// --- the delivery accepts everything ---
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d", code)
	}
	line := e.w328bLastJob(t)
	t.Logf("BUDGET privacy_public n=%d reads=%v writes=%v deletes=%v", n, line["fs_reads"], line["fs_writes"], line["fs_deletes"])
	// reads: 2 pages x 1 (users) + 2 per request (+ the cache-first Directory lookup, at most 1 per requester when cold).
	// writes: 3 per request + 1 per page. deletes: 1 per request.
	reads, writes, deletes := line["fs_reads"].(float64), line["fs_writes"].(float64), line["fs_deletes"].(float64)
	if line["outcome"] != "done" || reads < 2+2*n || reads > 2+3*n || writes != 3*n+2 || deletes != n {
		t.Errorf("job line = outcome %v reads %v writes %v deletes %v, want done / %d..%d / %d / %d",
			line["outcome"], reads, writes, deletes, 2+2*n, 2+3*n, 3*n+2, n)
	}
	if got := e.w328bUserField(t, p.uid, "followersCount"); got != n {
		t.Errorf("P.followersCount = %d, want exactly %d", got, n)
	}
	for _, r := range reqs {
		requested, edge := w328Invariants(t, e.fs, r.uid, p.uid)
		if requested || !edge {
			t.Fatalf("requester %s: request=%v edge=%v, want an edge and no request", r.uid, requested, edge)
		}
	}
	if got := e.w328bUserField(t, reqs[7].uid, "followingCount"); got != 1 {
		t.Errorf("requester followingCount = %d, want 1", got)
	}
	// A request to ANOTHER protected account is untouched by P's job (I-R still holds there).
	if requested, edge := w328Invariants(t, e.fs, reqs[0].uid, other.uid); !requested || edge {
		t.Errorf("request to the other protected account: request=%v edge=%v, want it untouched", requested, edge)
	}
	// FollowRequestAccepted: exactly one event per accepted request, actor P, published after the pages committed.
	got := map[string]bool{}
	for _, m := range e.w328bPullSub(t, notifSub) {
		if m["type"] != "follow_accepted" || m["actorId"] != p.uid {
			t.Errorf("unexpected notification event %v", m)
			continue
		}
		for _, r := range m["recipientIds"].([]any) {
			got[r.(string)] = true
		}
	}
	if len(got) != n {
		t.Errorf("follow_accepted events cover %d requesters, want %d", len(got), n)
	}
	for _, r := range reqs {
		if !got[r.uid] {
			t.Errorf("requester %s got no follow_accepted event", r.uid)
			break
		}
	}

	// --- redelivery: a no-op ---
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("redelivery = %d", code)
	}
	line = e.w328bLastJob(t)
	if line["outcome"] != "done" || line["fs_writes"] != float64(0) || line["fs_deletes"] != float64(0) || line["fs_reads"] != float64(2) {
		t.Errorf("redelivery line = %v / writes %v / deletes %v / reads %v, want done / 0 / 0 / 2", line["outcome"], line["fs_writes"], line["fs_deletes"], line["fs_reads"])
	}
	if got := e.w328bUserField(t, p.uid, "followersCount"); got != n {
		t.Errorf("after the redelivery P.followersCount = %d, want %d", got, n)
	}

	// --- forged: a message for an account that is still protected accepts nothing ---
	if code := e.deliverJSON(t, map[string]any{"kind": "privacy_public", "uid": other.uid, "at": time.Now().UTC()}); code != http.StatusNoContent {
		t.Fatalf("forged delivery = %d", code)
	}
	if line = e.w328bLastJob(t); line["outcome"] != "stopped:protected" || line["fs_writes"] != float64(0) {
		t.Errorf("forged line = %v writes %v, want stopped:protected / 0", line["outcome"], line["fs_writes"])
	}
	if requested, _ := w328Invariants(t, e.fs, reqs[0].uid, other.uid); !requested {
		t.Error("a forged message accepted a request of a protected account")
	}

	// --- re-protect before the delivery: unprotect, protect again, then the message arrives ---
	e.w328bToggle(t, other, "w328b-unprotect-00002", false)
	late := e.pull(t)
	if len(late) != 1 {
		t.Fatalf("messages = %v", late)
	}
	e.w328bToggle(t, other, "w328b-protect-000003", true)
	if code := e.deliver(t, late[0]); code != http.StatusNoContent {
		t.Fatalf("late delivery = %d", code)
	}
	if line = e.w328bLastJob(t); line["outcome"] != "stopped:protected" || line["fs_writes"] != float64(0) || line["fs_reads"] != float64(1) {
		t.Errorf("late line = %v reads %v writes %v, want stopped:protected / 1 / 0", line["outcome"], line["fs_reads"], line["fs_writes"])
	}
	if requested, edge := w328Invariants(t, e.fs, reqs[0].uid, other.uid); !requested || edge {
		t.Errorf("after a re-protect the request must stay: request=%v edge=%v", requested, edge)
	}

	// --- poison is acked ---
	for name, m := range map[string]map[string]any{
		"bad uid":    {"kind": "privacy_public", "uid": "bad/uid"},
		"no uid":     {"kind": "privacy_public"},
		"wrong kind": {"kind": "privacy_publicx", "uid": p.uid},
	} {
		if code := e.deliverJSON(t, m); code != http.StatusNoContent {
			t.Errorf("%s: delivery = %d, want an ack", name, code)
		}
	}
}

// w328bSubscribe creates the notifications topic and a subscription on it (the chain publishes lazily).
func (e *lifecycleEnv) w328bSubscribe(t *testing.T, topic string) string {
	t.Helper()
	ctx := context.Background()
	topicName := fmt.Sprintf("projects/%s/topics/%s", e.cfg.ProjectID, topic)
	sub := fmt.Sprintf("projects/%s/subscriptions/sub-%s", e.cfg.ProjectID, topic)
	if _, err := e.ps.Projects.Topics.Create(topicName, &pubsub.Topic{}).Context(ctx).Do(); err != nil {
		t.Fatalf("create notifications topic: %v", err)
	}
	if _, err := e.ps.Projects.Subscriptions.Create(sub, &pubsub.Subscription{Topic: topicName, AckDeadlineSeconds: 60}).Context(ctx).Do(); err != nil {
		t.Fatalf("create notifications subscription: %v", err)
	}
	return sub
}

// w328bPullSub is pull for another subscription.
func (e *lifecycleEnv) w328bPullSub(t *testing.T, sub string) []map[string]any {
	t.Helper()
	saved := e.sub
	e.sub = sub
	defer func() { e.sub = saved }()
	return e.pull(t)
}
