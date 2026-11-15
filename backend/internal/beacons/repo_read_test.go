package beacons

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// TestNearbyErr: a FAILED_PRECONDITION from Firestore (a missing or building index), bare or wrapped, is ErrNearbyIndex so
// the service can degrade; any other failure stays an error, is not ErrNearbyIndex, and names none of the query's area,
// city or cursor ids.
func TestNearbyErr(t *testing.T) {
	t.Parallel()
	const cursorID = "0000000000000000777"
	q := NearbyQuery{AreaID: "in.tst.alpha", CityID: "in.tst", AfterID: cursorID}
	index := status.Error(codes.FailedPrecondition, "The query requires an index. You can create it here: https://console")
	other := status.Error(codes.Internal, "boom at documents/beacons/"+cursorID+" for in.tst.alpha in city in.tst")
	for _, tc := range []struct {
		name      string
		err       error
		wantIndex bool
	}{
		{"bare FailedPrecondition", index, true},
		{"wrapped FailedPrecondition", fmt.Errorf("query run: %w", index), true},
		{"another code naming the ids", other, false},
		{"another code, wrapped", fmt.Errorf("query run: %w", status.Error(codes.Unavailable, "in.tst.alpha "+cursorID)), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := nearbyErr("list nearby", tc.err, q)
			if errors.Is(got, ErrNearbyIndex) != tc.wantIndex {
				t.Fatalf("errors.Is(ErrNearbyIndex) = %v, want %v (err %v)", !tc.wantIndex, tc.wantIndex, got)
			}
			if tc.wantIndex {
				return
			}
			for _, id := range []string{q.AreaID, q.CityID, cursorID} {
				if strings.Contains(got.Error(), id) {
					t.Errorf("the error names %q: %v", id, got)
				}
			}
		})
	}
}
