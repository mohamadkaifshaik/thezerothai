package identity

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// W3-6 (ADR-0024 D1-D3, D9): UpdateProfile's banner, location, website and pinned_post_id, over fakeRepo. The
// Firestore-backed paths are covered by the integration tests (repo budgets) and the apiserver chain test.

const (
	extrasUID  = "uid-1"
	pinID      = "0000000000000000301"
	otherPinID = "0000000000000000302"
)

type fakeBanners struct {
	ref   BannerRef
	err   error
	calls []string
}

func (f *fakeBanners) ResolveBanner(_ context.Context, uid, mediaID string) (BannerRef, error) {
	f.calls = append(f.calls, uid+"/"+mediaID)
	return f.ref, f.err
}

type fakePins struct {
	can   bool
	err   error
	calls []string
}

func (f *fakePins) CanPin(_ context.Context, uid, postID string) (bool, error) {
	f.calls = append(f.calls, uid+"/"+postID)
	return f.can, f.err
}

func extrasRegistry(mode flags.Mode, allow ...string) *flags.Registry {
	set := map[string]struct{}{}
	for _, u := range allow {
		set[u] = struct{}{}
	}
	return flags.NewRegistry(flags.Spec{Name: ProfileExtrasFlag, Mode: mode, Allowlist: set})
}

type extrasEnv struct {
	repo    *fakeRepo
	svc     *service
	banners *fakeBanners
	pins    *fakePins
}

// newExtrasEnv builds a service with profile_extras on for extrasUID and a banner resolver and pin checker that accept.
func newExtrasEnv(t *testing.T, reg ExtrasFlags, opts ...Option) *extrasEnv {
	t.Helper()
	repo := newFakeRepo()
	banners := &fakeBanners{ref: BannerRef{URL: "https://m/b.webp", ThumbURL: "https://m/b_t.webp"}}
	pins := &fakePins{can: true}
	all := append([]Option{WithBannerResolver(banners), WithPinChecker(pins), WithExtrasFlags(reg)}, opts...)
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, all...).(*service)
	if _, err := svc.CreateProfile(context.Background(), extrasUID, validKey, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	return &extrasEnv{repo: repo, svc: svc, banners: banners, pins: pins}
}

func (e *extrasEnv) update(ctx context.Context, p UpdateProfileParams) (Profile, error) {
	p.IdempotencyKey = validKey
	return e.svc.UpdateProfile(ctx, extrasUID, p)
}

// wantAPIErr asserts err is an *apierr.Error with the code, reason and (when non-empty) metadata key=value.
func wantAPIErr(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, key, value string) *apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want an *apierr.Error", err)
	}
	if ae.Code != code || ae.Reason != reason {
		t.Fatalf("code=%v reason=%v, want %v / %v", ae.Code, ae.Reason, code, reason)
	}
	if key != "" && ae.Metadata[key] != value {
		t.Fatalf("metadata[%q] = %q, want %q (all: %v)", key, ae.Metadata[key], value, ae.Metadata)
	}
	return ae
}

func wantValidation(t *testing.T, err error, field string) *apierr.Error {
	t.Helper()
	return wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", field)
}

