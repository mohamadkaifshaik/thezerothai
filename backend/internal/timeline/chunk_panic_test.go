package timeline

import (
	"strings"
	"testing"
)

// The per-chunk author queries run on errgroup goroutines, which the request's recover interceptor does not cover.
func TestListTimeline_PanicInChunkQueryFailsTheCallOnly(t *testing.T) {
	r, _ := listRig(t, names("m", 3)...)
	r.posts.hook = func() { panic("boom") }
	_, err := r.list("me", testListID, "", "", 20)
	if err == nil || !strings.Contains(err.Error(), "panic of type string") {
		t.Fatalf("err = %v, want the panic as this call's error", err)
	}
}
