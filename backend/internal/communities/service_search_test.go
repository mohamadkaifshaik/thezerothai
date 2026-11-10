package communities

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// F36: SearchCommunityMembers.

// fakePrefixes is a HandlePrefixReader over a fixed handle list (uid == handle here), with a real (prefix, limit) cache
// so the hit flag behaves like search.PrefixCache.
type fakePrefixes struct {
	users  []string
	calls  []string // prefix|limit of every Lookup
	misses int
	seen   map[string]bool
	err    error
}

func (p *fakePrefixes) Lookup(_ context.Context, prefix string, limit int) ([]identity.Profile, bool, error) {
	key := fmt.Sprintf("%s|%d", prefix, limit)
	p.calls = append(p.calls, key)
	if p.err != nil {
		return nil, false, p.err
	}
	hit := p.seen[key]
	if !hit {
		p.misses++
		if p.seen == nil {
			p.seen = map[string]bool{}
		}
		p.seen[key] = true
	}
	var out []identity.Profile
	for _, u := range p.users {
		if strings.HasPrefix(u, prefix) && len(out) < limit {
			out = append(out, profile(u, identity.AccountStatusActive))
		}
	}
	return out, hit, nil
}

// searchFixture: community testCID owned by owner1 with moderator mod1; members alice, alina, alex (JOINED), albert
// (BANNED); alfred is not a member. The flag is on for everyone unless a test changes it.
func searchFixture(t *testing.T) (*fixture, *fakePrefixes) {
	t.Helper()
	f := newListFixture()
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID, ModeratorIDs: []string{modUID}})
	px := &fakePrefixes{users: []string{"albert", "alex", "alfred", "alice", "alina"}}
	f.svc.d.Handles = px
	f.svc.d.Flags = flags.NewRegistry(flags.Spec{Name: MemberSearchFlagName, Mode: flags.On})
	f.repo.lst.entries = map[string]MemberEntry{
		testCID + "|alice":  {State: MemberJoined, At: testNow.Add(-time.Hour)},
		testCID + "|alina":  {State: MemberJoined, At: testNow.Add(-2 * time.Hour)},
		testCID + "|alex":   {State: MemberJoined, At: testNow.Add(-3 * time.Hour)},
		testCID + "|albert": {State: MemberBanned, At: testNow.Add(-4 * time.Hour)},
	}
	return f, px
}

func itemUIDs(items []MemberItem) string {
	var out []string
	for _, it := range items {
		out = append(out, it.Profile.UserID)
	}
	return fmt.Sprint(out)
}

func TestNormalizeSearchPrefix(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"al", "al"}, {"@Al", "al"}, {"  AL_9 ", "al_9"}, {"abcdefghijklmno", "abcdefghijklmno"},
		{"a", ""}, {"@a", ""}, {"", ""}, {"abcdefghijklmnop", ""}, {"al ice", ""}, {"#al", ""}, {"@@al", ""}, {"ál", ""},
	} {
		got, err := normalizeSearchPrefix(tc.in)
		if tc.want == "" {
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "prefix"})
			continue
		}
		if err != nil || got != tc.want {
			t.Errorf("normalizeSearchPrefix(%q) = %q, %v; want %q", tc.in, got, err, tc.want)
		}
	}
}

func TestSearchLimit(t *testing.T) {
	for in, want := range map[int32]int{0: 20, -5: 1, 1: 1, 7: 7, 20: 20, 21: 20, 1000: 20} {
		if got := searchLimit(in); got != want {
			t.Errorf("searchLimit(%d) = %d, want %d", in, got, want)
		}
	}
}

