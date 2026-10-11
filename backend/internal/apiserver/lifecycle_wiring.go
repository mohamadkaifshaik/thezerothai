// lifecycle_wiring.go adapts graph and posts to identity's consumer-side StepEraser / ExportSection interfaces
// (ADR-0011 D-C, the BlockChecker pattern): identity cannot import graph (import cycle) or posts, so the checkpoint
// encoding lives here. A step's checkpoint is the JSON of its module's own Checkpoint struct.
package apiserver

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// eraserStep adapts a module Eraser with a typed Checkpoint to identity.StepEraser.
type eraserStep[C any] struct {
	name  string
	purge func(ctx context.Context, uid string, cp C) (C, bool, error)
}

func (s eraserStep[C]) Name() string { return s.name }

func (s eraserStep[C]) Run(ctx context.Context, uid string, raw []byte) ([]byte, bool, error) {
	var cp C
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &cp); err != nil {
			return nil, false, fmt.Errorf("apiserver: decode %s checkpoint: %w", s.name, err)
		}
	}
	next, done, err := s.purge(ctx, uid, cp)
	if err != nil {
		return nil, false, err
	}
	out, err := json.Marshal(next)
	if err != nil {
		return nil, false, fmt.Errorf("apiserver: encode %s checkpoint: %w", s.name, err)
	}
	return out, done, nil
}

// postsEraserStep is the posts step (step "posts"): it runs first, before graph (ADR-0011 Q1, ADR-0010).
func postsEraserStep(e posts.Eraser) identity.StepEraser {
	return eraserStep[posts.Checkpoint]{name: "posts", purge: e.PurgeUser}
}

// graphEraserStep is the graph step (step "graph").
func graphEraserStep(e graph.Eraser) identity.StepEraser {
	return eraserStep[graph.Checkpoint]{name: "graph", purge: e.PurgeUser}
}

// mediaEraserStep is the media step (step "media", P4): it runs after posts and graph and before identity.
func mediaEraserStep(p *media.Purger) identity.StepEraser {
	return eraserStep[media.Checkpoint]{name: "media", purge: p.PurgeUser}
}

// graphExporter is the one method of graph's repo the export section needs.
type graphExporter interface {
	ExportUser(ctx context.Context, uid string) (graph.Export, error)
}

// graphSection is the export's `graph` section: graph.ExportUser's struct as JSON (never blockedBy, ADR-0008 D12).
type graphSection struct{ g graphExporter }

func (graphSection) Name() string { return "graph" }

func (s graphSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	data, err := s.g.ExportUser(ctx, uid)
	if err != nil {
		return err
	}
	if err := json.NewEncoder(w).Encode(data); err != nil {
		return fmt.Errorf("apiserver: write graph section: %w", err)
	}
	return nil
}

// postsSection is the export's `posts` section: posts.Exporter already streams one JSON value to w.
type postsSection struct{ x posts.Exporter }

func (postsSection) Name() string { return "posts" }

func (s postsSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.x.ExportUser(ctx, uid, w)
}

// registerLifecycleModules registers every module's Eraser and export section on l, in the ADR-0011 Q1 order.
// Later slices (engagement P5, notifications P6, reports P7) add their lines here, before the identity
// step, which Lifecycle always runs last.
func registerLifecycleModules(l *identity.Lifecycle, postsRepo *posts.FirestoreRepo, graphRepo *graph.FirestoreRepo, mediaPurger *media.Purger) error {
	for _, e := range []identity.StepEraser{postsEraserStep(postsRepo), graphEraserStep(graphRepo), mediaEraserStep(mediaPurger)} {
		if err := l.RegisterEraser(identity.BeforeIdentity, e); err != nil {
			return err
		}
	}
	for _, s := range []identity.ExportSection{graphSection{graphRepo}, postsSection{postsRepo}, mediaPurger} {
		if err := l.RegisterExportSection(s); err != nil {
			return err
		}
	}
	return nil
}
