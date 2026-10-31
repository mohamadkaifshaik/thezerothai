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
	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
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

// TestRegisterLifecycleModules: posts, graph, media, notifications and their export sections register once, before the identity step.
func TestRegisterLifecycleModules(t *testing.T) {
	l, err := identity.NewLifecycle(identity.LifecycleDeps{
		Repo: stubRepo{}, Cache: identity.NewCache(time.Minute), Publisher: stubPub{}, Auth: stubAuth{},
		ExportsPerDay: 1, ExportRetention: time.Hour, ExportURLTTL: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := registerLifecycleModules(l, posts.NewFirestoreRepo(nil), graph.NewFirestoreRepo(nil), media.NewPurger(nil, nil, ""), notifications.NewFirestoreRepo(nil)); err != nil {
		t.Fatalf("registerLifecycleModules: %v", err)
	}
	// The step names are persisted in users/{uid}.deletionJob.step and the section names are keys of the export file:
	// changing either strands in-flight deletions or breaks exports already handed out, so they are pinned here.
	if got, want := l.StepNames(), []string{"auth_disable", "posts", "graph", "media", "notifications", "identity", "auth_delete", "users_doc"}; !slices.Equal(got, want) {
		t.Errorf("deletion steps = %v, want %v", got, want)
	}
	if got, want := l.ExportSectionNames(), []string{"graph", "posts", "media", "notifications"}; !slices.Equal(got, want) {
		t.Errorf("export sections = %v, want %v", got, want)
	}
	if err := registerLifecycleModules(l, posts.NewFirestoreRepo(nil), graph.NewFirestoreRepo(nil), media.NewPurger(nil, nil, ""), notifications.NewFirestoreRepo(nil)); err == nil {
		t.Error("registering the same modules twice was accepted")
	}
}

// TestRegisterLifecycle_FullOrder pins the deletion order and the export sections exactly as Build registers them
// (registerLifecycleModules, then engagement, reports, scheduled, bookmarks, follow_requests, messaging and poll_votes). The step names are persisted in
// users/{uid}.deletionJob.step and the section names are keys of the export file, so a reorder or rename strands
// in-flight deletions or breaks exports already handed out (ADR-0011 Q1, ADR-0021: `scheduled` runs after the
// existing steps and before identity).
func TestRegisterLifecycle_FullOrder(t *testing.T) {
	l, err := identity.NewLifecycle(identity.LifecycleDeps{
		Repo: stubRepo{}, Cache: identity.NewCache(time.Minute), Publisher: stubPub{}, Auth: stubAuth{},
		ExportsPerDay: 1, ExportRetention: time.Hour, ExportURLTTL: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	postsRepo := posts.NewFirestoreRepo(nil)
	if err := registerLifecycleModules(l, postsRepo, graph.NewFirestoreRepo(nil), media.NewPurger(nil, nil, ""), notifications.NewFirestoreRepo(nil)); err != nil {
		t.Fatal(err)
	}
	if err := registerEngagementLifecycle(l, engagement.NewFirestoreRepo(nil, engagement.WriteDeps{})); err != nil {
		t.Fatal(err)
	}
	if err := registerModerationLifecycle(l, moderation.NewFirestoreRepo(nil, nil)); err != nil {
		t.Fatal(err)
	}
	if err := registerScheduledLifecycle(l, postsRepo); err != nil {
		t.Fatal(err)
	}
	if err := registerBookmarkLifecycle(l, engagement.NewFirestoreRepo(nil, engagement.WriteDeps{})); err != nil {
		t.Fatal(err)
	}
	graphRepo := graph.NewFirestoreRepo(nil)
	if err := registerFollowRequestsLifecycle(l, graphRepo); err != nil {
		t.Fatal(err)
	}
	if err := registerMessagingLifecycle(l, messaging.NewFirestoreRepo(nil, nil), nopHandles{}, nopSocial{}, nil); err != nil {
		t.Fatal(err)
	}
	listsRepo := lists.NewFirestoreRepo(nil, nil, nil)
	if err := registerListsLifecycle(l, listsRepo); err != nil {
		t.Fatal(err)
	}
	if err := registerPollVoteLifecycle(l, engagement.NewFirestoreRepo(nil, engagement.WriteDeps{}), 720*time.Hour); err != nil {
		t.Fatal(err)
	}
	wantSteps := []string{"auth_disable", "posts", "graph", "media", "notifications", "engagement", "reports", "scheduled", "bookmarks", "follow_requests", "messaging", "lists", "poll_votes", "identity", "auth_delete", "users_doc"}
	if got := l.StepNames(); !slices.Equal(got, wantSteps) {
		t.Errorf("deletion steps = %v, want %v", got, wantSteps)
	}
	wantSections := []string{"graph", "posts", "media", "notifications", "engagement", "reports", "scheduled", "bookmarks", "follow_requests", "messages", "lists", "poll_votes"}
	if got := l.ExportSectionNames(); !slices.Equal(got, wantSections) {
		t.Errorf("export sections = %v, want %v", got, wantSections)
	}
	if err := registerScheduledLifecycle(l, postsRepo); err == nil {
		t.Error("registering the scheduled step twice was accepted")
	}
	if err := registerBookmarkLifecycle(l, engagement.NewFirestoreRepo(nil, engagement.WriteDeps{})); err == nil {
		t.Error("registering the bookmarks step twice was accepted")
	}
	if err := registerFollowRequestsLifecycle(l, graphRepo); err == nil {
		t.Error("registering the follow_requests step twice was accepted")
	}
	if err := registerMessagingLifecycle(l, messaging.NewFirestoreRepo(nil, nil), nopHandles{}, nopSocial{}, nil); err == nil {
		t.Error("registering the messaging step twice was accepted")
	}
	if err := registerListsLifecycle(l, listsRepo); err == nil {
		t.Error("registering the lists step twice was accepted")
	}
	if err := registerPollVoteLifecycle(l, engagement.NewFirestoreRepo(nil, engagement.WriteDeps{}), 720*time.Hour); err == nil {
		t.Error("registering the poll_votes step twice was accepted")
	}
}

// nopHandles is a messaging.HandleSource that knows nobody.
type nopHandles struct{}

func (nopHandles) GetProfiles(context.Context, []string) (map[string]identity.Profile, error) {
	return nil, nil
}

// fakeMessagingEraser records the checkpoint it was handed and returns a fixed answer.
type fakeMessagingEraser struct {
	gotUID string
	gotCP  []byte
}

func (f *fakeMessagingEraser) PurgeUser(_ context.Context, uid string, cp []byte) ([]byte, bool, error) {
	f.gotUID, f.gotCP = uid, cp
	return []byte(`{"after":"x"}`), false, nil
}

type fakeMessagingExporter struct{}

func (fakeMessagingExporter) ExportUser(_ context.Context, _ string, w io.Writer) error {
	_, err := io.WriteString(w, `{"conversations":[]}`)
	return err
}

// TestMessagingAdapters: the step is named `messaging` and hands the opaque checkpoint through unchanged; the section is
// named `messages` and streams what messaging.Exporter writes.
func TestMessagingAdapters(t *testing.T) {
	e := &fakeMessagingEraser{}
	step := messagingStep{e}
	next, done, err := step.Run(context.Background(), "u1", []byte(`{"after":"a"}`))
	if step.Name() != "messaging" || err != nil || done || string(next) != `{"after":"x"}` || e.gotUID != "u1" || string(e.gotCP) != `{"after":"a"}` {
		t.Errorf("step %q: next %s done %v err %v; eraser saw %q %q", step.Name(), next, done, err, e.gotUID, e.gotCP)
	}
	var buf bytes.Buffer
	sec := messagesSection{fakeMessagingExporter{}}
	if sec.Name() != "messages" || sec.WriteSection(context.Background(), "u1", &buf) != nil || buf.String() != `{"conversations":[]}` {
		t.Errorf("section %q = %q", sec.Name(), buf.String())
	}
}

type fakeScheduledSource struct{}

func (fakeScheduledSource) ExportUser(_ context.Context, uid string, w io.Writer) error {
	_, err := io.WriteString(w, `{"userId":"`+uid+`","scheduled":[]}`)
	return err
}

// TestScheduledSection: the section is named `scheduled` and streams what posts.ScheduledExporter writes; the step is
// named `scheduled` and decodes its checkpoint from JSON like the others.
func TestScheduledSection(t *testing.T) {
	s := scheduledSection{x: fakeScheduledSource{}}
	var buf bytes.Buffer
	if s.Name() != "scheduled" || s.WriteSection(context.Background(), "u1", &buf) != nil || buf.String() != `{"userId":"u1","scheduled":[]}` {
		t.Errorf("section %q = %q", s.Name(), buf.String())
	}
	if got := scheduledEraserStep(posts.NewScheduledEraser(nil)).Name(); got != "scheduled" {
		t.Errorf("step name = %q", got)
	}
}

type fakeBookmarkSource struct{}

func (fakeBookmarkSource) ExportBookmarksPage(context.Context, string, *posts.Position, int) ([]engagement.ExportedBookmark, error) {
	return nil, nil
}

// TestBookmarkSection: the section is named `bookmarks` and streams what engagement.BookmarkExporter writes; the step
// is named `bookmarks` (its name is persisted in deletionJob.step) and has its own checkpoint type.
func TestBookmarkSection(t *testing.T) {
	s := bookmarkSection{engagement.NewBookmarkExporter(fakeBookmarkSource{})}
	var buf bytes.Buffer
	if s.Name() != "bookmarks" || s.WriteSection(context.Background(), "u1", &buf) != nil || buf.String() != "{\"bookmarks\":[]}\n" {
		t.Errorf("section %q = %q", s.Name(), buf.String())
	}
	if got := bookmarkEraserStep(engagement.NewBookmarkEraser(nil)).Name(); got != "bookmarks" {
		t.Errorf("step name = %q", got)
	}
}

type fakeRequestsExporter struct {
	out graph.RequestsExport
	err error
}

func (f fakeRequestsExporter) ExportRequests(context.Context, string) (graph.RequestsExport, error) {
	return f.out, f.err
}

// TestFollowRequestsSection: the section is named `follow_requests` (a key of the export file), streams
// {sent, received} newest first, never null, and passes an error through; the step name is persisted in
// deletionJob.step and has its own checkpoint type.
func TestFollowRequestsSection(t *testing.T) {
	at := time.Date(2026, 10, 28, 9, 0, 0, 0, time.UTC)
	tests := []struct {
		name    string
		out     graph.RequestsExport
		want    string
		wantErr bool
	}{
		{"empty is arrays, not null", graph.RequestsExport{Sent: []graph.RequestExportRow{}, Received: []graph.RequestExportRow{}}, "{\"sent\":[],\"received\":[]}\n", false},
		{"rows keep their order", graph.RequestsExport{
			Sent:     []graph.RequestExportRow{{UserID: "u2", Handle: "bob", RequestedAt: at}},
			Received: []graph.RequestExportRow{{UserID: "u3", RequestedAt: at}},
		}, "{\"sent\":[{\"userId\":\"u2\",\"handle\":\"bob\",\"requestedAt\":\"2026-10-28T09:00:00Z\"}],\"received\":[{\"userId\":\"u3\",\"requestedAt\":\"2026-10-28T09:00:00Z\"}]}\n", false},
		{"source error", graph.RequestsExport{}, "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var err error
			if tt.wantErr {
				err = errors.New("boom")
			}
			s := followRequestsSection{fakeRequestsExporter{out: tt.out, err: err}}
			if s.Name() != "follow_requests" {
				t.Fatalf("Name = %q", s.Name())
			}
			var buf bytes.Buffer
			gotErr := s.WriteSection(context.Background(), "u1", &buf)
			if (gotErr != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", gotErr, tt.wantErr)
			}
			if buf.String() != tt.want {
				t.Errorf("section = %q, want %q", buf.String(), tt.want)
			}
		})
	}
	if got := followRequestsEraserStep(graph.NewRequestEraser(nil)).Name(); got != "follow_requests" {
		t.Errorf("step name = %q", got)
	}
}

// TestFollowRequestsEraserStep_Checkpoint: the adapter decodes an empty checkpoint as the start and refuses garbage.
func TestFollowRequestsEraserStep_Checkpoint(t *testing.T) {
	s := followRequestsEraserStep(graph.NewRequestEraser(nil))
	if _, _, err := s.Run(context.Background(), "u1", []byte("{not json")); err == nil {
		t.Error("a corrupt checkpoint was accepted")
	}
	if _, _, err := s.Run(context.Background(), "u1", []byte(`{"Phase":9}`)); err == nil {
		t.Error("an unknown phase was accepted")
	}
}

// nopSocial is a messaging.Social with an empty social context.
type nopSocial struct{}

func (nopSocial) Snapshot(context.Context, string) (graph.Snapshot, error) {
	return graph.Snapshot{}, nil
}

type fakeListsPurger struct{ gotUID string }

func (f *fakeListsPurger) PurgeOwnedPage(_ context.Context, uid string) (int, error) {
	f.gotUID = uid
	return 3, nil
}

func (f *fakeListsPurger) RemoveMemberPage(context.Context, string) (lists.MemberPage, error) {
	return lists.MemberPage{}, nil
}

type fakeListsSource struct{}

func (fakeListsSource) ExportPage(context.Context, string, string, int) ([]lists.ExportedList, error) {
	return nil, nil
}

// TestListsAdapters: the step is named `lists` (the name is persisted in deletionJob.step), decodes and re-encodes its own
// checkpoint type, and the section is named `lists` and streams what lists.Exporter writes.
func TestListsAdapters(t *testing.T) {
	p := &fakeListsPurger{}
	step := listsEraserStep(lists.NewEraser(p))
	next, done, err := step.Run(context.Background(), "u1", nil)
	if step.Name() != "lists" || err != nil || done || string(next) != `{"phase":"member","deleted":3}` || p.gotUID != "u1" {
		t.Errorf("step %q: next %s done %v err %v; purger saw %q", step.Name(), next, done, err, p.gotUID)
	}
	next, done, err = step.Run(context.Background(), "u1", []byte(`{"phase":"member","deleted":3}`))
	if err != nil || !done || string(next) != `{"phase":"member","deleted":3}` {
		t.Errorf("member phase: next %s done %v err %v", next, done, err)
	}
	if _, _, err := step.Run(context.Background(), "u1", []byte(`{not json`)); err == nil {
		t.Error("a corrupt checkpoint was accepted")
	}
	var buf bytes.Buffer
	sec := listsSection{lists.NewExporter(fakeListsSource{})}
	if sec.Name() != "lists" || sec.WriteSection(context.Background(), "u1", &buf) != nil || buf.String() != "{\"lists\":[]}\n" {
		t.Errorf("section %q = %q", sec.Name(), buf.String())
	}
}
