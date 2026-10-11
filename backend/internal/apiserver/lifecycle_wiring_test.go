package apiserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"slices"
	"strings"
	"testing"
	"time"

	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// TestRestrictedAllowedProcedures_IsExactlyDeleteAccount is the guard of ADR-0011 Q2/Q3: the interceptor exemption
// for SUSPENDED and DELETING callers is one procedure, DeleteAccount. Adding a second needs an ADR (security-auditor T20).
func TestRestrictedAllowedProcedures_IsExactlyDeleteAccount(t *testing.T) {
	got := RestrictedAllowedProcedures()
	if want := []string{identityv1connect.IdentityServiceDeleteAccountProcedure}; !slices.Equal(got, want) {
		t.Fatalf("RestrictedAllowedProcedures() = %v, want exactly %v", got, want)
	}
}

type fakePostsEraser struct {
	seen  []posts.Checkpoint
	steps int
	err   error
}

func (f *fakePostsEraser) PurgeUser(_ context.Context, _ string, cp posts.Checkpoint) (posts.Checkpoint, bool, error) {
	f.seen = append(f.seen, cp)
	if f.err != nil {
		return cp, false, f.err
	}
	next := posts.Checkpoint{Deleted: cp.Deleted + 500}
	return next, len(f.seen) >= f.steps, nil
}

type fakeGraphEraser struct{ seen []graph.Checkpoint }

func (f *fakeGraphEraser) PurgeUser(_ context.Context, _ string, cp graph.Checkpoint) (graph.Checkpoint, bool, error) {
	f.seen = append(f.seen, cp)
	return graph.Checkpoint{Step: cp.Step + 1, Offset: cp.Offset + 7}, cp.Step >= 2, nil
}

// TestEraserStep: the adapters carry the module Checkpoint as JSON between calls, start from the zero value, and
// pass errors up without a checkpoint.
func TestEraserStep(t *testing.T) {
	ctx := context.Background()
	t.Run("posts: zero start, JSON round trip, done flag", func(t *testing.T) {
		e := &fakePostsEraser{steps: 2}
		step := postsEraserStep(e)
		if step.Name() != "posts" {
			t.Errorf("name = %q", step.Name())
		}
		cp1, done, err := step.Run(ctx, "u1", nil)
		if err != nil || done || string(cp1) != `{"Deleted":500}` {
			t.Fatalf("first call = %s, %v, %v", cp1, done, err)
		}
		cp2, done, err := step.Run(ctx, "u1", cp1)
		if err != nil || !done || string(cp2) != `{"Deleted":1000}` {
			t.Fatalf("second call = %s, %v, %v", cp2, done, err)
		}
		if e.seen[0] != (posts.Checkpoint{}) || e.seen[1].Deleted != 500 {
			t.Errorf("the eraser saw checkpoints %+v", e.seen)
		}
	})
	t.Run("graph: carries Step and Offset", func(t *testing.T) {
		e := &fakeGraphEraser{}
		step := graphEraserStep(e)
		if step.Name() != "graph" {
			t.Errorf("name = %q", step.Name())
		}
		var cp []byte
		var done bool
		var err error
		for i := 0; i < 3 && !done; i++ {
			cp, done, err = step.Run(ctx, "u1", cp)
			if err != nil {
				t.Fatal(err)
			}
		}
		if !done || e.seen[2] != (graph.Checkpoint{Step: 2, Offset: 14}) {
			t.Errorf("done=%v seen=%+v", done, e.seen)
		}
	})
	t.Run("errors and bad checkpoints", func(t *testing.T) {
		boom := errors.New("boom")
		cp, done, err := postsEraserStep(&fakePostsEraser{err: boom}).Run(ctx, "u1", nil)
		if !errors.Is(err, boom) || done || cp != nil {
			t.Errorf("eraser error: %s, %v, %v", cp, done, err)
		}
		_, _, err = postsEraserStep(&fakePostsEraser{}).Run(ctx, "u1", []byte("{not json"))
		if err == nil || !strings.Contains(err.Error(), "decode posts checkpoint") {
			t.Errorf("bad checkpoint err = %v", err)
		}
	})
}

