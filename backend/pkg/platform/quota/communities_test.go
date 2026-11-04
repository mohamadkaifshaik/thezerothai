package quota

import (
	"errors"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// TestCommunityKinds: the communityJoins and communityPosts counters reserve like the others, never touch another
// kind (the posts quota in particular: community posts are charged on top of it), and each Record field, valueFor case and
// increment case ship together (the whole-record Set of CheckAndReserveN would zero a field one of them forgot).
func TestCommunityKinds(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	tests := []struct {
		name     string
		kind     Kind
		rec      Record
		limit    int64
		wantErr  bool
		wantUsed int64
	}{
		{"first join of the day", CommunityJoins, Record{Day: Today()}, 20, false, 1},
		{"last join that fits", CommunityJoins, Record{Day: Today(), CommunityJoins: 19}, 20, false, 20},
		{"join at the daily cap", CommunityJoins, Record{Day: Today(), CommunityJoins: 20}, 20, true, 20},
		{"new-account join cap of 5", CommunityJoins, Record{Day: Today(), CommunityJoins: 5}, 5, true, 5},
		{"posts at their cap do not block joins", CommunityJoins, Record{Day: Today(), CommunityPosts: 50}, 20, false, 1},
		{"first community post of the day", CommunityPosts, Record{Day: Today()}, 50, false, 1},
		{"last community post that fits", CommunityPosts, Record{Day: Today(), CommunityPosts: 49}, 50, false, 50},
		{"community post at the daily cap", CommunityPosts, Record{Day: Today(), CommunityPosts: 50}, 50, true, 50},
		{"new-account community post cap of 10", CommunityPosts, Record{Day: Today(), CommunityPosts: 10}, 10, true, 10},
		{"joins at their cap do not block posts", CommunityPosts, Record{Day: Today(), CommunityJoins: 20, Posts: 7}, 50, false, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := &fakeBatch{}
			err := CheckAndReserve(b, ref, tt.rec, tt.kind, tt.limit)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				var ae *apierr.Error
				if !errors.As(err, &ae) || len(b.sets) != 0 {
					t.Fatalf("err = %v sets = %d, want QUOTA_EXCEEDED and nothing written", err, len(b.sets))
				}
				return
			}
			got := b.sets[0].(Record)
			if got.valueFor(tt.kind) != tt.wantUsed {
				t.Errorf("%s = %d, want %d", tt.kind, got.valueFor(tt.kind), tt.wantUsed)
			}
			other, otherWant := CommunityPosts, tt.rec.CommunityPosts
			if tt.kind == CommunityPosts {
				other, otherWant = CommunityJoins, tt.rec.CommunityJoins
			}
			if got.valueFor(other) != otherWant || got.Posts != tt.rec.Posts {
				t.Errorf("record = %+v, want the other community kind (%d) and posts (%d) untouched", got, otherWant, tt.rec.Posts)
			}
		})
	}
	rec := Record{CommunityJoins: 7, CommunityPosts: 9}
	if rec.valueFor(CommunityJoins) != 7 || rec.valueFor(CommunityPosts) != 9 || rec.valueFor(ListAdds) != 0 {
		t.Errorf("valueFor = %d/%d/%d, want 7/9/0", rec.valueFor(CommunityJoins), rec.valueFor(CommunityPosts), rec.valueFor(ListAdds))
	}
	var r Record
	r.increment(CommunityJoins, 2)
	r.increment(CommunityPosts, 3)
	if r.CommunityJoins != 2 || r.CommunityPosts != 3 || r.Posts != 0 || r.ListAdds != 0 {
		t.Errorf("increment = %+v", r)
	}
}

// TestCommunityKinds_QuotaMetadataName: QUOTA_EXCEEDED carries the snake_case wire names communities.proto documents
// (community_joins, community_posts), not the Firestore field names.
func TestCommunityKinds_QuotaMetadataName(t *testing.T) {
	tests := []struct {
		kind Kind
		want string
	}{
		{CommunityJoins, "community_joins"},
		{CommunityPosts, "community_posts"},
		{ListAdds, "list_adds"},
		{Posts, "posts"},
	}
	for _, tt := range tests {
		t.Run(string(tt.kind), func(t *testing.T) {
			err := ExceededError(tt.kind, time.Now())
			if got := err.Metadata["quota"]; got != tt.want {
				t.Errorf("meta quota = %q, want %q", got, tt.want)
			}
		})
	}
}

// TestCheckAndReserveBoth: posts and communityPosts move together in ONE Set (a second CheckAndReserve on the same record would write
// a copy without the first increment); posts wins the precedence; a refusal writes nothing.
func TestCheckAndReserveBoth(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	tests := []struct {
		name      string
		rec       Record
		wantQuota string
		wantPosts int64
		wantComm  int64
	}{
		{"both fit", Record{Day: Today(), Posts: 3, CommunityPosts: 4}, "", 4, 5},
		{"community at its cap", Record{Day: Today(), Posts: 3, CommunityPosts: 50}, "community_posts", 0, 0},
		{"posts at its cap", Record{Day: Today(), Posts: 100, CommunityPosts: 1}, "posts", 0, 0},
		{"both over: posts wins", Record{Day: Today(), Posts: 100, CommunityPosts: 50}, "posts", 0, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := &fakeBatch{}
			err := CheckAndReserveBoth(b, ref, tt.rec, Posts, 100, CommunityPosts, 50)
			if tt.wantQuota != "" {
				var ae *apierr.Error
				if !errors.As(err, &ae) || ae.Metadata["quota"] != tt.wantQuota || len(b.sets) != 0 {
					t.Fatalf("err = %v sets = %d, want QUOTA_EXCEEDED %s and nothing written", err, len(b.sets), tt.wantQuota)
				}
				return
			}
			if err != nil || len(b.sets) != 1 {
				t.Fatalf("err = %v sets = %d, want exactly one Set", err, len(b.sets))
			}
			got := b.sets[0].(Record)
			if got.Posts != tt.wantPosts || got.CommunityPosts != tt.wantComm {
				t.Fatalf("record = %+v, want posts %d communityPosts %d", got, tt.wantPosts, tt.wantComm)
			}
		})
	}
}
