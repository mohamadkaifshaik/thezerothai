package apiserver

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

type fakeListReporter struct {
	r   lists.ReportedList
	err error
}

func (f fakeListReporter) ReportableList(context.Context, string, string) (lists.ReportedList, error) {
	return f.r, f.err
}

// The adapter turns lists' sentinels into moderation's (which build the one wire answer) and copies the evidence field by field.
func TestListReportLookup_MapsErrorsAndEvidence(t *testing.T) {
	t.Parallel()
	made := time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC)
	boom := errors.New("deadline")
	tests := []struct {
		name    string
		in      fakeListReporter
		want    moderation.ReportedList
		wantErr error
	}{
		{"evidence", fakeListReporter{r: lists.ReportedList{OwnerUID: "o", OwnerHandle: "h", Name: "n", Description: "d", CreatedAt: made}},
			moderation.ReportedList{OwnerUID: "o", OwnerHandle: "h", Name: "n", Description: "d", CreatedAt: made}, nil},
		{"not found", fakeListReporter{err: lists.ErrNotFound}, moderation.ReportedList{}, moderation.ErrListNotFound},
		{"wrapped not found", fakeListReporter{err: fmt.Errorf("x: %w", lists.ErrNotFound)}, moderation.ReportedList{}, moderation.ErrListNotFound},
		{"own list", fakeListReporter{err: lists.ErrOwnList}, moderation.ReportedList{}, moderation.ErrOwnList},
		{"other error passes through", fakeListReporter{err: boom}, moderation.ReportedList{}, boom},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := listReportLookup{r: tt.in}.ReportableList(context.Background(), "caller", "id")
			if !errors.Is(err, tt.wantErr) || (tt.wantErr == nil && err != nil) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
		})
	}
	if _, err := (listReportLookup{}).ReportableList(context.Background(), "c", "i"); err == nil {
		t.Error("an unwired lookup must be an error")
	}
}
