//go:build integration

package apiserver

// W3-6 over the real Build chain (Firestore, Auth, Pub/Sub emulators): UpdateProfile with a banner, location, website
// and pinned post, the profile_extras gate, the pin kill switch (Profile.pinned_post_id omitted while the flag is
// globally off), and the post_delete job's identity step that clears the pin of a deleted post (ADR-0024 D1-D3, D9).
//
// As in the P4 chain test, finished media documents are seeded straight into Firestore the way FinalizeUpload leaves
// them (a signed PUT URL cannot be minted against the emulators).

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcUpdateProfile = "/dzeroth.identity.v1.IdentityService/UpdateProfile"

func profileExtrasOn(c *config.Config) {
	relaxLimits(c)
	mediaOn(c)
	c.FeatureProfileExtras = flags.Spec{Name: "profile_extras", Mode: flags.On}
}

func (e *lifecycleEnv) profileOfUser(t *testing.T, viewer testUser, uid string) *identityv1.Profile {
	t.Helper()
	resp, err := e.identity.GetProfile(context.Background(), authed(viewer.token, &identityv1.GetProfileRequest{
		Target: &identityv1.GetProfileRequest_UserId{UserId: uid},
	}))
	if err != nil {
		t.Fatalf("GetProfile(%s): %v", uid, err)
	}
	return resp.Msg.GetProfile()
}

