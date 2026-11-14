package communities

import (
	"context"
	"testing"
)

// TestRecentCoMembers: the community joined last (the tail of memberships.joined) is paged once, newest first, the caller left
// out; a community that is not ACTIVE or is gone gives nothing; the cap is clamped to 6.
func TestRecentCoMembers(t *testing.T) {
	f := newListFixture()
	older, newest := "0000000000000000951", "0000000000000000952"
	seedSearch(f, named(older, "Old", StatusActive), named(newest, "Runners", StatusActive))
	f.repo.mships = map[string]Memberships{"u1": {Joined: []string{older, newest}}}
	f.seedMembers(newest, false, "m1", "u1", "m2", "m3", "m4", "m5", "m6", "m7")
	got, err := f.svc.RecentCoMembers(context.Background(), "u1", 99)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 5 || got[0].UID != "m1" || got[0].CommunityID != newest || got[0].CommunityName != "Runners" {
		t.Fatalf("got %+v", got)
	}
	for _, m := range got {
		if m.UID == "u1" {
			t.Fatal("the caller was returned")
		}
	}
	if q := f.repo.lst.memberQs[0]; q.Limit != maxCoMembers || q.CommunityID != newest || q.Banned {
		t.Fatalf("query = %+v", q)
	}

	for name, c := range map[string]Community{
		"suspended": named(newest, "Runners", StatusSuspended),
		"archived":  named(newest, "Runners", StatusArchived),
	} {
		f := newListFixture()
		seedSearch(f, c)
		f.repo.mships = map[string]Memberships{"u1": {Joined: []string{newest}}}
		f.seedMembers(newest, false, "m1")
		if got, err := f.svc.RecentCoMembers(context.Background(), "u1", 6); err != nil || len(got) != 0 {
			t.Fatalf("%s: got %+v, %v", name, got, err)
		}
	}
	gone := newListFixture()
	gone.repo.mships = map[string]Memberships{"u1": {Joined: []string{"0000000000000000999"}}}
	if got, err := gone.svc.RecentCoMembers(context.Background(), "u1", 6); err != nil || len(got) != 0 {
		t.Fatalf("gone: got %+v, %v", got, err)
	}
	none := newListFixture()
	if got, err := none.svc.RecentCoMembers(context.Background(), "u1", 6); err != nil || got != nil {
		t.Fatalf("no memberships: got %+v, %v", got, err)
	}
}
