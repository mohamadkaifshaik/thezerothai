package engagement

import (
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

func TestUserCache(t *testing.T) {
	c := newUserCache(time.Minute, 0)
	if _, ok := c.get("u"); ok {
		t.Fatal("empty cache hit")
	}
	// An update of an absent entry never creates one (it would hide the user's other likes).
	if st := c.update("u", func(r, p []string) ([]string, []string) { return withID(r, "a"), p }); st != nil {
		t.Fatal("update created an entry")
	}
	c.set("u", UserLikes{Recent: []string{"a"}, RecentReposts: []string{"r"}})
	st := c.update("u", func(r, p []string) ([]string, []string) { return withID(r, "b"), withoutID(p, "r") })
	if st == nil || !reflect.DeepEqual(st.recent, []string{"a", "b"}) || len(st.reposts) != 0 {
		t.Fatalf("state = %+v", st)
	}
	if liked, reposted := st.set.Flags(&posts.Post{ID: "b"}); !liked || reposted {
		t.Fatalf("flags(b) = %v %v", liked, reposted)
	}
	c.delete("u")
	if _, ok := c.get("u"); ok {
		t.Fatal("entry survived delete")
	}
}

func TestListHelpers(t *testing.T) {
	if got := withID([]string{"a", "b"}, "a"); !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Errorf("withID dup = %v", got)
	}
	if got := withoutID([]string{"a", "b", "a"}, "a"); !reflect.DeepEqual(got, []string{"b"}) {
		t.Errorf("withoutID = %v", got)
	}
	if got := withoutIDs([]string{"a", "b", "c"}, []string{"a", "c"}); !reflect.DeepEqual(got, []string{"b"}) {
		t.Errorf("withoutIDs = %v", got)
	}
	if got := withoutIDs([]string{"a"}, nil); !reflect.DeepEqual(got, []string{"a"}) {
		t.Errorf("withoutIDs nil = %v", got)
	}
}
