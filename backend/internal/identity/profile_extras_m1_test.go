package identity

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-22 M-1 (ADR-0024 Amendment 1 A1 and A2), over fakeRepo: the kill switch hides the website next to the pin, and the
// exact string "" (a clear) is accepted from any authenticated caller whatever the flag. The Firestore-backed budgets
// (1 read / 1 write for a clear) are in profile_extras_integration_test.go and the wire contract in the apiserver chain
// test.

const (
	seedBanner      = "https://m/old_b.webp"
	seedBannerThumb = "https://m/old_b_t.webp"
	seedLocation    = "Pune"
	seedWebsite     = "https://old.example"
)

// matrixEnv is a service whose stored profile already holds every extra (seeded directly in the repo, because a caller
// outside the cohort could not have set them through the API).
type matrixEnv struct {
	repo    *fakeRepo
	svc     *service
	banners *fakeBanners
	pins    *fakePins
	uid     string
}

func newMatrixEnv(t *testing.T, reg ExtrasFlags, uid string) *matrixEnv {
	t.Helper()
	repo := newFakeRepo()
	banners := &fakeBanners{ref: BannerRef{URL: "https://m/b.webp", ThumbURL: "https://m/b_t.webp"}}
	pins := &fakePins{can: true}
	opts := []Option{WithBannerResolver(banners), WithPinChecker(pins)}
	if reg != nil { // a nil *flags.Registry would not be a nil interface, so wire nothing instead
		opts = append(opts, WithExtrasFlags(reg))
	}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, opts...).(*service)
	if _, err := svc.CreateProfile(context.Background(), uid, validKey, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	p := repo.profiles[uid]
	p.BannerURL, p.BannerThumbURL, p.Location, p.Website, p.PinnedPostID = seedBanner, seedBannerThumb, seedLocation, seedWebsite, pinID
	repo.profiles[uid] = p
	svc.Forget(uid) // CreateProfile cached the unseeded profile
	repo.getProfileCalls, repo.updateCalls = 0, 0
	return &matrixEnv{repo: repo, svc: svc, banners: banners, pins: pins, uid: uid}
}

// percentUIDs returns one uid inside and one outside a 50% cohort (the registry is the source of truth).
func percentUIDs(t *testing.T) (reg *flags.Registry, in, out string) {
	t.Helper()
	reg = flags.NewRegistry(flags.Spec{Name: ProfileExtrasFlag, Mode: flags.Percent, Percent: 50})
	for i := 0; i < 1000 && (in == "" || out == ""); i++ {
		u := "m1-bucket-" + strings.Repeat("y", i%5) + string(rune('a'+i%26)) + string(rune('a'+i/26%26))
		if reg.Enabled(u, ProfileExtrasFlag) && in == "" {
			in = u
		} else if !reg.Enabled(u, ProfileExtrasFlag) && out == "" {
			out = u
		}
	}
	if in == "" || out == "" {
		t.Fatal("could not find uids on both sides of the percent bucket")
	}
	return reg, in, out
}

