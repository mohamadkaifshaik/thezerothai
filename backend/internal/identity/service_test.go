package identity

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// fakeRepo is an in-memory Repo for service-layer unit tests (testing-strategy skill: "table-driven,
// fakes"). No Firestore, no emulator.
type fakeRepo struct {
	profiles  map[string]Profile
	handles   map[string]string // handleLower -> uid
	unread    map[string]int64
	createErr error
	changeErr error

	createCalls      int
	updateCalls      int
	changeCalls      int
	getProfileCalls  int
	getProfilesCalls int
	resolveCalls     int

	resolveManyCalls int
	resolveManyArgs  [][]string
	resolveManyErr   error
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{
		profiles: map[string]Profile{},
		handles:  map[string]string{},
		unread:   map[string]int64{},
	}
}

func (f *fakeRepo) GetProfile(_ context.Context, uid string) (Profile, error) {
	f.getProfileCalls++
	p, ok := f.profiles[uid]
	if !ok {
		return Profile{}, ErrNotFound
	}
	return p, nil
}

func (f *fakeRepo) ResolveHandle(_ context.Context, handleLower string) (string, error) {
	f.resolveCalls++
	uid, ok := f.handles[handleLower]
	if !ok {
		return "", ErrNotFound
	}
	return uid, nil
}

// ResolveHandles mirrors FirestoreRepo: one call (one GetAll), reads = len(handleLowers), misses absent.
func (f *fakeRepo) ResolveHandles(ctx context.Context, handleLowers []string) (map[string]string, error) {
	f.resolveManyCalls++
	f.resolveManyArgs = append(f.resolveManyArgs, append([]string(nil), handleLowers...))
	budget.FromContext(ctx).AddReads(int64(len(handleLowers)))
	if f.resolveManyErr != nil {
		return nil, f.resolveManyErr
	}
	out := map[string]string{}
	for _, h := range handleLowers {
		if uid, ok := f.handles[h]; ok {
			out[h] = uid
		}
	}
	return out, nil
}

func (f *fakeRepo) CreateProfile(ctx context.Context, uid, handle, handleLower, displayName string, now time.Time, authorize func(context.Context) error) (Profile, bool, error) {
	f.createCalls++
	if f.createErr != nil {
		return Profile{}, false, f.createErr
	}
	if existing, ok := f.profiles[uid]; ok {
		return existing, true, nil
	}
	if authorize != nil {
		if err := authorize(ctx); err != nil {
			return Profile{}, false, err
		}
	}
	if _, taken := f.handles[handleLower]; taken {
		return Profile{}, false, ErrHandleTaken
	}
	p := Profile{
		UserID: uid, Handle: handle, HandleLower: handleLower, DisplayName: displayName,
		Status: AccountStatusActive, CreatedAt: now, UpdatedAt: now,
	}
	f.profiles[uid] = p
	f.handles[handleLower] = uid
	return p, false, nil
}

func (f *fakeRepo) UpdateProfile(_ context.Context, uid string, mutate func(*Profile)) (Profile, error) {
	f.updateCalls++
	p, ok := f.profiles[uid]
	if !ok {
		return Profile{}, ErrNotFound
	}
	mutate(&p)
	f.profiles[uid] = p
	return p, nil
}

// ChangeHandle mirrors FirestoreRepo.ChangeHandle's decision table (api.go Repo doc comment, M4): every
// check runs against f.profiles[uid] (this fake's stand-in for "the doc read fresh inside the
// transaction"), never anything the service layer might have cached, since service.go no longer holds
// its own pre-transaction copy at all.
func (f *fakeRepo) ChangeHandle(_ context.Context, uid, newHandle, newHandleLower string, now time.Time, cooldown time.Duration) (Profile, string, error) {
	f.changeCalls++
	if f.changeErr != nil {
		return Profile{}, "", f.changeErr
	}
	p, ok := f.profiles[uid]
	if !ok {
		return Profile{}, "", ErrNotFound
	}

	if p.HandleLower == newHandleLower {
		if p.Handle == newHandle {
			return p, "", nil // true no-op
		}
		p.Handle = newHandle
		p.SnapshotVersion++
		p.UpdatedAt = now
		f.profiles[uid] = p
		return p, "", nil // case-only rename
	}

	if !p.HandleChangedAt.IsZero() {
		if elapsed := now.Sub(p.HandleChangedAt); elapsed < cooldown {
			return Profile{}, "", &ErrHandleChangeCooldown{RetryAfter: cooldown - elapsed}
		}
	}

	if ownerUID, taken := f.handles[newHandleLower]; taken && ownerUID != uid {
		return Profile{}, "", ErrHandleTaken
	}

	oldLower := p.HandleLower
	delete(f.handles, oldLower)
	p.Handle = newHandle
	p.HandleLower = newHandleLower
	p.HandleChangedAt = now
	p.SnapshotVersion++
	p.UpdatedAt = now
	f.profiles[uid] = p
	f.handles[newHandleLower] = uid
	return p, oldLower, nil
}

