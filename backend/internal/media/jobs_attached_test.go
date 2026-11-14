package media

import (
	"context"
	"testing"
)

// TestJobsHandle_DeletesImagesAttachedToThePost: an article's inline images are attached to its root post but are not in
// the post's media list, so the message names none of them. The job still deletes every image attached to the gone post
// that the author owns, and keeps an attached image owned by someone else.
func TestJobsHandle_DeletesImagesAttachedToThePost(t *testing.T) {
	const inline, foreign = "7000000000000000001", "7000000000000000002"
	tests := []struct {
		name       string
		live       bool
		wantOutput string
		wantDocs   int
	}{
		{name: "gone post: owned attached images deleted, foreign kept", live: false, wantOutput: "done", wantDocs: 1},
		{name: "live post: refused, nothing deleted", live: true, wantOutput: "refused", wantDocs: 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r, o := newFakeRepo(), newFakeObjects()
			seedPublished(r, o, inline, uidA, postP)
			seedPublished(r, o, foreign, "someone-else", postP)
			j := NewJobs(r, o, fakePosts{live: map[string]bool{postP: tt.live}}, nil)
			got, err := j.Handle(context.Background(), msg(t, PostDeleteMessage{UID: uidA, PostID: postP}))
			if err != nil || got != tt.wantOutput {
				t.Fatalf("outcome=%q err=%v, want %q", got, err, tt.wantOutput)
			}
			if len(r.docs) != tt.wantDocs {
				t.Fatalf("docs=%d, want %d", len(r.docs), tt.wantDocs)
			}
			if _, ok := r.docs[inline]; ok == (tt.wantOutput == "done") {
				t.Fatalf("owned inline image present=%v after %q", ok, tt.wantOutput)
			}
		})
	}
}
