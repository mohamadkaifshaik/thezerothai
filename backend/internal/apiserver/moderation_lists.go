// moderation_lists.go adapts the lists service to moderation.ListLookup (plan W5-44, security review W5-17 M-4): the
// composition root is the one place that knows both modules. moderation defines the interface and its own types and never
// imports lists; lists never imports moderation.
package apiserver

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// listReportLookup is moderation.ListLookup over the lists service.
type listReportLookup struct{ r lists.ListReporter }

var _ moderation.ListLookup = listReportLookup{}

// ReportableList maps lists' answer to moderation's: ErrNotFound and ErrOwnList become moderation's sentinels (moderation
// builds the one wire NOT_FOUND from them), the evidence is copied field by field, anything else passes through.
func (l listReportLookup) ReportableList(ctx context.Context, callerUID, listID string) (moderation.ReportedList, error) {
	if l.r == nil {
		return moderation.ReportedList{}, errors.New("list reports are not wired")
	}
	r, err := l.r.ReportableList(ctx, callerUID, listID)
	switch {
	case errors.Is(err, lists.ErrNotFound):
		return moderation.ReportedList{}, moderation.ErrListNotFound
	case errors.Is(err, lists.ErrOwnList):
		return moderation.ReportedList{}, moderation.ErrOwnList
	case err != nil:
		return moderation.ReportedList{}, err
	}
	return moderation.ReportedList{OwnerUID: r.OwnerUID, OwnerHandle: r.OwnerHandle, Name: r.Name, Description: r.Description, CreatedAt: r.CreatedAt}, nil
}
