package lists

import (
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// This file is the part of the module that timeline.GetListTimeline (W5-8) may use besides Reader and Guard: the one NOT_FOUND,
// the list_id check and the header converter. Each is the same code GetList runs, exported rather than copied, so the three
// RPCs cannot drift apart.

// NotFoundError is the one NOT_FOUND of D3 (ADR-0030): byte-identical for a missing, private, hidden, blocking or inactive-owner
// list. GetListTimeline returns it when Reader answers ErrNotFound, so the two RPCs match byte for byte.
func NotFoundError() *apierr.Error { return notFound() }

// ValidateListID is the 0-read VALIDATION field=list_id check GetList and every other list RPC runs before a read.
func ValidateListID(id string) error { return validateListID(id) }

// MembersInfo renders the header a Reader.Members answer already holds as the wire ListInfo, with no further read.
// PinnedByViewer is false until W5-9 fills it (see service.pinned). The member count is the one Members computed, net of the
// members who block the owner, which for the owner is one lower than GetList's stored count only while such a member exists.
func MembersInfo(m ListMembers) *listsv1.ListInfo {
	return toListInfo(View{Header: m.Header, Owner: m.Owner})
}