func TestUpdateProfile_Extras_FlagModes(t *testing.T) {
	// A uid the percent bucket puts inside and one outside a 50% cohort (the registry is the source of truth).
	var in, out string
	pct := flags.NewRegistry(flags.Spec{Name: ProfileExtrasFlag, Mode: flags.Percent, Percent: 50})
	for i := 0; i < 1000 && (in == "" || out == ""); i++ {
		u := "bucket-" + strings.Repeat("x", i%7) + string(rune('a'+i%26)) + string(rune('a'+i/26%26))
		if pct.Enabled(u, ProfileExtrasFlag) && in == "" {
			in = u
		} else if !pct.Enabled(u, ProfileExtrasFlag) && out == "" {
			out = u
		}
	}
	if in == "" || out == "" {
		t.Fatal("could not find uids on both sides of the percent bucket")
	}
	tests := []struct {
		name    string
		reg     ExtrasFlags
		uid     string
		wantOff bool
	}{
		{"off", extrasRegistry(flags.Off), extrasUID, true},
		{"allowlist, caller listed", extrasRegistry(flags.Allowlist, extrasUID), extrasUID, false},
		{"allowlist, caller not listed", extrasRegistry(flags.Allowlist, "someone-else"), extrasUID, true},
		{"allowlist, empty", extrasRegistry(flags.Allowlist), extrasUID, true},
		{"percent, caller in the cohort", pct, in, false},
		{"percent, caller outside the cohort", pct, out, true},
		{"on", extrasRegistry(flags.On), extrasUID, false},
		{"no flags wired", nil, extrasUID, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			var opts []Option
			if tt.reg != nil { // a nil *flags.Registry would not be a nil interface, so wire nothing instead
				opts = append(opts, WithExtrasFlags(tt.reg))
			}
			svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, opts...).(*service)
			if _, err := svc.CreateProfile(context.Background(), tt.uid, validKey, "Alice", "Alice A."); err != nil {
				t.Fatal(err)
			}
			got, err := svc.UpdateProfile(context.Background(), tt.uid, UpdateProfileParams{IdempotencyKey: validKey, Location: strp("Pune")})
			if tt.wantOff {
				_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "profile_extras")
				if repo.updateCalls != 0 || repo.getProfileCalls != 0 {
					t.Fatalf("a refused call touched the repo: updates=%d reads=%d", repo.updateCalls, repo.getProfileCalls)
				}
				return
			}
			if err != nil || got.Location != "Pune" || repo.updateCalls != 1 {
				t.Fatalf("UpdateProfile = %+v, %v (updates %d)", got, err, repo.updateCalls)
			}
		})
	}
}

func TestUpdateProfile_Extras_FlagOffGatesEveryFieldEvenAClear(t *testing.T) {
	empty := ""
	tests := []struct {
		name string
		p    UpdateProfileParams
	}{
		{"banner", UpdateProfileParams{BannerMediaID: strp("0000000000000000201")}},
		{"banner clear", UpdateProfileParams{BannerMediaID: &empty}},
		{"location", UpdateProfileParams{Location: strp("Pune")}},
		{"location clear", UpdateProfileParams{Location: &empty}},
		{"website", UpdateProfileParams{Website: strp("https://example.com")}},
		{"website clear", UpdateProfileParams{Website: &empty}},
		{"pin", UpdateProfileParams{PinnedPostID: strp(pinID)}},
		{"pin clear", UpdateProfileParams{PinnedPostID: &empty}},
		{"extras next to a name edit", UpdateProfileParams{DisplayName: strp("Alice B."), Location: strp("Pune")}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newExtrasEnv(t, extrasRegistry(flags.Off))
			_, err := e.update(context.Background(), tt.p)
			_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "profile_extras")
			if e.repo.updateCalls != 0 || len(e.banners.calls) != 0 || len(e.pins.calls) != 0 {
				t.Fatalf("0 reads and 0 writes expected: updates=%d banner calls=%v pin calls=%v", e.repo.updateCalls, e.banners.calls, e.pins.calls)
			}
			if e.repo.profiles[extrasUID].DisplayName != "Alice A." {
				t.Fatalf("a refused request changed the profile: %+v", e.repo.profiles[extrasUID])
			}
		})
	}
}

func TestUpdateProfile_Extras_NameAndBioPathIsUnchangedWhenFlagIsOff(t *testing.T) {
	e := newExtrasEnv(t, extrasRegistry(flags.Off))
	got, err := e.update(context.Background(), UpdateProfileParams{DisplayName: strp("Alice B."), Bio: strp(" hello ")})
	if err != nil || got.DisplayName != "Alice B." || got.Bio != "hello" || e.repo.updateCalls != 1 {
		t.Fatalf("UpdateProfile = %+v, %v (updates %d)", got, err, e.repo.updateCalls)
	}
}