// TestUpdateProfile_Extras_GateMatrix is the A2 gate matrix: every flag mode against every kind of value. A request
// is refused whole (FEATURE_DISABLED feature=profile_extras, 0 reads, 0 writes, nothing resolved) exactly when the
// caller is outside the cohort and the request SETS at least one of the four fields: any non-empty value,
// whitespace-only included, tested on the raw value before normalisation, even next to a clear. A request that only
// clears (the exact string "") passes for everyone, globally off included, at the same one write.
func TestUpdateProfile_Extras_GateMatrix(t *testing.T) {
	pct, pctIn, pctOut := percentUIDs(t)
	modes := []struct {
		name     string
		reg      ExtrasFlags
		uid      string
		inCohort bool
		globally bool // the kill switch is pulled: Registry.GloballyOff (mode off, or no flags wired)
	}{
		{"off", extrasRegistry(flags.Off), extrasUID, false, true},
		{"allowlist, caller listed", extrasRegistry(flags.Allowlist, extrasUID), extrasUID, true, false},
		{"allowlist, caller not listed", extrasRegistry(flags.Allowlist, "someone-else"), extrasUID, false, false},
		{"allowlist, empty", extrasRegistry(flags.Allowlist), extrasUID, false, false},
		{"percent, caller outside the cohort", pct, pctOut, false, false},
		{"percent, caller inside the cohort", pct, pctIn, true, false},
		{"on", extrasRegistry(flags.On), extrasUID, true, false},
		{"no flags wired", nil, extrasUID, false, true},
	}
	empty := ""
	values := []struct {
		name   string
		p      UpdateProfileParams
		sets   bool
		expect func(*Profile) // the stored extras afterwards, relative to the seed
	}{
		{"set location", UpdateProfileParams{Location: strp("Delhi")}, true, func(p *Profile) { p.Location = "Delhi" }},
		{"set website", UpdateProfileParams{Website: strp("https://new.example")}, true, func(p *Profile) { p.Website = "https://new.example" }},
		{"set pin", UpdateProfileParams{PinnedPostID: strp(otherPinID)}, true, func(p *Profile) { p.PinnedPostID = otherPinID }},
		{"set banner", UpdateProfileParams{BannerMediaID: strp("0000000000000000202")}, true, func(p *Profile) {
			p.BannerURL, p.BannerThumbURL = "https://m/b.webp", "https://m/b_t.webp"
		}},
		{"clear banner", UpdateProfileParams{BannerMediaID: &empty}, false, func(p *Profile) { p.BannerURL, p.BannerThumbURL = "", "" }},
		{"clear location", UpdateProfileParams{Location: &empty}, false, func(p *Profile) { p.Location = "" }},
		{"clear website", UpdateProfileParams{Website: &empty}, false, func(p *Profile) { p.Website = "" }},
		{"clear pin", UpdateProfileParams{PinnedPostID: &empty}, false, func(p *Profile) { p.PinnedPostID = "" }},
		{"clear all four", UpdateProfileParams{BannerMediaID: &empty, Location: &empty, Website: &empty, PinnedPostID: &empty}, false, func(p *Profile) {
			p.BannerURL, p.BannerThumbURL, p.Location, p.Website, p.PinnedPostID = "", "", "", "", ""
		}},
		{"clear all four next to a bio edit", UpdateProfileParams{Bio: strp("new bio"), BannerMediaID: &empty, Location: &empty, Website: &empty, PinnedPostID: &empty}, false, func(p *Profile) {
			p.BannerURL, p.BannerThumbURL, p.Location, p.Website, p.PinnedPostID = "", "", "", "", ""
		}},
		{"whitespace-only location is a set", UpdateProfileParams{Location: strp("   ")}, true, func(p *Profile) { p.Location = "" }},
		{"whitespace-only website is a set", UpdateProfileParams{Website: strp(" \t ")}, true, func(p *Profile) { p.Website = "" }},
		{"mixed: clear website, set location", UpdateProfileParams{Website: &empty, Location: strp("Delhi")}, true, func(p *Profile) {
			p.Website, p.Location = "", "Delhi"
		}},
		{"mixed: set banner, clear pin", UpdateProfileParams{BannerMediaID: strp("0000000000000000202"), PinnedPostID: &empty}, true, func(p *Profile) {
			p.BannerURL, p.BannerThumbURL, p.PinnedPostID = "https://m/b.webp", "https://m/b_t.webp", ""
		}},
		{"mixed: clear banner, location and website, set pin", UpdateProfileParams{BannerMediaID: &empty, Location: &empty, Website: &empty, PinnedPostID: strp(otherPinID)}, true, func(p *Profile) {
			p.BannerURL, p.BannerThumbURL, p.Location, p.Website, p.PinnedPostID = "", "", "", "", otherPinID
		}},
	}
	for _, m := range modes {
		for _, v := range values {
			t.Run(m.name+"/"+v.name, func(t *testing.T) {
				e := newMatrixEnv(t, m.reg, m.uid)
				params := v.p
				params.IdempotencyKey = validKey
				got, err := e.svc.UpdateProfile(context.Background(), m.uid, params)

				seed := e.repo.profiles[m.uid]
				if !m.inCohort && v.sets {
					_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "profile_extras")
					if e.repo.updateCalls != 0 || e.repo.getProfileCalls != 0 || len(e.banners.calls) != 0 || len(e.pins.calls) != 0 {
						t.Fatalf("a refused request must cost nothing: updates=%d reads=%d banner calls=%v pin calls=%v",
							e.repo.updateCalls, e.repo.getProfileCalls, e.banners.calls, e.pins.calls)
					}
					if seed.Location != seedLocation || seed.Website != seedWebsite || seed.PinnedPostID != pinID || seed.BannerURL != seedBanner || seed.Bio != "" {
						t.Fatalf("a refused request changed the profile: %+v", seed)
					}
					return
				}
				if err != nil {
					t.Fatalf("UpdateProfile: %v", err)
				}
				if e.repo.updateCalls != 1 {
					t.Fatalf("updateCalls = %d, want exactly 1 write", e.repo.updateCalls)
				}
				want := Profile{BannerURL: seedBanner, BannerThumbURL: seedBannerThumb, Location: seedLocation, Website: seedWebsite, PinnedPostID: pinID}
				v.expect(&want)
				gotStored := Profile{BannerURL: seed.BannerURL, BannerThumbURL: seed.BannerThumbURL, Location: seed.Location, Website: seed.Website, PinnedPostID: seed.PinnedPostID}
				if !reflect.DeepEqual(gotStored, want) {
					t.Fatalf("stored extras = %+v, want %+v", gotStored, want)
				}
				// The response is the presented view: while the kill switch is pulled it never carries the website or the
				// pin (a clear cannot bring them back), otherwise it is the stored value.
				wantWebsite, wantPin := want.Website, want.PinnedPostID
				if m.globally {
					wantWebsite, wantPin = "", ""
				}
				if got.Website != wantWebsite || got.PinnedPostID != wantPin || got.Location != want.Location || got.BannerURL != want.BannerURL {
					t.Fatalf("response = banner %q location %q website %q pin %q, want banner %q location %q website %q pin %q",
						got.BannerURL, got.Location, got.Website, got.PinnedPostID, want.BannerURL, want.Location, wantWebsite, wantPin)
				}
				if v.p.Bio != nil && seed.Bio != "new bio" {
					t.Fatalf("the bio edit next to the clears was dropped: %q", seed.Bio)
				}
				// A clear resolves and checks nothing, whatever the flag.
				if !v.sets && (len(e.banners.calls) != 0 || len(e.pins.calls) != 0) {
					t.Fatalf("a clear consulted a resolver: banner calls=%v pin calls=%v", e.banners.calls, e.pins.calls)
				}
			})
		}
	}
}

