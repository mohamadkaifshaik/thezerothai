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
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

const (
	testCID   = "0000000000000000501"
	otherCID  = "0000000000000000502"
	ownerUID  = "owner1"
	modUID    = "mod1"
	memberUID = "member1"
	bannedUID = "banned1"
	nobodyUID = "nobody1"
	goodKey   = "integration-key-0001"
)

var testNow = time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)

// fakeRepo is an in-memory Repo that records its calls and charges reads like the Firestore repo does (1 per point read).
type fakeRepo struct {
	mu        sync.Mutex
	docs      map[string]Community
	members   map[string]MemberState // cid|uid
	idem      map[string]string      // idempotency key -> request hash
	creates   []CreateParams
	updates   []UpdateParams
	gets      int
	memberGet int
	createErr error
	updateErr error
	getErr    error
	// replayDoc is what a replay answers with.
	replayDoc Community
	joins     []JoinParams
	leaves    []LeaveParams
	joinRes   JoinResult
	leaveRes  LeaveResult
	joinErr   error
	leaveErr  error
	mships    map[string]Memberships
	mshipsGet int
	manyGets  [][]string
	manyErr   error
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{mships: map[string]Memberships{}, docs: map[string]Community{}, members: map[string]MemberState{}, idem: map[string]string{}}
}

func (r *fakeRepo) Create(_ context.Context, p CreateParams) (CreateResult, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.creates = append(r.creates, p)
	if h, ok := r.idem[p.IdemKey]; ok {
		if h != p.RequestHash {
			return CreateResult{}, ErrKeyReused
		}
		return CreateResult{Outcome: Replayed, Community: r.replayDoc}, nil
	}
	if r.createErr != nil {
		return CreateResult{}, r.createErr
	}
	r.idem[p.IdemKey] = p.RequestHash
	c := Community{ID: p.ID, Name: p.Name, Description: p.Description, Rules: p.Rules, OwnerID: p.UID, MemberCount: 1,
		Status: StatusActive, Visibility: VisibilityPublic, CreatedAt: testNow, UpdatedAt: testNow}
	r.docs[p.ID] = c
	return CreateResult{Outcome: Written, Community: c}, nil
}

func (r *fakeRepo) Update(_ context.Context, p UpdateParams) (UpdateResult, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.updates = append(r.updates, p)
	if h, ok := r.idem[p.IdemKey]; ok {
		if h != p.RequestHash {
			return UpdateResult{}, ErrKeyReused
		}
		return UpdateResult{Outcome: Replayed, Community: r.replayDoc}, nil
	}
	if r.updateErr != nil {
		return UpdateResult{}, r.updateErr
	}
	r.idem[p.IdemKey] = p.RequestHash
	c := r.docs[p.ID]
	if p.Name != nil {
		c.Name = *p.Name
	}
	if p.Description != nil {
		c.Description = *p.Description
	}
	if p.Rules != nil {
		c.Rules = *p.Rules
	}
	r.docs[p.ID] = c
	return UpdateResult{Outcome: Written, Community: c}, nil
}

func (r *fakeRepo) Get(ctx context.Context, id string) (Community, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.gets++
	budget.FromContext(ctx).AddReads(1)
	if r.getErr != nil {
		return Community{}, r.getErr
	}
	c, ok := r.docs[id]
	if !ok {
		return Community{}, ErrNotFound
	}
	return c, nil
}

func (r *fakeRepo) Member(ctx context.Context, cid, uid string) (MemberState, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.memberGet++
	budget.FromContext(ctx).AddReads(1)
	return r.members[cid+"|"+uid], nil
}

// fakeDirectory serves profiles and charges one read per uid it was asked for, like an uncached identity.Directory.
type fakeDirectory struct {
	identity.Directory
	profiles map[string]identity.Profile
	// free makes a lookup cost 0 reads, like the production directory behind the account-status interceptor (it has just loaded the caller).
	free  bool
	asked int
	err   error
}

func (d *fakeDirectory) GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
	d.asked += len(uids)
	if !d.free {
		budget.FromContext(ctx).AddReads(int64(len(uids)))
	}
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if p, ok := d.profiles[u]; ok {
			out[u] = p
		}
	}
	return out, d.err
}