func TestUpdateProfile_Location(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    string
		wantErr bool
	}{
		{"plain", "Pune, India", "Pune, India", false},
		{"trimmed", "  Pune  ", "Pune", false},
		{"NFC composes e + combining acute", "Cafe\u0301", "Caf\u00e9", false},
		{"clear", "", "", false},
		{"whitespace only clears", "   ", "", false},
		{"exactly 30 code points", strings.Repeat("a", 30), strings.Repeat("a", 30), false},
		{"30 code points of multi-byte text", strings.Repeat("日", 30), strings.Repeat("日", 30), false},
		{"31 code points", strings.Repeat("a", 31), "", true},
		{"newline", "Pune\nIndia", "", true},
		{"tab", "Pune\tIndia", "", true},
		{"NUL", "Pune\x00", "", true},
		{"right-to-left override", "Pune\u202eIndia", "", true},
		{"isolate", "Pune\u2066India", "", true},
		{"invalid UTF-8", "Pune\xff", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newExtrasEnv(t, extrasRegistry(flags.On))
			got, err := e.update(context.Background(), UpdateProfileParams{Location: &tt.in})
			if tt.wantErr {
				_ = wantValidation(t, err, "location")
				if e.repo.updateCalls != 0 {
					t.Fatalf("a rejected location wrote %d times", e.repo.updateCalls)
				}
				return
			}
			if err != nil || got.Location != tt.want || e.repo.profiles[extrasUID].Location != tt.want {
				t.Fatalf("UpdateProfile = %q, %v; want %q", got.Location, err, tt.want)
			}
		})
	}
}

func TestUpdateProfile_Website(t *testing.T) {
	long100 := "https://example.com/" + strings.Repeat("a", 80)
	tests := []struct {
		name    string
		in      string
		want    string
		wantErr bool
	}{
		{"https", "https://example.com", "https://example.com", false},
		{"http with path and query", "http://example.com/a/b?c=d#e", "http://example.com/a/b?c=d#e", false},
		{"only the scheme is lower-cased", "HTTPS://Example.COM/Path", "https://Example.COM/Path", false},
		{"port", "https://example.com:8443/x", "https://example.com:8443/x", false},
		{"trimmed", "  https://example.com  ", "https://example.com", false},
		{"non-ASCII host is stored as typed", "https://bücher.example", "https://bücher.example", false},
		{"clear", "", "", false},
		{"exactly 100 characters", long100, long100, false},
		{"101 characters", long100 + "b", "", true},
		{"no scheme", "example.com", "", true},
		{"scheme-relative", "//example.com", "", true},
		{"ftp", "ftp://example.com", "", true},
		{"javascript", "javascript:alert(1)", "", true},
		{"data", "data:text/html,hi", "", true},
		{"mailto (opaque)", "mailto:a@example.com", "", true},
		{"file", "file:///etc/passwd", "", true},
		{"empty host", "https:///path", "", true},
		{"scheme only", "https://", "", true},
		{"userinfo", "https://user@example.com", "", true},
		{"userinfo with password", "https://user:secret@example.com", "", true},
		{"space inside", "https://exa mple.com", "", true},
		{"newline", "https://example.com/\nx", "", true},
		{"tab", "https://example.com/\tx", "", true},
		{"right-to-left override", "https://example.com/\u202ex", "", true},
		{"invalid UTF-8", "https://example.com/\xff", "", true},
		{"unparsable", "https://exa%zzmple.com", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newExtrasEnv(t, extrasRegistry(flags.On))
			got, err := e.update(context.Background(), UpdateProfileParams{Website: &tt.in})
			if tt.wantErr {
				ae := wantValidation(t, err, "website")
				if strings.Contains(ae.Message, tt.in) && tt.in != "" {
					t.Fatalf("the error message echoes the value: %q", ae.Message)
				}
				if e.repo.updateCalls != 0 {
					t.Fatalf("a rejected website wrote %d times", e.repo.updateCalls)
				}
				return
			}
			if err != nil || got.Website != tt.want || e.repo.profiles[extrasUID].Website != tt.want {
				t.Fatalf("UpdateProfile = %q, %v; want %q", got.Website, err, tt.want)
			}
		})
	}
}

