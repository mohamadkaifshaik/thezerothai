// Package pubsubpublish publishes one message to a Pub/Sub topic over the REST API (google.golang.org/api/pubsub/v1,
// already in the module graph). The gRPC client (cloud.google.com/go/pubsub) is not used: we publish a handful of
// messages a day, and the REST client keeps the binary and the cold start small. The service is built lazily on the
// first Publish, so nothing happens before ListenAndServe, and PUBSUB_EMULATOR_HOST is honored like the other
// Google clients do.
package pubsubpublish

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	pubsub "google.golang.org/api/pubsub/v1"

	"google.golang.org/api/option"
)

// publishTimeout bounds every publish (CLAUDE.md: every outbound call has a deadline).
const publishTimeout = 5 * time.Second

// Publisher publishes to one topic.
type Publisher struct {
	topic string // projects/<p>/topics/<t>
	opts  []option.ClientOption

	mu  sync.Mutex
	svc *pubsub.Service
}

// New returns a Publisher for projects/<project>/topics/<topic>. It does no I/O. opts are extra client options
// (tests pass an httptest endpoint); with PUBSUB_EMULATOR_HOST set and no opts, it talks to the emulator without
// credentials.
func New(project, topic string, opts ...option.ClientOption) (*Publisher, error) {
	if project == "" || topic == "" {
		return nil, errors.New("pubsubpublish: project and topic are required")
	}
	if len(opts) == 0 {
		if host := os.Getenv("PUBSUB_EMULATOR_HOST"); host != "" {
			opts = []option.ClientOption{option.WithEndpoint("http://" + host + "/"), option.WithoutAuthentication()}
		}
	}
	return &Publisher{topic: fmt.Sprintf("projects/%s/topics/%s", project, topic), opts: opts}, nil
}

func (p *Publisher) service(ctx context.Context) (*pubsub.Service, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.svc != nil {
		return p.svc, nil
	}
	svc, err := pubsub.NewService(ctx, p.opts...)
	if err != nil {
		return nil, fmt.Errorf("pubsubpublish: build service: %w", err)
	}
	p.svc = svc
	return svc, nil
}

// Publish sends data as one message and returns once Pub/Sub has accepted it.
func (p *Publisher) Publish(ctx context.Context, data []byte) error {
	ctx, cancel := context.WithTimeout(ctx, publishTimeout)
	defer cancel()
	svc, err := p.service(context.WithoutCancel(ctx))
	if err != nil {
		return err
	}
	req := &pubsub.PublishRequest{Messages: []*pubsub.PubsubMessage{{Data: base64.StdEncoding.EncodeToString(data)}}}
	resp, err := svc.Projects.Topics.Publish(p.topic, req).Context(ctx).Do()
	if err != nil {
		return fmt.Errorf("pubsubpublish: publish: %w", err)
	}
	if len(resp.MessageIds) != 1 {
		return fmt.Errorf("pubsubpublish: publish returned %d message ids, want 1", len(resp.MessageIds))
	}
	return nil
}
