package media

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

const (
	postP = "0000000000000000501"
	idM1  = "0000000000000000601"
	idM2  = "0000000000000000602"
)

func seedPublished(r *fakeRepo, o *fakeObjects, id, owner, postID string) {
	r.docs[id] = &Doc{
		ID: id, OwnerID: owner, Purpose: string(PurposePost), Status: string(StatusReady), PostID: postID,
		PublicPath: "m/" + id + ".jpg", ThumbPath: "m/" + id + "_t.jpg",
	}
	o.public["m/"+id+".jpg"] = "image/jpeg"
	o.public["m/"+id+"_t.jpg"] = "image/jpeg"
}

func msg(t *testing.T, m PostDeleteMessage) []byte {
	t.Helper()
	m.Kind = JobKindPostDelete
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestJobsHandle(t *testing.T) {
	five := []string{"0000000000000000601", "0000000000000000602", "0000000000000000603", "0000000000000000604", "0000000000000000605"}
	tests := []struct {
		name        string
		data        func(t *testing.T) []byte
		live        bool // the post still exists
		setup       func(r *fakeRepo, o *fakeObjects)
		wantOutcome string
		wantDocs    int
		wantPublic  int
	}{
		{
			name: "deletes the objects and documents of a deleted post",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1, idM2}})
			},
			setup: func(r *fakeRepo, o *fakeObjects) {
				seedPublished(r, o, idM1, uidA, postP)
				seedPublished(r, o, idM2, uidA, postP)
			},
			wantOutcome: "done",
		},
		{
			name: "redelivery after completion is a duplicate",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1}})
			},
			setup:       func(r *fakeRepo, o *fakeObjects) {},
			wantOutcome: "duplicate",
		},
		{
			name: "a live post is never touched",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1}})
			},
			live:        true,
			setup:       func(r *fakeRepo, o *fakeObjects) { seedPublished(r, o, idM1, uidA, postP) },
			wantOutcome: "refused", wantDocs: 1, wantPublic: 2,
		},
		{
			name: "another owner's image is skipped even if named",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1}})
			},
			setup:       func(r *fakeRepo, o *fakeObjects) { seedPublished(r, o, idM1, uidB, postP) },
			wantOutcome: "duplicate", wantDocs: 1, wantPublic: 2,
		},
		{
			name: "an image attached to a different post is skipped",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1}})
			},
			setup:       func(r *fakeRepo, o *fakeObjects) { seedPublished(r, o, idM1, uidA, "0000000000000000999") },
			wantOutcome: "duplicate", wantDocs: 1, wantPublic: 2,
		},
		{
			name: "an unattached image is skipped",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1}})
			},
			setup:       func(r *fakeRepo, o *fakeObjects) { seedPublished(r, o, idM1, uidA, "") },
			wantOutcome: "duplicate", wantDocs: 1, wantPublic: 2,
		},
		{
			name:        "malformed JSON is dropped",
			data:        func(*testing.T) []byte { return []byte("{") },
			setup:       func(*fakeRepo, *fakeObjects) {},
			wantOutcome: "dropped:malformed_message",
		},
		{
			name: "bad uid is dropped",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: "a_b", PostID: postP, MediaIDs: []string{idM1}})
			},
			setup:       func(*fakeRepo, *fakeObjects) {},
			wantOutcome: "dropped:invalid_message",
		},
		{
			name: "bad post id is dropped",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: uidA, PostID: "x/y", MediaIDs: []string{idM1}})
			},
			setup:       func(*fakeRepo, *fakeObjects) {},
			wantOutcome: "dropped:invalid_message",
		},
		{
			name: "path-like media id is dropped",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{"../x"}})
			},
			setup:       func(*fakeRepo, *fakeObjects) {},
			wantOutcome: "dropped:invalid_message",
		},
		{
			name:        "empty media list is dropped",
			data:        func(t *testing.T) []byte { return msg(t, PostDeleteMessage{UID: uidA, PostID: postP}) },
			setup:       func(*fakeRepo, *fakeObjects) {},
			wantOutcome: "dropped:invalid_message",
		},
		{
			name:        "more than four ids is dropped",
			data:        func(t *testing.T) []byte { return msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: five}) },
			setup:       func(*fakeRepo, *fakeObjects) {},
			wantOutcome: "dropped:invalid_message",
		},
		{
			name: "duplicate ids are dropped",
			data: func(t *testing.T) []byte {
				return msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1, idM1}})
			},
			setup:       func(*fakeRepo, *fakeObjects) {},
			wantOutcome: "dropped:invalid_message",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r, o := newFakeRepo(), newFakeObjects()
			tt.setup(r, o)
			j := NewJobs(r, o, fakePosts{live: map[string]bool{postP: tt.live}}, nil)
			got, err := j.Handle(context.Background(), tt.data(t))
			if err != nil || got != tt.wantOutcome {
				t.Fatalf("outcome=%q err=%v, want %q", got, err, tt.wantOutcome)
			}
			if len(r.docs) != tt.wantDocs || len(o.public) != tt.wantPublic {
				t.Fatalf("docs=%d public=%d, want %d/%d", len(r.docs), len(o.public), tt.wantDocs, tt.wantPublic)
			}
		})
	}
}

