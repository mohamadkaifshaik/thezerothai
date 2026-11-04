package communities

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// fakeModRepo is an in-memory ModerationRepo that records its calls (guarded by mu).
type fakeModRepo struct {
	mu      sync.Mutex
	posts   []ModeratePostParams
	roles   []SetRoleParams
	postRes ModeratePostResult
	roleRes SetRoleResult
	postErr error
	roleErr error
}

func (r *fakeModRepo) ModeratePost(_ context.Context, p ModeratePostParams) (ModeratePostResult, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.posts = append(r.posts, p)
	return r.postRes, r.postErr
}

func (r *fakeModRepo) SetRole(_ context.Context, p SetRoleParams) (SetRoleResult, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.roles = append(r.roles, p)
	return r.roleRes, r.roleErr
}

const (
	testPost = "0000000000000000611"
	userKey  = "target1"
)

func modFixture() (*fixture, *fakeModRepo) {
	f := newFixture()
	f.dir.profiles[userKey] = profile(userKey, identity.AccountStatusActive)
	f.dir.profiles["gone"] = profile("gone", identity.AccountStatusDeleting)
	m := &fakeModRepo{}
	f.svc.mod = m
	f.svc.d.CursorKey = []byte("0123456789abcdef0123456789abcdef")
	return f, m
}

func TestHideRestore_ValidationRunsBeforeAnyRead(t *testing.T) {
	tests := []struct {
		name  string
		in    PostActionInput
		field string
	}{
		{"short key", PostActionInput{Key: "k", CommunityID: testCID, PostID: testPost}, "idempotency_key"},
		{"bad community id", PostActionInput{Key: goodKey, CommunityID: "abc", PostID: testPost}, "community_id"},
		{"bad post id", PostActionInput{Key: goodKey, CommunityID: testCID, PostID: "12"}, "post_id"},
	}
	for _, tc := range tests {
		for _, restore := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/restore=%v", tc.name, restore), func(t *testing.T) {
				f, m := modFixture()
				call := f.svc.HideCommunityPost
				if restore {
					call = f.svc.RestoreCommunityPost
				}
				err := call(context.Background(), modUID, tc.in)
				wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, nil)
				if len(m.posts) != 0 || f.repo.gets != 0 {
					t.Errorf("validation touched storage: %d writes, %d gets", len(m.posts), f.repo.gets)
				}
			})
		}
	}
}

func TestHideCommunityPost_PassesTheRequestAndCachesTheWrittenCommunity(t *testing.T) {
	f, m := modFixture()
	f.svc.d.Limits.RecentRemovalsMax, f.svc.d.Limits.ModlogMax = 50, 100
	written := Community{ID: testCID, Name: "Go", OwnerID: ownerUID, Status: StatusActive, RecentRemovals: []Removal{{PostID: testPost, At: testNow}}}
	m.postRes = ModeratePostResult{Outcome: Written, Community: written}
	if err := f.svc.HideCommunityPost(context.Background(), modUID, PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost}); err != nil {
		t.Fatal(err)
	}
	p := m.posts[0]
	if p.UID != modUID || p.ID != testCID || p.PostID != testPost || p.Restore || p.RemovalsMax != 50 || p.ModlogMax != 100 || p.IdemKey == "" || p.RequestHash == "" {
		t.Errorf("params = %+v", p)
	}
	// the hide and the restore of the same post and key are different requests (rpc is part of the idempotency key)
	if err := f.svc.RestoreCommunityPost(context.Background(), modUID, PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost}); err != nil {
		t.Fatal(err)
	}
	if q := m.posts[1]; !q.Restore || q.IdemKey == p.IdemKey {
		t.Errorf("restore params = %+v, the same idempotency key as the hide", q)
	}
	// the written document replaced the cache entry: Reader.Get answers from it with no read
	got, err := f.svc.Get(context.Background(), testCID)
	if err != nil || len(got.RecentRemovals) != 1 || f.repo.gets != 0 {
		t.Errorf("Get = %+v, %v (gets %d), want the written community from the cache", got.RecentRemovals, err, f.repo.gets)
	}
}