type fakeGraphExporter struct {
	out graph.Export
	err error
}

func (f fakeGraphExporter) ExportUser(context.Context, string) (graph.Export, error) {
	return f.out, f.err
}

type fakePostsExporter struct{}

func (fakePostsExporter) ExportUser(_ context.Context, uid string, w io.Writer) error {
	_, err := w.Write([]byte(`{"userId":"` + uid + `","posts":[]}`))
	return err
}

func TestExportSections(t *testing.T) {
	ctx := context.Background()
	t.Run("graph is one JSON value and never carries blockedBy", func(t *testing.T) {
		s := graphSection{fakeGraphExporter{out: graph.Export{UserID: "u1", Following: []graph.ExportUser{{UserID: "u2", Handle: "bob"}}}}}
		if s.Name() != "graph" {
			t.Errorf("name = %q", s.Name())
		}
		var buf bytes.Buffer
		if err := s.WriteSection(ctx, "u1", &buf); err != nil {
			t.Fatal(err)
		}
		var v map[string]any
		if err := json.Unmarshal(buf.Bytes(), &v); err != nil {
			t.Fatalf("not JSON: %v", err)
		}
		if _, has := v["blockedBy"]; has || v["userId"] != "u1" {
			t.Errorf("graph section = %s", buf.Bytes())
		}
	})
	t.Run("graph error", func(t *testing.T) {
		boom := errors.New("boom")
		if err := (graphSection{fakeGraphExporter{err: boom}}).WriteSection(ctx, "u1", &bytes.Buffer{}); !errors.Is(err, boom) {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("posts delegates to posts.Exporter", func(t *testing.T) {
		s := postsSection{x: fakePostsExporter{}}
		if s.Name() != "posts" {
			t.Errorf("name = %q", s.Name())
		}
		var buf bytes.Buffer
		if err := s.WriteSection(ctx, "u9", &buf); err != nil || buf.String() != `{"userId":"u9","posts":[]}` {
			t.Errorf("posts section = %q, %v", buf.String(), err)
		}
	})
}

type stubRepo struct{ identity.LifecycleRepo }
type stubPub struct{ identity.JobPublisher }
type stubAuth struct{ identity.AuthClient }

// TestRegisterLifecycleModules: posts, graph, media and their export sections register once, before the identity step.
func TestRegisterLifecycleModules(t *testing.T) {
	l, err := identity.NewLifecycle(identity.LifecycleDeps{
		Repo: stubRepo{}, Cache: identity.NewCache(time.Minute), Publisher: stubPub{}, Auth: stubAuth{},
		ExportsPerDay: 1, ExportRetention: time.Hour, ExportURLTTL: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := registerLifecycleModules(l, posts.NewFirestoreRepo(nil), graph.NewFirestoreRepo(nil), media.NewPurger(nil, nil, "")); err != nil {
		t.Fatalf("registerLifecycleModules: %v", err)
	}
	// The step names are persisted in users/{uid}.deletionJob.step and the section names are keys of the export file:
	// changing either strands in-flight deletions or breaks exports already handed out, so they are pinned here.
	if got, want := l.StepNames(), []string{"auth_disable", "posts", "graph", "media", "identity", "auth_delete", "users_doc"}; !slices.Equal(got, want) {
		t.Errorf("deletion steps = %v, want %v", got, want)
	}
	if got, want := l.ExportSectionNames(), []string{"graph", "posts", "media"}; !slices.Equal(got, want) {
		t.Errorf("export sections = %v, want %v", got, want)
	}
	if err := registerLifecycleModules(l, posts.NewFirestoreRepo(nil), graph.NewFirestoreRepo(nil), media.NewPurger(nil, nil, "")); err == nil {
		t.Error("registering the same modules twice was accepted")
	}
}