func TestUpdateProfile_Banner(t *testing.T) {
	const mediaID = "0000000000000000202"
	tests := []struct {
		name      string
		banners   *fakeBanners // nil: no resolver wired
		wantErr   bool
		wantCalls int
	}{
		{"resolved banner is copied into the profile", &fakeBanners{ref: BannerRef{URL: "https://m/b.webp", ThumbURL: "https://m/b_t.webp"}}, false, 1},
		{"not ready is MEDIA_NOT_READY", &fakeBanners{err: ErrBannerNotReady}, true, 1},
		{"a wrapped not-ready is still MEDIA_NOT_READY", &fakeBanners{err: errors.Join(errors.New("ctx"), ErrBannerNotReady)}, true, 1},
		{"no resolver wired is MEDIA_NOT_READY", nil, true, 0},
		{"infrastructure error is not an apierr", &fakeBanners{err: errors.New("firestore down")}, true, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			opts := []Option{WithExtrasFlags(extrasRegistry(flags.On))}
			if tt.banners != nil {
				opts = append(opts, WithBannerResolver(tt.banners))
			}
			svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, opts...).(*service)
			if _, err := svc.CreateProfile(context.Background(), extrasUID, validKey, "Alice", "Alice A."); err != nil {
				t.Fatal(err)
			}
			id := mediaID
			got, err := svc.UpdateProfile(context.Background(), extrasUID, UpdateProfileParams{IdempotencyKey: validKey, BannerMediaID: &id})
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.banners != nil && len(tt.banners.calls) != tt.wantCalls {
				t.Fatalf("resolver calls = %v", tt.banners.calls)
			}
			if tt.banners != nil && tt.wantCalls == 1 && tt.banners.calls[0] != extrasUID+"/"+mediaID {
				t.Fatalf("resolver asked %q: it must be asked for the caller's own uid", tt.banners.calls[0])
			}
			if err != nil {
				var ae *apierr.Error
				if errors.As(err, &ae) {
					if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
						t.Fatalf("code=%v reason=%v", ae.Code, ae.Reason)
					}
				} else if strings.Contains(err.Error(), "firestore down") && strings.Contains(err.Error(), extrasUID) {
					t.Fatalf("an infrastructure error leaks the uid: %v", err)
				}
				if repo.updateCalls != 0 {
					t.Fatalf("updateCalls = %d: a rejected banner must write nothing", repo.updateCalls)
				}
				return
			}
			if got.BannerURL != "https://m/b.webp" || got.BannerThumbURL != "https://m/b_t.webp" {
				t.Fatalf("profile banner = %q / %q", got.BannerURL, got.BannerThumbURL)
			}
		})
	}
}

func TestUpdateProfile_Banner_EmptyIdRemovesWithoutResolving(t *testing.T) {
	e := newExtrasEnv(t, extrasRegistry(flags.On))
	if _, err := e.update(context.Background(), UpdateProfileParams{BannerMediaID: strp("0000000000000000202")}); err != nil {
		t.Fatal(err)
	}
	e.banners.calls = nil
	got, err := e.update(context.Background(), UpdateProfileParams{BannerMediaID: strp("")})
	if err != nil || got.BannerURL != "" || got.BannerThumbURL != "" {
		t.Fatalf("UpdateProfile = %+v, %v", got, err)
	}
	if len(e.banners.calls) != 0 {
		t.Fatalf("removing a banner resolved %v", e.banners.calls)
	}
	if p := e.repo.profiles[extrasUID]; p.BannerURL != "" || p.BannerThumbURL != "" {
		t.Fatalf("stored banner after removal: %+v", p)
	}
}

