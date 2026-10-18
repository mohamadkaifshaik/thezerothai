package posts

import "testing"

func TestPost_EmbeddedAuthor(t *testing.T) {
	t.Parallel()
	snap := func(uid string, unavailable bool) *Embedded {
		e := &Embedded{Unavailable: unavailable}
		e.Author.UserID = uid
		return e
	}
	tests := []struct {
		name string
		p    Post
		want string
	}{
		{"plain post", Post{}, ""},
		{"snapshot author", Post{Embedded: snap("snap", false), EmbeddedAuthorID: "top"}, "snap"},
		{"top-level id only", Post{EmbeddedAuthorID: "top"}, "top"},
		{"snapshot without author falls back", Post{Embedded: snap("", false), EmbeddedAuthorID: "top"}, "top"},
		{"tombstone", Post{Embedded: snap("snap", true), EmbeddedAuthorID: "top"}, ""},
		{"nil embedded and no id", Post{Embedded: nil}, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := tt.p.EmbeddedAuthor(); got != tt.want {
				t.Errorf("EmbeddedAuthor() = %q, want %q", got, tt.want)
			}
		})
	}
}
