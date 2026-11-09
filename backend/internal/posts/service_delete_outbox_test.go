package posts

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// fakeOutbox records what DeletePost stages (inside the delete batch) and what it marks done.
type fakeOutbox struct {
	staged  []outbox.Entry
	done    []outbox.Entry
	doneErr error
}

func (f *fakeOutbox) Stage(_ store.Batch, e outbox.Entry) error {
	if err := e.Validate(); err != nil {
		return err
	}
	f.staged = append(f.staged, e)
	return nil
}

func (f *fakeOutbox) Done(_ context.Context, e outbox.Entry) error {
	f.done = append(f.done, e)
	return f.doneErr
}

// pending is what is still in the outbox: staged and not done.
func (f *fakeOutbox) pending() []string {
	done := map[string]bool{}
	for _, e := range f.done {
		done[e.ID()] = true
	}
	var out []string
	for _, e := range f.staged {
		if !done[e.ID()] {
			out = append(out, e.ID())
		}
	}
	return out
}

func TestDelete_Outbox(t *testing.T) {
	tests := []struct {
		name        string
		media       []MediaRef
		jobsErr     error
		doneErr     error
		wantPending []string
		wantField   string
	}{
		{"publish succeeds: item staged then done", []MediaRef{{ID: mid1}}, nil, nil, nil, "published"},
		{"publish fails after the delete: the item remains for the sweeper", []MediaRef{{ID: mid1}, {ID: mid2}}, errors.New("pubsub down"), nil, []string{"post_delete:" + pidMine}, "publish_failed"},
		{"done fails: the delete still succeeds (a sweep republishes, idempotent)", nil, nil, errors.New("unavailable"), nil, "published"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ob := &fakeOutbox{doneErr: tt.doneErr}
			jobs := &fakeJobs{err: tt.jobsErr}
			e := newDeleteEnv()
			e.svc.jobs, e.svc.outbox = jobs, ob
			e.repo.docs[pidMine].Media = tt.media

			ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), testUID))
			if err := e.svc.Delete(ctx, testUID, key1, pidMine); err != nil {
				t.Fatal(err)
			}
			if f, _ := info.Get(fieldMediaJob); f != tt.wantField {
				t.Fatalf("%s = %v, want %s", fieldMediaJob, f, tt.wantField)
			}
			if len(ob.staged) != 1 || e.repo.stagedInDelete != 1 {
				t.Fatalf("staged %v (in the delete batch: %d), want exactly one in the batch", ob.staged, e.repo.stagedInDelete)
			}
			got := ob.staged[0]
			if got.Kind != PostDeleteOutboxKind || got.Key != pidMine || got.UID != testUID {
				t.Fatalf("entry = %+v", got)
			}
			w, err := DecodePostDeleteWork(got.Payload)
			if err != nil {
				t.Fatal(err)
			}
			wantIDs := make([]string, len(tt.media))
			for i, m := range tt.media {
				wantIDs[i] = m.ID
			}
			if w.UID != testUID || w.PostID != pidMine || !reflect.DeepEqual(w.MediaIDs, wantIDs) {
				t.Fatalf("payload = %+v, want the PostDeleted arguments", w)
			}
			if !reflect.DeepEqual(ob.pending(), tt.wantPending) {
				t.Fatalf("pending = %v, want %v", ob.pending(), tt.wantPending)
			}
		})
	}
}

func TestDelete_OutboxNothingForNoopsAndFailures(t *testing.T) {
	t.Run("not the owner, unknown post, lost race", func(t *testing.T) {
		ob := &fakeOutbox{}
		e := newDeleteEnv()
		e.svc.jobs, e.svc.outbox = &fakeJobs{}, ob
		if _, err := e.del(pidOther); err != nil {
			t.Fatal(err)
		}
		if _, err := e.del("0000000000000000999"); err != nil {
			t.Fatal(err)
		}
		e.repo.deleteRace = true
		if _, err := e.del(pidMine); err != nil {
			t.Fatal(err)
		}
		if len(ob.staged) != 0 || len(ob.done) != 0 {
			t.Fatalf("staged %v done %v, want nothing", ob.staged, ob.done)
		}
	})
	t.Run("the delete batch fails: nothing staged, nothing published", func(t *testing.T) {
		ob := &fakeOutbox{}
		jobs := &fakeJobs{}
		e := newDeleteEnv()
		e.svc.jobs, e.svc.outbox = jobs, ob
		e.repo.deleteErr = errors.New("unavailable")
		if _, err := e.del(pidMine); err == nil {
			t.Fatal("want the delete error")
		}
		if len(ob.staged) != 0 || len(jobs.calls) != 0 {
			t.Fatalf("staged %v jobs %v", ob.staged, jobs.calls)
		}
	})
	t.Run("no jobs publisher: no outbox item (it would never be delivered)", func(t *testing.T) {
		ob := &fakeOutbox{}
		e := newDeleteEnv()
		e.svc.outbox = ob
		if _, err := e.del(pidMine); err != nil {
			t.Fatal(err)
		}
		if len(ob.staged) != 0 {
			t.Fatalf("staged %v", ob.staged)
		}
	})
	t.Run("no outbox wired: today's best-effort publish", func(t *testing.T) {
		jobs := &fakeJobs{err: errors.New("down")}
		e := newDeleteEnv()
		e.svc.jobs = jobs
		if out, err := e.del(pidMine); err != nil || out != outcomeDeleted || len(jobs.calls) != 1 {
			t.Fatalf("out %s err %v jobs %v", out, err, jobs.calls)
		}
	})
}

func TestPostDeleteWork_RoundTripAndRejects(t *testing.T) {
	e, err := PostDeleteEntry(testUID, pidMine, []string{mid1})
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(e.Payload, &raw); err != nil || raw["uid"] != testUID || raw["postId"] != pidMine {
		t.Fatalf("payload %s: %v", e.Payload, err)
	}
	w, err := DecodePostDeleteWork(e.Payload)
	if err != nil || !reflect.DeepEqual(w, PostDeleteWork{UID: testUID, PostID: pidMine, MediaIDs: []string{mid1}}) {
		t.Fatalf("decode = %+v, %v", w, err)
	}
	if _, err := PostDeleteEntry(testUID, "not-a-post-id", nil); err == nil {
		t.Fatal("an invalid post id was accepted")
	}
	for _, bad := range []string{`{`, `{"uid":"","postId":"0000000000000000101"}`, `{"uid":"u","postId":"x"}`} {
		if _, err := DecodePostDeleteWork([]byte(bad)); err == nil {
			t.Errorf("DecodePostDeleteWork(%s) accepted", bad)
		}
	}
}

// A uid the outbox payload rejects (Firebase allows characters ids.ValidUID does not) never fails the delete: it falls
// back to the best-effort publish.
func TestDelete_OutboxEntryInvalidFallsBack(t *testing.T) {
	const oddUID = "uid_with.dots"
	ob := &fakeOutbox{}
	jobs := &fakeJobs{}
	e := newDeleteEnv()
	e.svc.jobs, e.svc.outbox = jobs, ob
	e.repo.docs[pidMine].AuthorID = oddUID
	ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), oddUID))
	if err := e.svc.Delete(ctx, oddUID, key1, pidMine); err != nil {
		t.Fatal(err)
	}
	if out, _ := info.Get(fieldOutcome); out != outcomeDeleted || len(jobs.calls) != 1 || len(ob.staged) != 0 {
		t.Fatalf("outcome %v jobs %v staged %v", out, jobs.calls, ob.staged)
	}
}
