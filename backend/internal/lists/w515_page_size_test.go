package lists

import (
	"context"
	"strconv"
	"testing"
)

// W5-15 / rule 5: every list page is limited, default 20, max 50, whatever page_size the client sends (0, negative, over the
// max). ListListMembers and ListUserLists share limits.ClampPageSize; this pins both entry points to it so a new path that
// reads page_size directly fails here.
var pageSizeCases = []struct {
	name string
	size int32
	want int
}{
	{"unset", 0, 20},
	{"negative", -7, 20},
	{"inside", 7, 7},
	{"default", 20, 20},
	{"just above the default", 21, 21},
	{"the max", 50, 50},
	{"just above the max", 51, 50},
	{"huge", 1 << 30, 50},
}

func TestListListMembers_PageSizeDefaultAndMax(t *testing.T) {
	t.Parallel()
	for _, tt := range pageSizeCases {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newReadEnv(nil, nil, memberList(60))
			for i := 1; i <= 60; i++ {
				m := "m" + strconv.Itoa(i)
				e.dir.profiles[m] = active(m, false)
			}
			p, err := e.svc.ListListMembers(context.Background(), viewerUID, testListID, tt.size, "")
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Items) != tt.want {
				t.Errorf("page_size %d returned %d members, want %d", tt.size, len(p.Items), tt.want)
			}
			if p.NextPageToken == "" {
				t.Errorf("60 members and a page of %d must carry a next token", tt.want)
			}
		})
	}
}

func TestListUserLists_PageSizeDefaultAndMax(t *testing.T) {
	t.Parallel()
	for _, tt := range pageSizeCases {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var ls []List
			for i := 1; i <= 60; i++ { // seeded past the 20-list cap so the clamp, not the data, bounds the page
				ls = append(ls, listN(i, testUID))
			}
			e := newReadEnv(nil, nil, ls...)
			p, err := e.svc.ListUserLists(context.Background(), testUID, UserListsInput{PageSize: tt.size})
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Lists) != tt.want {
				t.Errorf("page_size %d returned %d lists, want %d", tt.size, len(p.Lists), tt.want)
			}
			if p.NextPageToken == "" {
				t.Errorf("60 lists and a page of %d must carry a next token", tt.want)
			}
		})
	}
}
