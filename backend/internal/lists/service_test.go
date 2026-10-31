package lists

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

const (
	testKey    = "0123456789abcdef0123"
	testListID = "0000000000000000042"
	testUID    = "owner-1"
)

// fakeRepo records the params it was given and answers with a canned result. Guarded by a mutex so a parallel test stays race free.
type fakeRepo struct {
	mu sync.Mutex

	create    CreateResult
	update    UpdateResult
	del       DeleteResult
	err       error
	createdBy []CreateParams
	updatedBy []UpdateParams
	deletedBy []DeleteParams
}

func (f *fakeRepo) Create(_ context.Context, p CreateParams) (CreateResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.createdBy = append(f.createdBy, p)
	return f.create, f.err
}

func (f *fakeRepo) Update(_ context.Context, p UpdateParams) (UpdateResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.updatedBy = append(f.updatedBy, p)
	return f.update, f.err
}

func (f *fakeRepo) Delete(_ context.Context, p DeleteParams) (DeleteResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deletedBy = append(f.deletedBy, p)
	return f.del, f.err
}

func (f *fakeRepo) calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.createdBy) + len(f.updatedBy) + len(f.deletedBy)
}

// fakeDirectory serves one profile map; the embedded nil interface panics on any method the service must not call.
type fakeDirectory struct {
	identity.Directory
	profiles map[string]identity.Profile
	err      error
}

func (d fakeDirectory) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if p, ok := d.profiles[u]; ok {
			out[u] = p
		}
	}
	return out, d.err
}

type fakePins struct {
	mu        sync.Mutex
	pinned    bool
	err       error
	unpinned  []string
	retitled  []string
	retitleTo []string
}

func (p *fakePins) Unpin(_ context.Context, _, listID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.unpinned = append(p.unpinned, listID)
	return p.err
}

func (p *fakePins) Retitle(_ context.Context, _, listID, name string) (bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.retitled = append(p.retitled, listID)
	p.retitleTo = append(p.retitleTo, name)
	return p.pinned, p.err
}

type fixedIDs struct{}

func (fixedIDs) Generate() string { return testListID }

var testNow = time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)

func newTestService(repo Repo, pins Pins, created time.Time) (*service, *fakeRepo) {
	fr, _ := repo.(*fakeRepo)
	dir := fakeDirectory{profiles: map[string]identity.Profile{testUID: {UserID: testUID, Handle: "owner", CreatedAt: created}}}
	s := New(Deps{
		Repo: repo, Directory: dir, IDs: fixedIDs{}, Pins: pins, Now: func() time.Time { return testNow },
		Limits: Limits{MaxPerUser: 20, CreatesPerDay: 10, NewAccountCreatesPerDay: 3, NewAccountWindow: 24 * time.Hour, CacheEntries: 50},
	}).(*service)
	return s, fr
}

func oldAccount() time.Time { return testNow.Add(-72 * time.Hour) }

func ptr[T any](v T) *T { return &v }

// wantAPI asserts err is an *apierr.Error with the given code, reason and metadata.
func wantAPI(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, meta map[string]string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want an *apierr.Error", err)
	}
	if ae.Code != code || ae.Reason != reason {
		t.Fatalf("err = %d/%v %q, want %d/%v", ae.Code, ae.Reason, ae.Message, code, reason)
	}
	for k, v := range meta {
		if ae.Metadata[k] != v {
			t.Errorf("metadata[%q] = %q, want %q", k, ae.Metadata[k], v)
		}
	}
}

func TestCreateList_Validation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		in        CreateInput
		wantField string
	}{
		{"short key", CreateInput{Key: "short", Name: "Cricket"}, "idempotency_key"},
		{"empty name", CreateInput{Key: testKey, Name: ""}, "name"},
		{"blank name", CreateInput{Key: testKey, Name: "  \t "}, "name"},
		{"name of 26 code points", CreateInput{Key: testKey, Name: strings.Repeat("a", 26)}, "name"},
		{"name with a bidi override", CreateInput{Key: testKey, Name: "Cri‮ket"}, "name"},
		{"name with a newline", CreateInput{Key: testKey, Name: "Cri\nket"}, "name"},
		{"description of 101 code points", CreateInput{Key: testKey, Name: "Cricket", Description: strings.Repeat("d", 101)}, "description"},
		{"description with a newline", CreateInput{Key: testKey, Name: "Cricket", Description: "a\nb"}, "description"},
		{"description with a bidi isolate", CreateInput{Key: testKey, Name: "Cricket", Description: "a⁦b"}, "description"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			s, repo := newTestService(&fakeRepo{}, nil, oldAccount())
			_, err := s.CreateList(context.Background(), testUID, tt.in)
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tt.wantField})
			if repo.calls() != 0 {
				t.Errorf("the repository was called %d times, want 0 (validation runs before any read)", repo.calls())
			}
		})
	}
}