func (f *fakeRepo) UnreadNotificationCount(_ context.Context, uid string, _ time.Time) (int64, error) {
	return f.unread[uid], nil
}

func (f *fakeRepo) GetProfiles(_ context.Context, uids []string) (map[string]Profile, error) {
	f.getProfilesCalls++
	out := make(map[string]Profile, len(uids))
	for _, uid := range uids {
		if p, ok := f.profiles[uid]; ok {
			out[uid] = p
		}
	}
	return out, nil
}

func newTestService(repo Repo) *service {
	s := New(repo, NewCache(time.Minute), 7*24*time.Hour).(*service)
	return s
}

func wantValidationField(t *testing.T, err error, field string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error is %T, want *apierr.Error", err)
	}
	if ae.Code != connect.CodeInvalidArgument {
		t.Fatalf("Code = %v, want InvalidArgument", ae.Code)
	}
	if ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION {
		t.Fatalf("Reason = %v, want VALIDATION", ae.Reason)
	}
	if field != "" && ae.Metadata["field"] != field {
		t.Fatalf("Metadata[field] = %q, want %q", ae.Metadata["field"], field)
	}
}

const validKey = "0123456789abcdef"

func TestCreateProfile_Validation(t *testing.T) {
	tests := []struct {
		name        string
		key         string
		handle      string
		displayName string
		field       string
	}{
		{"bad idempotency key", "short", "alice", "Alice", "idempotency_key"},
		{"handle too short", validKey, "ab", "Alice", "handle"},
		{"handle bad chars", validKey, "al!ce", "Alice", "handle"},
		{"reserved handle", validKey, "admin", "Alice", "handle"},
		{"empty display name", validKey, "alice", "", "display_name"},
		{"display name too long", validKey, "alice", string(make([]byte, 51)), "display_name"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc := newTestService(newFakeRepo())
			_, err := svc.CreateProfile(context.Background(), "uid-1", tt.key, tt.handle, tt.displayName)
			wantValidationField(t, err, tt.field)
		})
	}
}

func TestCreateProfile_Success(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	p, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A.")
	if err != nil {
		t.Fatalf("CreateProfile() error = %v", err)
	}
	if p.UserID != "uid-1" || p.HandleLower != "alice" {
		t.Fatalf("unexpected profile: %+v", p)
	}
	// The cache should now serve this profile without hitting the repo again.
	if cached, ok := svc.cache.GetProfile("uid-1"); !ok || cached.Handle != "Alice" {
		t.Fatal("expected CreateProfile to populate the cache")
	}
}

func TestCreateProfile_HandleTaken(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("first CreateProfile: %v", err)
	}
	_, err := svc.CreateProfile(context.Background(), "uid-2", validKey, "Alice", "Someone Else")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_HANDLE_TAKEN {
		t.Fatalf("expected HANDLE_TAKEN, got %v", err)
	}
}

func TestCheckHandleAvailability(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	tests := []struct {
		name          string
		handle        string
		wantAvailable bool
		wantReason    string
	}{
		{"invalid format", "a!", false, "invalid_format"},
		{"reserved", "admin", false, "reserved"},
		{"taken", "alice", false, ""},
		{"taken different case", "ALICE", false, ""},
		{"available", "bob", true, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			available, reason, err := svc.CheckHandleAvailability(context.Background(), tt.handle)
			if err != nil {
				t.Fatalf("CheckHandleAvailability() error = %v", err)
			}
			if available != tt.wantAvailable || reason != tt.wantReason {
				t.Errorf("got (%v, %q), want (%v, %q)", available, reason, tt.wantAvailable, tt.wantReason)
			}
		})
	}
}