func TestHideCommunityPost_ReplayAndNoChangeLeaveTheCacheAlone(t *testing.T) {
	for _, o := range []Outcome{Replayed, Unchanged} {
		f, m := modFixture()
		m.postRes = ModeratePostResult{Outcome: o, Community: Community{ID: testCID, RecentRemovals: []Removal{{PostID: "x"}}}}
		if err := f.svc.HideCommunityPost(context.Background(), modUID, PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost}); err != nil {
			t.Fatal(err)
		}
		if _, ok := f.svc.cache.get(testCID); ok {
			t.Errorf("outcome %v put a community in the cache", o)
		}
	}
}

func TestModeration_ErrorMapping(t *testing.T) {
	tests := []struct {
		name   string
		err    error
		code   connect.Code
		reason commonv1.ErrorReason
		meta   map[string]string
	}{
		{"not a moderator", ErrNotModerator, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_moderator"}},
		{"not the owner", ErrNotOwner, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_owner"}},
		{"moderator target", ErrModeratorTarget, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, map[string]string{"reason": "moderator"}},
		{"archived", ErrArchived, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, map[string]string{"reason": "community_archived"}},
		{"moderator cap", ErrModeratorCap, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "community_moderators"}},
		{"bad target", ErrBadTarget, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, nil},
		{"post not found", ErrPostNotFound, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil},
		{"community not found", ErrNotFound, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil},
		{"key reused", ErrKeyReused, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f, m := modFixture()
			m.postErr, m.roleErr = tc.err, tc.err
			err := f.svc.HideCommunityPost(context.Background(), modUID, PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost})
			wantAPIErr(t, err, tc.code, tc.reason, tc.meta)
			_, err = f.svc.SetMemberRole(context.Background(), modUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: userKey, Action: RoleActionBan})
			wantAPIErr(t, err, tc.code, tc.reason, tc.meta)
		})
	}
	// an unknown error is a redacted internal error that names neither the uid nor the community
	f, m := modFixture()
	m.postErr = errors.New("rpc error: documents/communities/" + testCID + "/communityMembers/" + modUID)
	err := f.svc.HideCommunityPost(context.Background(), modUID, PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost})
	if err == nil || strings.Contains(err.Error(), testCID) || strings.Contains(err.Error(), modUID) {
		t.Errorf("internal error = %v, want it redacted", err)
	}
}

func TestSetMemberRole_ValidationAndTargetProfile(t *testing.T) {
	tests := []struct {
		name  string
		in    RoleInput
		field string // "" = NOT_FOUND user
	}{
		{"short key", RoleInput{Key: "k", CommunityID: testCID, UserID: userKey, Action: RoleActionBan}, "idempotency_key"},
		{"bad community", RoleInput{Key: goodKey, CommunityID: "x", UserID: userKey, Action: RoleActionBan}, "community_id"},
		{"bad user id", RoleInput{Key: goodKey, CommunityID: testCID, UserID: "a_b", Action: RoleActionBan}, "user_id"},
		{"empty user id", RoleInput{Key: goodKey, CommunityID: testCID, UserID: "", Action: RoleActionBan}, "user_id"},
		{"unspecified action", RoleInput{Key: goodKey, CommunityID: testCID, UserID: userKey}, "action"},
		{"unknown user", RoleInput{Key: goodKey, CommunityID: testCID, UserID: "ghost", Action: RoleActionBan}, ""},
		{"deleting user", RoleInput{Key: goodKey, CommunityID: testCID, UserID: "gone", Action: RoleActionBan}, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f, m := modFixture()
			_, err := f.svc.SetMemberRole(context.Background(), modUID, tc.in)
			if tc.field == "" {
				wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
				if !strings.Contains(err.Error(), "user not found") {
					t.Errorf("err = %v, want the 'user not found' text", err)
				}
			} else {
				wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, nil)
			}
			if len(m.roles) != 0 {
				t.Error("the repository ran")
			}
		})
	}
}

