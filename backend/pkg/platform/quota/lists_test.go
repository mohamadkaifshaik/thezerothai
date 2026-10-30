package quota

import (
	"errors"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// TestListKinds: the listCreates and listAdds counters (ADR-0030 D10) reserve like the others, never touch another kind, and
// each Record field, valueFor case and increment case ship together (ADR-0021 I-3: the whole-record Set of CheckAndReserveN
// would zero a field one of them forgot).
func TestListKinds(t *testing.T) {
	ref := (&firestore.Client{}).Collection("quotas").Doc("uid-1")
	tests := []struct {
		name     string
		kind     Kind
		rec      Record
		limit    int64
		wantErr  bool
		wantUsed int64
	}{
		{"first create of the day", ListCreates, Record{Day: Today()}, 10, false, 1},
		{"last create that fits", ListCreates, Record{Day: Today(), ListCreates: 9}, 10, false, 10},
		{"create at the daily cap", ListCreates, Record{Day: Today(), ListCreates: 10}, 10, true, 10},
		{"new-account create cap of 3", ListCreates, Record{Day: Today(), ListCreates: 3}, 3, true, 3},
		{"adds at their cap do not block creates", ListCreates, Record{Day: Today(), ListAdds: 300}, 10, false, 1},
		{"first add of the day", ListAdds, Record{Day: Today()}, 300, false, 1},
		{"last add that fits", ListAdds, Record{Day: Today(), ListAdds: 299}, 300, false, 300},
		{"add at the daily cap", ListAdds, Record{Day: Today(), ListAdds: 300}, 300, true, 300},
		{"new-account add cap of 50", ListAdds, Record{Day: Today(), ListAdds: 50}, 50, true, 50},
		{"creates at their cap do not block adds", ListAdds, Record{Day: Today(), ListCreates: 10, Bookmarks: 200}, 300, false, 1},
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
			other, otherWant := ListAdds, tt.rec.ListAdds
			if tt.kind == ListAdds {
				other, otherWant = ListCreates, tt.rec.ListCreates
			}
			if got.valueFor(other) != otherWant {
				t.Errorf("record = %+v, want the other list kind untouched (%d)", got, otherWant)
			}
		})
	}
	rec := Record{ListCreates: 7, ListAdds: 9}
	if rec.valueFor(ListCreates) != 7 || rec.valueFor(ListAdds) != 9 || rec.valueFor(DMNew) != 0 {
		t.Errorf("valueFor = %d/%d/%d, want 7/9/0", rec.valueFor(ListCreates), rec.valueFor(ListAdds), rec.valueFor(DMNew))
	}
	var r Record
	r.increment(ListCreates, 2)
	r.increment(ListAdds, 3)
	if r.ListCreates != 2 || r.ListAdds != 3 || r.DMNew != 0 || r.Bookmarks != 0 {
		t.Errorf("increment = %+v", r)
	}
}