func TestCheckHandleAvailability_UsesCacheWithoutRepoCall(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	svc.cache.SetProfile(Profile{UserID: "uid-1", Handle: "Alice", HandleLower: "alice"})

	available, _, err := svc.CheckHandleAvailability(context.Background(), "alice")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if available {
		t.Fatal("expected cached handle to be reported as taken")
	}
}

func TestGetMe(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	repo.unread["uid-1"] = 3

	result, err := svc.GetMe(context.Background(), "uid-1")
	if err != nil {
		t.Fatalf("GetMe() error = %v", err)
	}
	if result.UnreadNotificationCount != 3 {
		t.Errorf("UnreadNotificationCount = %d, want 3", result.UnreadNotificationCount)
	}

	// Change the underlying count; cached value should still be served (30s TTL).
	repo.unread["uid-1"] = 99
	result2, err := svc.GetMe(context.Background(), "uid-1")
	if err != nil {
		t.Fatalf("GetMe() error = %v", err)
	}
	if result2.UnreadNotificationCount != 3 {
		t.Errorf("UnreadNotificationCount = %d, want 3 (cached)", result2.UnreadNotificationCount)
	}
}

func TestGetMe_NotFound(t *testing.T) {
	svc := newTestService(newFakeRepo())
	_, err := svc.GetMe(context.Background(), "ghost")
	assertNotFound(t, err)
}

func TestGetProfile_ByUserIDAndHandle(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	byID, err := svc.GetProfile(context.Background(), "caller", ProfileTarget{UserID: "uid-1"})
	if err != nil || byID.UserID != "uid-1" {
		t.Fatalf("GetProfile by user_id: %+v, err=%v", byID, err)
	}

	byHandle, err := svc.GetProfile(context.Background(), "caller", ProfileTarget{Handle: "ALICE"})
	if err != nil || byHandle.UserID != "uid-1" {
		t.Fatalf("GetProfile by handle: %+v, err=%v", byHandle, err)
	}
}

func TestGetProfile_MissingTarget(t *testing.T) {
	svc := newTestService(newFakeRepo())
	_, err := svc.GetProfile(context.Background(), "caller", ProfileTarget{})
	wantValidationField(t, err, "target")
}

func TestGetProfile_NotFound(t *testing.T) {
	svc := newTestService(newFakeRepo())
	_, err := svc.GetProfile(context.Background(), "caller", ProfileTarget{Handle: "ghost"})
	assertNotFound(t, err)
}

// fakeBlockChecker is a table-driven-friendly BlockChecker fake (ADR-0008 T6): the ONLY fake in
// service_test.go (testing-strategy skill: table-driven, fakes) exercising the GetProfile block-enforcement
// path independent of graph.Service, whose emulator-backed transactions are exercised separately.
type fakeBlockChecker struct {
	blockedBy map[string]map[string]bool // viewer -> set of targets that blocked viewer
	err       error
	calls     int
}

func (f *fakeBlockChecker) IsBlockedBy(_ context.Context, viewerUID, targetUID string) (bool, error) {
	f.calls++
	if f.err != nil {
		return false, f.err
	}
	return f.blockedBy[viewerUID][targetUID], nil
}

// TestGetProfile_BlockedByTarget_NotFound (ADR-0008 D9): byte-identical NOT_FOUND to a missing profile.
func TestGetProfile_BlockedByTarget_NotFound(t *testing.T) {
	repo := newFakeRepo()
	if _, _, err := repo.CreateProfile(context.Background(), "uid-b", "Bob", "bob", "Bob", time.Now(), nil); err != nil {
		t.Fatalf("seed: %v", err)
	}
	bc := &fakeBlockChecker{blockedBy: map[string]map[string]bool{"uid-a": {"uid-b": true}}}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithBlockChecker(bc)).(*service)

	gotErr := func() error {
		_, err := svc.GetProfile(context.Background(), "uid-a", ProfileTarget{UserID: "uid-b"})
		return err
	}()
	wantErr := notFoundErr()
	assertNotFound(t, gotErr)
	if gotErr.Error() != wantErr.Error() {
		t.Errorf("GetProfile(blocked) error = %q, want byte-identical to the missing-profile error %q", gotErr, wantErr)
	}
	if bc.calls != 1 {
		t.Errorf("IsBlockedBy calls = %d, want 1", bc.calls)
	}
}