func TestSetMemberRole_WriteFillsTheCaches(t *testing.T) {
	f, m := modFixture()
	c := Community{ID: testCID, OwnerID: ownerUID, ModeratorIDs: []string{modUID}, MemberCount: 3, Status: StatusActive}
	m.roleRes = SetRoleResult{Outcome: Written, Community: c, TargetState: MemberBanned}
	f.svc.cache.putMemberships(userKey, Memberships{Joined: []string{testCID}})
	f.svc.cache.putMemberships(modUID, Memberships{})
	res, err := f.svc.SetMemberRole(context.Background(), modUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: userKey, Action: RoleActionBan})
	if err != nil || res.Role != RoleBanned || res.View.Role != RoleModerator || res.View.Community.MemberCount != 3 {
		t.Fatalf("result = %+v, %v", res, err)
	}
	if st, ok := f.svc.cache.getMember(testCID, userKey); !ok || st != MemberBanned {
		t.Errorf("member cache = %v, %v", st, ok)
	}
	for _, u := range []string{userKey, modUID} {
		if _, ok := f.svc.cache.getMemberships(u); ok {
			t.Errorf("memberships cache of %s survived the write", u)
		}
	}
	p := m.roles[0]
	if p.Action != RoleActionBan || p.Target != userKey || p.UID != modUID || p.MaxModerators != 10 || p.IdemKey == "" {
		t.Errorf("params = %+v (MaxModerators falls back to 10)", p)
	}
	// MAKE_MODERATOR answers the target's role from the written community
	c.ModeratorIDs = []string{modUID, userKey}
	m.roleRes = SetRoleResult{Outcome: Written, Community: c, TargetState: MemberJoined}
	res, err = f.svc.SetMemberRole(context.Background(), ownerUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: userKey, Action: RoleActionMakeModerator})
	if err != nil || res.Role != RoleModerator || res.View.Role != RoleOwner {
		t.Errorf("MAKE result = %+v, %v", res, err)
	}
	// a replay or no change leaves the member cache alone
	f.svc.cache.putMember(testCID, userKey, MemberJoined)
	m.roleRes = SetRoleResult{Outcome: Replayed, Community: c, TargetState: MemberBanned}
	if _, err := f.svc.SetMemberRole(context.Background(), modUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: userKey, Action: RoleActionBan}); err != nil {
		t.Fatal(err)
	}
	if st, _ := f.svc.cache.getMember(testCID, userKey); st != MemberJoined {
		t.Errorf("a replay changed the member cache to %v", st)
	}
}

func TestModerationRepoMissingIsAnInternalError(t *testing.T) {
	f := newFixture()
	err := f.svc.HideCommunityPost(context.Background(), modUID, PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost})
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Errorf("err = %v, want a plain internal error for an unwired repository (the interceptor maps it to INTERNAL)", err)
	}
}

func logCommunity(n int) Community {
	c := Community{ID: testCID, OwnerID: ownerUID, ModeratorIDs: []string{modUID}, Status: StatusActive}
	for i := 1; i <= n; i++ {
		e := LogEntry{Seq: int64(i), At: testNow.Add(time.Duration(i) * time.Minute), Actor: modUID, Action: ActionHide, PostID: testPost}
		switch i % 4 {
		case 1:
			e.Actor, e.Action, e.Target = DeletedMarker, ActionBan, userKey
		case 2:
			e.Action, e.Target, e.PostID = ActionBan, "gone", ""
		case 3:
			e.Action, e.Target, e.PostID = ActionUnban, DeletedMarker, ""
		}
		c.Modlog = append(c.Modlog, e)
	}
	c.ModlogSeq = int64(n)
	return c
}

