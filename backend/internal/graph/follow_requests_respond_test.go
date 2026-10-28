package graph

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-28a (ADR-0025 D7): the service layer of ListFollowRequests, RespondToFollowRequest and the request count, over fakes.

func w328Flags() FlagChecker {
	return flags.NewRegistry(flags.Spec{Name: graphFlagName, Mode: flags.On}, flags.Spec{Name: PrivateAccountsFlagName, Mode: flags.On})
}

// requestsFixture: protected "uid-p" holds n requests from r01..rNN (rNN newest); everyone is active.
func requestsFixture(n int) (*fakeRepo, *fakeDirectory) {
	repo := newFakeRepo()
	dir := &fakeDirectory{profiles: map[string]identity.Profile{"uid-p": activeProfile("uid-p", time.Now())}}
	base := time.Now().Add(-time.Hour)
	for i := n; i >= 1; i-- {
		r := fmt.Sprintf("r%02d", i)
		dir.profiles[r] = activeProfile(r, time.Now())
		repo.edges = append(repo.edges, Edge{DocID: r + "_uid-p", FollowerID: r, FolloweeID: "uid-p", CreatedAt: base.Add(time.Duration(i) * time.Second)})
	}
	return repo, dir
}

func requestsSvc(repo *fakeRepo, dir *fakeDirectory, ev FollowEvents) *service {
	return newTestServiceWithDirectory(repo, dir, Deps{Flags: w328Flags(), CursorKey: []byte("k"), Events: ev})
}

func TestListFollowRequests_PagesCoverAllOnce(t *testing.T) {
	repo, dir := requestsFixture(25)
	svc := requestsSvc(repo, dir, nil)
	var got []string
	token := ""
	pages := 0
	for {
		page, err := svc.ListFollowRequests(context.Background(), "uid-p", 20, token)
		if err != nil {
			t.Fatal(err)
		}
		pages++
		for _, it := range page.Items {
			got = append(got, it.User.UserID)
			if it.Relationship.FollowState != FollowStateNone || it.Since.IsZero() {
				t.Errorf("row %+v: want relationship NONE and a since", it)
			}
		}
		if token = page.NextPageToken; token == "" {
			break
		}
	}
	if pages != 2 || len(got) != 25 {
		t.Fatalf("pages = %d, rows = %d, want 2 pages and 25 rows", pages, len(got))
	}
	if got[0] != "r25" || got[24] != "r01" {
		t.Errorf("order = %s ... %s, want newest first (r25 ... r01)", got[0], got[24])
	}
	if !repo.lastEdgeQuery.Requests || repo.lastEdgeQuery.UID != "uid-p" {
		t.Errorf("query = %+v, want the incoming requests of uid-p", repo.lastEdgeQuery)
	}
}