// TestGetProfile_CallerBlocksTarget_StillVisible (ADR-0008 D9): "the caller can still view a target they
// blocked, so they can unblock" — IsBlockedBy is asked "did the TARGET block the VIEWER", never the reverse.
func TestGetProfile_CallerBlocksTarget_StillVisible(t *testing.T) {
	repo := newFakeRepo()
	if _, _, err := repo.CreateProfile(context.Background(), "uid-b", "Bob", "bob", "Bob", time.Now(), nil); err != nil {
		t.Fatalf("seed: %v", err)
	}
	// uid-b never blocked uid-a; only uid-a -> uid-b's block would live in graph.blocked, which this
	// BlockChecker fake has no notion of (Block enforcement here is one-directional by design, ADR-0008 D9).
	bc := &fakeBlockChecker{blockedBy: map[string]map[string]bool{}}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithBlockChecker(bc)).(*service)

	p, err := svc.GetProfile(context.Background(), "uid-a", ProfileTarget{UserID: "uid-b"})
	if err != nil {
		t.Fatalf("GetProfile() error = %v, want the profile to still be visible", err)
	}
	if p.UserID != "uid-b" {
		t.Fatalf("unexpected profile: %+v", p)
	}
}

func TestGetProfile_NilBlockChecker_NoOp(t *testing.T) {
	repo := newFakeRepo()
	if _, _, err := repo.CreateProfile(context.Background(), "uid-b", "Bob", "bob", "Bob", time.Now(), nil); err != nil {
		t.Fatalf("seed: %v", err)
	}
	svc := newTestService(repo) // no WithBlockChecker
	if _, err := svc.GetProfile(context.Background(), "uid-a", ProfileTarget{UserID: "uid-b"}); err != nil {
		t.Fatalf("GetProfile() error = %v, want no block enforcement when unwired", err)
	}
}

func TestGetProfile_OwnProfile_SkipsBlockCheck(t *testing.T) {
	repo := newFakeRepo()
	if _, _, err := repo.CreateProfile(context.Background(), "uid-a", "Alice", "alice", "Alice", time.Now(), nil); err != nil {
		t.Fatalf("seed: %v", err)
	}
	bc := &fakeBlockChecker{blockedBy: map[string]map[string]bool{"uid-a": {"uid-a": true}}}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithBlockChecker(bc)).(*service)
	if _, err := svc.GetProfile(context.Background(), "uid-a", ProfileTarget{UserID: "uid-a"}); err != nil {
		t.Fatalf("GetProfile(self) error = %v", err)
	}
	if bc.calls != 0 {
		t.Errorf("IsBlockedBy calls = %d, want 0 for a caller viewing their own profile", bc.calls)
	}
}

// fakeFeatureFlags is a minimal FeatureFlags fake for GetMe tests (ADR-0008 T3/D6).
type fakeFeatureFlags struct{ enabled []string }

func (f *fakeFeatureFlags) EnabledFeatures(string) []string { return f.enabled }

func TestGetMe_EnabledFeatures(t *testing.T) {
	repo := newFakeRepo()
	if _, _, err := repo.CreateProfile(context.Background(), "uid-1", "Alice", "alice", "Alice", time.Now(), nil); err != nil {
		t.Fatalf("seed: %v", err)
	}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithFeatureFlags(&fakeFeatureFlags{enabled: []string{"graph"}})).(*service)
	res, err := svc.GetMe(context.Background(), "uid-1")
	if err != nil {
		t.Fatalf("GetMe() error = %v", err)
	}
	if len(res.EnabledFeatures) != 1 || res.EnabledFeatures[0] != "graph" {
		t.Errorf("EnabledFeatures = %v, want [graph]", res.EnabledFeatures)
	}
}