// TestUpdateProfile_Extras_GateComesBeforeValidation: a caller outside the cohort who SETS an invalid value learns
// nothing about the field: the answer is FEATURE_DISABLED, never VALIDATION (the gate is checked first, 0 reads).
func TestUpdateProfile_Extras_GateComesBeforeValidation(t *testing.T) {
	tests := []struct {
		name string
		p    UpdateProfileParams
	}{
		{"location of 31 code points", UpdateProfileParams{Location: strp(strings.Repeat("a", 31))}},
		{"javascript website", UpdateProfileParams{Website: strp("javascript:alert(1)")}},
		{"malformed pin", UpdateProfileParams{PinnedPostID: strp("nope")}},
		{"a clear next to an invalid set", UpdateProfileParams{Website: strp(""), Location: strp("Pune\nIndia")}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newMatrixEnv(t, extrasRegistry(flags.Off), extrasUID)
			p := tt.p
			p.IdempotencyKey = validKey
			_, err := e.svc.UpdateProfile(context.Background(), extrasUID, p)
			_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "profile_extras")
			if e.repo.updateCalls != 0 || e.repo.getProfileCalls != 0 {
				t.Fatalf("a refused call touched the repo: updates=%d reads=%d", e.repo.updateCalls, e.repo.getProfileCalls)
			}
		})
	}
}