func TestSearchCommunityMembers_FlagModes(t *testing.T) {
	allow := map[string]struct{}{"in": {}}
	for _, tc := range []struct {
		name string
		spec flags.Spec
		uid  string
		off  bool
	}{
		{"off", flags.Spec{Name: MemberSearchFlagName, Mode: flags.Off, Allowlist: allow}, "in", true},
		{"allowlist, listed", flags.Spec{Name: MemberSearchFlagName, Mode: flags.Allowlist, Allowlist: allow}, "in", false},
		{"allowlist, unlisted", flags.Spec{Name: MemberSearchFlagName, Mode: flags.Allowlist, Allowlist: allow}, "out", true},
		{"percent 0", flags.Spec{Name: MemberSearchFlagName, Mode: flags.Percent}, "in", true},
		{"percent 100", flags.Spec{Name: MemberSearchFlagName, Mode: flags.Percent, Percent: 100}, "out", false},
		{"on", flags.Spec{Name: MemberSearchFlagName, Mode: flags.On}, "out", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, px := searchFixture(t)
			f.svc.d.Flags = flags.NewRegistry(tc.spec)
			_, err := f.svc.SearchCommunityMembers(context.Background(), tc.uid, SearchInput{CommunityID: testCID, Prefix: "al"})
			if tc.off {
				wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": MemberSearchFlagName})
				if len(px.calls) != 0 || len(f.repo.lst.byUIDCalls) != 0 {
					t.Error("a lookup ran with the flag off")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
		})
	}
	t.Run("nil checker is off", func(t *testing.T) {
		f, _ := searchFixture(t)
		f.svc.d.Flags = nil
		_, err := f.svc.SearchCommunityMembers(context.Background(), "in", SearchInput{CommunityID: testCID, Prefix: "al"})
		wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": MemberSearchFlagName})
	})
}

func TestSearchCommunityMembers_Rows(t *testing.T) {
	for _, tc := range []struct {
		name   string
		uid    string
		in     SearchInput
		snap   graph.Snapshot
		want   string
		banned bool
	}{
		{"members only, non-member dropped, handle order", "viewer", SearchInput{Prefix: "al"}, graph.Snapshot{}, "[alex alice alina]", false},
		{"narrower prefix", "viewer", SearchInput{Prefix: "@ALI"}, graph.Snapshot{}, "[alice alina]", false},
		{"limit applies to the global candidates (top-N trade-off)", "viewer", SearchInput{Prefix: "al", Limit: 2}, graph.Snapshot{}, "[alex]", false},
		{"D7: a member who blocks the viewer is dropped", "viewer", SearchInput{Prefix: "al"}, graph.Snapshot{BlockedBy: map[string]bool{"alice": true}}, "[alex alina]", false},
		{"F14: a moderator sees past blocks", modUID, SearchInput{Prefix: "al"}, graph.Snapshot{Blocked: map[string]bool{"alice": true}}, "[alex alice alina]", false},
		{"banned search for a moderator", ownerUID, SearchInput{Prefix: "al", Filter: FilterBanned}, graph.Snapshot{}, "[albert]", true},
		{"no match", "viewer", SearchInput{Prefix: "zz"}, graph.Snapshot{}, "[]", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, _ := searchFixture(t)
			f.gr.snap = tc.snap
			tc.in.CommunityID = testCID
			items, err := f.svc.SearchCommunityMembers(context.Background(), tc.uid, tc.in)
			if err != nil {
				t.Fatal(err)
			}
			if got := itemUIDs(items); got != tc.want {
				t.Fatalf("rows = %s, want %s", got, tc.want)
			}
			for _, it := range items {
				want := RoleMember
				if tc.banned {
					want = RoleBanned
				}
				if it.Role != want || !it.Since.Equal(f.repo.lst.entries[testCID+"|"+it.Profile.UserID].At) {
					t.Errorf("%s: role %v since %v", it.Profile.UserID, it.Role, it.Since)
				}
			}
		})
	}
}