func TestUpdateProfile_Pin(t *testing.T) {
	tests := []struct {
		name       string
		pins       *fakePins // nil: no checker wired
		id         string
		wantOK     bool
		wantCalls  int
		wantLogged string
	}{
		{"own visible post", &fakePins{can: true}, pinID, true, 1, "ok"},
		{"refused (not own, hidden, a REPOST, unknown: all the same false)", &fakePins{can: false}, pinID, false, 1, "rejected"},
		{"malformed id never reaches the checker", &fakePins{can: true}, "not-a-post-id", false, 0, "rejected"},
		{"short numeric id", &fakePins{can: true}, "123", false, 0, "rejected"},
		{"no checker wired", nil, pinID, false, 0, "rejected"},
	}
	var messages []string
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			opts := []Option{WithExtrasFlags(extrasRegistry(flags.On))}
			if tt.pins != nil {
				opts = append(opts, WithPinChecker(tt.pins))
			}
			svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, opts...).(*service)
			if _, err := svc.CreateProfile(context.Background(), extrasUID, validKey, "Alice", "Alice A."); err != nil {
				t.Fatal(err)
			}
			ctx, _ := logger.WithRequestInfo(context.Background())
			got, err := svc.UpdateProfile(ctx, extrasUID, UpdateProfileParams{IdempotencyKey: validKey, PinnedPostID: &tt.id})
			if v, _ := logger.RequestField(ctx, "pin_check"); v != tt.wantLogged {
				t.Fatalf("pin_check = %v, want %q", v, tt.wantLogged)
			}
			if tt.pins != nil && len(tt.pins.calls) != tt.wantCalls {
				t.Fatalf("checker calls = %v", tt.pins.calls)
			}
			if tt.wantCalls == 1 && tt.pins.calls[0] != extrasUID+"/"+tt.id {
				t.Fatalf("checker asked %q: it must be asked for the caller's own uid", tt.pins.calls[0])
			}
			if tt.wantOK {
				if err != nil || got.PinnedPostID != tt.id || repo.profiles[extrasUID].PinnedPostID != tt.id {
					t.Fatalf("UpdateProfile = %+v, %v", got, err)
				}
				return
			}
			ae := wantValidation(t, err, "pinned_post_id")
			messages = append(messages, ae.Message)
			if strings.Contains(ae.Message, tt.id) {
				t.Fatalf("the error message echoes the id: %q", ae.Message)
			}
			if repo.updateCalls != 0 {
				t.Fatalf("a rejected pin wrote %d times", repo.updateCalls)
			}
		})
	}
	for _, m := range messages[1:] {
		if m != messages[0] {
			t.Fatalf("pin rejections differ (an existence oracle): %q vs %q", m, messages[0])
		}
	}
}

func TestUpdateProfile_Pin_CheckerFailureIsNotAVerdict(t *testing.T) {
	e := newExtrasEnv(t, extrasRegistry(flags.On))
	e.pins.err = errors.New("firestore down for " + extrasUID)
	ctx, _ := logger.WithRequestInfo(context.Background())
	_, err := e.svc.UpdateProfile(ctx, extrasUID, UpdateProfileParams{IdempotencyKey: validKey, PinnedPostID: strp(pinID)})
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v: an infrastructure failure must not be a VALIDATION answer", err)
	}
	if strings.Contains(err.Error(), extrasUID) {
		t.Fatalf("the error leaks the uid: %v", err)
	}
	if v, ok := logger.RequestField(ctx, "pin_check"); ok {
		t.Fatalf("pin_check = %v: only ok and rejected are verdicts", v)
	}
	if e.repo.updateCalls != 0 {
		t.Fatal("a failed check must write nothing")
	}
}