func TestJobsHandle_InfrastructureErrorsNackWithoutLeakingIDs(t *testing.T) {
	r, o := newFakeRepo(), newFakeObjects()
	seedPublished(r, o, idM1, uidA, postP)
	o.deletePub = errors.New("storage 503 for object m/" + idM1 + ".jpg owner " + uidA)
	j := NewJobs(r, o, fakePosts{}, nil)
	_, err := j.Handle(context.Background(), msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1}}))
	if err == nil {
		t.Fatal("a storage failure must nack so Pub/Sub redelivers")
	}
	if strings.Contains(err.Error(), uidA) {
		t.Fatalf("error leaks the uid: %v", err)
	}
	if len(r.docs) != 1 {
		t.Fatal("the document must outlive a failed object delete so the redelivery can find the objects (objects first, document last)")
	}
	// The redelivery after recovery completes.
	o.deletePub = nil
	got, err := j.Handle(context.Background(), msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1}}))
	if err != nil || got != "done" || len(r.docs) != 0 || len(o.public) != 0 {
		t.Fatalf("redelivery: %q %v docs=%d public=%d", got, err, len(r.docs), len(o.public))
	}

	j2 := NewJobs(r, o, fakePosts{err: errors.New("firestore down")}, nil)
	if _, err := j2.Handle(context.Background(), msg(t, PostDeleteMessage{UID: uidA, PostID: postP, MediaIDs: []string{idM1}})); err == nil {
		t.Fatal("a failed post check must nack, not ack")
	}
}

func TestJobsPostDeleted_PublishesTheContract(t *testing.T) {
	pub := &fakePublisher{}
	j := NewJobs(newFakeRepo(), newFakeObjects(), fakePosts{}, pub)
	if err := j.PostDeleted(context.Background(), uidA, postP, []string{idM1, idM2}); err != nil {
		t.Fatal(err)
	}
	if len(pub.msgs) != 1 {
		t.Fatalf("published %d", len(pub.msgs))
	}
	var m PostDeleteMessage
	if err := json.Unmarshal(pub.msgs[0], &m); err != nil {
		t.Fatal(err)
	}
	if m.Kind != "post_delete" || m.UID != uidA || m.PostID != postP || len(m.MediaIDs) != 2 {
		t.Fatalf("message = %+v", m)
	}
	// The wire keys are the P5 contract: pin them.
	for _, k := range []string{`"kind":"post_delete"`, `"uid":`, `"postId":`, `"mediaIds":`} {
		if !bytes.Contains(pub.msgs[0], []byte(k)) {
			t.Fatalf("wire message %s lacks %s", pub.msgs[0], k)
		}
	}
	if err := NewJobs(newFakeRepo(), newFakeObjects(), fakePosts{}, nil).PostDeleted(context.Background(), uidA, postP, []string{idM1}); err == nil {
		t.Fatal("no publisher must be an error the caller can log")
	}
}