type fakeGraph struct {
	snap  graph.Snapshot
	err   error
	calls int
}

func (g *fakeGraph) Snapshot(ctx context.Context, _ string) (graph.Snapshot, error) {
	g.calls++
	budget.FromContext(ctx).AddReads(1)
	return g.snap, g.err
}

type seqIDs struct{ n int }

func (s *seqIDs) Generate() string { s.n++; return fmt.Sprintf("%019d", 700+s.n) }

func profile(uid string, st identity.AccountStatus) identity.Profile {
	return identity.Profile{UserID: uid, Handle: "h" + uid, DisplayName: "D " + uid, Status: st}
}

type fixture struct {
	svc  *service
	repo *fakeRepo
	dir  *fakeDirectory
	gr   *fakeGraph
}

func newFixture(creators ...string) *fixture {
	repo := newFakeRepo()
	dir := &fakeDirectory{profiles: map[string]identity.Profile{
		ownerUID: profile(ownerUID, identity.AccountStatusActive),
		modUID:   profile(modUID, identity.AccountStatusActive),
		"mod2":   profile("mod2", identity.AccountStatusDeleting),
	}}
	gr := &fakeGraph{}
	s := New(Deps{
		Repo: repo, Directory: dir, Graph: gr, IDs: &seqIDs{}, Creators: creators,
		Limits: Limits{MaxOwned: 2, MaxJoined: 50, MaxRules: 10, ModlogMax: 100, CacheEntries: 50, MembersCacheEntries: 50},
	}).(*service)
	return &fixture{svc: s, repo: repo, dir: dir, gr: gr}
}

func (f *fixture) seed(c Community) {
	if c.Status == "" {
		c.Status = StatusActive
	}
	c.Visibility = VisibilityPublic
	f.repo.docs[c.ID] = c
}

func wantAPIErr(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, meta map[string]string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want *apierr.Error %v/%v", err, code, reason)
	}
	if ae.Code != code || ae.Reason != reason {
		t.Fatalf("err = %v/%v (%s), want %v/%v", ae.Code, ae.Reason, ae.Message, code, reason)
	}
	for k, v := range meta {
		if ae.Metadata[k] != v {
			t.Errorf("metadata[%q] = %q, want %q", k, ae.Metadata[k], v)
		}
	}
}

func TestCreateCommunity_CreatorsCheckIsFirst(t *testing.T) {
	f := newFixture("someone-else")
	// a non-creator who also sends a bad key and bad text still gets not_creator, and nothing is read or written
	_, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{Key: "x", Name: "", Rules: make([]Rule, 99)})
	wantAPIErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_creator"})
	if len(f.repo.creates) != 0 || f.repo.gets != 0 {
		t.Errorf("repo touched for a non-creator: %d creates, %d gets", len(f.repo.creates), f.repo.gets)
	}
}

func TestCreateCommunity_Validation(t *testing.T) {
	rules := func(n int) []Rule {
		out := make([]Rule, n)
		for i := range out {
			out[i] = Rule{Title: fmt.Sprintf("Rule %d", i), Text: "text"}
		}
		return out
	}
	tests := []struct {
		name  string
		in    CreateInput
		field string
	}{
		{"short key", CreateInput{Key: "short", Name: "Go"}, "idempotency_key"},
		{"key with a space", CreateInput{Key: "integration key 0001", Name: "Go"}, "idempotency_key"},
		{"empty name", CreateInput{Key: goodKey, Name: "  "}, "name"},
		{"31 code points", CreateInput{Key: goodKey, Name: strings.Repeat("a", 31)}, "name"},
		{"newline in name", CreateInput{Key: goodKey, Name: "a\nb"}, "name"},
		{"bidi override in name", CreateInput{Key: goodKey, Name: "a" + string(rune(0x202e)) + "b"}, "name"},
		{"161 code point description", CreateInput{Key: goodKey, Name: "Go", Description: strings.Repeat("d", 161)}, "description"},
		{"control character in description", CreateInput{Key: goodKey, Name: "Go", Description: "a\tb"}, "description"},
		{"11 rules", CreateInput{Key: goodKey, Name: "Go", Rules: rules(11)}, "rules"},
		{"empty rule title", CreateInput{Key: goodKey, Name: "Go", Rules: []Rule{{Title: " "}}}, "rules"},
		{"61 code point rule title", CreateInput{Key: goodKey, Name: "Go", Rules: []Rule{{Title: strings.Repeat("t", 61)}}}, "rules"},
		{"newline in a rule title", CreateInput{Key: goodKey, Name: "Go", Rules: []Rule{{Title: "a\nb"}}}, "rules"},
		{"301 code point rule text", CreateInput{Key: goodKey, Name: "Go", Rules: []Rule{{Title: "t", Text: strings.Repeat("x", 301)}}}, "rules"},
		{"bidi control in a rule text", CreateInput{Key: goodKey, Name: "Go", Rules: []Rule{{Title: "t", Text: "a" + string(rune(0x202e)) + "b"}}}, "rules"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := newFixture(ownerUID)
			_, err := f.svc.CreateCommunity(context.Background(), ownerUID, tt.in)
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tt.field})
			if len(f.repo.creates) != 0 {
				t.Errorf("repo reached with invalid input")
			}
		})
	}
}

