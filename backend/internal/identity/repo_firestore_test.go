package identity

import (
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// These tests cover the pure Firestore-doc<->domain conversion helpers and the write-only Counters
// methods without touching a real Firestore backend (a zero-value *firestore.Client is enough to build
// DocumentRefs and a fakeBatch records writes). CreateProfile/GetProfile/ChangeHandle/etc. need a real
// transactional backend and are covered by repo_firestore_integration_test.go (build tag `integration`,
// run via `make test-int` against the Firestore emulator).

type fakeCountersBatch struct {
	updates []struct {
		ref *firestore.DocumentRef
		u   []firestore.Update
	}
}

func (f *fakeCountersBatch) Set(*firestore.DocumentRef, interface{}, ...firestore.SetOption) store.Batch {
	return f
}
func (f *fakeCountersBatch) Create(*firestore.DocumentRef, interface{}) store.Batch { return f }
func (f *fakeCountersBatch) Update(ref *firestore.DocumentRef, u []firestore.Update) store.Batch {
	f.updates = append(f.updates, struct {
		ref *firestore.DocumentRef
		u   []firestore.Update
	}{ref, u})
	return f
}
func (f *fakeCountersBatch) Delete(*firestore.DocumentRef, ...firestore.Precondition) store.Batch { return f }

func TestUserDoc_ToProfile_RoundTrip(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	p := Profile{
		UserID: "uid-1", Handle: "Alice", HandleLower: "alice", DisplayName: "Alice A.", Bio: "hi",
		AvatarURL: "https://x/a.jpg", AvatarThumbURL: "https://x/t.jpg", IsPrivate: true, Verified: true,
		Status: AccountStatusActive, FollowersCount: 10, FollowingCount: 20, PostsCount: 30,
		NotificationsSeenAt: now, HandleChangedAt: now, SnapshotVersion: 2, CreatedAt: now, UpdatedAt: now,
	}
	doc := profileToDoc(p)
	got := doc.toProfile("uid-1")
	if got != p {
		t.Errorf("round trip mismatch:\n got  %+v\n want %+v", got, p)
	}
}

func TestStatusStringMapping(t *testing.T) {
	tests := []struct {
		status AccountStatus
		str    string
	}{
		{AccountStatusActive, "ACTIVE"},
		{AccountStatusSuspended, "SUSPENDED"},
		{AccountStatusDeleting, "DELETING"},
		{AccountStatusUnspecified, ""},
	}
	for _, tt := range tests {
		if got := statusToString(tt.status); got != tt.str {
			t.Errorf("statusToString(%v) = %q, want %q", tt.status, got, tt.str)
		}
		if got := statusFromString(tt.str); tt.str != "" && got != tt.status {
			t.Errorf("statusFromString(%q) = %v, want %v", tt.str, got, tt.status)
		}
	}
	if got := statusFromString("garbage"); got != AccountStatusUnspecified {
		t.Errorf("statusFromString(garbage) = %v, want Unspecified", got)
	}
}

func TestFirestoreRepo_RefPaths(t *testing.T) {
	client := &firestore.Client{}
	r := NewFirestoreRepo(client, nil)
	if got, want := r.userRef("uid-1").Path, client.Collection(usersCollection).Doc("uid-1").Path; got != want {
		t.Errorf("userRef path = %q, want %q", got, want)
	}
	if got, want := r.handleRef("alice").Path, client.Collection(handlesCollection).Doc("alice").Path; got != want {
		t.Errorf("handleRef path = %q, want %q", got, want)
	}
}

func TestFirestoreRepo_Counters(t *testing.T) {
	client := &firestore.Client{}
	r := NewFirestoreRepo(client, nil)
	b := &fakeCountersBatch{}

	r.AddPostsCount(b, "uid-1", 1)
	r.AddFollowersCount(b, "uid-1", 1)
	r.AddFollowingCount(b, "uid-1", -1)

	if len(b.updates) != 3 {
		t.Fatalf("expected 3 Update() calls, got %d", len(b.updates))
	}
	wantPaths := []string{"postsCount", "followersCount", "followingCount"}
	for i, want := range wantPaths {
		if got := b.updates[i].u[0].Path; got != want {
			t.Errorf("update[%d].Path = %q, want %q", i, got, want)
		}
	}
}
