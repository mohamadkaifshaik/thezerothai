package idempotency

import (
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

func TestKeyFormatValid(t *testing.T) {
	tests := []struct {
		name string
		key  string
		want bool
	}{
		{"valid 16 chars", "0123456789abcdef", true},
		{"valid with dash/underscore", "abc-DEF_012345678", true},
		{"too short", "short", false},
		{"too long", "0123456789012345678901234567890123456789012345678901234567890123456789", false},
		{"invalid char", "abcdefghijklmno!", false},
		{"empty", "", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := KeyFormatValid(tc.key); got != tc.want {
				t.Errorf("KeyFormatValid(%q) = %v, want %v", tc.key, got, tc.want)
			}
		})
	}
}

func TestKey_DeterministicAndScoped(t *testing.T) {
	k1 := Key("uid-1", "CreatePost", "client-key-a")
	k2 := Key("uid-1", "CreatePost", "client-key-a")
	if k1 != k2 {
		t.Fatal("Key() must be deterministic for the same inputs")
	}
	if len(k1) != 64 { // hex-encoded sha256
		t.Fatalf("len(Key()) = %d, want 64", len(k1))
	}

	if Key("uid-2", "CreatePost", "client-key-a") == k1 {
		t.Error("Key() must be scoped per uid")
	}
	if Key("uid-1", "CreateUpload", "client-key-a") == k1 {
		t.Error("Key() must be scoped per rpc")
	}
	if Key("uid-1", "CreatePost", "client-key-b") == k1 {
		t.Error("Key() must be scoped per idempotency key")
	}
}

func TestHashRequest_DeterministicAndDistinct(t *testing.T) {
	a := HashRequest("text=hello|media=")
	b := HashRequest("text=hello|media=")
	if a != b {
		t.Fatal("HashRequest() must be deterministic")
	}
	if HashRequest("text=world|media=") == a {
		t.Error("HashRequest() must differ for different canonical bodies")
	}
}

func TestStore_RefPath(t *testing.T) {
	client := &firestore.Client{}
	s := New(client)
	key := Key("uid-1", "CreatePost", "client-key")
	if got, want := s.Ref(key).Path, client.Collection(collection).Doc(key).Path; got != want {
		t.Errorf("Ref path = %q, want %q", got, want)
	}
}

func TestPut_SetsExpireAtWhenZero(t *testing.T) {
	client := &firestore.Client{}
	s := New(client)
	b := &fakeBatch{}
	s.Put(b, "some-key", Record{UID: "uid-1", RPC: "CreatePost"})

	if len(b.created) != 1 {
		t.Fatalf("expected 1 Create() call, got %d", len(b.created))
	}
	rec := b.created[0].(Record)
	if rec.ExpireAt.IsZero() {
		t.Error("expected ExpireAt to default to now+TTL when unset")
	}
}

type fakeBatch struct {
	created []interface{}
}

func (f *fakeBatch) Set(*firestore.DocumentRef, interface{}, ...firestore.SetOption) store.Batch {
	return f
}
func (f *fakeBatch) Create(_ *firestore.DocumentRef, data interface{}) store.Batch {
	f.created = append(f.created, data)
	return f
}
func (f *fakeBatch) Update(*firestore.DocumentRef, []firestore.Update) store.Batch        { return f }
func (f *fakeBatch) Delete(*firestore.DocumentRef, ...firestore.Precondition) store.Batch { return f }