func TestCreateCommunity_Boundaries(t *testing.T) {
	f := newFixture(ownerUID)
	rules := make([]Rule, 10)
	for i := range rules {
		rules[i] = Rule{Title: strings.Repeat("t", 60), Text: strings.Repeat("x", 300)}
	}
	v, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{
		Key: goodKey, Name: strings.Repeat("n", 30), Description: strings.Repeat("d", 160), Rules: rules,
	})
	if err != nil {
		t.Fatalf("limits exactly at the bounds: %v", err)
	}
	if len(v.Community.Rules) != 10 {
		t.Errorf("rules = %d", len(v.Community.Rules))
	}
}

func TestCreateCommunity_StoresNormalizedAndFillsCaches(t *testing.T) {
	f := newFixture(ownerUID)
	v, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{
		Key: goodKey, Name: "  Café Club ", Description: " about \n us ", Rules: []Rule{{Title: " Be kind ", Text: ""}},
	})
	if err != nil {
		t.Fatal(err)
	}
	p := f.repo.creates[0]
	if p.Name != "Café Club" || p.Description != "about \n us" || p.Rules[0].Title != "Be kind" {
		t.Errorf("stored %q %q %+v, want trimmed NFC", p.Name, p.Description, p.Rules)
	}
	if p.MaxOwned != 2 || p.MaxJoined != 50 || p.UID != ownerUID || len(p.ID) != 19 {
		t.Errorf("params = %+v", p)
	}
	if v.Role != RoleOwner || v.Community.OwnerID != ownerUID {
		t.Errorf("view = %+v, want the OWNER view", v)
	}
	// the written data fills the caches: GetCommunity then reads nothing
	ctx, c := budget.WithCounter(context.Background())
	if _, err := f.svc.GetCommunity(ctx, ownerUID, v.Community.ID); err != nil {
		t.Fatal(err)
	}
	if f.repo.gets != 0 || f.repo.memberGet != 0 {
		t.Errorf("the owner's first Get read the repo (%d gets, %d member gets) after the write filled the caches", f.repo.gets, f.repo.memberGet)
	}
	_ = c
}

func TestCreateCommunity_ErrorMapping(t *testing.T) {
	tests := []struct {
		name   string
		err    error
		code   connect.Code
		reason commonv1.ErrorReason
		meta   map[string]string
	}{
		{"owned cap", ErrOwnedLimit, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "communities_owned"}},
		{"joined cap", ErrJoinedLimit, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "communities_joined"}},
		{"key reused", ErrKeyReused, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := newFixture(ownerUID)
			f.repo.createErr = tt.err
			_, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{Key: goodKey, Name: "Go"})
			wantAPIErr(t, err, tt.code, tt.reason, tt.meta)
		})
	}
	t.Run("unknown error is internal and names no id", func(t *testing.T) {
		f := newFixture(ownerUID)
		f.repo.createErr = fmt.Errorf("rpc error: documents/communityMemberships/%s", ownerUID)
		_, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{Key: goodKey, Name: "Go"})
		if err == nil || strings.Contains(err.Error(), ownerUID) {
			t.Errorf("err = %v, want a redacted internal error", err)
		}
	})
}