func TestListModerationLog_RolesPagingAndPeople(t *testing.T) {
	f, _ := modFixture()
	f.seed(logCommunity(60))
	// who may read
	for _, tc := range []struct {
		uid string
		ok  bool
	}{{ownerUID, true}, {modUID, true}, {memberUID, false}, {bannedUID, false}, {nobodyUID, false}} {
		_, err := f.svc.ListModerationLog(context.Background(), tc.uid, LogInput{CommunityID: testCID})
		if tc.ok && err != nil {
			t.Errorf("%s: %v", tc.uid, err)
		}
		if !tc.ok {
			wantAPIErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_moderator"})
		}
	}
	// 25 a page whatever is asked, newest first, the token carries the last seq
	p1, err := f.svc.ListModerationLog(context.Background(), ownerUID, LogInput{CommunityID: testCID, PageSize: 50})
	if err != nil || len(p1.Items) != 25 || p1.Items[0].Entry.Seq != 60 || p1.Items[24].Entry.Seq != 36 || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %d items, token %q, err %v", len(p1.Items), p1.NextPageToken, err)
	}
	p2, err := f.svc.ListModerationLog(context.Background(), ownerUID, LogInput{CommunityID: testCID, PageToken: p1.NextPageToken})
	if err != nil || len(p2.Items) != 25 || p2.Items[0].Entry.Seq != 35 || p2.NextPageToken == "" {
		t.Fatalf("page 2 = %d items, err %v", len(p2.Items), err)
	}
	p3, err := f.svc.ListModerationLog(context.Background(), ownerUID, LogInput{CommunityID: testCID, PageToken: p2.NextPageToken})
	if err != nil || len(p3.Items) != 10 || p3.Items[9].Entry.Seq != 1 || p3.NextPageToken != "" {
		t.Fatalf("page 3 = %d items, token %q, err %v", len(p3.Items), p3.NextPageToken, err)
	}
	// people: the deleted marker and a non-ACTIVE account read as deleted; a live one is a row; no target is neither
	byAction := map[int64]LogItem{}
	for _, it := range append(append(p1.Items, p2.Items...), p3.Items...) {
		byAction[it.Entry.Seq] = it
	}
	if it := byAction[1]; !it.ActorDeleted || it.Target == nil || it.TargetDeleted { // seq 1: deleted actor, live target
		t.Errorf("seq 1 = %+v", it)
	}
	if it := byAction[2]; it.ActorDeleted || it.Actor == nil || !it.TargetDeleted || it.Target != nil { // target is a DELETING account
		t.Errorf("seq 2 = %+v", it)
	}
	if it := byAction[3]; !it.TargetDeleted || it.Actor == nil { // target is the marker
		t.Errorf("seq 3 = %+v", it)
	}
	if it := byAction[4]; it.Target != nil || it.TargetDeleted || it.ActorDeleted || it.Entry.PostID != testPost { // a hide has no target
		t.Errorf("seq 4 = %+v", it)
	}
	// tokens are bound to the caller and the community; garbage is VALIDATION with no read
	gets := f.repo.gets
	for _, tok := range []string{"garbage", p1.NextPageToken} {
		who := ownerUID
		if tok == p1.NextPageToken {
			who = modUID
		}
		_, err = f.svc.ListModerationLog(context.Background(), who, LogInput{CommunityID: testCID, PageToken: tok})
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, nil)
	}
	if f.repo.gets != gets {
		t.Error("a bad page token cost a read")
	}
}

