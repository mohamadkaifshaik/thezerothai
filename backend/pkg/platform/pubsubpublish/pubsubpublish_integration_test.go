//go:build integration

package pubsubpublish

import (
	"context"
	"encoding/base64"
	"fmt"
	"math/rand"
	"os"
	"testing"
	"time"

	pubsub "google.golang.org/api/pubsub/v1"

	"google.golang.org/api/option"
)

// TestPublish_Integration publishes through the REST client to the Pub/Sub emulator and pulls the message back,
// which proves PUBSUB_EMULATOR_HOST is honored and the base64 payload round-trips.
func TestPublish_Integration(t *testing.T) {
	host := os.Getenv("PUBSUB_EMULATOR_HOST")
	if host == "" {
		t.Skip("PUBSUB_EMULATOR_HOST not set; run via the emulator suite")
	}
	ctx := context.Background()
	project := "demo-pubsubpublish"
	topic := fmt.Sprintf("jobs-%d", rand.Int63())
	subName := "sub-" + topic

	admin, err := pubsub.NewService(ctx, option.WithEndpoint("http://"+host+"/"), option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	topicName := fmt.Sprintf("projects/%s/topics/%s", project, topic)
	fullSub := fmt.Sprintf("projects/%s/subscriptions/%s", project, subName)
	if _, err := admin.Projects.Topics.Create(topicName, &pubsub.Topic{}).Context(ctx).Do(); err != nil {
		t.Fatalf("create topic: %v", err)
	}
	if _, err := admin.Projects.Subscriptions.Create(fullSub, &pubsub.Subscription{Topic: topicName, AckDeadlineSeconds: 10}).Context(ctx).Do(); err != nil {
		t.Fatalf("create subscription: %v", err)
	}

	p, err := New(project, topic)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte(`{"kind":"account_delete","uid":"u1","seq":0}`)
	if err := p.Publish(ctx, payload); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := admin.Projects.Subscriptions.Pull(fullSub, &pubsub.PullRequest{MaxMessages: 1}).Context(ctx).Do()
		if err != nil {
			t.Fatalf("pull: %v", err)
		}
		if len(resp.ReceivedMessages) == 1 {
			got, _ := base64.StdEncoding.DecodeString(resp.ReceivedMessages[0].Message.Data)
			if string(got) != string(payload) {
				t.Fatalf("pulled %q, want %q", got, payload)
			}
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("the published message never arrived")
}
