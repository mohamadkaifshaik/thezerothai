package identity

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/publicid"
)

// TestCreateProfile_RejectsPublicIDShapedUID: a caller uid that is a well-formed public id, or the tombstone id, is
// refused before any read, write or Auth call, whatever FEATURE_PUBLIC_IDS says, so the uid and public id spaces stay
// disjoint (the edge passes an unknown public id and the tombstone to handlers as if they were unknown uids, which is
// only safe while no account can have such a uid). The answer is the terminal signup refusal (PERMISSION_DENIED "this
// account cannot be used to sign up"), not a sign-in-again answer the app would loop on. A uid that only resembles
// one (uppercase, one character short) is accepted as before.
func TestCreateProfile_RejectsPublicIDShapedUID(t *testing.T) {
	for _, mode := range []string{"off", "on"} {
		t.Run("flag "+mode, func(t *testing.T) {
			for _, tc := range []struct {
				uid    string
				reject bool
			}{
				{pid('1'), true},
				{"u0000000000000000000000000a", true},
				{"U0000000000000000000000000a", false},
				{publicid.Tombstone, true},            // not a valid public id, but the edge passes it through as one
				{"u000000000000000000000000a", false}, // 26 characters
				{"FbUid00000000000000000000001", false},
			} {
				repo := newFakeRepo()
				svc := newPubService(repo, pubFlags{mode: mode})
				svc.newPublicID = seqIDs(pid('9'))
				_, err := svc.CreateProfile(context.Background(), tc.uid, validKey, "Alice", "Alice A.")
				if !tc.reject {
					if err != nil {
						t.Errorf("uid %q: CreateProfile = %v, want success", tc.uid, err)
					}
					continue
				}
				var ae *apierr.Error
				if !errors.As(err, &ae) {
					t.Fatalf("uid %q: err = %v, want an *apierr.Error", tc.uid, err)
				}
				if ae.Code != connect.CodePermissionDenied || ae.Reason != commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED ||
					ae.Message != "this account cannot be used to sign up" || len(ae.Metadata) != 0 {
					t.Errorf("uid %q: err = %+v, want the signup refusal", tc.uid, ae)
				}
				if repo.createCalls != 0 || repo.getProfileCalls != 0 {
					t.Errorf("uid %q: repo creates=%d gets=%d, want none", tc.uid, repo.createCalls, repo.getProfileCalls)
				}
			}
		})
	}
}