func TestCreateCommunity_SameKeyDifferentBodyIsReused(t *testing.T) {
	f := newFixture(ownerUID)
	if _, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{Key: goodKey, Name: "Go"}); err != nil {
		t.Fatal(err)
	}
	for name, in := range map[string]CreateInput{
		"name":        {Key: goodKey, Name: "Rust"},
		"description": {Key: goodKey, Name: "Go", Description: "x"},
		"rules":       {Key: goodKey, Name: "Go", Rules: []Rule{{Title: "a"}}},
	} {
		_, err := f.svc.CreateCommunity(context.Background(), ownerUID, in)
		if name == "" || err == nil {
			t.Errorf("%s changed under the same key: err = %v, want IDEMPOTENCY_KEY_REUSED", name, err)
			continue
		}
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
	}
	// the same body replays, and a replay leaves the caches alone
	f.repo.replayDoc = Community{ID: testCID, Name: "Go", OwnerID: ownerUID, Status: StatusActive}
	v, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{Key: goodKey, Name: "Go"})
	if err != nil || v.Community.ID != testCID {
		t.Fatalf("replay = %+v, %v", v, err)
	}
	if _, ok := f.svc.cache.get(testCID); ok {
		t.Error("a replay filled the cache")
	}
}

func TestUpdateCommunity_Validation(t *testing.T) {
	str := func(s string) *string { return &s }
	tests := []struct {
		name  string
		in    UpdateInput
		field string
	}{
		{"bad key", UpdateInput{Key: "k", CommunityID: testCID}, "idempotency_key"},
		{"short id", UpdateInput{Key: goodKey, CommunityID: "12"}, "community_id"},
		{"letters in id", UpdateInput{Key: goodKey, CommunityID: "000000000000000050x"}, "community_id"},
		{"name cannot be cleared", UpdateInput{Key: goodKey, CommunityID: testCID, Name: str("")}, "name"},
		{"31 code point name", UpdateInput{Key: goodKey, CommunityID: testCID, Name: str(strings.Repeat("a", 31))}, "name"},
		{"long description", UpdateInput{Key: goodKey, CommunityID: testCID, Description: str(strings.Repeat("d", 161))}, "description"},
		{"11 rules", UpdateInput{Key: goodKey, CommunityID: testCID, Rules: &[]Rule{{Title: "1"}, {Title: "2"}, {Title: "3"}, {Title: "4"}, {Title: "5"}, {Title: "6"}, {Title: "7"}, {Title: "8"}, {Title: "9"}, {Title: "10"}, {Title: "11"}}}, "rules"},
		{"bad rule", UpdateInput{Key: goodKey, CommunityID: testCID, Rules: &[]Rule{{Title: ""}}}, "rules"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := newFixture(ownerUID)
			_, err := f.svc.UpdateCommunity(context.Background(), ownerUID, tt.in)
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tt.field})
			if len(f.repo.updates) != 0 {
				t.Error("repo reached with invalid input")
			}
		})
	}
}

