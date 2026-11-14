package main

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/lists"
)

// fakeRecounter returns a fixed recount: the dry-run result, or with write the same result marked Written unless in step.
type fakeRecounter struct{ res lists.FollowRecount }

func (f fakeRecounter) RecountFollowers(_ context.Context, _ string, write bool) (lists.FollowRecount, error) {
	r := f.res
	if write && !r.InStep() {
		r.Written = true
	}
	return r, nil
}

func TestRecountListFollows_Output(t *testing.T) {
	cases := []struct {
		name  string
		res   lists.FollowRecount
		write bool
		want  []string
	}{
		{"in step", lists.FollowRecount{Stored: 2, Counted: 2}, true, []string{"followerCount=2 markers=2", "in step: nothing to write"}},
		{"drift dry run", lists.FollowRecount{Stored: 3, Counted: 2}, false, []string{"followerCount=3 markers=2", "dry-run: would set followerCount to 2"}},
		{"missing dry run", lists.FollowRecount{Counted: 0, Missing: true}, false, []string{"followerCount=missing markers=0", "dry-run: would set followerCount to 0"}},
		{"missing write", lists.FollowRecount{Counted: 0, Missing: true}, true, []string{"followerCount=missing markers=0", "set followerCount to 0"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			b := &backends{listFollows: fakeRecounter{res: tc.res}}
			if err := recountListFollows(context.Background(), b, testListID, tc.write, &out); err != nil {
				t.Fatal(err)
			}
			for _, w := range tc.want {
				if !strings.Contains(out.String(), w) {
					t.Errorf("output %q lacks %q", out.String(), w)
				}
			}
			if strings.Contains(out.String(), "nothing to write") && tc.res.Missing {
				t.Errorf("missing field reported as in step: %q", out.String())
			}
		})
	}
}