func (e *lifecycleEnv) createRootPost(t *testing.T, u testUser, key, text string) string {
	t.Helper()
	resp, err := e.posts.CreatePost(context.Background(), authed(u.token, &postsv1.CreatePostRequest{IdempotencyKey: key, Text: text}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	return resp.Msg.GetPost().GetPost().GetPostId()
}

func TestProfileExtras_Chain(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, profileExtrasOn)
	a, b := e.newUser(t), e.newUser(t)
	banner := e.seedMedia(t, a.uid, media.PurposeBanner)
	theirBanner := e.seedMedia(t, b.uid, media.PurposeBanner)
	avatar := e.seedMedia(t, a.uid, media.PurposeAvatar)
	postImage := e.seedMedia(t, a.uid, media.PurposePost)
	p1 := e.createRootPost(t, a, "pinext-post-key-000001", "my first post")
	p2 := e.createRootPost(t, a, "pinext-post-key-000002", "my second post")
	theirPost := e.createRootPost(t, b, "pinext-post-key-000003", "b's post")

	update := func(req *identityv1.UpdateProfileRequest) (*identityv1.Profile, error) {
		resp, err := e.identity.UpdateProfile(ctx, authed(a.token, req))
		if err != nil {
			return nil, err
		}
		return resp.Msg.GetProfile(), nil
	}
	str := func(s string) *string { return &s }

	// --- a banner that is not the caller's own READY BANNER: one answer, nothing written ---
	for name, id := range map[string]string{"someone else's banner": theirBanner, "an avatar": avatar, "a post image": postImage, "unknown": "0000000000000000042", "malformed": "nope"} {
		_, err := update(&identityv1.UpdateProfileRequest{IdempotencyKey: "pinext-bad-banner-0001", BannerMediaId: str(id)})
		if d := wireError(t, err, connect.CodeFailedPrecondition); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY {
			t.Errorf("%s: reason = %v, want MEDIA_NOT_READY", name, d.GetReason())
		}
	}

	// --- a pin the caller may not set: the same VALIDATION answer for every cause ---
	var rejectMessages []string
	for name, id := range map[string]string{"another user's post": theirPost, "unknown post": "0000000000000000042", "malformed id": "nope"} {
		_, err := update(&identityv1.UpdateProfileRequest{IdempotencyKey: "pinext-bad-pin-000001", PinnedPostId: str(id)})
		d := wireError(t, err, connect.CodeInvalidArgument)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION || d.GetMetadata()["field"] != "pinned_post_id" {
			t.Errorf("%s: reason=%v metadata=%v, want VALIDATION field=pinned_post_id", name, d.GetReason(), d.GetMetadata())
		}
		rejectMessages = append(rejectMessages, d.GetMessage())
	}
	for _, m := range rejectMessages[1:] {
		if m != rejectMessages[0] {
			t.Errorf("pin rejection messages differ (an existence oracle): %q vs %q", m, rejectMessages[0])
		}
	}
	if line := lastRequestLine(t, e, rpcUpdateProfile); line["pin_check"] != "rejected" {
		t.Errorf("pin_check = %v, want rejected", line["pin_check"])
	}

	// --- bad location and website ---
	_, err := update(&identityv1.UpdateProfileRequest{IdempotencyKey: "pinext-bad-loc-000001", Location: str("line one\nline two")})
	if d := wireError(t, err, connect.CodeInvalidArgument); d.GetMetadata()["field"] != "location" {
		t.Errorf("location metadata = %v", d.GetMetadata())
	}
	_, err = update(&identityv1.UpdateProfileRequest{IdempotencyKey: "pinext-bad-web-000001", Website: str("javascript:alert(1)")})
	if d := wireError(t, err, connect.CodeInvalidArgument); d.GetMetadata()["field"] != "website" {
		t.Errorf("website metadata = %v", d.GetMetadata())
	}
	if got := e.profileOfUser(t, b, a.uid); got.GetLocation() != "" || got.GetBannerUrl() != "" || got.GetPinnedPostId() != "" || got.GetWebsite() != "" {
		t.Fatalf("a rejected request changed the profile: %v", got)
	}

	// --- everything at once: 1 write, and the budget of the ticket ---
	got, err := update(&identityv1.UpdateProfileRequest{
		IdempotencyKey: "pinext-all-fields-0001", BannerMediaId: &banner, Location: str("Pune"), Website: str("HTTPS://example.com/me"), PinnedPostId: &p1,
	})
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if got.GetBannerUrl() == "" || got.GetBannerThumbUrl() == "" || got.GetBannerUrl() == got.GetBannerThumbUrl() ||
		got.GetLocation() != "Pune" || got.GetWebsite() != "https://example.com/me" || got.GetPinnedPostId() != p1 {
		t.Fatalf("profile = %v", got)
	}
	line := lastRequestLine(t, e, rpcUpdateProfile)
	// Worst case 4 reads with the interceptor cold (it is warm after sign-up): the transaction, the banner's media doc and
	// the pinned post (warm in the posts cache after CreatePost). 1 write.
	if reads, _ := line["fs_reads"].(float64); reads > 4 {
		t.Errorf("fs_reads = %v, want <= 4", line["fs_reads"])
	}
	if writes, _ := line["fs_writes"].(float64); writes != 1 {
		t.Errorf("fs_writes = %v, want 1", line["fs_writes"])
	}
	if line["profile_fields_changed"] != "banner,location,website,pinned_post" || line["pin_check"] != "ok" {
		t.Errorf("profile_fields_changed=%v pin_check=%v", line["profile_fields_changed"], line["pin_check"])
	}

	// Another viewer sees the extras (rendering is ungated) and the pin; the author snapshot did not move.
	seen := e.profileOfUser(t, b, a.uid)
	if seen.GetBannerUrl() != got.GetBannerUrl() || seen.GetLocation() != "Pune" || seen.GetWebsite() != "https://example.com/me" || seen.GetPinnedPostId() != p1 {
		t.Fatalf("viewer's profile = %v", seen)
	}
	if fsDocField(t, e, "users/"+a.uid, "snapshotVersion") != int64(0) {
		t.Errorf("snapshotVersion = %v: the extras are not part of the author snapshot", fsDocField(t, e, "users/"+a.uid, "snapshotVersion"))
	}
	me, err := e.identity.GetMe(ctx, authed(a.token, &identityv1.GetMeRequest{}))
	if err != nil || me.Msg.GetProfile().GetPinnedPostId() != p1 || me.Msg.GetProfile().GetLocation() != "Pune" {
		t.Fatalf("GetMe = %v, %v", me, err)
	}

	// --- re-pin to the second post, then delete the FIRST: the newer pin stays ---
	if got, err = update(&identityv1.UpdateProfileRequest{IdempotencyKey: "pinext-repin-0000001", PinnedPostId: &p2}); err != nil || got.GetPinnedPostId() != p2 {
		t.Fatalf("re-pin = %v, %v", got, err)
	}
	e.pull(t) // drain
	if _, err := e.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: "pinext-del-p1-000001", PostId: p1})); err != nil {
		t.Fatalf("DeletePost p1: %v", err)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "post_delete" || msgs[0]["postId"] != p1 {
		t.Fatalf("job messages = %v", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d", code)
	}
	if got := e.profileOfUser(t, b, a.uid).GetPinnedPostId(); got != p2 {
		t.Fatalf("pinned_post_id = %q after deleting an older post, want the newer pin %q kept", got, p2)
	}

	// --- a forged post_delete for a LIVE pinned post is dropped: the job never acts on the message's word alone ---
	if code := e.deliverJSON(t, map[string]any{"kind": "post_delete", "uid": a.uid, "postId": p2}); code != http.StatusNoContent {
		t.Fatalf("forged delivery = %d (an ack: dropped, not retried forever)", code)
	}
	if got := e.profileOfUser(t, b, a.uid).GetPinnedPostId(); got != p2 {
		t.Fatalf("a forged post_delete unpinned a live post: pinned_post_id = %q", got)
	}

	// --- deleting the pinned post clears the pin; a redelivery is harmless ---
	if _, err := e.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: "pinext-del-p2-000001", PostId: p2})); err != nil {
		t.Fatalf("DeletePost p2: %v", err)
	}
	msgs = e.pull(t)
	if len(msgs) != 1 || msgs[0]["postId"] != p2 {
		t.Fatalf("job messages = %v", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d", code)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("redelivery = %d", code)
	}
	if got := e.profileOfUser(t, b, a.uid); got.GetPinnedPostId() != "" || got.GetLocation() != "Pune" || got.GetBannerUrl() == "" {
		t.Fatalf("profile after the pinned post was deleted = %v: the pin clears, nothing else", got)
	}
	if v := fsDocField(t, e, "users/"+a.uid, "pinnedPostId"); v != "" && v != nil {
		t.Errorf("stored pinnedPostId = %v", v)
	}

	// --- "" removes the banner and clears the fields, and costs no resolve ---
	got, err = update(&identityv1.UpdateProfileRequest{IdempotencyKey: "pinext-clear-000001", BannerMediaId: str(""), Location: str(""), Website: str("")})
	if err != nil || got.GetBannerUrl() != "" || got.GetBannerThumbUrl() != "" || got.GetLocation() != "" || got.GetWebsite() != "" {
		t.Fatalf("clear = %v, %v", got, err)
	}
	line = lastRequestLine(t, e, rpcUpdateProfile)
	if reads, _ := line["fs_reads"].(float64); reads > 2 {
		t.Errorf("clear: fs_reads = %v, want <= 2 (interceptor + transaction)", line["fs_reads"])
	}
}