func TestCreateList_Params(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name        string
		in          CreateInput
		created     time.Time
		wantPrivate bool
		wantQuota   int64
		wantName    string
		wantDesc    string
	}{
		{"is_private absent is private (F3)", CreateInput{Key: testKey, Name: "Cricket"}, oldAccount(), true, 10, "Cricket", ""},
		{"is_private false is public", CreateInput{Key: testKey, Name: "Cricket", IsPrivate: ptr(false)}, oldAccount(), false, 10, "Cricket", ""},
		{"is_private true is private", CreateInput{Key: testKey, Name: "Cricket", IsPrivate: ptr(true)}, oldAccount(), true, 10, "Cricket", ""},
		{"new account gets the small quota tier", CreateInput{Key: testKey, Name: "Cricket"}, testNow.Add(-time.Hour), true, 3, "Cricket", ""},
		{"text is trimmed and NFC", CreateInput{Key: testKey, Name: "  Café ", Description: " é "}, oldAccount(), true, 10, "Café", "é"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := &fakeRepo{create: CreateResult{Outcome: Written, Header: Header{ID: testListID}}}
			s, _ := newTestService(repo, nil, tt.created)
			if _, err := s.CreateList(context.Background(), testUID, tt.in); err != nil {
				t.Fatal(err)
			}
			if len(repo.createdBy) != 1 {
				t.Fatalf("repo calls = %d", len(repo.createdBy))
			}
			p := repo.createdBy[0]
			if p.IsPrivate != tt.wantPrivate || p.QuotaLimit != tt.wantQuota || p.Name != tt.wantName || p.Description != tt.wantDesc {
				t.Errorf("params = %+v, want private %v quota %d name %q description %q", p, tt.wantPrivate, tt.wantQuota, tt.wantName, tt.wantDesc)
			}
			if p.MaxPerUser != 20 || p.ID != testListID || p.UID != testUID || p.IdemKey == "" || p.IdemKey == testKey {
				t.Errorf("params = %+v: cap, id, uid or hashed key wrong", p)
			}
		})
	}
}

// The request hash separates what the idempotency record must tell apart, and an unset optional from its zero value.
func TestRequestHashes(t *testing.T) {
	t.Parallel()
	if createHash("a", "b", nil) == createHash("a", "b", ptr(true)) || createHash("a", "b", ptr(true)) == createHash("a", "b", ptr(false)) {
		t.Error("createHash must distinguish is_private unset, true and false")
	}
	if createHash("a", "b", nil) != createHash("a", "b", nil) {
		t.Error("createHash must be deterministic")
	}
	if createHash("a|description=b", "", nil) == createHash("a", "b", nil) {
		t.Error("createHash must not be fooled by a delimiter inside a field")
	}
	if updateHash(testListID, nil, nil, nil) == updateHash(testListID, nil, ptr(""), nil) {
		t.Error("updateHash must distinguish an unset description from an empty one")
	}
	if updateHash(testListID, ptr("x"), nil, nil) == updateHash("0000000000000000043", ptr("x"), nil, nil) {
		t.Error("updateHash must include the list id")
	}
	if deleteHash(testListID) == deleteHash("0000000000000000043") {
		t.Error("deleteHash must include the list id")
	}
}