func TestUpdateProfile_Pin_EmptyUnpinsWithoutChecking(t *testing.T) {
	e := newExtrasEnv(t, extrasRegistry(flags.On))
	if _, err := e.update(context.Background(), UpdateProfileParams{PinnedPostID: strp(pinID)}); err != nil {
		t.Fatal(err)
	}
	e.pins.calls = nil
	ctx, _ := logger.WithRequestInfo(context.Background())
	got, err := e.svc.UpdateProfile(ctx, extrasUID, UpdateProfileParams{IdempotencyKey: validKey, PinnedPostID: strp("")})
	if err != nil || got.PinnedPostID != "" || e.repo.profiles[extrasUID].PinnedPostID != "" {
		t.Fatalf("UpdateProfile = %+v, %v", got, err)
	}
	if len(e.pins.calls) != 0 {
		t.Fatalf("unpinning consulted the checker: %v", e.pins.calls)
	}
	if _, ok := logger.RequestField(ctx, "pin_check"); ok {
		t.Fatal("pin_check is only for a non-empty pinned_post_id")
	}
}

func TestUpdateProfile_Extras_AllFieldsInOneCall(t *testing.T) {
	e := newExtrasEnv(t, extrasRegistry(flags.On))
	got, err := e.update(context.Background(), UpdateProfileParams{
		BannerMediaID: strp("0000000000000000202"), Location: strp("Pune"), Website: strp("https://example.com"), PinnedPostID: strp(pinID),
	})
	if err != nil {
		t.Fatal(err)
	}
	want := Profile{BannerURL: "https://m/b.webp", BannerThumbURL: "https://m/b_t.webp", Location: "Pune", Website: "https://example.com", PinnedPostID: pinID}
	if got.BannerURL != want.BannerURL || got.BannerThumbURL != want.BannerThumbURL || got.Location != want.Location ||
		got.Website != want.Website || got.PinnedPostID != want.PinnedPostID {
		t.Fatalf("profile = %+v, want the extras of %+v", got, want)
	}
	if e.repo.updateCalls != 1 {
		t.Fatalf("updateCalls = %d, want exactly 1 write for the whole edit", e.repo.updateCalls)
	}
	// A later edit of one field leaves the others alone.
	got, err = e.update(context.Background(), UpdateProfileParams{Location: strp("Delhi")})
	if err != nil || got.Location != "Delhi" || got.Website != want.Website || got.PinnedPostID != pinID || got.BannerURL != want.BannerURL {
		t.Fatalf("second edit = %+v, %v", got, err)
	}
}