func TestUpdateCommunity_PassesSetFieldsAndMapsErrors(t *testing.T) {
	str := func(s string) *string { return &s }
	t.Run("only set fields reach the repo; empty description and empty rules are values", func(t *testing.T) {
		f := newFixture(ownerUID)
		f.seed(Community{ID: testCID, Name: "Old", Description: "d", OwnerID: ownerUID, Rules: []Rule{{Title: "r"}}})
		empty := []Rule{}
		v, err := f.svc.UpdateCommunity(context.Background(), ownerUID, UpdateInput{Key: goodKey, CommunityID: testCID, Description: str(""), Rules: &empty})
		if err != nil {
			t.Fatal(err)
		}
		p := f.repo.updates[0]
		if p.Name != nil || p.Description == nil || *p.Description != "" || p.Rules == nil || len(*p.Rules) != 0 {
			t.Errorf("params = %+v, want name unset, description \"\", rules set and empty", p)
		}
		if v.Community.Description != "" || len(v.Community.Rules) != 0 || v.Role != RoleOwner {
			t.Errorf("view = %+v", v)
		}
		if c, ok := f.svc.cache.get(testCID); !ok || c.Description != "" {
			t.Error("the written data did not refresh the cache")
		}
	})
	t.Run("a nil Rules list is not an empty one in the idempotency hash", func(t *testing.T) {
		empty := []Rule{}
		if updateHash(testCID, nil, nil, nil) == updateHash(testCID, nil, nil, &empty) {
			t.Error("unset rules and an empty rule list hash alike")
		}
		if updateHash(testCID, str(""), nil, nil) == updateHash(testCID, nil, nil, nil) {
			t.Error("an empty name and an unset name hash alike")
		}
		if updateHash(testCID, nil, nil, nil) == updateHash(otherCID, nil, nil, nil) {
			t.Error("the community id is not in the hash")
		}
	})
	for _, tt := range []struct {
		name   string
		err    error
		code   connect.Code
		reason commonv1.ErrorReason
		meta   map[string]string
	}{
		{"not the owner", ErrNotOwner, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_owner"}},
		{"archived", ErrArchived, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, map[string]string{"reason": "community_archived"}},
		{"not found", ErrNotFound, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil},
		{"key reused", ErrKeyReused, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil},
	} {
		t.Run(tt.name, func(t *testing.T) {
			f := newFixture(ownerUID)
			f.repo.updateErr = tt.err
			_, err := f.svc.UpdateCommunity(context.Background(), ownerUID, UpdateInput{Key: goodKey, CommunityID: testCID, Name: str("New")})
			wantAPIErr(t, err, tt.code, tt.reason, tt.meta)
		})
	}
}

func TestGetCommunity_NotFoundBytesAreIdentical(t *testing.T) {
	f := newFixture(ownerUID)
	f.seed(Community{ID: testCID, Name: "Hidden", OwnerID: ownerUID, Status: StatusSuspended})
	_, errSusp := f.svc.GetCommunity(context.Background(), nobodyUID, testCID)
	_, errMissing := f.svc.GetCommunity(context.Background(), nobodyUID, otherCID)
	_, errBadID := f.svc.GetCommunity(context.Background(), nobodyUID, "123")
	wantAPIErr(t, errSusp, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	wantAPIErr(t, errBadID, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "community_id"})
	var a, b *apierr.Error
	errors.As(errSusp, &a)
	errors.As(errMissing, &b)
	if a == nil || b == nil || a.Code != b.Code || a.Reason != b.Reason || a.Message != b.Message || a.Message != "community not found" {
		t.Errorf("SUSPENDED %v and missing %v differ", errSusp, errMissing)
	}
	// SUSPENDED answers before the member doc, the graph or any profile is read: the same cost as a missing id
	if f.repo.memberGet != 0 || f.gr.calls != 0 || f.dir.asked != 0 {
		t.Errorf("SUSPENDED read further: %d member docs, %d graphs, %d profiles", f.repo.memberGet, f.gr.calls, f.dir.asked)
	}
	// the owner sees it, with its status
	d, err := f.svc.GetCommunity(context.Background(), ownerUID, testCID)
	if err != nil || d.View.Community.Status != StatusSuspended || d.View.Role != RoleOwner {
		t.Fatalf("owner of a SUSPENDED community: %+v, %v", d, err)
	}
	// ARCHIVED is readable by everyone
	f.seed(Community{ID: "0000000000000000503", Name: "Quiet", Status: StatusArchived})
	d, err = f.svc.GetCommunity(context.Background(), nobodyUID, "0000000000000000503")
	if err != nil || d.View.Community.Status != StatusArchived || d.Owner != nil {
		t.Fatalf("ARCHIVED with no owner: %+v, %v", d, err)
	}
}

func TestGetCommunity_Roles(t *testing.T) {
	tests := []struct {
		uid        string
		want       Role
		memberRead int
	}{
		{ownerUID, RoleOwner, 0},
		{modUID, RoleModerator, 0},
		{memberUID, RoleMember, 1},
		{bannedUID, RoleBanned, 1},
		{nobodyUID, RoleNone, 1},
	}
	for _, tt := range tests {
		t.Run(tt.uid, func(t *testing.T) {
			f := newFixture(ownerUID)
			f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID, ModeratorIDs: []string{modUID}, MemberCount: 3, CreatedAt: testNow})
			f.repo.members[testCID+"|"+memberUID] = MemberJoined
			f.repo.members[testCID+"|"+bannedUID] = MemberBanned
			d, err := f.svc.GetCommunity(context.Background(), tt.uid, testCID)
			if err != nil {
				t.Fatal(err)
			}
			if d.View.Role != tt.want {
				t.Errorf("role = %v, want %v", d.View.Role, tt.want)
			}
			if f.repo.memberGet != tt.memberRead {
				t.Errorf("member doc reads = %d, want %d", f.repo.memberGet, tt.memberRead)
			}
			// a second call is warm: nothing is read, not even for an outsider (absence is cached)
			before, g0, d0 := f.repo.gets+f.repo.memberGet, f.gr.calls, f.dir.asked
			ctx, c := budget.WithCounter(context.Background())
			if _, err := f.svc.GetCommunity(ctx, tt.uid, testCID); err != nil {
				t.Fatal(err)
			}
			if f.repo.gets+f.repo.memberGet != before {
				t.Error("a warm Get read the repo")
			}
			// profiles and the graph are cache-first behind their own modules (this fake charges them every time)
			_ = g0
			_ = d0
			_ = c
		})
	}
}

