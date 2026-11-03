package identity

import (
	"context"
	"testing"
)

// The rule runs on write only; a stored bio with an invisible character is returned as stored, and a read writes nothing.
func TestW555_StoredBioReadsUnchanged(t *testing.T) {
	repo := newFakeRepo()
	stored := "old\u200bbio"
	repo.profiles["uid-1"] = Profile{UserID: "uid-1", Handle: "Alice", HandleLower: "alice", DisplayName: "Alice", Bio: stored, Status: AccountStatusActive}
	svc := newTestService(repo)
	got, err := svc.GetProfile(context.Background(), "caller", ProfileTarget{UserID: "uid-1"})
	if err != nil {
		t.Fatal(err)
	}
	if got.Bio != stored {
		t.Errorf("bio = %q, want %q unchanged", got.Bio, stored)
	}
	if repo.updateCalls != 0 || repo.createCalls != 0 {
		t.Error("a read wrote")
	}
}