func TestUpdateProfile_Extras_NeverTouchTheAuthorSnapshot(t *testing.T) {
	repo := newFakeRepo()
	pub := &fakePublisher{log: &opLog{}}
	q := &fakeSnapQuota{}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour,
		WithProfileSnapshots(ProfileSnapshotDeps{Publisher: pub, Flags: fakeSnapFlags{on: true}, Quota: q, PerDay: 5}),
		WithBannerResolver(&fakeBanners{ref: BannerRef{URL: "https://m/b.webp", ThumbURL: "https://m/b_t.webp"}}),
		WithPinChecker(&fakePins{can: true}),
		WithExtrasFlags(extrasRegistry(flags.On)),
	).(*service)
	ctx := context.Background()
	if _, err := svc.CreateProfile(ctx, extrasUID, validKey, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	before := repo.profiles[extrasUID].SnapshotVersion
	got, err := svc.UpdateProfile(ctx, extrasUID, UpdateProfileParams{
		IdempotencyKey: validKey, BannerMediaID: strp("0000000000000000202"), Location: strp("Pune"),
		Website: strp("https://example.com"), PinnedPostID: strp(pinID),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.SnapshotVersion != before {
		t.Fatalf("snapshotVersion %d -> %d: the extras are not part of the author snapshot", before, got.SnapshotVersion)
	}
	if q.calls != 0 || len(pub.msgs) != 0 {
		t.Fatalf("snapshotEdits spent %d times, %d jobs published: the extras must trigger neither", q.calls, len(pub.msgs))
	}
}

func TestUpdateProfile_Extras_FieldsChangedLogsNamesNeverValues(t *testing.T) {
	e := newExtrasEnv(t, extrasRegistry(flags.On))
	ctx, _ := logger.WithRequestInfo(context.Background())
	_, err := e.svc.UpdateProfile(ctx, extrasUID, UpdateProfileParams{
		IdempotencyKey: validKey, DisplayName: strp("Secret Name"), Bio: strp("secret bio"), BannerMediaID: strp("0000000000000000202"),
		Location: strp("Secret City"), Website: strp("https://secret.example"), PinnedPostID: strp(pinID),
	})
	if err != nil {
		t.Fatal(err)
	}
	v, _ := logger.RequestField(ctx, "profile_fields_changed")
	got, _ := v.(string)
	if got != "display_name,bio,banner,location,website,pinned_post" {
		t.Fatalf("profile_fields_changed = %q", got)
	}
	for _, secret := range []string{"secret", "Secret", "0000000000000000202", pinID, "example"} {
		if strings.Contains(got, secret) {
			t.Fatalf("profile_fields_changed leaks a value: %q", got)
		}
	}

	// Setting the same values again changes nothing: no field is listed, and no field is reported for an unset one.
	ctx2, _ := logger.WithRequestInfo(context.Background())
	if _, err := e.svc.UpdateProfile(ctx2, extrasUID, UpdateProfileParams{
		IdempotencyKey: validKey, Location: strp("Secret City"), Website: strp("https://secret.example"), PinnedPostID: strp(pinID),
	}); err != nil {
		t.Fatal(err)
	}
	if v, ok := logger.RequestField(ctx2, "profile_fields_changed"); ok {
		t.Fatalf("profile_fields_changed = %v for an edit that changed nothing", v)
	}
}

// TestProfile_PinOmittedOnlyWhileGloballyOff covers every RPC that returns a Profile (the pin kill switch, ADR-0024 D3):
// with profile_extras off for everyone the pin is gone from the response while the banner, location and website stay;
// in a rollout (allowlist, even an empty one, or percent 0) and on the pin is returned to every viewer, listed or not.
func TestProfile_PinOmittedOnlyWhileGloballyOff(t *testing.T) {
	tests := []struct {
		name    string
		mode    flags.Mode
		wantPin bool
	}{
		{"off", flags.Off, false},
		{"allowlist, caller and viewers not listed", flags.Allowlist, true},
		{"percent 0", flags.Percent, true},
		{"on", flags.On, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Seed the stored profile directly: the flag is irrelevant to what is stored, only to what is shown.
			repo := newFakeRepo()
			svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithExtrasFlags(extrasRegistry(tt.mode))).(*service)
			ctx := context.Background()
			if _, err := svc.CreateProfile(ctx, extrasUID, validKey, "Alice", "Alice A."); err != nil {
				t.Fatal(err)
			}
			p := repo.profiles[extrasUID]
			p.BannerURL, p.BannerThumbURL, p.Location, p.Website, p.PinnedPostID = "https://m/b.webp", "https://m/b_t.webp", "Pune", "https://example.com", pinID
			repo.profiles[extrasUID] = p
			svc.Forget(extrasUID) // CreateProfile cached the unseeded profile

			check := func(rpc string, got Profile) {
				t.Helper()
				if (got.PinnedPostID != "") != tt.wantPin {
					t.Errorf("%s: pinned_post_id = %q, want present=%v", rpc, got.PinnedPostID, tt.wantPin)
				}
				if got.BannerURL != "https://m/b.webp" || got.BannerThumbURL != "https://m/b_t.webp" || got.Location != "Pune" || got.Website != "https://example.com" {
					t.Errorf("%s: banner, location and website must be returned whatever the flag says: %+v", rpc, got)
				}
			}
			me, err := svc.GetMe(ctx, extrasUID)
			if err != nil {
				t.Fatal(err)
			}
			check("GetMe", me.Profile)
			self, err := svc.GetProfile(ctx, extrasUID, ProfileTarget{UserID: extrasUID})
			if err != nil {
				t.Fatal(err)
			}
			check("GetProfile (self)", self)
			other, err := svc.GetProfile(ctx, "viewer", ProfileTarget{UserID: extrasUID})
			if err != nil {
				t.Fatal(err)
			}
			check("GetProfile (other viewer)", other)
			byHandle, err := svc.GetProfile(ctx, "viewer", ProfileTarget{Handle: "Alice"})
			if err != nil {
				t.Fatal(err)
			}
			check("GetProfile (by handle)", byHandle)
			replay, err := svc.CreateProfile(ctx, extrasUID, validKey, "Alice", "Alice A.")
			if err != nil {
				t.Fatal(err)
			}
			check("CreateProfile (replay)", replay)
			renamed, err := svc.ChangeHandle(ctx, extrasUID, validKey, "alice_new")
			if err != nil {
				t.Fatal(err)
			}
			check("ChangeHandle", renamed)
			updated, err := svc.UpdateProfile(ctx, extrasUID, UpdateProfileParams{IdempotencyKey: validKey, Bio: strp("hi")})
			if err != nil {
				t.Fatal(err)
			}
			check("UpdateProfile (a name or bio edit)", updated)
			// Nothing was erased on the way: the stored pin is still there for the day the flag comes back.
			if repo.profiles[extrasUID].PinnedPostID != pinID {
				t.Fatalf("stored pin = %q: hiding the pin must not erase it", repo.profiles[extrasUID].PinnedPostID)
			}
		})
	}
}