func TestProfileExtras_FlagGateAndKillSwitch(t *testing.T) {
	ctx := context.Background()
	aTok, aUID := mintToken(t, "")
	bTok, bUID := mintToken(t, "")
	// Allowlist mode with a only: b is outside the cohort. The pin is omitted only when the flag is globally off.
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		relaxLimits(c)
		mediaOn(c)
		c.FeatureProfileExtras = flags.Spec{Name: "profile_extras", Mode: flags.Allowlist, Allowlist: map[string]struct{}{aUID: {}}}
	})
	e.createProfile(t, aTok)
	e.createProfile(t, bTok)
	a, b := testUser{aTok, aUID}, testUser{bTok, bUID}
	loc, spaces := "Pune", "   "

	// Outside the cohort: FEATURE_DISABLED feature=profile_extras for a SET, and for a request that mixes a clear with a
	// set (refused whole), with 0 writes (ADR-0024 Amendment 1 A2: only a clear passes, below).
	empty := ""
	for name, req := range map[string]*identityv1.UpdateProfileRequest{
		"location":         {IdempotencyKey: "pinext-gate-000000001", Location: &loc},
		"clear plus a set": {IdempotencyKey: "pinext-gate-000000002", PinnedPostId: &empty, Location: &loc},
		"whitespace-only":  {IdempotencyKey: "pinext-gate-000000005", Website: &spaces},
	} {
		_, err := e.identity.UpdateProfile(ctx, authed(b.token, req))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || d.GetMetadata()["feature"] != "profile_extras" {
			t.Errorf("%s: reason=%v metadata=%v", name, d.GetReason(), d.GetMetadata())
		}
		line := lastRequestLine(t, e, rpcUpdateProfile)
		if writes, _ := line["fs_writes"].(float64); writes != 0 {
			t.Errorf("%s: fs_writes = %v, want 0", name, line["fs_writes"])
		}
		if reads, _ := line["fs_reads"].(float64); reads > 1 {
			t.Errorf("%s: fs_reads = %v, want at most the interceptor's 1", name, line["fs_reads"])
		}
	}
	// The name and bio path is unchanged for them.
	bio := "hello"
	if _, err := e.identity.UpdateProfile(ctx, authed(b.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "pinext-gate-000000003", Bio: &bio})); err != nil {
		t.Fatalf("bio edit outside the cohort: %v", err)
	}
	// A clear is accepted from outside the cohort (A2): the extras a caller once set in the cohort can always be removed.
	if _, err := e.fs.Doc("users/"+b.uid).Update(ctx, []firestore.Update{
		{Path: "location", Value: "Pune"}, {Path: "website", Value: "https://example.com"}, {Path: "pinnedPostId", Value: "0000000000000000301"},
		{Path: "bannerUrl", Value: "https://m/b.webp"}, {Path: "bannerThumbUrl", Value: "https://m/b_t.webp"},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	cleared, err := e.identity.UpdateProfile(ctx, authed(b.token, &identityv1.UpdateProfileRequest{
		IdempotencyKey: "pinext-gate-000000006", BannerMediaId: &empty, Location: &empty, Website: &empty, PinnedPostId: &empty,
	}))
	if err != nil {
		t.Fatalf("a clear outside the cohort: %v", err)
	}
	if p := cleared.Msg.GetProfile(); p.GetBannerUrl() != "" || p.GetLocation() != "" || p.GetWebsite() != "" || p.GetPinnedPostId() != "" {
		t.Errorf("response after the clear = %v", p)
	}
	line := lastRequestLine(t, e, rpcUpdateProfile)
	if writes, _ := line["fs_writes"].(float64); writes != 1 {
		t.Errorf("a clear: fs_writes = %v, want 1", line["fs_writes"])
	}
	if reads, _ := line["fs_reads"].(float64); reads > 2 {
		t.Errorf("a clear: fs_reads = %v, want <= 2 (interceptor + transaction)", line["fs_reads"])
	}
	for _, f := range []string{"location", "website", "pinnedPostId", "bannerUrl", "bannerThumbUrl"} {
		if v := fsDocField(t, e, "users/"+b.uid, f); v != "" && v != nil {
			t.Errorf("stored %s = %v after the clear", f, v)
		}
	}
	// GetMe lists profile_extras only for the allowlisted caller.
	meA, _ := e.identity.GetMe(ctx, authed(a.token, &identityv1.GetMeRequest{}))
	meB, _ := e.identity.GetMe(ctx, authed(b.token, &identityv1.GetMeRequest{}))
	if !slices.Contains(meA.Msg.GetEnabledFeatures(), "profile_extras") || slices.Contains(meB.Msg.GetEnabledFeatures(), "profile_extras") {
		t.Errorf("enabled_features: a=%v b=%v", meA.Msg.GetEnabledFeatures(), meB.Msg.GetEnabledFeatures())
	}

	// In the cohort: the pin is set; every viewer, listed or not, sees it while the flag is a rollout.
	pid := e.createRootPost(t, a, "pinext-gate-post-0001", "pinned")
	if _, err := e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "pinext-gate-000000004", PinnedPostId: &pid, Location: &loc})); err != nil {
		t.Fatalf("UpdateProfile in the cohort: %v", err)
	}
	if got := e.profileOfUser(t, b, aUID); got.GetPinnedPostId() != pid || got.GetLocation() != "Pune" {
		t.Fatalf("a viewer outside the cohort sees %v, want the pin and location", got)
	}
}