func TestGetMe_NilFeatureFlags_NoOp(t *testing.T) {
	repo := newFakeRepo()
	if _, _, err := repo.CreateProfile(context.Background(), "uid-1", "Alice", "alice", "Alice", time.Now(), nil); err != nil {
		t.Fatalf("seed: %v", err)
	}
	svc := newTestService(repo)
	res, err := svc.GetMe(context.Background(), "uid-1")
	if err != nil {
		t.Fatalf("GetMe() error = %v", err)
	}
	if len(res.EnabledFeatures) != 0 {
		t.Errorf("EnabledFeatures = %v, want empty", res.EnabledFeatures)
	}
}

// TestGetProfiles_CacheFirstThenBatch (ADR-0008 T6): cached hits cost 0 repo calls; misses go through one
// GetProfiles (GetAll) call; missing/non-ACTIVE ids are silently dropped.
func TestGetProfiles_CacheFirstThenBatch(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	ctx := context.Background()
	for _, uid := range []string{"uid-a", "uid-b"} {
		if _, err := svc.CreateProfile(ctx, uid, validKey, "handle"+uid[len(uid)-1:], "Name"); err != nil {
			t.Fatalf("CreateProfile(%s): %v", uid, err)
		}
	}
	// uid-c exists in the repo but was never fetched through svc, so it's a cache miss; uid-ghost doesn't
	// exist at all and must be silently dropped. Seeded directly on the repo (bypassing handle validation).
	if _, _, err := repo.CreateProfile(ctx, "uid-c", "handlec", "handlec", "Name", time.Now(), nil); err != nil {
		t.Fatalf("seed uid-c: %v", err)
	}

	before := repo.getProfilesCalls
	got, err := svc.GetProfiles(ctx, []string{"uid-a", "uid-b", "uid-c", "uid-ghost"})
	if err != nil {
		t.Fatalf("GetProfiles() error = %v", err)
	}
	if repo.getProfilesCalls != before+1 {
		t.Errorf("getProfilesCalls = %d, want %d (one batched call for the misses)", repo.getProfilesCalls, before+1)
	}
	if len(got) != 3 {
		t.Fatalf("GetProfiles() = %d entries, want 3 (uid-ghost dropped): %+v", len(got), got)
	}
	for _, uid := range []string{"uid-a", "uid-b", "uid-c"} {
		if _, ok := got[uid]; !ok {
			t.Errorf("expected %s in result", uid)
		}
	}

	// A second call for the same ids now costs 0 repo calls (uid-a/uid-b were already cached; uid-c was
	// cached as a side effect of the first GetProfiles call).
	before2 := repo.getProfilesCalls
	if _, err := svc.GetProfiles(ctx, []string{"uid-a", "uid-b", "uid-c"}); err != nil {
		t.Fatalf("GetProfiles() error = %v", err)
	}
	if repo.getProfilesCalls != before2 {
		t.Errorf("getProfilesCalls = %d, want %d (fully cached)", repo.getProfilesCalls, before2)
	}
}

func TestForget_EvictsProfileAndUnreadCount(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	ctx := context.Background()
	if _, err := svc.CreateProfile(ctx, "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	if _, err := svc.GetMe(ctx, "uid-1"); err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if _, ok := svc.cache.GetProfile("uid-1"); !ok {
		t.Fatal("expected uid-1 to be cached before Forget")
	}
	svc.Forget("uid-1")
	if _, ok := svc.cache.GetProfile("uid-1"); ok {
		t.Error("expected Forget to evict the cached profile")
	}
	if _, ok := svc.cache.GetUnreadCount("uid-1"); ok {
		t.Error("expected Forget to evict the cached unread count")
	}
}

