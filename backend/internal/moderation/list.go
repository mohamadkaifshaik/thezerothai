// list.go is moderation's side of "report a list" (security review W5-17 M-4, plan W5-44): the target type, the shape check
// of the list id and the consumer-side seam through which moderation reaches a list. moderation never reads lists/* itself:
// lists implements ListReporter and the composition root adapts it (the MessageLookup pattern, ADR-0027 D15).
package moderation

import (
	"context"
	"errors"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// TargetList is a report about one list. The doc stores "LIST"; targetId is the list id (19 digits, the post id shape).
const TargetList TargetType = "LIST"

// ListsFlagName is the wire name of FEATURE_LISTS (lists.FlagName; moderation does not import lists). A report of a list needs
// it not globally off, the same rule as MESSAGE: a user dropped from the allowlist can still report what they saw.
const ListsFlagName = "lists"

// ReportedList is what a ListLookup answers: the evidence of one list, taken at report time. It holds no member id.
type ReportedList struct {
	// OwnerUID becomes the report's TargetOwnerID. It never reaches a client or a log.
	OwnerUID string
	// OwnerHandle is the owner's handle.
	OwnerHandle string
	// Name and Description are the list's text as the reporter saw it (public once the list is public).
	Name        string
	Description string
	// CreatedAt is when the list was created.
	CreatedAt time.Time
}

// Lookup errors. Sentinels: moderation builds the wire answer, so every "no such list" cause has the same bytes.
var (
	// ErrListNotFound covers every way a list can be unreportable for this caller: missing, malformed id, private, hidden,
	// an owner who blocks the caller or is not ACTIVE.
	ErrListNotFound = errors.New("moderation: list not found")
	// ErrOwnList is a list the caller owns.
	ErrOwnList = errors.New("moderation: own list")
)

// ListLookup is the consumer-side seam to lists. ReportableList answers whether callerUID may see the list (ADR-0030 D3) and
// is not its owner, and returns its evidence. It returns ErrListNotFound, ErrOwnList or an infrastructure error. It checks no
// flag. Firestore, worst case: list 1 + caller graph 1 + owner users 1 + owner graph 1 (all cache-first, 0 warm).
type ListLookup interface {
	ReportableList(ctx context.Context, callerUID, listID string) (ReportedList, error)
}

// listNotFound is the one NOT_FOUND of a list report (byte-identical for every cause, and the same bytes GetList answers).
func listNotFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "list not found")
}
