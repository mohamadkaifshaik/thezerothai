package lists

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// NotFoundError is what timeline answers for ErrNotFound: it must equal, field for field, what the GetList handler path
// answers through mapErr, so the two RPCs cannot drift (ADR-0030 D3, byte-identical).
func TestNotFoundError_MatchesTheHandlerPath(t *testing.T) {
	t.Parallel()
	got := NotFoundError()
	via := mapErr(context.Background(), "get", "u", "1", ErrNotFound)
	var want *apierr.Error
	if !errors.As(via, &want) {
		t.Fatalf("mapErr(ErrNotFound) = %#v", via)
	}
	if got.Code != connect.CodeNotFound || got.Message != notFoundText ||
		got.Code != want.Code || got.Message != want.Message || got.Reason != want.Reason || fmt.Sprint(got.Metadata) != fmt.Sprint(want.Metadata) {
		t.Fatalf("NotFoundError() = %#v, handler path = %#v", got, want)
	}
}

func TestValidateListID_IsTheHandlerCheck(t *testing.T) {
	t.Parallel()
	for id, ok := range map[string]bool{"": false, "abc": false, "123": false, "1000000000000000001": true} {
		if err := ValidateListID(id); (err == nil) != ok {
			t.Errorf("ValidateListID(%q) = %v", id, err)
		}
	}
	var ae *apierr.Error
	if err := ValidateListID("x"); !errors.As(err, &ae) || ae.Metadata["field"] != "list_id" {
		t.Errorf("err = %#v, want VALIDATION field=list_id", err)
	}
}

func TestMembersInfo_RendersTheHeaderWithoutARead(t *testing.T) {
	t.Parallel()
	info := MembersInfo(ListMembers{
		Header: Header{ID: "7", Name: "Friends", Description: "d", IsPrivate: true, MemberCount: 3},
		Owner:  identity.Profile{UserID: "o", Handle: "owner", DisplayName: "Owner", Verified: true},
	})
	if info.GetListId() != "7" || info.GetName() != "Friends" || info.GetDescription() != "d" || !info.GetIsPrivate() || info.GetMemberCount() != 3 ||
		info.GetOwner().GetUserId() != "o" || info.GetOwner().GetHandle() != "owner" || !info.GetOwner().GetVerified() || info.GetPinnedByViewer() {
		t.Fatalf("info = %v", info)
	}
}