// TestGetProfile_InvalidUserID (minor fix, phase0 code review): user_id is caller-supplied and must be
// validated (length/charset) like every other input, not passed straight to a Firestore lookup.
func TestGetProfile_InvalidUserID(t *testing.T) {
	tests := []struct {
		name   string
		userID string
	}{
		{"too long", string(make([]byte, 129))},
		{"bad chars", "uid with spaces"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// string(make([]byte, 129)) is 129 NUL bytes, which also fails the charset check; that's fine,
			// this test only asserts the RPC rejects it as a validation error on the right field.
			svc := newTestService(newFakeRepo())
			_, err := svc.GetProfile(context.Background(), "caller", ProfileTarget{UserID: tt.userID})
			wantValidationField(t, err, "user_id")
		})
	}
}

func TestUpdateProfile_Validation(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	longBio := string(make([]byte, 161))
	badDisplay := ""
	avatarID := "some-media-id"

	tests := []struct {
		name   string
		params UpdateProfileParams
		field  string
	}{
		{"bad idempotency key", UpdateProfileParams{IdempotencyKey: "x"}, "idempotency_key"},
		{"bad display name", UpdateProfileParams{IdempotencyKey: validKey, DisplayName: &badDisplay}, "display_name"},
		{"bio too long", UpdateProfileParams{IdempotencyKey: validKey, Bio: &longBio}, "bio"},
		{"avatar media not ready", UpdateProfileParams{IdempotencyKey: validKey, AvatarMediaID: &avatarID}, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := svc.UpdateProfile(context.Background(), "uid-1", tt.params)
			if err == nil {
				t.Fatal("expected an error")
			}
			if tt.field != "" {
				wantValidationField(t, err, tt.field)
			}
		})
	}
}

func TestUpdateProfile_Success(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	newName := "Alice B."
	newBio := "hello world"
	isPrivate := false // ADR-0008 D1 (L9): true is rejected; false stays accepted.

	got, err := svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{
		IdempotencyKey: validKey, DisplayName: &newName, Bio: &newBio, IsPrivate: &isPrivate,
	})
	if err != nil {
		t.Fatalf("UpdateProfile() error = %v", err)
	}
	if got.DisplayName != newName || got.Bio != newBio || got.IsPrivate {
		t.Fatalf("unexpected profile: %+v", got)
	}
	if cached, _ := svc.cache.GetProfile("uid-1"); cached.DisplayName != newName {
		t.Fatal("expected UpdateProfile to refresh the cache from the write, not a re-read")
	}
}

// TestUpdateProfile_RejectsIsPrivateTrue closes L9 (ADR-0008 D1): private accounts are deferred, so
// is_private=true is rejected with VALIDATION and 0 writes.
func TestUpdateProfile_RejectsIsPrivateTrue(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	before := repo.updateCalls
	isPrivate := true
	_, err := svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{IdempotencyKey: validKey, IsPrivate: &isPrivate})
	wantValidationField(t, err, "is_private")
	if repo.updateCalls != before {
		t.Errorf("updateCalls = %d, want %d (0 writes)", repo.updateCalls, before)
	}
}

func TestUpdateProfile_RemoveAvatar(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	repo.profiles["uid-1"] = func() Profile {
		p := repo.profiles["uid-1"]
		p.AvatarURL, p.AvatarThumbURL = "https://x/full.jpg", "https://x/thumb.jpg"
		return p
	}()
	empty := ""
	got, err := svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{IdempotencyKey: validKey, AvatarMediaID: &empty})
	if err != nil {
		t.Fatalf("UpdateProfile() error = %v", err)
	}
	if got.AvatarURL != "" || got.AvatarThumbURL != "" {
		t.Fatalf("expected avatar to be cleared, got %+v", got)
	}
}

func TestUpdateProfile_NotFound(t *testing.T) {
	svc := newTestService(newFakeRepo())
	_, err := svc.UpdateProfile(context.Background(), "ghost", UpdateProfileParams{IdempotencyKey: validKey})
	assertNotFound(t, err)
}

func TestChangeHandle_NoOpForSameHandle(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	got, err := svc.ChangeHandle(context.Background(), "uid-1", validKey, "Alice")
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	if got.HandleLower != "alice" || got.Handle != "Alice" {
		t.Fatalf("unexpected profile: %+v", got)
	}
	// A true no-op must never touch the handles map (no free-then-reclaim of the caller's own handle).
	if len(repo.handles) != 1 {
		t.Errorf("handles = %v, want exactly the original entry untouched", repo.handles)
	}
}