func TestGetCommunity_RoleHoldersAndRelationships(t *testing.T) {
	f := newFixture(ownerUID)
	f.dir.profiles["mod3"] = profile("mod3", identity.AccountStatusSuspended)
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID, ModeratorIDs: []string{modUID, "mod2", "mod3", "gone"}})
	f.gr.snap = graph.Snapshot{Following: map[string]bool{ownerUID: true}, Blocked: map[string]bool{modUID: true}, Muted: map[string]bool{modUID: true}}
	d, err := f.svc.GetCommunity(context.Background(), nobodyUID, testCID)
	if err != nil {
		t.Fatal(err)
	}
	if d.Owner == nil || d.Owner.Profile.UserID != ownerUID || d.Owner.Relationship.FollowState != graph.FollowStateFollowing {
		t.Errorf("owner = %+v, want the followed owner row", d.Owner)
	}
	// every ACTIVE role holder is shown to every viewer whatever the blocks (D7); DELETING, SUSPENDED and missing accounts are left out
	if len(d.Moderators) != 1 || d.Moderators[0].Profile.UserID != modUID || !d.Moderators[0].Relationship.Blocking || !d.Moderators[0].Relationship.Muting {
		t.Errorf("moderators = %+v, want only the blocked and muted ACTIVE moderator", d.Moderators)
	}
	// an owner who is not ACTIVE is left out for every viewer
	f2 := newFixture(ownerUID)
	f2.dir.profiles[ownerUID] = profile(ownerUID, identity.AccountStatusDeleting)
	f2.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID})
	d2, err := f2.svc.GetCommunity(context.Background(), nobodyUID, testCID)
	if err != nil || d2.Owner != nil {
		t.Errorf("DELETING owner shown: %+v, %v", d2.Owner, err)
	}
}

func TestGetCommunity_ColdReadsFitTheBudget(t *testing.T) {
	// ADR-0031: 15 cold including the interceptor's 1 = community 1 + caller member doc 1 + caller graph 1 + owner and 10 moderators 11
	f := newFixture(ownerUID)
	mods := make([]string, 10)
	for i := range mods {
		mods[i] = fmt.Sprintf("m%d", i)
		f.dir.profiles[mods[i]] = profile(mods[i], identity.AccountStatusActive)
	}
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID, ModeratorIDs: mods})
	ctx, c := budget.WithCounter(context.Background())
	if _, err := f.svc.GetCommunity(ctx, nobodyUID, testCID); err != nil {
		t.Fatal(err)
	}
	if c.Reads() != 14 || c.Writes() != 0 {
		t.Errorf("cold Get = %d reads, %d writes, want 14 (+ the interceptor's 1 = 15), 0", c.Reads(), c.Writes())
	}
	// the owner skips the member doc
	ctx, c = budget.WithCounter(context.Background())
	if _, err := f.svc.GetCommunity(ctx, ownerUID, testCID); err != nil {
		t.Fatal(err)
	}
	if c.Reads() != 12 {
		t.Errorf("owner's Get = %d reads, want 12 (the community is cached; graph 1 + 11 profiles; the member doc is skipped for the owner)", c.Reads())
	}
}

