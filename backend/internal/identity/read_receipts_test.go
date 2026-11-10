package identity

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// F3: Profile.read_receipts and UpdateProfile.read_receipts.

func receiptsRegistry(mode flags.Mode, allow ...string) *flags.Registry {
	set := map[string]struct{}{}
	for _, u := range allow {
		set[u] = struct{}{}
	}
	return flags.NewRegistry(flags.Spec{Name: ReadReceiptsFlag, Mode: mode, Allowlist: set})
}

func boolPtr(b bool) *bool { return &b }

func TestUpdateProfile_ReadReceipts_FlagModes(t *testing.T) {
	tests := []struct {
		name    string
		reg     ExtrasFlags
		wantErr bool
	}{
		{"on", receiptsRegistry(flags.On), false},
		{"allowlist with the caller", receiptsRegistry(flags.Allowlist, extrasUID), false},
		{"allowlist without the caller", receiptsRegistry(flags.Allowlist, "someone-else"), true},
		{"off", receiptsRegistry(flags.Off), true},
		{"no flags wired", nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newExtrasEnv(t, tt.reg)
			p, err := e.update(context.Background(), UpdateProfileParams{ReadReceipts: boolPtr(true)})
			if tt.wantErr {
				_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", ReadReceiptsFlag)
				if e.repo.updateCalls != 0 {
					t.Error("a gated request reached the repository")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !p.ReadReceipts || !e.repo.profiles[extrasUID].ReadReceipts {
				t.Errorf("response %v stored %v", p.ReadReceipts, e.repo.profiles[extrasUID].ReadReceipts)
			}
		})
	}
}

// The undo rule: turning receipts off is never gated, even with the flag off, and it hides them at once (the cached profile
// the messaging module reads is the written one).
func TestUpdateProfile_ReadReceipts_OffIsNeverGated(t *testing.T) {
	e := newExtrasEnv(t, receiptsRegistry(flags.On))
	if _, err := e.update(context.Background(), UpdateProfileParams{ReadReceipts: boolPtr(true)}); err != nil {
		t.Fatal(err)
	}
	e.svc.extras = receiptsRegistry(flags.Off)
	if _, err := e.update(context.Background(), UpdateProfileParams{ReadReceipts: boolPtr(false)}); err != nil {
		t.Fatalf("off with the flag off: %v", err)
	}
	if e.repo.profiles[extrasUID].ReadReceipts {
		t.Error("stored value still on")
	}
	if cached, ok := e.svc.cache.GetProfile(extrasUID); !ok || cached.ReadReceipts {
		t.Errorf("cached profile after off: ok=%v receipts=%v", ok, cached.ReadReceipts)
	}
}

func TestUpdateProfile_ReadReceipts_NoOpWritesNothing(t *testing.T) {
	e := newExtrasEnv(t, receiptsRegistry(flags.On))
	if _, err := e.update(context.Background(), UpdateProfileParams{ReadReceipts: boolPtr(true)}); err != nil {
		t.Fatal(err)
	}
	writes := e.repo.updateWrites
	if _, err := e.update(context.Background(), UpdateProfileParams{ReadReceipts: boolPtr(true)}); err != nil {
		t.Fatal(err)
	}
	if e.repo.updateWrites != writes {
		t.Error("repeating the same setting wrote the profile")
	}
	e2 := newExtrasEnv(t, receiptsRegistry(flags.On))
	before := e2.repo.updateWrites
	if _, err := e2.update(context.Background(), UpdateProfileParams{ReadReceipts: boolPtr(false)}); err != nil {
		t.Fatal(err)
	}
	if e2.repo.updateWrites != before {
		t.Error("setting the default wrote the profile")
	}
}

// present(): the kill switch hides the stored value while the flag is globally off; an allowlist is a rollout, not the switch.
func TestPresent_ReadReceiptsKillSwitch(t *testing.T) {
	p := Profile{UserID: "u", ReadReceipts: true}
	tests := []struct {
		name string
		reg  ExtrasFlags
		want bool
	}{
		{"on", receiptsRegistry(flags.On), true},
		{"allowlist (a rollout)", receiptsRegistry(flags.Allowlist, "someone-else"), true},
		{"off (the kill switch)", receiptsRegistry(flags.Off), false},
		{"no flags wired", nil, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &service{}
			if tt.reg != nil {
				s.extras = tt.reg
			}
			if got := s.present(p).ReadReceipts; got != tt.want {
				t.Errorf("present = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestUserDoc_ReadReceiptsRoundTrip(t *testing.T) {
	d := profileToDoc(Profile{UserID: "u", ReadReceipts: true, CreatedAt: time.Unix(1, 0)})
	if !d.ReadReceipts || !d.toProfile("u").ReadReceipts {
		t.Errorf("doc = %+v", d)
	}
	if profileToDoc(Profile{UserID: "u"}).ReadReceipts {
		t.Error("the default must stay absent (omitempty)")
	}
	if !toProtoProfile(Profile{ReadReceipts: true}).GetReadReceipts() {
		t.Error("Profile.read_receipts missing from the wire profile")
	}
	if got := profileSection(Profile{ReadReceipts: true}); !got.ReadReceipts {
		t.Error("export profile section lacks readReceipts")
	}
}

// The setting is the owner's alone: another user's GetProfile (by id or by handle) never carries it.
func TestGetProfile_ReadReceiptsOwnerOnly(t *testing.T) {
	e := newExtrasEnv(t, receiptsRegistry(flags.On))
	if _, err := e.update(context.Background(), UpdateProfileParams{ReadReceipts: boolPtr(true)}); err != nil {
		t.Fatal(err)
	}
	self, err := e.svc.GetProfile(context.Background(), extrasUID, ProfileTarget{UserID: extrasUID})
	if err != nil || !self.ReadReceipts {
		t.Fatalf("owner view: %+v, %v", self, err)
	}
	for _, target := range []ProfileTarget{{UserID: extrasUID}, {Handle: "Alice"}} {
		other, err := e.svc.GetProfile(context.Background(), "viewer", target)
		if err != nil {
			t.Fatal(err)
		}
		if other.ReadReceipts {
			t.Errorf("another user sees the setting (%+v)", target)
		}
	}
}

// The identity export carries the setting while it is on and omits it while off (the default), so the golden export is unchanged.
func TestProfileSection_ReadReceiptsExport(t *testing.T) {
	for _, tt := range []struct {
		on   bool
		want bool
	}{{true, true}, {false, false}} {
		raw, err := json.Marshal(profileSection(Profile{UserID: "u1", Handle: "Alice", ReadReceipts: tt.on}))
		if err != nil {
			t.Fatal(err)
		}
		if got := strings.Contains(string(raw), `"readReceipts":true`); got != tt.want {
			t.Errorf("setting %v: export %s, readReceipts present = %v, want %v", tt.on, raw, got, tt.want)
		}
	}
}