func TestListFollowRequests_DropsRowsAndLogs(t *testing.T) {
	repo, dir := requestsFixture(5)
	dir.profiles["r02"] = identity.Profile{UserID: "r02", Status: identity.AccountStatusSuspended}
	delete(dir.profiles, "r03")
	svc := requestsSvc(repo, dir, nil)
	svc.cache.Set("uid-p", Snapshot{Blocked: map[string]bool{"r04": true}, BlockedBy: map[string]bool{"r05": true}, Following: map[string]bool{"r01": true}})
	ctx, info := obsCtx()
	page, err := svc.ListFollowRequests(ctx, "uid-p", 20, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || page.Items[0].User.UserID != "r01" || page.Items[0].Relationship.FollowState != FollowStateFollowing {
		t.Fatalf("items = %+v, want only r01 (FOLLOWING: the caller follows the requester back)", page.Items)
	}
	if got := field(info, "rows_dropped"); fmt.Sprint(got) != "4" {
		t.Errorf("rows_dropped = %v, want 4", got)
	}
	if page.NextPageToken != "" {
		t.Error("a short query result must not issue a token")
	}
}

func TestListFollowRequests_TokenBinding(t *testing.T) {
	repo, dir := requestsFixture(25)
	svc := requestsSvc(repo, dir, nil)
	dir.profiles["uid-q"] = activeProfile("uid-q", time.Now())
	first, err := svc.ListFollowRequests(context.Background(), "uid-p", 20, "")
	if err != nil || first.NextPageToken == "" {
		t.Fatalf("first page: %v token=%q", err, first.NextPageToken)
	}
	other := cursor.Encode(svc.cursorKey, "uid-p|followers|uid-p", cursor.Cursor{CreatedAt: time.Now(), DocID: "r01_uid-p"})
	wrongDoc := cursor.Encode(svc.cursorKey, requestsBinding("uid-p"), cursor.Cursor{CreatedAt: time.Now(), DocID: "r01_uid-other"})
	expired := cursor.EncodeAt(svc.cursorKey, requestsBinding("uid-p"), cursor.Cursor{CreatedAt: time.Now(), DocID: "r01_uid-p"}, time.Now().Add(-48*time.Hour))
	for name, tc := range map[string]struct{ caller, token string }{
		"foreign caller": {"uid-q", first.NextPageToken}, "another list": {"uid-p", other}, "doc of another account": {"uid-p", wrongDoc},
		"expired": {"uid-p", expired}, "tampered": {"uid-p", first.NextPageToken + "x"},
	} {
		t.Run(name, func(t *testing.T) {
			before := repo.edgeCalls
			_, err := svc.ListFollowRequests(context.Background(), tc.caller, 20, tc.token)
			assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if repo.edgeCalls != before {
				t.Error("a bad token must cost 0 reads")
			}
		})
	}
}

func TestListFollowRequests_GateAndErrors(t *testing.T) {
	repo, dir := requestsFixture(2)
	svc := newTestServiceWithDirectory(repo, dir, Deps{Flags: flags.NewRegistry(flags.Spec{Name: graphFlagName, Mode: flags.Off}), CursorKey: []byte("k")})
	_, err := svc.ListFollowRequests(context.Background(), "uid-p", 20, "")
	assertAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if repo.edgeCalls != 0 {
		t.Error("a refused call must not query")
	}

	svc = requestsSvc(repo, dir, nil)
	repo.err = errors.New("boom uid-p")
	if _, err = svc.ListFollowRequests(context.Background(), "uid-p", 20, ""); err == nil {
		t.Fatal("want an error from the snapshot read")
	}
	repo.err = nil
	dir.err = errors.New("hydrate down")
	if _, err = svc.ListFollowRequests(context.Background(), "uid-p", 20, ""); err == nil {
		t.Fatal("want an error from hydration")
	}
}

func TestRespondToFollowRequest(t *testing.T) {
	tests := []struct {
		name         string
		accept       bool
		outcome      RespondOutcome
		wantAccepted int
		wantForget   int
		wantDropped  bool // the requester's snapshot is dropped from this instance
	}{
		{"accept", true, RespondAccept, 1, 1, true},
		{"decline", false, RespondDecline, 0, 0, true},
		{"replay", true, RespondReplay, 0, 0, false},
		{"requester inactive", true, RespondRequesterInactive, 0, 0, true},
		{"drift", true, RespondDrift, 0, 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo, dir := requestsFixture(1)
			repo.respondOutcome = tt.outcome
			ev := &recordingFollowEvents{}
			svc := requestsSvc(repo, dir, ev)
			svc.cache.Set("r01", Snapshot{})
			svc.cache.Set("uid-p", Snapshot{Following: map[string]bool{"r01": true}})
			ctx, info := obsCtx()
			rel, err := svc.RespondToFollowRequest(ctx, "uid-p", validKey, "r01", tt.accept)
			if err != nil {
				t.Fatal(err)
			}
			if rel.UserID != "r01" || rel.FollowState != FollowStateFollowing {
				t.Errorf("relationship = %+v, want the caller's own view of r01 (FOLLOWING from the snapshot)", rel)
			}
			if len(ev.accepted) != tt.wantAccepted || len(ev.calls) != 0 || len(ev.requests) != 0 {
				t.Errorf("accepted=%v followed=%v requested=%v, want %d accepted and nothing else", ev.accepted, ev.calls, ev.requests, tt.wantAccepted)
			}
			if tt.wantAccepted == 1 && (ev.accepted[0].target != "uid-p" || ev.accepted[0].requester != "r01") {
				t.Errorf("FollowRequestAccepted = %+v, want target uid-p, requester r01", ev.accepted[0])
			}
			if dir.forgetCalled != tt.wantForget {
				t.Errorf("directory Forget calls = %d, want %d", dir.forgetCalled, tt.wantForget)
			}
			if _, cached := svc.cache.Get("r01"); cached == tt.wantDropped {
				t.Errorf("requester snapshot cached = %v, want dropped = %v", cached, tt.wantDropped)
			}
			if got := field(info, "respond"); got != string(tt.outcome) {
				t.Errorf("respond log = %v, want %q", got, tt.outcome)
			}
			if repo.respondArgs.TargetUID != "uid-p" || repo.respondArgs.RequesterUID != "r01" || repo.respondArgs.Accept != tt.accept {
				t.Errorf("RespondArgs = %+v", repo.respondArgs)
			}
		})
	}
}

func TestRespondToFollowRequest_Validation(t *testing.T) {
	tests := []struct {
		name, key, requester string
	}{
		{"short key", "short", "r01"},
		{"bad requester id", validKey, "a_b"},
		{"empty requester", validKey, ""},
		{"self", validKey, "uid-p"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo, dir := requestsFixture(1)
			svc := requestsSvc(repo, dir, nil)
			_, err := svc.RespondToFollowRequest(context.Background(), "uid-p", tt.key, tt.requester, true)
			assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if repo.respondCalls != 0 {
				t.Error("a rejected call must not reach the repo")
			}
		})
	}
}

