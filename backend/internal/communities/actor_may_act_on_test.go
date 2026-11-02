package communities

import "testing"

func TestActorMayActOn_Table(t *testing.T) {
	c := Community{OwnerID: "o", ModeratorIDs: []string{"m1", "m2"}}
	tests := []struct {
		name, actor, author string
		want                error
	}{
		{"owner on owner", "o", "o", nil},
		{"owner on moderator", "o", "m1", nil},
		{"owner on member", "o", "x", nil},
		{"moderator on owner", "m1", "o", ErrNotOwner},
		{"moderator on other moderator", "m1", "m2", ErrNotOwner},
		{"moderator on self", "m1", "m1", nil},
		{"moderator on member", "m1", "x", nil},
		{"moderator on former moderator", "m1", "gone", nil},
		{"moderator on empty author", "m1", "", nil},
	}
	for _, tc := range tests {
		if got := actorMayActOn(c, tc.actor, tc.author); got != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}