// TestChangeHandle_CaseOnlyRename (M4 minor: "case-only rename no-op"): requesting the same handle with
// different casing (e.g. "alice" -> "Alice") must actually update the display form, not be dropped as an
// identical no-op — only the handleLower key is the uniqueness/no-op boundary.
func TestChangeHandle_CaseOnlyRename(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	got, err := svc.ChangeHandle(context.Background(), "uid-1", validKey, "Alice")
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	if got.Handle != "Alice" || got.HandleLower != "alice" {
		t.Fatalf("unexpected profile: %+v", got)
	}
	if len(repo.handles) != 1 {
		t.Errorf("handles = %v, want exactly the original entry untouched (case-only rename doesn't free/reclaim)", repo.handles)
	}
}

// TestChangeHandle_IdempotentRetry_OwnedHandle (M4): handles/{new} already existing and already owned by
// the caller (e.g. a retried request whose earlier attempt got far enough to write it) must succeed, not
// HANDLE_TAKEN.
func TestChangeHandle_IdempotentRetry_OwnedHandle(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	// Simulate a prior attempt that reserved the new handle for uid-1 without the user doc reflecting it
	// yet (the scenario FirestoreRepo.ChangeHandle's handleOwnedByCaller branch guards against).
	repo.handles["bob"] = "uid-1"

	got, err := svc.ChangeHandle(context.Background(), "uid-1", validKey, "bob")
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v, want success (idempotent retry)", err)
	}
	if got.HandleLower != "bob" {
		t.Fatalf("unexpected profile: %+v", got)
	}
	if _, aliceStillTaken := repo.handles["alice"]; aliceStillTaken {
		t.Error("expected the old handle 'alice' to be freed")
	}
}

func TestChangeHandle_CooldownActive(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	now := time.Now()
	svc.now = func() time.Time { return now }
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	p := repo.profiles["uid-1"]
	p.HandleChangedAt = now.Add(-24 * time.Hour) // changed 1 day ago; cooldown is 7 days
	repo.profiles["uid-1"] = p

	_, err := svc.ChangeHandle(context.Background(), "uid-1", validKey, "newhandle")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED {
		t.Fatalf("expected LIMIT_REACHED, got %v", err)
	}
	if ae.RetryAfter <= 0 {
		t.Error("expected a positive retry_after")
	}
}

func TestChangeHandle_CooldownElapsed(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	now := time.Now()
	svc.now = func() time.Time { return now }
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	p := repo.profiles["uid-1"]
	p.HandleChangedAt = now.Add(-8 * 24 * time.Hour)
	repo.profiles["uid-1"] = p

	got, err := svc.ChangeHandle(context.Background(), "uid-1", validKey, "newhandle")
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	if got.HandleLower != "newhandle" {
		t.Fatalf("unexpected profile: %+v", got)
	}
	if _, stillCached := svc.cache.GetHandleUID("alice"); stillCached {
		t.Error("expected the old handle to be invalidated from cache")
	}
}

func TestChangeHandle_Validation(t *testing.T) {
	svc := newTestService(newFakeRepo())
	_, err := svc.ChangeHandle(context.Background(), "uid-1", "bad", "newhandle")
	wantValidationField(t, err, "idempotency_key")

	_, err = svc.ChangeHandle(context.Background(), "uid-1", validKey, "a!")
	wantValidationField(t, err, "new_handle")
}

