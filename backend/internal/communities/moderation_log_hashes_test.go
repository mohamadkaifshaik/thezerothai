package communities

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ADR-0031 D13a: the keyed community_hash, post_hash and target_hash on the moderation request lines, and no raw id.
// Not parallel: the log key is process-wide.

func installLogKey(t *testing.T, secret string) {
	t.Helper()
	if err := logger.SetConversationKey([]byte(secret)); err != nil {
		t.Fatal(err)
	}
}

func lineFields(info *logger.RequestInfo) map[string]string {
	m := map[string]string{}
	for _, a := range info.Fields() {
		m[a.Key] = fmt.Sprint(a.Value.Any())
	}
	return m
}

// noRawIDs fails when any request-line value contains one of the raw ids or their plain (unkeyed) digests.
func noRawIDs(t *testing.T, fields map[string]string, raw ...string) {
	t.Helper()
	for k, v := range fields {
		for _, id := range raw {
			if strings.Contains(v, id) || strings.Contains(v, logger.HashUID(id)) {
				t.Errorf("request line field %s=%q carries %q or its unkeyed hash", k, v, id)
			}
		}
	}
}

func TestModerationRequestLines_KeyedHashesPerAction(t *testing.T) {
	installLogKey(t, "w552-key-one")
	c := Community{ID: testCID, OwnerID: ownerUID, ModeratorIDs: []string{modUID}, Status: StatusActive}
	tests := []struct {
		name string
		run  func(f *fixture, m *fakeModRepo, ctx context.Context)
		want map[string]string // field -> value; "" = must be absent
	}{
		{"hide", func(f *fixture, m *fakeModRepo, ctx context.Context) {
			m.postRes = ModeratePostResult{Outcome: Written, Community: c}
			_ = f.svc.HideCommunityPost(ctx, modUID, PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost})
		}, map[string]string{"mod_action": "hide", "community_hash": logger.HashCommunity(testCID), "post_hash": logger.HashPost(testPost), "target_hash": ""}},
		{"restore", func(f *fixture, m *fakeModRepo, ctx context.Context) {
			m.postRes = ModeratePostResult{Outcome: Written, Community: c}
			_ = f.svc.RestoreCommunityPost(ctx, modUID, PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost})
		}, map[string]string{"mod_action": "restore", "community_hash": logger.HashCommunity(testCID), "post_hash": logger.HashPost(testPost), "target_hash": ""}},
		{"reply hide", func(f *fixture, m *fakeModRepo, ctx context.Context) {
			m.postRes = ModeratePostResult{Outcome: Written, Community: c, Reply: true}
			_ = f.svc.HideCommunityPost(ctx, modUID, PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost})
		}, map[string]string{"mod_target": "reply", "community_hash": logger.HashCommunity(testCID), "post_hash": logger.HashPost(testPost)}},
		{"ban", func(f *fixture, m *fakeModRepo, ctx context.Context) {
			m.roleRes = SetRoleResult{Outcome: Written, Community: c, TargetState: MemberBanned}
			_, _ = f.svc.SetMemberRole(ctx, modUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: userKey, Action: RoleActionBan})
		}, map[string]string{"mod_action": "ban", "community_hash": logger.HashCommunity(testCID), "target_hash": logger.HashTarget(userKey), "post_hash": ""}},
		{"unban", func(f *fixture, m *fakeModRepo, ctx context.Context) {
			m.roleRes = SetRoleResult{Outcome: Written, Community: c}
			_, _ = f.svc.SetMemberRole(ctx, modUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: userKey, Action: RoleActionUnban})
		}, map[string]string{"community_hash": logger.HashCommunity(testCID), "target_hash": logger.HashTarget(userKey)}},
		{"make moderator", func(f *fixture, m *fakeModRepo, ctx context.Context) {
			m.roleRes = SetRoleResult{Outcome: Written, Community: c}
			_, _ = f.svc.SetMemberRole(ctx, ownerUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: userKey, Action: RoleActionMakeModerator})
		}, map[string]string{"community_hash": logger.HashCommunity(testCID), "target_hash": logger.HashTarget(userKey)}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f, m := modFixture()
			ctx, info := logger.WithRequestInfo(context.Background())
			tc.run(f, m, ctx)
			got := lineFields(info)
			for k, want := range tc.want {
				if v, ok := got[k]; want == "" && ok {
					t.Errorf("%s = %q, want absent", k, v)
				} else if want != "" && v != want {
					t.Errorf("%s = %q, want %q", k, v, want)
				}
			}
			noRawIDs(t, got, testCID, testPost, userKey, modUID)
		})
	}
}

func TestModerationRequestLines_UpdateAndModeratorLeave(t *testing.T) {
	installLogKey(t, "w552-key-one")
	t.Run("update", func(t *testing.T) {
		f := newFixture(ownerUID)
		name := "New"
		ctx, info := logger.WithRequestInfo(context.Background())
		_, _ = f.svc.UpdateCommunity(ctx, ownerUID, UpdateInput{Key: goodKey, CommunityID: testCID, Name: &name})
		got := lineFields(info)
		if got["community_hash"] != logger.HashCommunity(testCID) {
			t.Errorf("community_hash = %q", got["community_hash"])
		}
		noRawIDs(t, got, testCID, ownerUID)
	})
	t.Run("moderator leave has it, a member leave does not", func(t *testing.T) {
		f := joinFixture(t)
		f.dir.profiles[modUID] = profile(modUID, identity.AccountStatusActive)
		if _, err := f.svc.GetCommunity(context.Background(), modUID, testCID); err != nil { // warm: lists the moderator
			t.Fatal(err)
		}
		f.repo.leaveRes = LeaveResult{Outcome: Written, State: MemberNone, Community: &Community{ID: testCID, Status: StatusActive, OwnerID: ownerUID}}
		ctx, info := logger.WithRequestInfo(context.Background())
		if _, err := f.svc.LeaveCommunity(ctx, modUID, in(testCID)); err != nil {
			t.Fatal(err)
		}
		got := lineFields(info)
		if got["community_hash"] != logger.HashCommunity(testCID) {
			t.Errorf("moderator leave community_hash = %q", got["community_hash"])
		}
		noRawIDs(t, got, testCID, modUID)

		f2 := joinFixture(t)
		f2.repo.leaveRes = LeaveResult{Outcome: Written, State: MemberNone}
		ctx2, info2 := logger.WithRequestInfo(context.Background())
		if _, err := f2.svc.LeaveCommunity(ctx2, memberUID, in(testCID)); err != nil {
			t.Fatal(err)
		}
		if _, ok := lineFields(info2)["community_hash"]; ok {
			t.Error("a plain member's leave writes no modlog entry and carries no community_hash")
		}
	})
}

func TestModerationRequestLines_MalformedIDIsNeverHashed(t *testing.T) {
	installLogKey(t, "w552-key-one")
	f, _ := modFixture()
	ctx, info := logger.WithRequestInfo(context.Background())
	_ = f.svc.HideCommunityPost(ctx, modUID, PostActionInput{Key: goodKey, CommunityID: "abc", PostID: testPost})
	got := lineFields(info)
	if _, ok := got["community_hash"]; ok {
		t.Errorf("fields = %v, want no community_hash for a malformed id", got)
	}
}
