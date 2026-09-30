package identity

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// M3: GetProfile of a SUSPENDED or DELETING profile, by id and by handle, is byte-identical to the
// missing-user error, at no extra reads; the owner still sees their own profile; ACTIVE is unaffected.
func TestGetProfile_NonActiveIsNotFound(t *testing.T) {
	tests := []struct {
		name    string
		status  AccountStatus
		caller  string
		target  ProfileTarget
		visible bool
	}{
		{"suspended by id", AccountStatusSuspended, "uid-a", ProfileTarget{UserID: "uid-b"}, false},
		{"suspended by handle", AccountStatusSuspended, "uid-a", ProfileTarget{Handle: "Bob"}, false},
		{"deleting by id", AccountStatusDeleting, "uid-a", ProfileTarget{UserID: "uid-b"}, false},
		{"deleting by handle", AccountStatusDeleting, "uid-a", ProfileTarget{Handle: "bob"}, false},
		{"own suspended profile stays visible to its owner", AccountStatusSuspended, "uid-b", ProfileTarget{UserID: "uid-b"}, true},
		{"own deleting profile stays visible to its owner", AccountStatusDeleting, "uid-b", ProfileTarget{UserID: "uid-b"}, true},
		{"active", AccountStatusActive, "uid-a", ProfileTarget{UserID: "uid-b"}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			if _, _, err := repo.CreateProfile(context.Background(), "uid-b", "Bob", "bob", "Bob", time.Now()); err != nil {
				t.Fatal(err)
			}
			p := repo.profiles["uid-b"]
			p.Status = tt.status
			repo.profiles["uid-b"] = p
			svc := newTestService(repo)

			got, err := svc.GetProfile(context.Background(), tt.caller, tt.target)
			if tt.visible {
				if err != nil || got.UserID != "uid-b" {
					t.Fatalf("GetProfile = %+v, %v; want the profile", got, err)
				}
				return
			}
			assertNotFound(t, err)
			_, missing := newTestService(newFakeRepo()).GetProfile(context.Background(), tt.caller, ProfileTarget{UserID: "uid-zz"})
			if err.Error() != missing.Error() || connect.CodeOf(apierr.ToConnect(err)) != connect.CodeOf(apierr.ToConnect(missing)) {
				t.Errorf("error %q differs from the missing-user error %q", err, missing)
			}
			if repo.getProfileCalls > 1 {
				t.Errorf("profile reads = %d, want at most 1 (no extra reads for the status check)", repo.getProfileCalls)
			}
		})
	}
}

// GetMe (the caller's own profile) is not subject to the M3 hiding.
func TestGetMe_NonActiveStillServed(t *testing.T) {
	repo := newFakeRepo()
	if _, _, err := repo.CreateProfile(context.Background(), "uid-b", "Bob", "bob", "Bob", time.Now()); err != nil {
		t.Fatal(err)
	}
	p := repo.profiles["uid-b"]
	p.Status = AccountStatusDeleting
	repo.profiles["uid-b"] = p
	if _, err := newTestService(repo).GetMe(context.Background(), "uid-b"); err != nil {
		t.Fatalf("GetMe on a DELETING profile: %v", err)
	}
}

// L3: Firestore-reserved ids (__x__) are VALIDATION for uids and handles, by id and by handle, before any read.
func TestReservedDocIDs(t *testing.T) {
	if ValidUserID("__x__") || ValidUserID("____") {
		t.Error("ValidUserID accepted a reserved doc id")
	}
	for _, ok := range []string{"__x", "x__", "___", "_x_", "a__b__c", "uid-1"} {
		if !ValidUserID(ok) {
			t.Errorf("ValidUserID(%q) = false, want true", ok)
		}
	}
	if handleFormatIssue("__ab__") != "invalid_format" {
		t.Error("handleFormatIssue accepted a reserved doc id")
	}

	repo := newFakeRepo()
	svc := newTestService(repo)
	_, err := svc.GetProfile(context.Background(), "caller", ProfileTarget{UserID: "__x__"})
	wantValidationField(t, err, "user_id")
	_, err = svc.GetProfile(context.Background(), "caller", ProfileTarget{Handle: "__x__"})
	wantValidationField(t, err, "handle")
	_, err = svc.GetProfile(context.Background(), "caller", ProfileTarget{Handle: "no spaces allowed"})
	wantValidationField(t, err, "handle")
	if repo.getProfileCalls != 0 {
		t.Errorf("repo reads = %d, want 0", repo.getProfileCalls)
	}
}