func TestListModerationLog_StatusRules(t *testing.T) {
	f, _ := modFixture()
	f.seed(logCommunity(2))
	_, err0 := f.svc.ListModerationLog(context.Background(), ownerUID, LogInput{CommunityID: "1"})
	wantAPIErr(t, err0, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, nil)
	// ARCHIVED is readable, SUSPENDED and missing are the one NOT_FOUND
	c := logCommunity(2)
	c.Status = StatusArchived
	f.seed(c)
	f.svc.cache.communities.Delete(testCID)
	if page, err := f.svc.ListModerationLog(context.Background(), ownerUID, LogInput{CommunityID: testCID}); err != nil || len(page.Items) != 2 {
		t.Errorf("archived: %d items, %v", len(page.Items), err)
	}
	c.Status = StatusSuspended
	f.seed(c)
	f.svc.cache.communities.Delete(testCID)
	_, err := f.svc.ListModerationLog(context.Background(), ownerUID, LogInput{CommunityID: testCID})
	wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	_, err = f.svc.ListModerationLog(context.Background(), ownerUID, LogInput{CommunityID: otherCID})
	wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	// an empty log is an empty page
	f.seed(Community{ID: testCID, OwnerID: ownerUID})
	f.svc.cache.communities.Delete(testCID)
	if page, err := f.svc.ListModerationLog(context.Background(), ownerUID, LogInput{CommunityID: testCID}); err != nil || len(page.Items) != 0 || page.NextPageToken != "" {
		t.Errorf("empty log: %+v, %v", page, err)
	}
}

func TestAppendLog_KeepsTheNewest100AndNumbersEntries(t *testing.T) {
	c := logCommunity(100)
	log, seq := appendLog(c, LogEntry{At: testNow, Actor: modUID, Action: ActionHide, PostID: testPost}, 100)
	if len(log) != 100 || seq != 101 || log[0].Seq != 2 || log[99].Seq != 101 {
		t.Errorf("101st entry: len %d seq %d first %d last %d, want the oldest dropped", len(log), seq, log[0].Seq, log[99].Seq)
	}
	if len(c.Modlog) != 100 || c.Modlog[0].Seq != 1 {
		t.Error("appendLog changed its input")
	}
	if log, _ = appendLog(Community{}, LogEntry{}, 0); len(log) != 1 {
		t.Error("a zero cap must fall back to the default, not drop everything")
	}
}

func TestRemovalsAfter_RestoreHideAndCap(t *testing.T) {
	c := Community{RecentRemovals: []Removal{{PostID: "a", At: testNow}, {PostID: "b", At: testNow.Add(time.Minute)}}}
	if got, trunc := removalsAfter(c, "a", true, testNow, 50); len(got) != 1 || got[0].PostID != "b" || !trunc.IsZero() {
		t.Errorf("restore: %+v %v", got, trunc)
	}
	if got, _ := removalsAfter(c, "a", false, testNow.Add(time.Hour), 50); len(got) != 2 || got[1].PostID != "a" {
		t.Errorf("a repeated hide must move the entry, not duplicate it: %+v", got)
	}
	got, trunc := removalsAfter(c, "c", false, testNow.Add(time.Hour), 2)
	if len(got) != 2 || got[0].PostID != "b" || got[1].PostID != "c" || !trunc.Equal(testNow) {
		t.Errorf("cap 2: %+v truncatedAt %v, want [b c] and the dropped entry's time", got, trunc)
	}
}

