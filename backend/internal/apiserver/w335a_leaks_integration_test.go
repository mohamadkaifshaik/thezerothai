//go:build integration

package apiserver

// W3-35a (ADR-0025 D4, D12, AQ5; plan Part B rules 9 and 10) through the real Build chain on the emulators:
//   - flag off keeps protection: with FEATURE_PRIVATE_ACCOUNTS off everywhere a protected P stays protected on every
//     read path, and can still unprotect, list and answer requests (undo is never gated);
//   - the stale set: a set that cannot be refreshed is served for PROTECTED_SET_MAX_STALE, then UNAVAILABLE for a viewer
//     who needs it; a viewer who reads only their own or followed authors is unaffected (the 10 minutes of production
//     are scaled to seconds through the same two knobs, CACHE_TTL and PROTECTED_SET_MAX_STALE);
//   - media-URL leaks: another user's export carries post ids and that user's own text only; protecting retires nothing
//     and a banner replacement retires exactly as for a public account;
//   - ListSuggestedUsers shows P (header data) and a Follow of P from there is a request.

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestW335a_FlagOffKeepsProtection(t *testing.T) {
	w := newW335aWorld(t)
	follower, stranger, requester := w.w.user(t), w.w.user(t), w.w.user(t)
	w.w.w320Follow(t, follower, w.p.uid)
	w.protect(t, true)
	w.w.w328Request(t, requester, w.p.uid)

	off := func(c *config.Config) {
		w335aOn(c)
		c.FeaturePrivateAccounts = flags.Spec{Name: "private_accounts", Mode: flags.Off}
	}
	r := newW320Chain(t, off)
	w.oracleParity(t, r, "flag off, stranger", stranger, w.pid)
	w.checkTabsListsPin(t, r, w335aViewer{name: "stranger, flag off", u: stranger, tabs: no, lists: no, pin: no})
	w.checkTabsListsPin(t, r, w335aViewer{name: "follower, flag off", u: follower, tabs: yes, lists: yes, pin: yes})
	for name, b := range w.scanBodies(t, newW320Chain(t, off), stranger) {
		if w.leaks(b) {
			t.Errorf("flag off: %s leaks P's content to a stranger: %s", name, b)
		}
	}

	// Undo is never gated: P lists and answers the pending request, and unprotects, with the flag off.
	page, err := r.w328List(w.p)
	if err != nil || len(page.GetRequests()) != 1 {
		t.Fatalf("ListFollowRequests with the flag off: %v err=%v, want the one request", page, err)
	}
	if _, err := r.w328Respond(w.p, requester.uid, true); err != nil {
		t.Fatalf("Respond with the flag off: %v", err)
	}
	pub := false
	if _, err := r.w320Update(w.p, &identityv1.UpdateProfileRequest{IsPrivate: &pub}); err != nil {
		t.Fatalf("unprotect with the flag off: %v", err)
	}
	// Protecting again with the flag off is refused, so the state only shrinks.
	prot := true
	if _, err := r.w320Update(w.p, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err == nil {
		t.Errorf("protecting with the flag off succeeded")
	}
	if st, _, b := w.raw(t, newW320Chain(t, off), stranger, postsv1connect.PostServiceGetPostProcedure, &postsv1.GetPostRequest{PostId: w.pid}); st != http.StatusOK || !w.leaks(b) {
		t.Errorf("after the unprotect a stranger gets %d %s, want the post", st, b)
	}
}

// A set that cannot be refreshed: served while younger than PROTECTED_SET_MAX_STALE, then UNAVAILABLE for a viewer who
// needs it. An isolated project (stub verifier) so the corrupted set document disturbs no other test.
func TestW335a_StaleProtectedSet(t *testing.T) {
	ctx := context.Background()
	project := "demo-w335a-" + strings.ReplaceAll(contractKey("p"), "contract-p-", "")
	env := newChainWith(t, func(c *config.Config) {
		w329bOn(c)
		relaxLimits(c)
		c.ProjectID = project
		c.CacheTTL = time.Second
		c.Privacy.ProtectedSetMaxStale = 4 * time.Second
	}, stubVerifier{})
	now := time.Now()
	for _, uid := range []string{"p", "stranger", "follower"} {
		doc := map[string]any{
			"handle": "h" + uid, "handleLower": "h" + uid, "displayName": "Name " + uid, "status": "ACTIVE",
			"isPrivate": uid == "p", "createdAt": now.Add(-48 * time.Hour), "updatedAt": now,
		}
		if _, err := env.fs.Doc("users/"+uid).Set(ctx, doc); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := env.fs.Doc("graph/follower").Set(ctx, map[string]any{"following": []string{"p"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := env.fs.Doc("privacy/protectedAuthors").Set(ctx, map[string]any{"uids": []string{"p"}}); err != nil {
		t.Fatal(err)
	}
	post := func(uid, text string) string {
		r, err := env.posts.CreatePost(ctx, authed(uid, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w335a-st"), Text: text}))
		if err != nil {
			t.Fatalf("CreatePost as %s: %v", uid, err)
		}
		return r.Msg.GetPost().GetPost().GetPostId()
	}
	pPost, ownPost := post("p", "protected"), post("stranger", "the stranger's own post")
	get := func(uid, id string) error {
		_, err := env.posts.GetPost(ctx, authed(uid, &postsv1.GetPostRequest{PostId: id}))
		return err
	}
	// Loaded once: the set is known, the stranger is refused as NOT_FOUND.
	wireError(t, get("stranger", pPost), connect.CodeNotFound)

	// The set document becomes unreadable. Once a refresh has been attempted and failed, the last good copy still serves.
	if _, err := env.fs.Doc("privacy/protectedAuthors").Set(ctx, map[string]any{"uids": "not-an-array"}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(4 * time.Second)
	for !env.logs.w326bHas("WARN", "protected_set_stale") {
		if time.Now().After(deadline) {
			t.Fatal("no protected_set_stale WARN: the refresh was never attempted or the stale copy was not served")
		}
		wireError(t, get("stranger", pPost), connect.CodeNotFound) // still refused: the last good set, never "everyone is public"
		time.Sleep(250 * time.Millisecond)
	}

	// Past the bound the viewer who needs the set gets UNAVAILABLE; own and followed authors are unaffected.
	deadline = time.Now().Add(15 * time.Second)
	for {
		err := get("stranger", pPost)
		if connect.CodeOf(err) == connect.CodeUnavailable {
			break
		}
		if connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("stranger = %v, want NOT_FOUND until the bound passes, then UNAVAILABLE", err)
		}
		if time.Now().After(deadline) {
			t.Fatal("the stale set was still served long after PROTECTED_SET_MAX_STALE")
		}
		time.Sleep(250 * time.Millisecond)
	}
	if err := get("stranger", ownPost); err != nil {
		t.Errorf("a viewer's own post with the set unavailable: %v, want it served", err)
	}
	if err := get("follower", pPost); err != nil {
		t.Errorf("an approved follower with the set unavailable: %v, want the post", err)
	}
	if err := get("p", pPost); err != nil {
		t.Errorf("the author with the set unavailable: %v, want the post", err)
	}
	d := wireError(t, get("stranger", pPost), connect.CodeUnavailable)
	if d.GetReason() == commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT {
		t.Errorf("UNAVAILABLE must not say PROTECTED_ACCOUNT (no oracle)")
	}
}

// Another user's export, after liking, bookmarking, reposting and quoting P's post, carries post ids and that user's own
// text only (posts/purge.go: the copied text and its author are not the user's data).
func TestW335a_ExportOfAnotherUserCarriesNoProtectedContent(t *testing.T) {
	ctx := context.Background()
	w := newW335aWorld(t)
	u := w.w.user(t)
	if _, err := w.w.add(u, contractKey("w335a-xbm"), w.pid); err != nil {
		t.Fatal(err)
	}
	w.w.like(t, u, w.pid)
	if _, err := w.w.eng.RepostPost(ctx, authed(u.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w335a-xrp"), PostId: w.pid})); err != nil {
		t.Fatal(err)
	}
	const own = "U-owned-quote-text"
	quote := w.post(t, u, &postsv1.CreatePostRequest{Text: own, QuoteOfPostId: w.pid})
	w.protect(t, true)

	_, raw := w.e.exportOf(t, testUser(u), "w335a-export-key-0001")
	s := string(raw)
	if strings.Contains(s, w335aMarkerPrefix) || strings.Contains(s, w.img) || strings.Contains(s, "/m/") {
		t.Errorf("the export carries P's text or image: %s", s)
	}
	for _, want := range []string{w.pid, quote, own} {
		if !strings.Contains(s, want) {
			t.Errorf("the export lacks %q (post ids and the user's own text are the point of the section): %s", want, s)
		}
	}
}

// With PROFILE_MEDIA_RETIRE=banner a protected account's banner replacement retires exactly as a public account's, and
// protecting retires nothing (the avatar and banner stay public header data).
func TestW335a_ProtectingRetiresNothingAndBannerReplacementRetiresAsForAPublicAccount(t *testing.T) {
	w := newW335aWorldCfg(t, func(c *config.Config) { c.ProfileMediaRetire = config.ProfileMediaRetireBanner })
	e := w.e
	retire := func(who bmUser, protect bool) (messages int, outcome string, current string) {
		t.Helper()
		u := testUser(who)
		a1, b1, b2 := e.seedMedia(t, u.uid, media.PurposeAvatar), e.seedMedia(t, u.uid, media.PurposeBanner), e.seedMedia(t, u.uid, media.PurposeBanner)
		e.updateImages(t, u, "w335a-ret1-"+u.uid[:8]+"-padpad", &a1, &b1)
		e.pull(t) // drain
		if protect {
			prot := true
			if _, err := w.w.w320Update(who, &identityv1.UpdateProfileRequest{IsPrivate: &prot}); err != nil {
				t.Fatal(err)
			}
			if msgs := e.pull(t); len(msgs) != 0 {
				t.Fatalf("protecting published %v, want nothing", msgs)
			}
		}
		e.updateImages(t, u, "w335a-ret2-"+u.uid[:8]+"-padpad", nil, &b2)
		msgs := e.pull(t)
		if len(msgs) != 1 || msgs[0]["kind"] != media.JobKindProfileMediaRetired || msgs[0]["purpose"] != "BANNER" || msgs[0]["oldUrl"] != e.profileImageURL(b1) {
			t.Fatalf("banner replacement published %v, want exactly one BANNER retire message for the old banner", msgs)
		}
		if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
			t.Fatalf("delivery = %d", code)
		}
		if _, _, retired := e.mediaDocFields(t, b1); !retired {
			t.Errorf("the replaced banner was not retired")
		}
		out, _ := e.lastRetireLine(t)["outcome"].(string)
		return len(msgs), out, b2
	}
	pubMsgs, pubOutcome, _ := retire(w.w.user(t), false)
	protMsgs, protOutcome, current := retire(w.p, true)
	if pubMsgs != protMsgs || pubOutcome != protOutcome || protOutcome != "retired" {
		t.Errorf("protected account: %d message(s), outcome %q; public account: %d, %q; want identical and retired", protMsgs, protOutcome, pubMsgs, pubOutcome)
	}
	// The banner now in use is not retired by anything that happened.
	if _, _, retired := e.mediaDocFields(t, current); retired {
		t.Errorf("the protected account's current banner was retired")
	}
}

// ADR-0025 D4 rows ListSuggestedUsers and GetProfileRelationship: P may be suggested (header data only) and following P
// from the suggestion creates a request.
func TestW335a_SuggestedProtectedAccountAndFollowCreatesARequest(t *testing.T) {
	w := newW335aWorld(t)
	v, c1, c2 := w.w.user(t), w.w.user(t), w.w.user(t)
	for i := 0; i < 3; i++ { // friends of friends needs three followees and three candidates (ADR-0024 D8)
		fe := w.w.user(t)
		w.w.w320Follow(t, fe, c1.uid)
		w.w.w320Follow(t, fe, c2.uid)
		w.w.w320Follow(t, fe, w.p.uid)
		w.w.w320Follow(t, v, fe.uid)
	}
	w.protect(t, true)

	r := newW320Chain(t, w335aOn)
	got, err := r.w320Suggest(v, 0)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, it := range got.GetUsers() {
		if it.GetUser().GetUserId() == w.p.uid {
			found = true
			if !it.GetUser().GetIsPrivate() {
				t.Errorf("the suggested row of a protected account lacks is_private")
			}
		}
	}
	if !found {
		t.Fatalf("P was not suggested: %v", got)
	}
	r.w328Request(t, v, w.p.uid) // asserts REQUESTED
	rel, err := newW320Chain(t, w335aOn).w320Rel(v, w.p.uid)
	if err != nil || rel.GetRelationship().GetFollowState() != graphv1.FollowState_FOLLOW_STATE_REQUESTED {
		t.Errorf("GetProfileRelationship after the request = %v err=%v, want REQUESTED", rel, err)
	}
}