// TestNormalize_EmptyIsAValidClear: the A2 rule leans on "" passing the field validation, so the clear is not a
// VALIDATION error for a caller inside the cohort either.
func TestNormalize_EmptyIsAValidClear(t *testing.T) {
	if got := normalizeLocation(""); got != "" || locationIssue(got) {
		t.Fatalf("normalizeLocation(%q) = %q, issue=%v: an empty location must be a valid clear", "", got, locationIssue(got))
	}
	if got, ok := normalizeWebsite(""); !ok || got != "" {
		t.Fatalf("normalizeWebsite(%q) = %q, %v: an empty website must be a valid clear", "", got, ok)
	}
	// Whitespace-only also normalises to a clear, which is exactly why the gate must look at the raw value.
	if got := normalizeLocation("   "); got != "" {
		t.Fatalf("normalizeLocation of spaces = %q", got)
	}
	if got, ok := normalizeWebsite("   "); !ok || got != "" {
		t.Fatalf("normalizeWebsite of spaces = %q, %v", got, ok)
	}
}

// TestProfile_WebsiteFlagFlipShowsStoredWebsiteWithoutAWrite: the website follows the pin (A1). The cache holds the
// stored value, so a flag that comes back shows it again at once, and nothing was written either way.
func TestProfile_WebsiteFlagFlipShowsStoredWebsiteWithoutAWrite(t *testing.T) {
	repo := newFakeRepo()
	live := &flipFlags{}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithExtrasFlags(live)).(*service)
	if _, err := svc.CreateProfile(context.Background(), extrasUID, validKey, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	p := repo.profiles[extrasUID]
	p.Website = seedWebsite
	repo.profiles[extrasUID] = p
	svc.Forget(extrasUID)
	get := func(viewer string) string {
		got, err := svc.GetProfile(context.Background(), viewer, ProfileTarget{UserID: extrasUID})
		if err != nil {
			t.Fatal(err)
		}
		return got.Website
	}
	live.off = true
	for _, viewer := range []string{extrasUID, "viewer"} { // the owner's own view included
		if got := get(viewer); got != "" {
			t.Fatalf("website while globally off, viewer %q = %q", viewer, got)
		}
	}
	live.off = false
	if got := get("viewer"); got != seedWebsite {
		t.Fatalf("website after the flag came back = %q", got)
	}
	if repo.updateCalls != 0 {
		t.Fatal("flipping the flag wrote")
	}
}

func TestParseProfileFields(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    []ProfileField
		wantErr string
	}{
		{"one", "website", []ProfileField{ProfileFieldWebsite}, ""},
		{"all five, in the order given", "bio,avatar,banner,location,website",
			[]ProfileField{ProfileFieldBio, ProfileFieldAvatar, ProfileFieldBanner, ProfileFieldLocation, ProfileFieldWebsite}, ""},
		{"empty", "", nil, "--fields is required"},
		{"empty item", "website,", nil, "unknown field"},
		{"leading empty item", ",website", nil, "unknown field"},
		{"unknown", "website,pin", nil, `unknown field "pin"`},
		{"display name is not clearable", "display_name", nil, "unknown field"},
		{"repeated", "website,location,website", nil, `"website" is repeated`},
		{"case matters", "Website", nil, "unknown field"},
		{"spaces are not trimmed", "website, location", nil, "unknown field"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseProfileFields(tt.in)
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want it to contain %q", err, tt.wantErr)
				}
				return
			}
			if err != nil || !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("ParseProfileFields(%q) = %v, %v; want %v", tt.in, got, err, tt.want)
			}
		})
	}
}