func TestSearchCommunityMembers_Refusals(t *testing.T) {
	ctx := context.Background()
	t.Run("banned for a non-moderator is FORBIDDEN after the community read", func(t *testing.T) {
		f, px := searchFixture(t)
		_, err := f.svc.SearchCommunityMembers(ctx, "alice", SearchInput{CommunityID: testCID, Prefix: "al", Filter: FilterBanned})
		wantAPIErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_moderator"})
		if len(px.calls) != 0 {
			t.Error("handle lookup ran for a refused caller")
		}
	})
	for name, in := range map[string]SearchInput{
		"prefix too short":   {CommunityID: testCID, Prefix: "a"},
		"bad community id":   {CommunityID: "12", Prefix: "al"},
		"unknown filter":     {CommunityID: testCID, Prefix: "al", Filter: MemberFilter(-1)},
		"filter not allowed": {CommunityID: testCID, Prefix: "al", Filter: MemberFilter(7)},
	} {
		t.Run(name, func(t *testing.T) {
			f, px := searchFixture(t)
			_, err := f.svc.SearchCommunityMembers(ctx, "viewer", in)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != connect.CodeInvalidArgument || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION {
				t.Fatalf("err = %v, want VALIDATION", err)
			}
			if len(px.calls) != 0 {
				t.Error("a lookup ran for an invalid request")
			}
		})
	}
	t.Run("missing and suspended are NOT_FOUND", func(t *testing.T) {
		f, _ := searchFixture(t)
		f.seed(Community{ID: otherCID, Name: "S", OwnerID: ownerUID, Status: StatusSuspended})
		for _, id := range []string{otherCID, "0000000000000000999"} {
			_, err := f.svc.SearchCommunityMembers(ctx, ownerUID, SearchInput{CommunityID: id, Prefix: "al"})
			wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		}
	})
	t.Run("a lookup error is an internal error, never a partial answer", func(t *testing.T) {
		f, px := searchFixture(t)
		px.err = errors.New("firestore down")
		if _, err := f.svc.SearchCommunityMembers(ctx, "viewer", SearchInput{CommunityID: testCID, Prefix: "al"}); err == nil {
			t.Fatal("no error")
		}
	})
}

// TestSearchCommunityMembers_PrefixCacheAndLimit: the candidate read goes through the shared (prefix, limit) cache with
// the clamped limit, so a repeat is a hit; limit 0 asks for 20 and 99 is clamped to 20.
func TestSearchCommunityMembers_PrefixCacheAndLimit(t *testing.T) {
	f, px := searchFixture(t)
	ctx := context.Background()
	for _, l := range []int32{0, 99, 5} {
		if _, err := f.svc.SearchCommunityMembers(ctx, "viewer", SearchInput{CommunityID: testCID, Prefix: "@AL", Limit: l}); err != nil {
			t.Fatal(err)
		}
	}
	if fmt.Sprint(px.calls) != "[al|20 al|20 al|5]" || px.misses != 2 {
		t.Fatalf("lookups = %v, misses %d; want al|20 twice (one hit) and al|5", px.calls, px.misses)
	}
}

// TestServer_SearchCommunityMembers: the communities gate runs first (FEATURE_DISABLED feature=communities when off,
// whatever the member search flag), then the request reaches the service with the filter mapped; rows render as on the
// member page.
func TestServer_SearchCommunityMembers(t *testing.T) {
	off := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Off}, flags.Spec{Name: MemberSearchFlagName, Mode: flags.On}), &fakeService{})
	_, err := off.SearchCommunityMembers(authedCtx("u1"), connect.NewRequest(&communitiesv1.SearchCommunityMembersRequest{CommunityId: testCID, Prefix: "al"}))
	wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": FlagName})

	since := time.Now().Truncate(time.Second)
	svc := &fakeService{searchItems: []MemberItem{{Profile: profile("alice", identity.AccountStatusActive), Since: since, Role: RoleMember}}}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
	for _, tc := range []struct {
		in   communitiesv1.CommunityMemberFilter
		want MemberFilter
	}{
		{communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_UNSPECIFIED, FilterJoined},
		{communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_JOINED, FilterJoined},
		{communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_BANNED, FilterBanned},
		{communitiesv1.CommunityMemberFilter(99), MemberFilter(-1)},
	} {
		resp, err := s.SearchCommunityMembers(authedCtx("u1"), connect.NewRequest(&communitiesv1.SearchCommunityMembersRequest{CommunityId: testCID, Prefix: "al", Filter: tc.in, Limit: 7}))
		if err != nil {
			t.Fatal(err)
		}
		got := svc.searchIn[len(svc.searchIn)-1]
		if got.Filter != tc.want || got.Prefix != "al" || got.Limit != 7 || got.CommunityID != testCID {
			t.Errorf("filter %v: service got %+v", tc.in, got)
		}
		m := resp.Msg.GetMembers()
		if len(m) != 1 || m[0].GetUser().GetUser().GetUserId() != "alice" || m[0].GetRole() != communitiesv1.CommunityRole_COMMUNITY_ROLE_MEMBER || !m[0].GetUser().GetSince().AsTime().Equal(since) {
			t.Errorf("response = %v", resp.Msg)
		}
	}
}