func TestServerModeration_GateThenServiceAndMapping(t *testing.T) {
	for _, m := range flagModes() {
		t.Run(m.name, func(t *testing.T) {
			svc := &fakeService{roleRes: RoleResult{Role: RoleBanned, View: sampleView()}}
			s := NewServer(flags.NewRegistry(m.spec), svc)
			ctx := authedCtx(m.uid)
			_, e1 := s.HideCommunityPost(ctx, connect.NewRequest(&communitiesv1.HideCommunityPostRequest{IdempotencyKey: goodKey, CommunityId: testCID, PostId: testPost}))
			_, e2 := s.RestoreCommunityPost(ctx, connect.NewRequest(&communitiesv1.RestoreCommunityPostRequest{IdempotencyKey: goodKey, CommunityId: testCID, PostId: testPost}))
			_, e3 := s.SetMemberRole(ctx, connect.NewRequest(&communitiesv1.SetMemberRoleRequest{IdempotencyKey: goodKey, CommunityId: testCID, UserId: userKey, Action: communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_UNBAN}))
			_, e4 := s.ListModerationLog(ctx, connect.NewRequest(&communitiesv1.ListModerationLogRequest{CommunityId: testCID, PageSize: 7}))
			touched := len(svc.hides) + len(svc.restores) + len(svc.roles) + len(svc.logs)
			for _, err := range []error{e1, e2, e3, e4} {
				if m.wantOff {
					assertDisabled(t, err)
				} else if err != nil {
					t.Errorf("flag on: %v", err)
				}
			}
			if m.wantOff && touched != 0 {
				t.Error("the service ran for a caller outside the flag")
			}
			if !m.wantOff && (touched != 4 || svc.roles[0].Action != RoleActionUnban || svc.roles[0].UserID != userKey || svc.logs[0].PageSize != 7 || svc.hides[0].PostID != testPost) {
				t.Errorf("the request did not reach the service intact: %+v %+v %+v", svc.hides, svc.roles, svc.logs)
			}
		})
	}
}

func TestServerModeration_ResponseShapes(t *testing.T) {
	svc := &fakeService{
		roleRes: RoleResult{Role: RoleBanned, View: View{Role: RoleModerator, Community: Community{ID: testCID, Name: "Go", MemberCount: 3, Status: StatusActive, CreatedAt: testNow}}},
		logPage: LogPage{NextPageToken: "tok", Items: []LogItem{
			{Entry: LogEntry{Seq: 2, At: testNow, Action: ActionBan}, Actor: &identity.Profile{UserID: modUID, Handle: "h", IsPrivate: true}, Target: &identity.Profile{UserID: userKey, Handle: "t"}},
			{Entry: LogEntry{Seq: 1, At: testNow, Action: ActionOwnerHandover}, ActorDeleted: true, TargetDeleted: true},
		}},
	}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
	ctx := authedCtx(modUID)
	r, err := s.SetMemberRole(ctx, connect.NewRequest(&communitiesv1.SetMemberRoleRequest{IdempotencyKey: goodKey, CommunityId: testCID, UserId: userKey, Action: communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_BAN}))
	if err != nil || r.Msg.Role != communitiesv1.CommunityRole_COMMUNITY_ROLE_BANNED || r.Msg.Community.MemberCount != 3 || r.Msg.Community.ViewerRole != communitiesv1.CommunityRole_COMMUNITY_ROLE_MODERATOR {
		t.Errorf("SetMemberRole response = %+v, %v", r, err)
	}
	if svc.roles[0].Action != RoleActionBan {
		t.Errorf("action = %v", svc.roles[0].Action)
	}
	l, err := s.ListModerationLog(ctx, connect.NewRequest(&communitiesv1.ListModerationLogRequest{CommunityId: testCID}))
	if err != nil || len(l.Msg.Entries) != 2 || l.Msg.NextPageToken != "tok" {
		t.Fatalf("ListModerationLog = %+v, %v", l, err)
	}
	e0, e1 := l.Msg.Entries[0], l.Msg.Entries[1]
	if e0.Action != communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_BAN || e0.Actor.GetUserId() != modUID || e0.Actor.GetIsPrivate() || e0.Target.GetUserId() != userKey || e0.ActorDeleted {
		t.Errorf("entry 0 = %+v (the lock badge stays unset)", e0)
	}
	if e1.Action != communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_OWNER_HANDOVER || e1.Actor != nil || e1.Target != nil || !e1.ActorDeleted || !e1.TargetDeleted {
		t.Errorf("entry 1 = %+v", e1)
	}
	// every stored action has a wire value; an unknown one is UNSPECIFIED
	for _, a := range []string{ActionHide, ActionRestore, ActionBan, ActionUnban, ActionMakeModerator, ActionRemoveMod, ActionEdit, ActionModeratorLeft, ActionOwnerHandover} {
		if logActionToProto(a) == communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_UNSPECIFIED {
			t.Errorf("action %s has no wire value", a)
		}
	}
	if logActionToProto("NEW") != communitiesv1.ModerationLogAction_MODERATION_LOG_ACTION_UNSPECIFIED || roleActionFromProto(communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_UNSPECIFIED) != RoleActionNone {
		t.Error("unknown values must map to the zero value")
	}
	// a service error is passed through
	svc.err = NotFoundError()
	_, err = s.HideCommunityPost(ctx, connect.NewRequest(&communitiesv1.HideCommunityPostRequest{}))
	wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
}

