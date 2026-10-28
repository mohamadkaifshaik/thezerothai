//go:build integration

package apiserver

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// hidingPosts wraps a posts.Service so the embedded type loses the AudienceOf hook: what a refactor that decorates
// postsSvc would do. posts.AudienceOf then returns nil and the engagement lists would fail open.
type hidingPosts struct{ posts.Service }

// W3-36 L-5: build refuses to start, naming the seam, when the engagement Audience would be nil; the real wiring starts.
func TestBuild_RefusesMissingProtectedSeam(t *testing.T) {
	skipIfNoEmulators(t)
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	cfg.FeaturePosts = flags.Spec{Name: "posts", Mode: flags.On}
	log := slog.New(slog.NewJSONHandler(&logBuf{}, nil))

	_, fsClient, err := build(context.Background(), cfg, log, nil, func(o *buildOpts) {
		o.audienceSource = func(s posts.Service) posts.Service { return hidingPosts{s} }
	})
	if err == nil {
		_ = fsClient.Close()
		t.Fatal("build started with a nil engagement Audience")
	}
	if !errors.Is(err, errProtectedSeamMissing) || !strings.Contains(err.Error(), "engagement.Deps.Audience") {
		t.Fatalf("err = %v, want the named engagement seam", err)
	}

	h, fsClient, err := build(context.Background(), cfg, log, nil)
	if err != nil || h == nil {
		t.Fatalf("the real wiring must start: %v", err)
	}
	_ = fsClient.Close()
}
