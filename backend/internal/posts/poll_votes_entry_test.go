package posts

import "testing"

// WithPollVotes reads the choice from "<postId>:<index>" (before W6-29) and "<postId>:<index>:<closesAtUnix>" entries alike, and
// skips what it cannot read (security L-2: the third part is the retention clock, owned by the engagement module).
func TestWithPollVotes_EntryForms(t *testing.T) {
	t.Parallel()
	vs := NewViewerSet(nil, nil).WithPollVotes([]string{
		"100:2", "200:1:1793534400", "300:9:1793534400", "400:x:1", ":1:1", "500", "600:3:",
	})
	tests := []struct {
		id     string
		want   int
		wantOK bool
	}{
		{"100", 2, true}, {"200", 1, true}, {"300", 0, false}, {"400", 0, false}, {"500", 0, false}, {"600", 3, true},
	}
	for _, tt := range tests {
		got, ok := vs.PollChoice(&Post{ID: tt.id})
		if ok != tt.wantOK || (ok && got != tt.want) {
			t.Errorf("post %s = %d,%v want %d,%v", tt.id, got, ok, tt.want, tt.wantOK)
		}
	}
}
