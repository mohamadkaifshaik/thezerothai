package apiserver

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

type fakeBeaconReporter struct {
	r   beacons.ReportedBeacon
	err error
}

func (f fakeBeaconReporter) ReportableBeacon(context.Context, string, string) (beacons.ReportedBeacon, error) {
	return f.r, f.err
}

// The adapter turns beacons' sentinels into moderation's (which build the one wire answer), copies the evidence field by
// field, and refuses to answer before the beacons service is bound.
func TestLateBeaconLookup_MapsErrorsAndEvidence(t *testing.T) {
	t.Parallel()
	made := time.Date(2026, 11, 6, 0, 0, 0, 0, time.UTC)
	boom := errors.New("deadline")
	tests := []struct {
		name    string
		in      *fakeBeaconReporter
		want    moderation.ReportedBeacon
		wantErr error
	}{
		{"evidence", &fakeBeaconReporter{r: beacons.ReportedBeacon{OrganiserUID: "o", OrganiserHandle: "h", Title: "t", Details: "d", Venue: "v", CreatedAt: made}},
			moderation.ReportedBeacon{OrganiserUID: "o", OrganiserHandle: "h", Title: "t", Details: "d", Venue: "v", CreatedAt: made}, nil},
		{"not found", &fakeBeaconReporter{err: beacons.ErrNotFound}, moderation.ReportedBeacon{}, moderation.ErrBeaconNotFound},
		{"wrapped not found", &fakeBeaconReporter{err: fmt.Errorf("x: %w", beacons.ErrNotFound)}, moderation.ReportedBeacon{}, moderation.ErrBeaconNotFound},
		{"own beacon", &fakeBeaconReporter{err: beacons.ErrOwnBeacon}, moderation.ReportedBeacon{}, moderation.ErrOwnBeacon},
		{"other error passes through", &fakeBeaconReporter{err: boom}, moderation.ReportedBeacon{}, boom},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			l := &lateBeaconLookup{r: tt.in}
			got, err := l.ReportableBeacon(context.Background(), "caller", "1234567890123456789")
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Fatalf("evidence = %+v, want %+v", got, tt.want)
			}
		})
	}
	t.Run("unbound", func(t *testing.T) {
		t.Parallel()
		var ae *moderation.ReportedBeacon
		_ = ae
		if _, err := (&lateBeaconLookup{}).ReportableBeacon(context.Background(), "caller", "1234567890123456789"); err == nil || errors.Is(err, moderation.ErrBeaconNotFound) {
			t.Fatalf("unbound lookup = %v, want an infrastructure error", err)
		}
	})
}
