package communities

import (
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// TestErrors_Shape: the three constructors produce the code, reason and metadata communities.proto documents (ADR-0031 N1, N6),
// and they survive apierr.ToConnect with the ErrorDetail intact.
func TestErrors_Shape(t *testing.T) {
	tests := []struct {
		name       string
		err        *apierr.Error
		wantCode   connect.Code
		wantReason commonv1.ErrorReason
		wantKey    string
		wantValue  string
	}{
		{"banned", Forbidden(ReasonBanned), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "banned"},
		{"not_member", Forbidden(ReasonNotMember), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "not_member"},
		{"not_moderator", Forbidden(ReasonNotModerator), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "not_moderator"},
		{"not_owner", Forbidden(ReasonNotOwner), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "not_owner"},
		{"not_creator", Forbidden(ReasonNotCreator), connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "reason", "not_creator"},
		{"state owner", StateConflict(StateOwner), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "reason", "owner"},
		{"state moderator", StateConflict(StateModerator), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "reason", "moderator"},
		{"state archived", StateConflict(StateArchived), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "reason", "community_archived"},
		{"owned", LimitReached(LimitOwned), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "communities_owned"},
		{"joined", LimitReached(LimitJoined), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "communities_joined"},
		{"moderators", LimitReached(LimitModerators), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "community_moderators"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.err.Code != tt.wantCode || tt.err.Reason != tt.wantReason || tt.err.Metadata[tt.wantKey] != tt.wantValue || len(tt.err.Metadata) != 1 {
				t.Fatalf("err = %+v, want %v %v %s=%s", tt.err, tt.wantCode, tt.wantReason, tt.wantKey, tt.wantValue)
			}
			ce := apierr.ToConnect(tt.err)
			if ce.Code() != tt.wantCode {
				t.Fatalf("ToConnect code = %v, want %v", ce.Code(), tt.wantCode)
			}
			var found bool
			for _, d := range ce.Details() {
				v, err := d.Value()
				if err != nil {
					t.Fatal(err)
				}
				if ed, ok := v.(*commonv1.ErrorDetail); ok {
					found = true
					if ed.GetReason() != tt.wantReason || ed.GetMetadata()[tt.wantKey] != tt.wantValue {
						t.Errorf("detail = %v, want reason %v %s=%s", ed, tt.wantReason, tt.wantKey, tt.wantValue)
					}
				}
			}
			if !found {
				t.Error("no ErrorDetail attached")
			}
			var ae *apierr.Error
			if !errors.As(error(tt.err), &ae) {
				t.Error("not an *apierr.Error")
			}
		})
	}
}

// TestLimits_PostsPerCommunityCap: the uid|cid DailyCap admits the configured number per uid and community per day and keeps
// uids and communities apart; the key cannot be forged by a uid (a uid has no "|").
func TestLimits_PostsPerCommunityCap(t *testing.T) {
	c := NewPostsPerCommunityCap(2)
	k := PostsCapKey("uid-a", "1111111111111111111")
	if k != "uid-a|1111111111111111111" {
		t.Fatalf("key = %q", k)
	}
	for i := 1; i <= 3; i++ {
		if got, want := c.Allow(k), i <= 2; got != want {
			t.Fatalf("post %d: Allow = %v, want %v (exactly 2 per uid and community)", i, got, want)
		}
	}
	if !c.Allow(PostsCapKey("uid-a", "2222222222222222222")) {
		t.Error("another community must have its own allowance")
	}
	if !c.Allow(PostsCapKey("uid-b", "1111111111111111111")) {
		t.Error("another uid must have its own allowance")
	}
	for name, want := range map[string]string{
		LimitMutationDaily:          "community_mutation_daily",
		LimitModActionsDaily:        "community_mod_actions_daily",
		LimitPostsPerCommunityDaily: "community_posts_per_community_daily",
	} {
		if name != want {
			t.Errorf("limit name %q, want %q", name, want)
		}
	}
}