func TestProfile_PinHiddenWhenNoFlagsWired(t *testing.T) {
	repo := newFakeRepo()
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour).(*service)
	if _, err := svc.CreateProfile(context.Background(), extrasUID, validKey, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	p := repo.profiles[extrasUID]
	p.PinnedPostID = pinID
	repo.profiles[extrasUID] = p
	svc.Forget(extrasUID) // CreateProfile cached the unseeded profile
	got, err := svc.GetProfile(context.Background(), "viewer", ProfileTarget{UserID: extrasUID})
	if err != nil || got.PinnedPostID != "" {
		t.Fatalf("GetProfile = %+v, %v: with no flags wired profile_extras is off for everyone", got, err)
	}
}

func TestProfile_PinFlagFlipShowsStoredPinWithoutAWrite(t *testing.T) {
	// The cache holds the stored value, so a flag that comes back shows the pin again at once (same instance).
	repo := newFakeRepo()
	live := &flipFlags{}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithExtrasFlags(live)).(*service)
	if _, err := svc.CreateProfile(context.Background(), extrasUID, validKey, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	p := repo.profiles[extrasUID]
	p.PinnedPostID = pinID
	repo.profiles[extrasUID] = p
	svc.Forget(extrasUID) // CreateProfile cached the unseeded profile
	get := func() string {
		got, err := svc.GetProfile(context.Background(), "viewer", ProfileTarget{UserID: extrasUID})
		if err != nil {
			t.Fatal(err)
		}
		return got.PinnedPostID
	}
	live.off = true
	if got := get(); got != "" {
		t.Fatalf("pin while globally off = %q", got)
	}
	live.off = false
	if got := get(); got != pinID {
		t.Fatalf("pin after the flag came back = %q", got)
	}
	if repo.updateCalls != 0 {
		t.Fatal("flipping the flag wrote")
	}
}

type flipFlags struct{ off bool }

func (f *flipFlags) Enabled(_, _ string) bool  { return !f.off }
func (f *flipFlags) GloballyOff(_ string) bool { return f.off }

func TestNormalizeWebsite_KeepsEverythingButTheSchemeCase(t *testing.T) {
	got, ok := normalizeWebsite("HtTpS://Example.com/A?b=C")
	if !ok || got != "https://Example.com/A?b=C" {
		t.Fatalf("normalizeWebsite = %q, %v", got, ok)
	}
}