func TestRoleActionNames(t *testing.T) {
	for a, want := range map[RoleAction]string{RoleActionBan: "ban", RoleActionUnban: "unban", RoleActionMakeModerator: "make_moderator", RoleActionRemoveModerator: "remove_moderator", RoleActionNone: "none"} {
		if a.String() != want {
			t.Errorf("%d = %q, want %q", a, a.String(), want)
		}
	}
}

// OnPostRestored fires once, only after a committed (Written) restore; never on a hide, a replay, a no-op or an error.
func TestRestoreCommunityPost_OnPostRestoredOnlyAfterACommittedRestore(t *testing.T) {
	tests := []struct {
		name    string
		restore bool
		out     Outcome
		err     error
		want    int
	}{
		{"committed restore", true, Written, nil, 1},
		{"replayed restore", true, Replayed, nil, 0},
		{"unchanged restore", true, Unchanged, nil, 0},
		{"failed restore", true, Written, ErrNotModerator, 0},
		{"committed hide", false, Written, nil, 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f, m := modFixture()
			var got []string
			f.svc.d.OnPostRestored = func(cid string) { got = append(got, cid) }
			m.postRes = ModeratePostResult{Outcome: tc.out, Community: Community{ID: testCID, Status: StatusActive}}
			m.postErr = tc.err
			in := PostActionInput{Key: goodKey, CommunityID: testCID, PostID: testPost}
			call := f.svc.HideCommunityPost
			if tc.restore {
				call = f.svc.RestoreCommunityPost
			}
			_ = call(context.Background(), modUID, in)
			if len(got) != tc.want || (tc.want == 1 && got[0] != testCID) {
				t.Errorf("callback calls = %v, want %d", got, tc.want)
			}
		})
	}
}

// A RESTORE entry of the platform marker has no person: an unset actor with actor_deleted false, and the marker is never
// looked up in the directory.
func TestListModerationLog_PlatformMarkerIsNoPerson(t *testing.T) {
	f, _ := modFixture()
	c := Community{ID: testCID, OwnerID: ownerUID, ModeratorIDs: []string{modUID}, Status: StatusActive, ModlogSeq: 2, Modlog: []LogEntry{
		{Seq: 1, At: testNow, Actor: modUID, Action: ActionHide, PostID: testPost},
		{Seq: 2, At: testNow.Add(time.Minute), Actor: PlatformMarker, Action: ActionRestore},
	}}
	f.seed(c)
	page, err := f.svc.ListModerationLog(context.Background(), ownerUID, LogInput{CommunityID: testCID})
	if err != nil || len(page.Items) != 2 {
		t.Fatalf("items = %d, err %v", len(page.Items), err)
	}
	if it := page.Items[0]; it.Entry.Actor != PlatformMarker || it.Actor != nil || it.ActorDeleted || it.Target != nil || it.TargetDeleted {
		t.Errorf("platform entry = %+v", it)
	}
	if it := page.Items[1]; it.Actor == nil || it.ActorDeleted {
		t.Errorf("moderator entry = %+v", it)
	}
}