func TestChangeHandle_HandleTaken(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	if _, err := svc.CreateProfile(context.Background(), "uid-2", validKey, "Bob", "Bob B."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	_, err := svc.ChangeHandle(context.Background(), "uid-1", validKey, "bob")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_HANDLE_TAKEN {
		t.Fatalf("expected HANDLE_TAKEN, got %v", err)
	}
}

func TestAccountStatus(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	exists, status, err := svc.AccountStatus(context.Background(), "uid-1")
	if err != nil || !exists || status != AccountStatusActive {
		t.Fatalf("got (%v, %v, %v)", exists, status, err)
	}

	exists, status, err = svc.AccountStatus(context.Background(), "ghost")
	if err != nil || exists || status != AccountStatusUnspecified {
		t.Fatalf("got (%v, %v, %v), want (false, Unspecified, nil)", exists, status, err)
	}
}

// TestAccountStatus_NegativeCacheAvoidsRepeatReads (M1): a caller with no profile yet must not cost a
// repo read on every single AccountStatus check (authn.AccountStatusInterceptor calls this on every
// non-exempt RPC) — the ~10s negative cache means only the first miss touches the repo.
func TestAccountStatus_NegativeCacheAvoidsRepeatReads(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)

	for i := 0; i < 3; i++ {
		exists, status, err := svc.AccountStatus(context.Background(), "ghost")
		if err != nil || exists || status != AccountStatusUnspecified {
			t.Fatalf("call %d: got (%v, %v, %v), want (false, Unspecified, nil)", i, exists, status, err)
		}
	}
	if repo.getProfileCalls != 1 {
		t.Errorf("repo.GetProfile called %d times, want exactly 1 (negative cache should absorb the rest)", repo.getProfileCalls)
	}

	// CreateProfile must overwrite the negative cache entry (M1) so the caller is immediately recognized.
	if _, err := svc.CreateProfile(context.Background(), "ghost", validKey, "ghost", "Ghost"); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	exists, status, err := svc.AccountStatus(context.Background(), "ghost")
	if err != nil || !exists || status != AccountStatusActive {
		t.Fatalf("after CreateProfile: got (%v, %v, %v), want (true, Active, nil)", exists, status, err)
	}
	if repo.getProfileCalls != 1 {
		t.Errorf("repo.GetProfile called %d times after CreateProfile, want still 1 (served from the positive cache CreateProfile just warmed)", repo.getProfileCalls)
	}
}

func assertNotFound(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error is %T, want *apierr.Error", err)
	}
	if ae.Code != connect.CodeNotFound {
		t.Fatalf("Code = %v, want NotFound", ae.Code)
	}
}

// TestLookupProfiles_MissingVsInactive (ADR-0008 T27): missing means "GetAll confirmed no doc"; SUSPENDED and
// DELETING are in neither found nor missing; a uid only negatively cached is not reported missing again.
func TestLookupProfiles_MissingVsInactive(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestService(repo)
	ctx := context.Background()
	repo.profiles["uid-a"] = Profile{UserID: "uid-a", Status: AccountStatusActive}
	repo.profiles["uid-s"] = Profile{UserID: "uid-s", Status: AccountStatusSuspended}
	repo.profiles["uid-d"] = Profile{UserID: "uid-d", Status: AccountStatusDeleting}

	found, missing, err := svc.LookupProfiles(ctx, []string{"uid-a", "uid-s", "uid-d", "uid-ghost"})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := found["uid-a"]; !ok || len(found) != 1 {
		t.Errorf("found = %v, want only uid-a", found)
	}
	if len(missing) != 1 || missing[0] != "uid-ghost" {
		t.Errorf("missing = %v, want [uid-ghost] (never SUSPENDED/DELETING)", missing)
	}
	if repo.getProfilesCalls != 1 {
		t.Errorf("getProfilesCalls = %d, want 1", repo.getProfilesCalls)
	}

	// Negative-cached now: no extra read, and not reported missing again (clean-up needs a fresh read).
	_, missing, err = svc.LookupProfiles(ctx, []string{"uid-ghost"})
	if err != nil || len(missing) != 0 || repo.getProfilesCalls != 1 {
		t.Errorf("second lookup: missing=%v err=%v calls=%d", missing, err, repo.getProfilesCalls)
	}
}

// TestProfileNotFoundError_IsTheGetProfileError: other modules reuse the exact NOT_FOUND bytes (ADR-0010 T9).
func TestProfileNotFoundError_IsTheGetProfileError(t *testing.T) {
	var a, b *apierr.Error
	if !errors.As(ProfileNotFoundError(), &a) || !errors.As(notFoundErr(), &b) || a.Code != b.Code || a.Reason != b.Reason || a.Message != b.Message {
		t.Fatalf("ProfileNotFoundError = %#v, want %#v", a, b)
	}
}