func TestCreateList_ErrorMapping(t *testing.T) {
	t.Parallel()
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	tests := []struct {
		name   string
		ctx    context.Context
		repoEr error
		check  func(t *testing.T, err error)
	}{
		{"at the cap", context.Background(), ErrListLimit, func(t *testing.T, err error) {
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "lists"})
		}},
		{"key reused", context.Background(), ErrKeyReused, func(t *testing.T, err error) {
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
		}},
		{"daily quota passes through", context.Background(), apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "daily limit").WithMeta("quota", "list_creates"), func(t *testing.T, err error) {
			wantAPI(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, map[string]string{"quota": "list_creates"})
		}},
		{"contention is retryable", context.Background(), status.Error(codes.Aborted, "lock"), func(t *testing.T, err error) {
			wantAPI(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		}},
		{"the transaction timeout is retryable", context.Background(), context.DeadlineExceeded, func(t *testing.T, err error) {
			wantAPI(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		}},
		{"the client left", canceled, errors.New("rpc error: canceled"), func(t *testing.T, err error) {
			wantAPI(t, err, connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		}},
		{"anything else is internal and redacted", context.Background(), errors.New("firestore: doc lists/" + testListID + " for " + testUID + " exploded"), func(t *testing.T, err error) {
			var ae *apierr.Error
			if errors.As(err, &ae) {
				t.Fatalf("an unknown error must not become an API error: %+v", ae)
			}
			if strings.Contains(err.Error(), testUID) {
				t.Errorf("the uid leaked into the error chain: %v", err)
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			s, _ := newTestService(&fakeRepo{err: tt.repoEr}, nil, oldAccount())
			_, err := s.CreateList(tt.ctx, testUID, CreateInput{Key: testKey, Name: "Cricket"})
			tt.check(t, err)
		})
	}
}

func TestCreateList_ProfileMissing(t *testing.T) {
	t.Parallel()
	s, repo := newTestService(&fakeRepo{}, nil, oldAccount())
	_, err := s.CreateList(context.Background(), "someone-else", CreateInput{Key: testKey, Name: "Cricket"})
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, nil)
	if repo.calls() != 0 {
		t.Error("the repository was called without a profile")
	}
}

func TestCreateList_CacheAndView(t *testing.T) {
	t.Parallel()
	l := List{ID: testListID, OwnerID: testUID, Name: "Cricket", MemberIDs: []string{}, IsPrivate: true}
	t.Run("a written list fills the cache and the view carries the owner row", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{create: CreateResult{Outcome: Written, Header: l.header(), List: &l}}
		s, _ := newTestService(repo, nil, oldAccount())
		v, err := s.CreateList(context.Background(), testUID, CreateInput{Key: testKey, Name: "Cricket"})
		if err != nil {
			t.Fatal(err)
		}
		if v.Header.ID != testListID || v.Owner.Handle != "owner" || v.PinnedByViewer {
			t.Errorf("view = %+v", v)
		}
		if _, ok := s.cache.get(testListID); !ok {
			t.Error("the written list is not in the instance cache")
		}
	})
	t.Run("a replay leaves the cache alone", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{create: CreateResult{Outcome: Replayed, Header: l.header()}}
		s, _ := newTestService(repo, nil, oldAccount())
		if _, err := s.CreateList(context.Background(), testUID, CreateInput{Key: testKey, Name: "Cricket"}); err != nil {
			t.Fatal(err)
		}
		if _, ok := s.cache.get(testListID); ok {
			t.Error("a replay filled the cache from a stale header")
		}
	})
}

