//go:build integration

package apiserver

// W3-26b (ADR-0025 D4, D7, AQ3, AQ6) through the real Build chain on the emulators, FEATURE_PRIVATE_ACCOUNTS on:
//   - GetProfile of a protected P: a stranger gets the whole header and no pinned_post_id; P and an approved follower get the
//     pin; the read count is the same as before Part B (3 cold for a viewer, 1 for the owner);
//   - GetMe pending_follow_request_count: a protected caller pays +1 read (one count()) on a cold instance, a public caller
//     pays nothing and gets 0, a second call inside 30 s reads nothing, and the count moves after a Follow request (the
//     follow_request notification evicts it) and after an accept (Forget);
//   - a protected set that cannot be loaded: the stranger gets the header without the pin and a WARN pin_omitted
//     reason=set_unavailable, the owner and a follower still get the pin (an isolated project whose set document is garbage).

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	rpcGetProfile = identityv1connect.IdentityServiceGetProfileProcedure
	rpcGetMe      = identityv1connect.IdentityServiceGetMeProcedure
)

func w326bOn(c *config.Config) {
	w328On(c)
	c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
	c.FeatureProfileExtras = flags.Spec{Name: "profile_extras", Mode: flags.On}
}

func (e *bmChain) w326bGetProfile(t *testing.T, viewer bmUser, uid string) *identityv1.Profile {
	t.Helper()
	r, err := e.identity.GetProfile(context.Background(), authed(viewer.token, &identityv1.GetProfileRequest{
		Target: &identityv1.GetProfileRequest_UserId{UserId: uid},
	}))
	if err != nil {
		t.Fatalf("GetProfile(%s): %v", uid, err)
	}
	return r.Msg.GetProfile()
}

func (e *bmChain) w326bGetMe(t *testing.T, u bmUser) *identityv1.GetMeResponse {
	t.Helper()
	r, err := e.identity.GetMe(context.Background(), authed(u.token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	return r.Msg
}

func TestW326b_PinOmittedForUnapprovedViewers(t *testing.T) {
	w := newW320Chain(t, w326bOn)
	p, follower, stranger := w.user(t), w.user(t), w.user(t)
	pid := w.post(t, p, "pinned by a protected account")
	if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{PinnedPostId: &pid}); err != nil {
		t.Fatalf("pin: %v", err)
	}
	prot := true
	if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
		t.Fatalf("protect: %v", err)
	}
	w.w328Request(t, follower, p.uid)
	w.w328Request(t, stranger, p.uid) // a pending requester is not approved
	if _, err := w.w328Respond(p, follower.uid, true); err != nil {
		t.Fatalf("accept: %v", err)
	}

	tests := []struct {
		name    string
		viewer  bmUser
		wantPin bool
		reads   int64 // cold instance: interceptor + target users + viewer graph (the owner's profile is one doc)
	}{
		{"stranger", bmUser{}, false, 3}, // an empty viewer means a fresh account that never asked (its own profile is warm)
		{"pending requester", stranger, false, 3},
		{"approved follower", follower, true, 3},
		{"the account itself", p, true, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cold := newW320Chain(t, w326bOn)
			viewer := tt.viewer
			if viewer.uid == "" {
				viewer = cold.user(t)
			}
			got := cold.w326bGetProfile(t, viewer, p.uid)
			if got.GetUserId() != p.uid || got.GetHandle() == "" || !got.GetIsPrivate() || got.GetDisplayName() == "" {
				t.Errorf("header = %v, want every header field and is_private", got)
			}
			if (got.GetPinnedPostId() != "") != tt.wantPin {
				t.Errorf("pinned_post_id = %q, want present=%v", got.GetPinnedPostId(), tt.wantPin)
			}
			c := cold.lineBudget(t, rpcGetProfile)
			budgettest.Assert(t, "GetProfile of a protected account, "+tt.name+" (cold)", c, budgettest.Budget{Reads: tt.reads})
			if line := cold.logs.requestLines(rpcGetProfile); !tt.wantPin && line[len(line)-1]["pin_omitted"] != "protected" {
				t.Errorf("request line pin_omitted = %v, want protected", line[len(line)-1]["pin_omitted"])
			}
		})
	}
}