func TestRespondToFollowRequest_Errors(t *testing.T) {
	t.Run("requester at the following cap", func(t *testing.T) {
		repo, dir := requestsFixture(1)
		repo.respondErr = &LimitReachedError{Limit: "requester_following"}
		svc := requestsSvc(repo, dir, nil)
		ctx, info := obsCtx()
		_, err := svc.RespondToFollowRequest(ctx, "uid-p", validKey, "r01", true)
		assertAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
		if got := field(info, "respond"); got != "requester_cap" {
			t.Errorf("respond log = %v, want requester_cap", got)
		}
	})
	t.Run("contention is retryable", func(t *testing.T) {
		repo, dir := requestsFixture(1)
		repo.respondErr = ErrContention
		_, err := requestsSvc(repo, dir, nil).RespondToFollowRequest(context.Background(), "uid-p", validKey, "r01", false)
		assertAPIErr(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	})
	t.Run("repo failure", func(t *testing.T) {
		repo, dir := requestsFixture(1)
		repo.respondErr = errors.New("boom")
		if _, err := requestsSvc(repo, dir, nil).RespondToFollowRequest(context.Background(), "uid-p", validKey, "r01", true); err == nil {
			t.Fatal("want an error")
		}
	})
	t.Run("snapshot failure after the commit", func(t *testing.T) {
		repo, dir := requestsFixture(1)
		repo.respondOutcome = RespondDecline
		repo.err = errors.New("down")
		if _, err := requestsSvc(repo, dir, nil).RespondToFollowRequest(context.Background(), "uid-p", validKey, "r01", false); err == nil {
			t.Fatal("want an error")
		}
	})
	t.Run("flag off", func(t *testing.T) {
		repo, dir := requestsFixture(1)
		svc := newTestServiceWithDirectory(repo, dir, Deps{Flags: flags.NewRegistry(flags.Spec{Name: graphFlagName, Mode: flags.Off})})
		_, err := svc.RespondToFollowRequest(context.Background(), "uid-p", validKey, "r01", true)
		assertAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	})
}

// The requester's status is looked up through the Directory only when the repo asks (an accept of a request that exists),
// and an inactive or unknown requester reads as not active.
func TestRespondToFollowRequest_RequesterActiveCallback(t *testing.T) {
	repo, dir := requestsFixture(1)
	dir.profiles["r02"] = identity.Profile{UserID: "r02", Status: identity.AccountStatusSuspended}
	asked := &askedDirectory{fakeDirectory: *dir}
	repo.respondOutcome = RespondAccept
	svc := newTestServiceWithDirectory(repo, asked, Deps{Flags: w328Flags()})
	if _, err := svc.RespondToFollowRequest(context.Background(), "uid-p", validKey, "r01", true); err != nil {
		t.Fatal(err)
	}
	if len(asked.asked) != 0 {
		t.Errorf("directory asked %v although the repo never called RequesterActive", asked.asked)
	}
	repo.respondAskActive = true
	for uid, want := range map[string]bool{"r01": true, "r02": false, "ghost": false} {
		asked.asked = nil
		if _, err := svc.RespondToFollowRequest(context.Background(), "uid-p", validKey, uid, true); err != nil {
			t.Fatal(err)
		}
		got, _ := repo.respondArgs.RequesterActive(context.Background())
		if got != want || len(asked.asked) == 0 || asked.asked[0][0] != uid {
			t.Errorf("RequesterActive(%s) = %v (asked %v), want %v", uid, got, asked.asked, want)
		}
	}
	asked.err = errors.New("down")
	if _, err := svc.RespondToFollowRequest(context.Background(), "uid-p", validKey, "r01", true); err == nil {
		t.Fatal("a Directory failure inside the accept must fail the call")
	}
}

func TestClassifyAccept(t *testing.T) {
	full := make([]string, maxFollowing)
	for i := range full {
		full[i] = fmt.Sprintf("u%d", i)
	}
	tests := []struct {
		name      string
		requester doc
		exists    bool
		active    bool
		want      acceptKind
	}{
		{"edge", doc{}, true, true, acceptEdge},
		{"inactive", doc{}, true, false, acceptInactive},
		{"no graph doc", doc{}, false, true, acceptInactive},
		{"drift: already following", doc{Following: []string{"p"}}, true, true, acceptDrift},
		{"at the cap", doc{Following: full}, true, true, acceptAtCap},
		{"one below the cap", doc{Following: full[:maxFollowing-1]}, true, true, acceptEdge},
		{"drift wins over the cap", doc{Following: append([]string{"p"}, full[1:]...)}, true, true, acceptDrift},
		{"inactive wins over the cap", doc{Following: full}, true, false, acceptInactive},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := classifyAccept(tt.requester, tt.exists, tt.active, "p"); got != tt.want {
				t.Errorf("classifyAccept = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestPendingFollowRequests(t *testing.T) {
	repo, dir := requestsFixture(0)
	repo.countN = 7
	svc := requestsSvc(repo, dir, nil)
	n, err := svc.PendingFollowRequests(context.Background(), "uid-p")
	if err != nil || n != 7 || repo.countCalls != 1 {
		t.Fatalf("PendingFollowRequests = %d, %v (calls %d), want 7", n, err, repo.countCalls)
	}
	repo.countErr = errors.New("down uid-p")
	if _, err = svc.PendingFollowRequests(context.Background(), "uid-p"); err == nil {
		t.Fatal("want the count error")
	}
}

type fakeProtected struct {
	uids  map[string]bool
	err   error
	calls int
}

type fakeProtectedSet struct{ uids map[string]bool }

func (s fakeProtectedSet) Has(uid string) bool { return s.uids[uid] }
func (s fakeProtectedSet) CanSee(viewer, author string, following bool) bool {
	return viewer == author || !s.uids[author] || following
}

func (f *fakeProtected) Current(context.Context) (identity.ProtectedSet, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	return fakeProtectedSet{uids: f.uids}, nil
}

// ListFollowers and ListFollowing of a protected account (ADR-0025 D5): approved viewers and the owner see the page, anyone
// else gets PROTECTED_ACCOUNT before any page read, and the set is asked only when it can matter.
func TestListFollowLists_ProtectedAccount(t *testing.T) {
	tests := []struct {
		name       string
		protected  map[string]bool
		setErr     error
		snap       Snapshot
		caller     string
		wantErr    bool
		wantCode   connect.Code
		wantReason commonv1.ErrorReason
		wantAsked  int
	}{
		{"public target", map[string]bool{}, nil, Snapshot{}, "uid-v", false, 0, 0, 1},
		{"stranger of a protected target", map[string]bool{"uid-t": true}, nil, Snapshot{}, "uid-v", true, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, 1},
		{"requested only is not approved", map[string]bool{"uid-t": true}, nil, Snapshot{Requested: map[string]bool{"uid-t": true}}, "uid-v", true, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, 1},
		{"approved follower", map[string]bool{"uid-t": true}, nil, Snapshot{Following: map[string]bool{"uid-t": true}}, "uid-v", false, 0, 0, 0},
		{"the owner", map[string]bool{"uid-t": true}, nil, Snapshot{}, "uid-t", false, 0, 0, 0},
		{"set unavailable fails closed", map[string]bool{}, errors.New("stale"), Snapshot{}, "uid-v", true, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, 1},
	}
	for _, tt := range tests {
		for _, followers := range []bool{true, false} {
			t.Run(fmt.Sprintf("%s/followers=%v", tt.name, followers), func(t *testing.T) {
				repo, dir := followersFixture(3)
				dir.profiles["uid-v"] = activeProfile("uid-v", time.Now())
				prot := &fakeProtected{uids: tt.protected, err: tt.setErr}
				svc := newTestServiceWithDirectory(repo, dir, Deps{Flags: w328Flags(), CursorKey: []byte("k"), Protected: prot})
				svc.cache.Set(tt.caller, tt.snap)
				var err error
				if followers {
					_, err = svc.ListFollowers(context.Background(), tt.caller, "uid-t", 20, "")
				} else {
					_, err = svc.ListFollowing(context.Background(), tt.caller, "uid-t", 20, "")
				}
				if tt.wantErr {
					assertAPIErr(t, err, tt.wantCode, tt.wantReason)
					if repo.edgeCalls != 0 {
						t.Error("a refused list must not read a page")
					}
				} else if err != nil {
					t.Fatal(err)
				}
				if prot.calls != tt.wantAsked {
					t.Errorf("protected set asked %d times, want %d", prot.calls, tt.wantAsked)
				}
			})
		}
	}
}

// With no protected-author loader wired (opsctl, older wiring) nobody is protected: the lists behave as before.
func TestListFollowers_NoLoaderMeansPublic(t *testing.T) {
	repo, dir := followersFixture(2)
	dir.profiles["uid-v"] = activeProfile("uid-v", time.Now())
	svc := newTestServiceWithDirectory(repo, dir, Deps{Flags: w328Flags(), CursorKey: []byte("k")})
	if _, err := svc.ListFollowers(context.Background(), "uid-v", "uid-t", 20, ""); err != nil {
		t.Fatal(err)
	}
}