func TestUpdateList(t *testing.T) {
	t.Parallel()
	public := List{ID: testListID, OwnerID: testUID, Name: "New", IsPrivate: false, MemberIDs: []string{"a", "b"}}
	private := public
	private.IsPrivate = true

	t.Run("validation", func(t *testing.T) {
		t.Parallel()
		tests := []struct {
			name  string
			in    UpdateInput
			field string
		}{
			{"bad key", UpdateInput{Key: "x", ListID: testListID}, "idempotency_key"},
			{"list id not 19 digits", UpdateInput{Key: testKey, ListID: "42"}, "list_id"},
			{"list id with letters", UpdateInput{Key: testKey, ListID: "00000000000000000ab"}, "list_id"},
			{"name cleared", UpdateInput{Key: testKey, ListID: testListID, Name: ptr("")}, "name"},
			{"name with bidi", UpdateInput{Key: testKey, ListID: testListID, Name: ptr("a‮b")}, "name"},
			{"description too long", UpdateInput{Key: testKey, ListID: testListID, Description: ptr(strings.Repeat("d", 101))}, "description"},
		}
		for _, tt := range tests {
			t.Run(tt.name, func(t *testing.T) {
				t.Parallel()
				s, repo := newTestService(&fakeRepo{}, nil, oldAccount())
				_, err := s.UpdateList(context.Background(), testUID, tt.in)
				wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tt.field})
				if repo.calls() != 0 {
					t.Error("the repository was called")
				}
			})
		}
	})

	t.Run("an empty description is allowed and sent as set", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{update: UpdateResult{Outcome: Written, Header: public.header(), List: &public}}
		s, _ := newTestService(repo, nil, oldAccount())
		if _, err := s.UpdateList(context.Background(), testUID, UpdateInput{Key: testKey, ListID: testListID, Description: ptr("")}); err != nil {
			t.Fatal(err)
		}
		if p := repo.updatedBy[0]; p.Description == nil || *p.Description != "" || p.Name != nil || p.IsPrivate != nil {
			t.Errorf("params = %+v, want only description set to empty", p)
		}
	})

	t.Run("not found is the one message", func(t *testing.T) {
		t.Parallel()
		s, _ := newTestService(&fakeRepo{err: ErrNotFound}, nil, oldAccount())
		_, err := s.UpdateList(context.Background(), testUID, UpdateInput{Key: testKey, ListID: testListID, Name: ptr("x")})
		wantAPI(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		if err.Error() != notFoundText {
			t.Errorf("message = %q, want %q", err.Error(), notFoundText)
		}
	})

	t.Run("a write that keeps the list public refreshes the cache", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{update: UpdateResult{Outcome: Written, Header: public.header(), List: &public}}
		s, _ := newTestService(repo, nil, oldAccount())
		s.cache.put(List{ID: testListID, Name: "Old"})
		if _, err := s.UpdateList(context.Background(), testUID, UpdateInput{Key: testKey, ListID: testListID, Name: ptr("New")}); err != nil {
			t.Fatal(err)
		}
		if got, ok := s.cache.get(testListID); !ok || got.Name != "New" {
			t.Errorf("cache = %+v, %v, want the written list", got, ok)
		}
	})

	t.Run("making a list private evicts it", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{update: UpdateResult{Outcome: Written, Header: private.header(), List: &private}}
		s, _ := newTestService(repo, nil, oldAccount())
		s.cache.put(public)
		if _, err := s.UpdateList(context.Background(), testUID, UpdateInput{Key: testKey, ListID: testListID, IsPrivate: ptr(true)}); err != nil {
			t.Fatal(err)
		}
		if _, ok := s.cache.get(testListID); ok {
			t.Error("a list made private is still cached")
		}
	})

	t.Run("a replay touches neither the cache nor the pins", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{update: UpdateResult{Outcome: Replayed, Header: public.header(), NameChanged: true}}
		pins := &fakePins{pinned: true}
		s, _ := newTestService(repo, pins, oldAccount())
		s.cache.put(List{ID: testListID, Name: "Cached"})
		if _, err := s.UpdateList(context.Background(), testUID, UpdateInput{Key: testKey, ListID: testListID, Name: ptr("New")}); err != nil {
			t.Fatal(err)
		}
		if got, _ := s.cache.get(testListID); got.Name != "Cached" {
			t.Errorf("cache = %+v, a replay must not overwrite it", got)
		}
	})

	t.Run("a rename of a pinned list retitles the tab and reports it pinned", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{update: UpdateResult{Outcome: Written, Header: public.header(), List: &public, NameChanged: true}}
		pins := &fakePins{pinned: true}
		s, _ := newTestService(repo, pins, oldAccount())
		v, err := s.UpdateList(context.Background(), testUID, UpdateInput{Key: testKey, ListID: testListID, Name: ptr("New")})
		if err != nil || !v.PinnedByViewer {
			t.Fatalf("view = %+v err = %v, want pinned_by_viewer", v, err)
		}
		if len(pins.retitled) != 1 || pins.retitleTo[0] != "New" {
			t.Errorf("retitled = %v to %v", pins.retitled, pins.retitleTo)
		}
	})

	t.Run("no name change, no Pins call", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{update: UpdateResult{Outcome: Written, Header: public.header(), List: &public}}
		pins := &fakePins{}
		s, _ := newTestService(repo, pins, oldAccount())
		if _, err := s.UpdateList(context.Background(), testUID, UpdateInput{Key: testKey, ListID: testListID, IsPrivate: ptr(false)}); err != nil {
			t.Fatal(err)
		}
		if len(pins.retitled) != 0 {
			t.Errorf("Retitle called for an unchanged name: %v", pins.retitled)
		}
	})

	t.Run("a Pins failure never fails the RPC", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{update: UpdateResult{Outcome: Written, Header: public.header(), List: &public, NameChanged: true}}
		s, _ := newTestService(repo, &fakePins{err: errors.New("users doc busy")}, oldAccount())
		if _, err := s.UpdateList(context.Background(), testUID, UpdateInput{Key: testKey, ListID: testListID, Name: ptr("New")}); err != nil {
			t.Fatalf("err = %v, want success", err)
		}
	})
}