func (e *bmChain) w326bWaitRequestNotif(t *testing.T, to, from string) {
	t.Helper()
	w328WaitNotif(t, e.chainEnv, to, "follow_request_"+from)
}

func TestW326b_GetMePendingFollowRequestCount(t *testing.T) {
	w := newW320Chain(t, w326bOn)
	p, publicCaller := w.user(t), w.user(t)
	a, b, c := w.user(t), w.user(t), w.user(t)
	prot := true
	if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
		t.Fatalf("protect: %v", err)
	}
	w.w328Request(t, a, p.uid)
	w.w328Request(t, b, p.uid)
	w.w326bWaitRequestNotif(t, p.uid, b.uid)

	// A public caller on a cold instance: the interceptor's profile and the unread count, no request count.
	coldPublic := newW320Chain(t, w326bOn)
	if me := coldPublic.w326bGetMe(t, publicCaller); me.GetPendingFollowRequestCount() != 0 {
		t.Errorf("public caller count = %d, want 0", me.GetPendingFollowRequestCount())
	}
	pub := coldPublic.lineBudget(t, rpcGetMe)
	budgettest.Assert(t, "GetMe, public caller (cold)", pub, budgettest.Budget{Reads: 2})

	// A protected caller on a cold instance pays exactly one more read (one count(), 2 matches, minimum 1).
	cold := newW320Chain(t, w326bOn)
	if me := cold.w326bGetMe(t, p); me.GetPendingFollowRequestCount() != 2 {
		t.Fatalf("protected caller count = %d, want 2", me.GetPendingFollowRequestCount())
	}
	prLine := cold.lineBudget(t, rpcGetMe)
	budgettest.Assert(t, "GetMe, protected caller (cold)", prLine, budgettest.Budget{Reads: 3})
	if prLine.Reads() != pub.Reads()+1 {
		t.Errorf("protected cold GetMe = %d reads, want the public %d + 1", prLine.Reads(), pub.Reads())
	}
	// The second call, inside 30 s, costs nothing and says so.
	if me := cold.w326bGetMe(t, p); me.GetPendingFollowRequestCount() != 2 {
		t.Fatalf("second call count = %d, want 2", me.GetPendingFollowRequestCount())
	}
	lines := cold.logs.requestLines(rpcGetMe)
	if hit := lines[len(lines)-1]["follow_requests_count_cache_hit"]; hit != true {
		t.Errorf("second GetMe follow_requests_count_cache_hit = %v, want true", hit)
	}
	budgettest.Assert(t, "GetMe, protected caller (second call, 30 s cache)", cold.lineBudget(t, rpcGetMe), budgettest.Budget{Reads: 0})

	// The count moves on this instance: after a Follow request (the follow_request notification evicts it) and after an
	// accept (Forget). Both are inside the 30 s window.
	if me := w.w326bGetMe(t, p); me.GetPendingFollowRequestCount() != 2 {
		t.Fatalf("count on the seeding instance = %d, want 2", me.GetPendingFollowRequestCount())
	}
	w.w328Request(t, c, p.uid)
	w.w326bWaitRequestNotif(t, p.uid, c.uid)
	if me := w.w326bGetMe(t, p); me.GetPendingFollowRequestCount() != 3 {
		t.Errorf("after a Follow request count = %d, want 3", me.GetPendingFollowRequestCount())
	}
	budgettest.Assert(t, "GetMe, protected caller after a request", w.lineBudget(t, rpcGetMe), budgettest.Budget{Reads: 2})
	if _, err := w.w328Respond(p, a.uid, true); err != nil {
		t.Fatalf("accept: %v", err)
	}
	if me := w.w326bGetMe(t, p); me.GetPendingFollowRequestCount() != 2 {
		t.Errorf("after an accept count = %d, want 2", me.GetPendingFollowRequestCount())
	}
	if _, err := w.w328Respond(p, b.uid, false); err != nil {
		t.Fatalf("decline: %v", err)
	}
	_ = w.w326bGetMe(t, p) // the decline writes no counter: Forget is not called, so the count may be up to 30 s stale
	// Unprotecting: the badge disappears for a public caller at once (profile cache is written from the commit).
	off := false
	if _, err := w.w320Update(p, &identityv1.UpdateProfileRequest{IsPrivate: &off}); err != nil {
		t.Fatalf("unprotect: %v", err)
	}
	if me := w.w326bGetMe(t, p); me.GetPendingFollowRequestCount() != 0 {
		t.Errorf("after unprotect count = %d, want 0", me.GetPendingFollowRequestCount())
	}
}