func TestGetCommunity_MissingIdIsRememberedForTheTTL(t *testing.T) {
	f := newFixture(ownerUID)
	for range 3 {
		if _, err := f.svc.GetCommunity(context.Background(), nobodyUID, testCID); err == nil || !strings.Contains(err.Error(), "community not found") {
			t.Fatalf("err = %v", err)
		}
	}
	if f.repo.gets != 1 {
		t.Errorf("repo reads for a probed missing id = %d, want 1 (negative cache)", f.repo.gets)
	}
	// creating it clears the negative entry on this instance
	f.seed(Community{ID: testCID, Name: "Now", OwnerID: ownerUID})
	f.svc.cache.put(f.repo.docs[testCID])
	if _, err := f.svc.GetCommunity(context.Background(), nobodyUID, testCID); err != nil {
		t.Errorf("after put: %v", err)
	}
}

func TestGetCommunity_ErrorsAreInternalAndRedacted(t *testing.T) {
	f := newFixture(ownerUID)
	f.repo.getErr = fmt.Errorf("rpc error on communities/%s", testCID)
	_, err := f.svc.GetCommunity(context.Background(), nobodyUID, testCID)
	if err == nil || strings.Contains(err.Error(), testCID) {
		t.Errorf("err = %v, want a redacted internal error", err)
	}
	f = newFixture(ownerUID)
	f.seed(Community{ID: testCID, OwnerID: ownerUID})
	f.dir.err = errors.New("directory down")
	if _, err := f.svc.GetCommunity(context.Background(), nobodyUID, testCID); err == nil {
		t.Error("a directory failure was swallowed")
	}
	f = newFixture(ownerUID)
	f.seed(Community{ID: testCID, OwnerID: ownerUID})
	f.gr.err = errors.New("graph down")
	if _, err := f.svc.GetCommunity(context.Background(), nobodyUID, testCID); err == nil {
		t.Error("a graph failure was swallowed")
	}
}

func TestRoleOf(t *testing.T) {
	c := Community{OwnerID: ownerUID, ModeratorIDs: []string{modUID}}
	for uid, want := range map[string]Role{ownerUID: RoleOwner, modUID: RoleModerator, nobodyUID: RoleNone, "": RoleNone} {
		if got := c.RoleOf(uid); got != want {
			t.Errorf("RoleOf(%q) = %v, want %v", uid, got, want)
		}
	}
	if (Community{}).RoleOf("") != RoleNone {
		t.Error("an owner-less community made the empty uid its owner")
	}
}

func (r *fakeRepo) Join(_ context.Context, p JoinParams) (JoinResult, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.joins = append(r.joins, p)
	if r.joinErr != nil {
		return JoinResult{}, r.joinErr
	}
	return r.joinRes, nil
}

func (r *fakeRepo) Leave(_ context.Context, p LeaveParams) (LeaveResult, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.leaves = append(r.leaves, p)
	if r.leaveErr != nil {
		return LeaveResult{}, r.leaveErr
	}
	return r.leaveRes, nil
}

func (r *fakeRepo) Memberships(ctx context.Context, uid string) (Memberships, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.mshipsGet++
	budget.FromContext(ctx).AddReads(1)
	return r.mships[uid], nil
}

func (r *fakeRepo) GetMany(ctx context.Context, ids []string) (map[string]Community, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.manyGets = append(r.manyGets, append([]string(nil), ids...))
	budget.FromContext(ctx).AddReads(int64(len(ids)))
	if r.manyErr != nil {
		return nil, r.manyErr
	}
	out := map[string]Community{}
	for _, id := range ids {
		if c, ok := r.docs[id]; ok {
			out[id] = c
		}
	}
	return out, nil
}