func TestDeleteList(t *testing.T) {
	t.Parallel()
	t.Run("validation", func(t *testing.T) {
		t.Parallel()
		s, repo := newTestService(&fakeRepo{}, nil, oldAccount())
		wantAPI(t, s.DeleteList(context.Background(), testUID, "x", testListID), connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "idempotency_key"})
		wantAPI(t, s.DeleteList(context.Background(), testUID, testKey, "abc"), connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "list_id"})
		if repo.calls() != 0 {
			t.Error("the repository was called")
		}
	})
	t.Run("a deleted list is evicted and unpinned", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{del: DeleteResult{Outcome: Written, Deleted: true}}
		pins := &fakePins{}
		s, _ := newTestService(repo, pins, oldAccount())
		s.cache.put(List{ID: testListID})
		if err := s.DeleteList(context.Background(), testUID, testKey, testListID); err != nil {
			t.Fatal(err)
		}
		if _, ok := s.cache.get(testListID); ok {
			t.Error("the deleted list is still cached")
		}
		if len(pins.unpinned) != 1 || pins.unpinned[0] != testListID {
			t.Errorf("unpinned = %v", pins.unpinned)
		}
	})
	t.Run("a foreign or missing list is success with no effect", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{del: DeleteResult{Outcome: Unchanged}}
		pins := &fakePins{}
		s, _ := newTestService(repo, pins, oldAccount())
		s.cache.put(List{ID: testListID})
		if err := s.DeleteList(context.Background(), testUID, testKey, testListID); err != nil {
			t.Fatalf("err = %v, want success", err)
		}
		if _, ok := s.cache.get(testListID); !ok {
			t.Error("a no-op delete evicted somebody else's cached list")
		}
		if len(pins.unpinned) != 0 {
			t.Errorf("Unpin called for a list this call did not delete: %v", pins.unpinned)
		}
	})
	t.Run("a replay does nothing more", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{del: DeleteResult{Outcome: Replayed}}
		pins := &fakePins{}
		s, _ := newTestService(repo, pins, oldAccount())
		if err := s.DeleteList(context.Background(), testUID, testKey, testListID); err != nil || len(pins.unpinned) != 0 {
			t.Errorf("err = %v unpinned = %v", err, pins.unpinned)
		}
	})
	t.Run("nil Pins and a failing Pins are both fine", func(t *testing.T) {
		t.Parallel()
		repo := &fakeRepo{del: DeleteResult{Outcome: Written, Deleted: true}}
		for _, pins := range []Pins{nil, &fakePins{err: errors.New("busy")}} {
			s, _ := newTestService(repo, pins, oldAccount())
			if err := s.DeleteList(context.Background(), testUID, testKey, testListID); err != nil {
				t.Errorf("pins %T: err = %v", pins, err)
			}
		}
	})
	t.Run("repository error is mapped", func(t *testing.T) {
		t.Parallel()
		s, _ := newTestService(&fakeRepo{err: ErrKeyReused}, nil, oldAccount())
		wantAPI(t, s.DeleteList(context.Background(), testUID, testKey, testListID), connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
	})
}

func TestIsNew(t *testing.T) {
	t.Parallel()
	s, _ := newTestService(&fakeRepo{}, nil, oldAccount())
	tests := []struct {
		name    string
		created time.Time
		want    bool
	}{
		{"an hour old", testNow.Add(-time.Hour), true},
		{"just inside the window", testNow.Add(-24*time.Hour + time.Second), true},
		{"exactly at the window", testNow.Add(-24 * time.Hour), false},
		{"old", testNow.Add(-30 * 24 * time.Hour), false},
		{"unknown creation time is not new", time.Time{}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := s.isNew(identity.Profile{CreatedAt: tt.created}); got != tt.want {
				t.Errorf("isNew = %v, want %v", got, tt.want)
			}
		})
	}
}