// w326bHas reports whether a log line has the given level and message.
func (b *logBuf) w326bHas(level, msg string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, line := range strings.Split(b.buf.String(), "\n") {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) == nil && rec["level"] == level && rec["msg"] == msg {
			return true
		}
	}
	return false
}

// stubVerifier accepts the token as the uid, so the test can use an isolated Firestore project (a project the Auth
// emulator has no users for).
type stubVerifier struct{}

func (stubVerifier) VerifyIDToken(_ context.Context, tok string) (authn.Claims, error) {
	return authn.Claims{UID: tok, EmailVerified: true, SignInProvider: authn.SignInProviderGoogle, AuthTime: time.Now()}, nil
}

// TestW326b_SetUnavailableFailsClosedForTheUnapproved: the set document of an isolated project is garbage, so the loader
// cannot load it. A stranger gets the header without the pin and a WARN; the owner and a follower still get the pin
// because they never need the set (AQ6).
func TestW326b_SetUnavailableFailsClosedForTheUnapproved(t *testing.T) {
	ctx := context.Background()
	project := "demo-w326b-" + strings.ReplaceAll(contractKey("p"), "contract-p-", "")
	env := newChainWith(t, func(c *config.Config) {
		w326bOn(c)
		relaxLimits(c)
		c.ProjectID = project
	}, stubVerifier{})
	now := time.Now()
	seedUser := func(uid string, pinned bool) {
		doc := map[string]any{
			"handle": "h" + uid, "handleLower": "h" + uid, "displayName": "Name " + uid, "status": "ACTIVE",
			"isPrivate": uid == "p", "createdAt": now.Add(-48 * time.Hour), "updatedAt": now,
		}
		if pinned {
			doc["pinnedPostId"] = "0000000000000000101"
		}
		if _, err := env.fs.Doc("users/"+uid).Set(ctx, doc); err != nil {
			t.Fatal(err)
		}
	}
	seedUser("p", true)
	seedUser("stranger", false)
	seedUser("follower", false)
	if _, err := env.fs.Doc("graph/follower").Set(ctx, map[string]any{"following": []string{"p"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := env.fs.Doc("privacy/protectedAuthors").Set(ctx, map[string]any{"uids": "not-an-array"}); err != nil {
		t.Fatal(err)
	}

	get := func(viewer string) *identityv1.Profile {
		r, err := env.identity.GetProfile(ctx, authed(viewer, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: "p"}}))
		if err != nil {
			t.Fatalf("GetProfile as %s: %v", viewer, err)
		}
		return r.Msg.GetProfile()
	}
	got := get("stranger")
	if got.GetHandle() != "hp" || !got.GetIsPrivate() || got.GetPinnedPostId() != "" {
		t.Errorf("stranger with the set unavailable: %v, want the header and no pin", got)
	}
	if line := env.logs.requestLines(rpcGetProfile); line[len(line)-1]["pin_omitted"] != "set_unavailable" {
		t.Errorf("request line pin_omitted = %v, want set_unavailable", line[len(line)-1]["pin_omitted"])
	}
	if !env.logs.w326bHas("WARN", "pin_omitted") {
		t.Errorf("no WARN pin_omitted line in the logs")
	}
	if got := get("follower"); got.GetPinnedPostId() == "" {
		t.Error("an approved follower must keep the pin without the set")
	}
	if got := get("p"); got.GetPinnedPostId() == "" {
		t.Error("the account itself must keep the pin without the set")
	}
}
