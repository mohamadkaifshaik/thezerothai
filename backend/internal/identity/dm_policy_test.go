package identity

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// F9: Profile.dm_policy and UpdateProfile.dm_policy.

func dmRegistry(mode flags.Mode, allow ...string) *flags.Registry {
	set := map[string]struct{}{}
	for _, u := range allow {
		set[u] = struct{}{}
	}
	return flags.NewRegistry(flags.Spec{Name: DMPolicyFlag, Mode: mode, Allowlist: set})
}

func dmPol(p DMPolicy) *DMPolicy { return &p }

func TestUpdateProfile_DMPolicy_FlagModes(t *testing.T) {
	tests := []struct {
		name     string
		reg      ExtrasFlags
		set      DMPolicy
		wantErr  bool
		wantSeen DMPolicy // what the caller's own response carries
	}{
		{"on: FOLLOWING_ONLY", dmRegistry(flags.On), DMPolicyFollowingOnly, false, DMPolicyFollowingOnly},
		{"allowlist with the caller", dmRegistry(flags.Allowlist, extrasUID), DMPolicyFollowingOnly, false, DMPolicyFollowingOnly},
		{"allowlist without the caller", dmRegistry(flags.Allowlist, "someone-else"), DMPolicyFollowingOnly, true, ""},
		{"off", dmRegistry(flags.Off), DMPolicyFollowingOnly, true, ""},
		{"no flags wired", nil, DMPolicyFollowingOnly, true, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var reg ExtrasFlags
			if tt.reg != nil {
				reg = tt.reg
			}
			e := newExtrasEnv(t, reg)
			p, err := e.update(context.Background(), UpdateProfileParams{DMPolicy: dmPol(tt.set)})
			if tt.wantErr {
				_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", DMPolicyFlag)
				if e.repo.updateCalls != 0 {
					t.Error("a gated request reached the repository")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if p.DMPolicy != tt.wantSeen || e.repo.profiles[extrasUID].DMPolicy != DMPolicyFollowingOnly {
				t.Errorf("response %q stored %q", p.DMPolicy, e.repo.profiles[extrasUID].DMPolicy)
			}
		})
	}
}

// The undo rule: going back to EVERYONE_REQUESTS is never gated, even with the flag off.
func TestUpdateProfile_DMPolicy_UndoIsNeverGated(t *testing.T) {
	e := newExtrasEnv(t, dmRegistry(flags.On))
	if _, err := e.update(context.Background(), UpdateProfileParams{DMPolicy: dmPol(DMPolicyFollowingOnly)}); err != nil {
		t.Fatal(err)
	}
	e.svc.extras = dmRegistry(flags.Off) // the flag is switched off later
	p, err := e.update(context.Background(), UpdateProfileParams{DMPolicy: dmPol(DMPolicyEveryoneRequests)})
	if err != nil {
		t.Fatalf("undo with the flag off: %v", err)
	}
	if p.DMPolicy != DMPolicyEveryoneRequests || e.repo.profiles[extrasUID].DMPolicy != DMPolicyEveryoneRequests {
		t.Errorf("after undo: response %q stored %q", p.DMPolicy, e.repo.profiles[extrasUID].DMPolicy)
	}
}

func TestUpdateProfile_DMPolicy_NoOpWritesNothing(t *testing.T) {
	e := newExtrasEnv(t, dmRegistry(flags.On))
	if _, err := e.update(context.Background(), UpdateProfileParams{DMPolicy: dmPol(DMPolicyFollowingOnly)}); err != nil {
		t.Fatal(err)
	}
	writes := e.repo.updateWrites
	if _, err := e.update(context.Background(), UpdateProfileParams{DMPolicy: dmPol(DMPolicyFollowingOnly)}); err != nil {
		t.Fatal(err)
	}
	if e.repo.updateWrites != writes {
		t.Error("repeating the same policy wrote the profile")
	}
	// Setting the default on a profile that never had one is also a no-op.
	e2 := newExtrasEnv(t, dmRegistry(flags.On))
	before := e2.repo.updateWrites
	if _, err := e2.update(context.Background(), UpdateProfileParams{DMPolicy: dmPol(DMPolicyEveryoneRequests)}); err != nil {
		t.Fatal(err)
	}
	if e2.repo.updateWrites != before {
		t.Error("setting the default wrote the profile")
	}
}

// present(): the kill switch hides the stored value in every response while the flag is globally off; an allowlist is a
// rollout, not the switch. The stored value (and so the cache) is untouched.
func TestPresent_DMPolicyKillSwitch(t *testing.T) {
	p := Profile{UserID: "u", DMPolicy: DMPolicyFollowingOnly}
	tests := []struct {
		name string
		reg  ExtrasFlags
		want DMPolicy
	}{
		{"on", dmRegistry(flags.On), DMPolicyFollowingOnly},
		{"allowlist (a rollout)", dmRegistry(flags.Allowlist, "someone-else"), DMPolicyFollowingOnly},
		{"off (the kill switch)", dmRegistry(flags.Off), DMPolicyEveryoneRequests},
		{"no flags wired", nil, DMPolicyEveryoneRequests},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &service{}
			if tt.reg != nil {
				s.extras = tt.reg
			}
			if got := s.present(p).DMPolicy; got != tt.want {
				t.Errorf("present = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestDMPolicyProtoMapping(t *testing.T) {
	tests := []struct {
		in     identityv1.DmPolicy
		want   DMPolicy
		wantOK bool
	}{
		{identityv1.DmPolicy_DM_POLICY_EVERYONE_REQUESTS, DMPolicyEveryoneRequests, true},
		{identityv1.DmPolicy_DM_POLICY_FOLLOWING_ONLY, DMPolicyFollowingOnly, true},
		{identityv1.DmPolicy_DM_POLICY_UNSPECIFIED, "", false},
		{identityv1.DmPolicy(99), "", false},
	}
	for _, tt := range tests {
		got, ok := dmPolicyFromProto(tt.in)
		if got != tt.want || ok != tt.wantOK {
			t.Errorf("dmPolicyFromProto(%v) = %q, %v", tt.in, got, ok)
		}
	}
	if dmPolicyToProto(DMPolicyFollowingOnly) != identityv1.DmPolicy_DM_POLICY_FOLLOWING_ONLY || dmPolicyToProto(DMPolicyEveryoneRequests) != identityv1.DmPolicy_DM_POLICY_UNSPECIFIED {
		t.Error("dmPolicyToProto")
	}
	if got := toProtoProfile(Profile{DMPolicy: DMPolicyFollowingOnly}).GetDmPolicy(); got != identityv1.DmPolicy_DM_POLICY_FOLLOWING_ONLY {
		t.Errorf("Profile.dm_policy = %v", got)
	}
}

func TestUserDoc_DMPolicyRoundTrip(t *testing.T) {
	d := profileToDoc(Profile{UserID: "u", DMPolicy: DMPolicyFollowingOnly, CreatedAt: time.Unix(1, 0)})
	if d.DMPolicy != "following_only" || d.toProfile("u").DMPolicy != DMPolicyFollowingOnly {
		t.Errorf("doc = %+v", d)
	}
	if profileToDoc(Profile{UserID: "u"}).DMPolicy != "" {
		t.Error("the default must stay absent (omitempty)")
	}
}
