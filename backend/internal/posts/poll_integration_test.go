//go:build integration

package posts

import (
	"context"
	"reflect"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// createWithPoll is one CreatePost call with a poll (flag on, limits at the config defaults), warm like create().
func (in *createInstance) createWithPoll(t *testing.T, uid, key, text string, poll *PollInput) (*Post, error) {
	t.Helper()
	in.svc.poll = testPollLimits
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
	if _, err := in.svc.directory.GetProfiles(context.Background(), []string{uid}); err != nil {
		t.Fatalf("warm profile: %v", err)
	}
	return in.svc.Create(ctx, uid, CreateInput{IdempotencyKey: key, Text: text, Poll: poll, PollsEnabled: true})
}

// TestCreate_Integration_Poll: the poll is written in the post's own commit, closesAt is the Snowflake createdAt + the duration,
// a root post does, closesAt is the Snowflake createdAt + the duration,
// the stored counts are "0".."n-1" all 0 with total 0, the same key with the same poll replays and with another poll is
// IDEMPOTENCY_KEY_REUSED, and a rejected poll writes nothing.
func TestCreate_Integration_Poll(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.signUp(t, "uid-alice", "alice")

	draft := &PollInput{Choices: []string{" Yes ", "No", "Maybe"}, DurationMinutes: 1440}
	p, err := in.createWithPoll(t, "uid-alice", key(1), "Which one?", draft)
	if err != nil {
		t.Fatal(err)
	}

	snap, err := client.Collection(postsCollection).Doc(p.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d postDoc
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	created, _ := snowflake.Time(p.ID)
	if d.Poll == nil || !reflect.DeepEqual(d.Poll.Options, []string{"Yes", "No", "Maybe"}) || d.Poll.DurationMin != 1440 ||
		!d.Poll.ClosesAt.Equal(created.Add(24*time.Hour)) || d.Poll.Total != 0 ||
		!reflect.DeepEqual(d.Poll.Counts, map[string]int64{"0": 0, "1": 0, "2": 0}) {
		t.Fatalf("stored poll = %+v (createdAt %v)", d.Poll, created)
	}
	if !p.Poll.ClosesAt.Equal(d.Poll.ClosesAt) || !reflect.DeepEqual(p.Poll.Counts, []int64{0, 0, 0}) {
		t.Fatalf("returned poll = %+v", p.Poll)
	}

	again, err := in.createWithPoll(t, "uid-alice", key(1), "Which one?", draft)
	if err != nil || again.ID != p.ID || again.Poll == nil || !again.Poll.ClosesAt.Equal(p.Poll.ClosesAt) {
		t.Fatalf("replay = %+v, %v", again, err)
	}

	_, err = in.createWithPoll(t, "uid-alice", key(1), "Which one?", &PollInput{Choices: []string{"Yes", "No", "Perhaps"}, DurationMinutes: 1440})
	wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	_, err = in.createWithPoll(t, "uid-alice", key(1), "Which one?", nil)
	wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)

	before := countDocs(t, client, postsCollection)
	_, err = in.createWithPoll(t, "uid-alice", key(2), "Which one?", &PollInput{Choices: []string{"Yes", "yes"}, DurationMinutes: 60})
	wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	if countDocs(t, client, postsCollection) != before {
		t.Fatal("a rejected poll wrote a post")
	}

	// The read path decodes the poll back from the emulator (cold cache).
	in.cache.DeletePost(p.ID)
	got, err := in.svc.Get(context.Background(), p.ID)
	if err != nil || got.Poll == nil || !reflect.DeepEqual(got.Poll.Options, []string{"Yes", "No", "Maybe"}) || got.Poll.Total != 0 {
		t.Fatalf("get = %+v, %v", got, err)
	}
}
