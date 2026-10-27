//go:build integration

package apiserver

// W3-20: the cross-ticket journey of UI wave W3 Part A through the real apiserver chain (Firestore, Auth and Pub/Sub
// emulators, the production route table and interceptors): an account sets a banner, location, website and a pinned post;
// a visitor opens every tab, likes and lists the like, sees "Follows you" appear when the account follows back, gets
// who-to-follow suggestions; the pinned post is deleted and the pin clears itself; the account exports (the new profile
// fields are in the export), then every flag is flipped off in a new instance over the SAME data and each gated surface
// refuses while the ungated ones keep working; finally the account is deleted and none of its W3 data survives.
// A signed PUT URL cannot be minted against the emulators, so READY media documents are seeded the way FinalizeUpload
// leaves them (as the P4 chain test does); the upload and moderation logic has its own tests (banner_matrix_integration).

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"testing"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestW320_E2E_ProfileGraphCompletionJourney(t *testing.T) {
	ctx := context.Background()
	e, w := newW320Life(t, nil)
	a, b := w.user(t), w.user(t)
	x, y := w.user(t), w.user(t)
	cands := w.w320Users(t, 3)

	// --- 1. A sets a banner, location, website and a pin ---
	banner := e.seedMedia(t, a.uid, media.PurposeBanner)
	img1, img2 := e.seedMedia(t, a.uid, media.PurposePost), e.seedMedia(t, a.uid, media.PurposePost)
	create := func(u bmUser, req *postsv1.CreatePostRequest) string {
		req.IdempotencyKey = contractKey("w320-e2e")
		r, err := w.posts.CreatePost(ctx, authed(u.token, req))
		if err != nil {
			t.Fatalf("CreatePost: %v", err)
		}
		return r.Msg.GetPost().GetPost().GetPostId()
	}
	text1 := create(a, &postsv1.CreatePostRequest{Text: "hello from A"})
	pinned := create(a, &postsv1.CreatePostRequest{Text: "my pinned photo", MediaIds: []string{img1}})
	photo2 := create(a, &postsv1.CreatePostRequest{Text: "another photo", MediaIds: []string{img2}})
	bPost := create(b, &postsv1.CreatePostRequest{Text: "B's post"})
	prof, err := w.w320Update(a, &identityv1.UpdateProfileRequest{
		BannerMediaId: &banner, Location: w320Str("Pune"), Website: w320Str("https://example.com/a"), PinnedPostId: &pinned,
	})
	if err != nil || prof.GetBannerUrl() == "" || prof.GetBannerThumbUrl() == "" || prof.GetLocation() != "Pune" ||
		prof.GetWebsite() != "https://example.com/a" || prof.GetPinnedPostId() != pinned {
		t.Fatalf("UpdateProfile = %v, %v", prof, err)
	}
	// A reposts B's post, so A's Reposts tab has a row.
	rp, err := w.eng.RepostPost(ctx, authed(a.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w320-e2e-rp"), PostId: bPost}))
	if err != nil {
		t.Fatal(err)
	}
	repost := rp.Msg.GetRepostPostId()

	// --- 2. B (a visitor) sees the profile and opens every tab ---
	w.w320Follow(t, b, a.uid)
	seen := w.w320Profile(t, b, a.uid)
	if seen.GetBannerUrl() != prof.GetBannerUrl() || seen.GetLocation() != "Pune" || seen.GetWebsite() != "https://example.com/a" || seen.GetPinnedPostId() != pinned {
		t.Fatalf("B sees %v", seen)
	}
	tabs := map[string]struct {
		call func() ([]string, error)
		want []string
	}{
		"Posts": {func() ([]string, error) {
			r, err := w.w320TabCall(b, a.uid, tabPostsPB, false, 20, "", "")
			return tabPostIDs(r), err
		}, nil},
		"Replies": {func() ([]string, error) {
			r, err := w.w320TabCall(b, a.uid, 2, true, 20, "", "")
			return tabPostIDs(r), err
		}, nil},
		"Media": {func() ([]string, error) {
			r, err := w.w320TabCall(b, a.uid, tabMediaPB, false, 20, "", "")
			return tabPostIDs(r), err
		}, []string{photo2, pinned}},
		"Reposts": {func() ([]string, error) {
			r, err := w.w320TabCall(b, a.uid, tabRepostsPB, false, 20, "", "")
			return tabPostIDs(r), err
		}, []string{repost}},
	}
	for name, tc := range tabs {
		got, err := tc.call()
		if err != nil {
			t.Fatalf("tab %s: %v", name, err)
		}
		if tc.want != nil && !slices.Equal(got, tc.want) {
			t.Errorf("tab %s = %v, want %v", name, got, tc.want)
		}
		if name == "Posts" && (!slices.Contains(got, text1) || !slices.Contains(got, pinned) || !slices.Contains(got, photo2)) {
			t.Errorf("Posts tab = %v, want A's three posts", got)
		}
	}

	// --- 3. B likes the pinned post and lists their likes (owner only) ---
	w.like(t, b, pinned)
	liked, err := w.listLiked(b, 0, "")
	if err != nil || !slices.Equal(likedPostIDs(liked), []string{pinned}) {
		t.Fatalf("B's likes = %v, %v", likedPostIDs(liked), err)
	}
	if lo, err := w.listLiked(a, 0, ""); err != nil || len(lo.GetPosts()) != 0 {
		t.Fatalf("A's likes = %v, %v; want none (B's like is not A's)", likedPostIDs(lo), err)
	}

	// --- 4. "Follows you": A follows B back ---
	rel, err := w.w320Rel(b, a.uid)
	if err != nil || rel.GetFollowedBy() || rel.GetRelationship().GetFollowState() != graphv1.FollowState_FOLLOW_STATE_FOLLOWING {
		t.Fatalf("B -> A before A follows back: %v, %v; want FOLLOWING and followed_by=false", rel, err)
	}
	w.w320Follow(t, a, b.uid)
	rel, err = w.w320Rel(b, a.uid)
	if err != nil || !rel.GetFollowedBy() {
		t.Fatalf("B -> A after A follows back: %v, %v; want followed_by=true", rel, err)
	}

	// --- 5. Who to follow: B follows x and y too; A, x and y each follow the three candidates ---
	w.w320Follow(t, b, x.uid)
	w.w320Follow(t, b, y.uid)
	for _, f := range []bmUser{a, x, y} {
		for _, c := range cands {
			w.w320Follow(t, f, c.uid)
		}
	}
	sug, err := w.w320Suggest(b, 0)
	if err != nil {
		t.Fatal(err)
	}
	got := w320SugUIDs(sug)
	want := []string{cands[0].uid, cands[1].uid, cands[2].uid}
	if !slices.Equal(w320Sorted(got), w320Sorted(want)) {
		t.Errorf("B's suggestions = %v, want the three candidates %v", got, want)
	}

	// --- 6. The pinned post is deleted: the job clears the pin; the post leaves the Media tab and B's likes ---
	e.pull(t)
	if _, err := w.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("w320-e2e-del"), PostId: pinned})); err != nil {
		t.Fatal(err)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "post_delete" {
		t.Fatalf("job messages = %v", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d", code)
	}
	after := newW320Chain(t, w320TabsOn)
	if p := after.w320Profile(t, b, a.uid); p.GetPinnedPostId() != "" || p.GetLocation() != "Pune" || p.GetBannerUrl() == "" {
		t.Errorf("after the delete job: %v; the pin clears and nothing else", p)
	}
	if r, err := after.w320TabCall(b, a.uid, tabMediaPB, false, 20, "", ""); err != nil || !slices.Equal(tabPostIDs(r), []string{photo2}) {
		t.Errorf("Media tab after the delete = %v, %v", tabPostIDs(r), err)
	}
	if l, err := after.listLiked(b, 0, ""); err != nil || len(l.GetPosts()) != 0 {
		t.Errorf("B's likes after the post was deleted = %v, %v; want the row dropped", likedPostIDs(l), err)
	}

	// --- 7. A pins the second photo and exports: the new profile fields are in the export ---
	if _, err := w.w320Update(a, &identityv1.UpdateProfileRequest{PinnedPostId: &photo2}); err != nil {
		t.Fatal(err)
	}
	exp, err := w.identity.RequestAccountExport(ctx, authed(a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: contractKey("w320-e2e-exp")}))
	if err != nil {
		t.Fatal(err)
	}
	var exportMsg map[string]any
	for _, m := range e.pull(t) {
		if m["kind"] == "account_export" {
			exportMsg = m
		}
	}
	if exportMsg == nil {
		t.Fatal("no account_export job")
	}
	if code := e.deliver(t, exportMsg); code != http.StatusNoContent {
		t.Fatalf("export delivery = %d; job lines %v; logs %s", code, e.jobLines(), e.logsWithMsg("account_job"))
	}
	rd, err := e.bucket.Object(exp.Msg.GetExportId() + ".json").NewReader(ctx)
	if err != nil {
		t.Fatalf("export object: %v", err)
	}
	raw, _ := io.ReadAll(rd)
	_ = rd.Close()
	var envlp struct {
		Profile map[string]any `json:"profile"`
	}
	if err := json.Unmarshal(raw, &envlp); err != nil {
		t.Fatalf("export JSON: %v", err)
	}
	for k, wantV := range map[string]any{"location": "Pune", "website": "https://example.com/a", "pinnedPostId": photo2} {
		if envlp.Profile[k] != wantV {
			t.Errorf("export profile.%s = %v, want %v", k, envlp.Profile[k], wantV)
		}
	}
	if s, _ := envlp.Profile["bannerUrl"].(string); s == "" {
		t.Errorf("export profile has no bannerUrl: %v", envlp.Profile)
	}
	if _, has := envlp.Profile["bannerThumbUrl"]; has {
		t.Error("export carries the derived bannerThumbUrl")
	}

	// --- 8. Flip each flag off in a new instance over the same data ---
	off := func(c *config.Config) {
		w320Base(c)
		c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
		c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
		// every W3 flag stays at its default: off
	}
	o := newW320Chain(t, off)
	o.w320Warm(t, b)
	o.w320Warm(t, a)
	for _, f := range w320FlagNames {
		if slices.Contains(o.enabledFeatures(t, b), f) {
			t.Errorf("enabled_features lists %s with the flag off", f)
		}
	}
	// profile_extras off: the pin is omitted, banner and location keep rendering, setting a field is refused. The website
	// is blanked with the pin since W3-22 M-1(a) (#354); the constant says which of the two the code does.
	wantWebsite := "https://example.com/a"
	if !w320WebsiteShownWhileExtrasGloballyOff {
		wantWebsite = ""
	}
	op := o.w320Profile(t, b, a.uid)
	if op.GetPinnedPostId() != "" || op.GetLocation() != "Pune" || op.GetBannerUrl() == "" || op.GetWebsite() != wantWebsite {
		t.Errorf("profile with profile_extras off = %v (want website %q)", op, wantWebsite)
	}
	_, err = o.w320Update(a, &identityv1.UpdateProfileRequest{Location: w320Str("Mumbai")})
	w320Disabled(t, "UpdateProfile location, profile_extras off", err, "profile_extras")
	// profile_tabs off: Media and Reposts refused, Posts still served.
	_, err = o.w320TabCall(b, a.uid, tabMediaPB, false, 20, "", "")
	w320Disabled(t, "Media tab, profile_tabs off", err, "profile_tabs")
	_, err = o.w320TabCall(b, a.uid, tabRepostsPB, false, 20, "", "")
	w320Disabled(t, "Reposts tab, profile_tabs off", err, "profile_tabs")
	if r, err := o.w320TabCall(b, a.uid, tabPostsPB, false, 20, "", ""); err != nil || !slices.Contains(tabPostIDs(r), text1) {
		t.Errorf("Posts tab with profile_tabs off: %v, %v", tabPostIDs(r), err)
	}
	// likes_list and follow_suggestions off.
	_, err = o.listLiked(b, 0, "")
	w320Disabled(t, "ListLikedPosts, likes_list off", err, "likes_list")
	_, err = o.w320Suggest(b, 0)
	w320Disabled(t, "ListSuggestedUsers, follow_suggestions off", err, "follow_suggestions")
	// "Follows you" has no flag of its own: it keeps answering.
	if r, err := o.w320Rel(b, a.uid); err != nil || !r.GetFollowedBy() {
		t.Errorf("GetProfileRelationship with the W3 flags off: %v, %v; it needs graph only", r, err)
	}

	// --- 9. A deletes the account: no W3 data survives ---
	residue := []struct{ col, field string }{
		{"posts", "authorId"}, {"media", "ownerId"}, {"follows", "followerId"}, {"follows", "followeeId"}, {"exports", "uid"},
	}
	for _, q := range residue { // the check below is not vacuous: every collection holds A's documents before the delete
		docs, err := e.fs.Collection(q.col).Where(q.field, "==", a.uid).Limit(5).Documents(ctx).GetAll()
		if err != nil || len(docs) == 0 {
			t.Fatalf("before the delete %s.%s == A: %d docs, err %v; the journey should have created some", q.col, q.field, len(docs), err)
		}
	}
	if _, err := w.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: contractKey("w320-e2e-acct")})); err != nil {
		t.Fatal(err)
	}
	var deleteMsg map[string]any
	for _, m := range e.pull(t) {
		if m["kind"] == "account_delete" && m["uid"] == a.uid {
			deleteMsg = m
		}
	}
	if deleteMsg == nil {
		t.Fatal("DeleteAccount published no account_delete job")
	}
	e.pastGate(t, a.uid)
	for i := 0; i < 20; i++ { // the job is resumable: deliver until it acks, re-pulling any continuation
		code := e.deliver(t, deleteMsg)
		if code == http.StatusNoContent {
			break
		}
		for _, m := range e.pull(t) {
			if m["kind"] == "account_delete" && m["uid"] == a.uid {
				deleteMsg = m
			}
		}
	}
	if fsDocExists(t, e.fs, "users/"+a.uid) {
		t.Error("users doc survived")
	}
	for _, q := range residue {
		docs, err := e.fs.Collection(q.col).Where(q.field, "==", a.uid).Limit(5).Documents(ctx).GetAll()
		if err != nil || len(docs) != 0 {
			t.Errorf("%s.%s == deleted uid: %d docs, err %v (residue: the banner and the images go with the account)", q.col, q.field, len(docs), err)
		}
	}
	// The visitor's world still works and A's profile is gone.
	late := newW320Chain(t, w320TabsOn)
	_, err = late.identity.GetProfile(ctx, authed(b.token, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: a.uid}}))
	wireError(t, err, connect.CodeNotFound)
	_, err = late.w320TabCall(b, a.uid, tabMediaPB, false, 20, "", "")
	wireError(t, err, connect.CodeNotFound)
	_, err = late.w320Rel(b, a.uid)
	wireError(t, err, connect.CodeNotFound)
	if _, err := late.listLiked(b, 0, ""); err != nil {
		t.Errorf("B's likes list after A's deletion: %v", err)
	}
}