// TestProfileExtras_KillSwitchOmitsThePinAndWebsite: with profile_extras globally off (mode off) the stored pin and website
// are not returned by any RPC, the owner's own view included, while banner and location still are (ADR-0024 D3: clients
// stop the GetPost call; Amendment 1 A1: the link stops rendering). A clear still works, at 1 read and 1 write
// (Amendment 1 A2).
func TestProfileExtras_KillSwitchOmitsThePinAndWebsite(t *testing.T) {
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		relaxLimits(c)
		c.FeatureProfileExtras = flags.Spec{Name: "profile_extras", Mode: flags.Off}
	})
	a, b := e.newUser(t), e.newUser(t)
	pid := e.createRootPost(t, a, "pinext-kill-post-0001", "pinned while the flag was on")
	if _, err := e.fs.Doc("users/"+a.uid).Update(context.Background(), []firestore.Update{
		{Path: "pinnedPostId", Value: pid}, {Path: "location", Value: "Pune"}, {Path: "website", Value: "https://example.com"},
		{Path: "bannerUrl", Value: "https://m/b.webp"}, {Path: "bannerThumbUrl", Value: "https://m/b_t.webp"},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	check := func(rpc string, p *identityv1.Profile) {
		t.Helper()
		if p.GetPinnedPostId() != "" || p.GetWebsite() != "" {
			t.Errorf("%s: pinned_post_id = %q, website = %q while profile_extras is globally off", rpc, p.GetPinnedPostId(), p.GetWebsite())
		}
		if p.GetLocation() != "Pune" || p.GetBannerUrl() != "https://m/b.webp" || p.GetBannerThumbUrl() != "https://m/b_t.webp" {
			t.Errorf("%s: banner and location must stay visible: %v", rpc, p)
		}
	}
	check("GetProfile (viewer)", e.profileOfUser(t, b, a.uid))
	check("GetProfile (self)", e.profileOfUser(t, a, a.uid))
	me, err := e.identity.GetMe(context.Background(), authed(a.token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	check("GetMe", me.Msg.GetProfile())
	bio := "still editable"
	upd, err := e.identity.UpdateProfile(context.Background(), authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "pinext-kill-000000001", Bio: &bio}))
	if err != nil {
		t.Fatal(err)
	}
	check("UpdateProfile (bio)", upd.Msg.GetProfile())
	// The stored pin is untouched, ready for the day the flag comes back.
	if fsDocField(t, e, "users/"+a.uid, "pinnedPostId") != pid || fsDocField(t, e, "users/"+a.uid, "website") != "https://example.com" {
		t.Errorf("stored pinnedPostId = %v, website = %v, want both kept", fsDocField(t, e, "users/"+a.uid, "pinnedPostId"), fsDocField(t, e, "users/"+a.uid, "website"))
	}

	// The owner cannot see their website or pin now, but the clear still works (A2): 1 read and 1 write beyond the
	// interceptor, the stored values go, and the response still shows neither.
	empty := ""
	cleared, err := e.identity.UpdateProfile(context.Background(), authed(a.token, &identityv1.UpdateProfileRequest{
		IdempotencyKey: "pinext-kill-000000002", Website: &empty, Location: &empty, PinnedPostId: &empty, BannerMediaId: &empty,
	}))
	if err != nil {
		t.Fatalf("a clear while profile_extras is globally off: %v", err)
	}
	if p := cleared.Msg.GetProfile(); p.GetWebsite() != "" || p.GetPinnedPostId() != "" || p.GetLocation() != "" || p.GetBannerUrl() != "" {
		t.Errorf("response after the clear = %v", p)
	}
	line := lastRequestLine(t, e, rpcUpdateProfile)
	if writes, _ := line["fs_writes"].(float64); writes != 1 {
		t.Errorf("clear: fs_writes = %v, want 1", line["fs_writes"])
	}
	if reads, _ := line["fs_reads"].(float64); reads > 2 {
		t.Errorf("clear: fs_reads = %v, want <= 2 (interceptor + transaction)", line["fs_reads"])
	}
	for _, f := range []string{"website", "location", "pinnedPostId", "bannerUrl", "bannerThumbUrl"} {
		if v := fsDocField(t, e, "users/"+a.uid, f); v != "" && v != nil {
			t.Errorf("stored %s = %v after the clear", f, v)
		}
	}
}

// lastRequestLine returns the last logged request line for rpc.
func lastRequestLine(t *testing.T, e *lifecycleEnv, rpc string) map[string]any {
	t.Helper()
	lines := e.requestLinesFor(rpc)
	if len(lines) == 0 {
		t.Fatalf("no request line for %s", rpc)
	}
	return lines[len(lines)-1]
}

// fsDocField reads one field of a document (nil when the field or the document is absent).
func fsDocField(t *testing.T, e *lifecycleEnv, path, field string) any {
	t.Helper()
	snap, err := e.fs.Doc(path).Get(context.Background())
	if err != nil {
		t.Fatalf("get %s: %v", path, err)
	}
	return snap.Data()[field]
}
