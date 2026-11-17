package graph

import (
	"errors"
	"os"
	"regexp"
	"strings"
	"testing"
)

// A follows document id is "<follower>_<followee>": two uids. The decode error is returned to whoever lists edges (a
// profile's follower list, the suggester, an account export) and logged there, so it carries no document id.
func TestEdgeDecodeErr_CarriesNoDocumentID(t *testing.T) {
	t.Parallel()
	cause := errors.New("firestore: cannot set type time.Time to string")
	err := edgeDecodeErr(cause)
	if !errors.Is(err, cause) {
		t.Errorf("errors.Is no longer reaches the cause: %v", err)
	}
	if got, want := err.Error(), "graph: decode follow: "+cause.Error(); got != want {
		t.Errorf("err = %q, want %q", got, want)
	}
}

// The edge queries need a live Firestore to fail, so the error text is guarded at the source: nothing in repo_edges.go
// formats a document id or the queried uid into an error.
func TestRepoEdges_ErrorsNameNoUID(t *testing.T) {
	t.Parallel()
	src, err := os.ReadFile("repo_edges.go")
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		re   *regexp.Regexp
	}{
		{"a document id in an error", regexp.MustCompile(`Errorf\([^\n]*Ref\.ID`)},
		{"the queried uid in the query name", regexp.MustCompile(`runEdgeQuery\([^\n]*UID`)},
		{"a uid in an error", regexp.MustCompile(`Errorf\([^\n]*\b(uid|UID|followerUIDs\[|followeeUID)\b`)},
	}
	for _, tt := range tests {
		if loc := tt.re.FindIndex(src); loc != nil {
			line := 1 + strings.Count(string(src[:loc[0]]), "\n")
			t.Errorf("repo_edges.go:%d: %s: %s", line, tt.name, src[loc[0]:loc[1]])
		}
	}
}
