package identity

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-22 L-2c at the service boundary: display name and bio refuse control and bidi characters and are stored in NFC,
// on CreateProfile and UpdateProfile, whatever the profile_extras flag says (they are not extras). The per-rule
// vectors live in the shared fixture (profile_text_fixture_test.go); these tests prove the rules are wired in.

// cp builds a string from code points, so no invisible or right-to-left character sits in this source.
func cp(rs ...rune) string { return string(rs) }

func TestUpdateProfile_DisplayNameRules(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    string
		wantErr bool
	}{
		{"plain", "Asha Rao", "Asha Rao", false},
		{"trimmed", "  Asha  ", "Asha", false},
		{"NFC composes", "Jose" + cp(0x301), "Jos" + cp(0xE9), false},
		{"emoji ZWJ sequence", cp(0x1F469, 0x200D, 0x1F4BB) + " Dev", cp(0x1F469, 0x200D, 0x1F4BB) + " Dev", false},
		{"right-to-left override", "Asha" + cp(0x202E) + "Rao", "", true},
		{"left-to-right isolate", "Asha" + cp(0x2066) + "Rao", "", true},
		{"newline", "Asha\nRao", "", true},
		{"tab", "Asha\tRao", "", true},
		{"NUL", "Asha" + cp(0) + "Rao", "", true},
		{"line separator", "Asha" + cp(0x2028) + "Rao", "", true},
		{"paragraph separator", "Asha" + cp(0x2029) + "Rao", "", true},
		{"invalid UTF-8", "Asha\xff", "", true},
		{"empty", "", "", true},
		{"51 code points", strings.Repeat("a", 51), "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newExtrasEnv(t, extrasRegistry(flags.Off)) // the flag has nothing to do with the name
			before := e.repo.updateCalls
			got, err := e.update(context.Background(), UpdateProfileParams{DisplayName: &tt.in})
			if tt.wantErr {
				_ = wantValidation(t, err, "display_name")
				if e.repo.updateCalls != before {
					t.Fatalf("a rejected display name wrote %d times", e.repo.updateCalls-before)
				}
				return
			}
			if err != nil || got.DisplayName != tt.want || e.repo.profiles[extrasUID].DisplayName != tt.want {
				t.Fatalf("UpdateProfile = %q, %v; want %q", got.DisplayName, err, tt.want)
			}
		})
	}
}

func TestUpdateProfile_BioRules(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    string
		wantErr bool
	}{
		{"plain", "Builder of small things.", "Builder of small things.", false},
		{"newline is kept", "one\ntwo", "one\ntwo", false},
		{"outer whitespace is trimmed", "\n  hello \n", "hello", false},
		{"NFC composes and is what is stored", "Cafe" + cp(0x301), "Caf" + cp(0xE9), false},
		{"clear", "", "", false},
		{"exactly 160 code points", strings.Repeat("a", 160), strings.Repeat("a", 160), false},
		{"the count is after trim", strings.Repeat("a", 160) + "     ", strings.Repeat("a", 160), false},
		{"the count is after NFC", strings.Repeat("e"+cp(0x301), 160), strings.Repeat(cp(0xE9), 160), false},
		{"161 code points", strings.Repeat("a", 161), "", true},
		{"carriage return", "one\rtwo", "", true},
		{"CRLF", "one\r\ntwo", "", true},
		{"tab", "one\ttwo", "", true},
		{"NUL", "one" + cp(0) + "two", "", true},
		{"line separator", "one" + cp(0x2028) + "two", "", true},
		{"paragraph separator", "one" + cp(0x2029) + "two", "", true},
		{"right-to-left override", "one" + cp(0x202E) + "two", "", true},
		{"pop directional isolate", "one" + cp(0x2069) + "two", "", true},
		{"invalid UTF-8", "one\xff", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newExtrasEnv(t, extrasRegistry(flags.Off))
			before := e.repo.updateCalls
			got, err := e.update(context.Background(), UpdateProfileParams{Bio: &tt.in})
			if tt.wantErr {
				_ = wantValidation(t, err, "bio")
				if e.repo.updateCalls != before {
					t.Fatalf("a rejected bio wrote %d times", e.repo.updateCalls-before)
				}
				return
			}
			if err != nil || got.Bio != tt.want || e.repo.profiles[extrasUID].Bio != tt.want {
				t.Fatalf("UpdateProfile = %q, %v; want %q", got.Bio, err, tt.want)
			}
		})
	}
}

func TestCreateProfile_DisplayNameRules(t *testing.T) {
	for _, name := range []string{"Asha" + cp(0x202E) + "Rao", "Asha\nRao", "As" + cp(0x2028) + "ha", cp(0x2066) + "Asha", "Asha\xff"} {
		svc := New(newFakeRepo(), NewCache(time.Minute), 7*24*time.Hour).(*service)
		_, err := svc.CreateProfile(context.Background(), extrasUID, validKey, "Alice", name)
		_ = wantValidation(t, err, "display_name")
	}
	svc := New(newFakeRepo(), NewCache(time.Minute), 7*24*time.Hour).(*service)
	got, err := svc.CreateProfile(context.Background(), extrasUID, validKey, "Alice", "Jose"+cp(0x301))
	if err != nil || got.DisplayName != "Jos"+cp(0xE9) {
		t.Fatalf("CreateProfile = %q, %v; want the NFC name", got.DisplayName, err)
	}
}

// TestProfileText_NewWritesOnly: the rules run when a value is submitted, never when one is read. A profile stored
// before W3-22 with a character the rules now refuse is returned as stored by GetProfile and GetMe, and an update that
// leaves the field out is not refused because of it.
func TestProfileText_NewWritesOnly(t *testing.T) {
	e := newExtrasEnv(t, extrasRegistry(flags.On))
	legacy := e.repo.profiles[extrasUID]
	legacy.DisplayName = "Old" + cp(0x202E) + "Name"
	legacy.Bio = "old\tbio"
	e.repo.profiles[extrasUID] = legacy
	e.svc.cache.InvalidateProfile(extrasUID)

	location := "Pune"
	got, err := e.update(context.Background(), UpdateProfileParams{Location: &location})
	if err != nil || got.Location != "Pune" || got.DisplayName != legacy.DisplayName || got.Bio != legacy.Bio {
		t.Fatalf("an update that leaves name and bio out = %+v, %v; want them untouched", got, err)
	}
	read, err := e.svc.GetProfile(context.Background(), extrasUID, ProfileTarget{UserID: extrasUID})
	if err != nil || read.DisplayName != legacy.DisplayName || read.Bio != legacy.Bio {
		t.Fatalf("GetProfile = %+v, %v; want the stored values as they are", read, err)
	}
}
