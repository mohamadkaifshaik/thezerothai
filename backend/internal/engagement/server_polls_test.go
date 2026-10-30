package engagement

import (
	"testing"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestVotePoll_FlagMatrix (ADR-0029 D6 step 2, W6-4): FEATURE_POSTS, then FEATURE_ENGAGEMENT on for the caller, then
// FEATURE_POLLS NOT globally off. Every refusal is FEATURE_DISABLED naming the flag, before any Firestore access (the
// stub service has no repo); a caller the gate lets through reaches the skeleton's Unimplemented.
func TestVotePoll_FlagMatrix(t *testing.T) {
	on := func(n string) flags.Spec { return flags.Spec{Name: n, Mode: flags.On} }
	off := func(n string) flags.Spec { return flags.Spec{Name: n, Mode: flags.Off} }
	allow := func(n, uids string) flags.Spec {
		return flags.Spec{Name: n, Mode: flags.Allowlist, Allowlist: map[string]struct{}{uids: {}}}
	}
	pct0 := func(n string) flags.Spec { return flags.Spec{Name: n, Mode: flags.Percent, Percent: 0} }

	tests := []struct {
		name        string
		specs       []flags.Spec
		uid         string
		wantFeature string // "" = passes the gate (Unimplemented)
	}{
		{"all on", []flags.Spec{on("posts"), on("engagement"), on("polls")}, "u", ""},
		{"posts off", []flags.Spec{off("posts"), on("engagement"), on("polls")}, "u", "posts"},
		{"engagement off", []flags.Spec{on("posts"), off("engagement"), on("polls")}, "u", "engagement"},
		{"engagement allowlist, caller outside", []flags.Spec{on("posts"), allow("engagement", "other"), on("polls")}, "u", "engagement"},
		{"polls unset (off)", []flags.Spec{on("posts"), on("engagement")}, "u", "polls"},
		{"polls off", []flags.Spec{on("posts"), on("engagement"), off("polls")}, "u", "polls"},
		{"polls allowlist, caller outside: may vote", []flags.Spec{on("posts"), on("engagement"), allow("polls", "other")}, "u", ""},
		{"polls percent 0: a rollout, not the kill switch", []flags.Spec{on("posts"), on("engagement"), pct0("polls")}, "u", ""},
		{"polls allowlist, caller inside", []flags.Spec{on("posts"), on("engagement"), allow("polls", "u")}, "u", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := NewServer(&stubSvc{}, flags.NewRegistry(tt.specs...))
			_, err := srv.VotePoll(uidCtx(tt.uid), connect.NewRequest(&engagementv1.VotePollRequest{}))
			if tt.wantFeature == "" {
				if connect.CodeOf(err) != connect.CodeUnimplemented || featureDisabledErr(err) != nil {
					t.Fatalf("err = %v, want Unimplemented after the gate", err)
				}
				return
			}
			ae := featureDisabledErr(err)
			if ae == nil {
				t.Fatalf("err = %v, want FEATURE_DISABLED", err)
			}
			// posts off is the whole-service answer without a feature name (posts.GuardFeature).
			if tt.wantFeature != "posts" && ae.Metadata["feature"] != tt.wantFeature {
				t.Errorf("metadata feature = %q, want %q", ae.Metadata["feature"], tt.wantFeature)
			}
		})
	}
}
