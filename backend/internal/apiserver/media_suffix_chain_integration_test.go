//go:build integration

package apiserver

// W3-39 (W3-36 M-2) over the real Build chain: images whose documents carry a nameSuffix flow through CreatePost,
// UpdateProfile (replace), the profile_media_retired job, DeletePost and the post_delete job exactly like old
// documents, with the same Firestore reads and writes (+0). The same flow runs once with old-shape documents and once
// with suffixed ones, and the per-request costs are compared, so a regression in either shape fails the budget.
//
// A signed PUT URL cannot be minted against the emulators, so the READY documents are seeded the way FinalizeUpload
// leaves them (see media_chain_integration_test.go); the finalize naming itself is covered by the media package.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	mrand "math/rand"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// seedMediaShaped writes a READY media document like FinalizeUpload leaves it: with a nameSuffix and the suffixed
// public paths, or (suffixed false) the pre-W3-39 shape.
func (e *lifecycleEnv) seedMediaShaped(t *testing.T, uid string, purpose media.Purpose, suffixed bool) (id, suffix string) {
	t.Helper()
	id = fmt.Sprintf("%019d", 4_000_000_000_000_000_000+mrand.Int63n(1_000_000_000))
	d := media.Doc{
		OwnerID: uid, Purpose: string(purpose), Status: string(media.StatusReady), ContentType: "image/jpeg",
		Bytes: 1000, ThumbBytes: 100, Width: 1200, Height: 800, Blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
		PublicPath: "m/" + id + ".jpg", ThumbPath: "m/" + id + "_t.jpg", CreatedAt: time.Now().UTC(),
	}
	if suffixed {
		var b [16]byte
		if _, err := rand.Read(b[:]); err != nil {
			t.Fatal(err)
		}
		suffix = hex.EncodeToString(b[:])
		d.NameSuffix = suffix
		d.PublicPath, d.ThumbPath = "m/"+id+"-"+suffix+".jpg", "m/"+id+"-"+suffix+"_t.jpg"
	}
	if _, err := e.fs.Collection("media").Doc(id).Set(context.Background(), d); err != nil {
		t.Fatalf("seed media: %v", err)
	}
	return id, suffix
}

// chainCosts are the Firestore reads and writes of each step of the chain.
type chainCosts map[string][2]float64

func (e *lifecycleEnv) costOf(t *testing.T, rpc string) [2]float64 {
	t.Helper()
	l := lastRequestLine(t, e, rpc)
	r, _ := l["fs_reads"].(float64)
	w, _ := l["fs_writes"].(float64)
	return [2]float64{r, w}
}

// jobCost sums the reads and writes of every account_job line of a kind logged since the line count was taken.
func (e *lifecycleEnv) jobCost(kind string, since int) [2]float64 {
	var c [2]float64
	for _, l := range e.jobLines()[since:] {
		if l["account_job"] != kind {
			continue
		}
		r, _ := l["fs_reads"].(float64)
		w, _ := l["fs_writes"].(float64)
		c[0] += r
		c[1] += w
	}
	return c
}

func runNameChain(t *testing.T, suffixed bool) chainCosts {
	t.Helper()
	ctx := context.Background()
	hex32 := regexp.MustCompile(`^m/[0-9]{19}-[0-9a-f]{32}(_t)?\.jpg$`)
	costs := chainCosts{}
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		mediaOn(c)
		retireOn(config.ProfileMediaRetireAll)(c)
	})
	a := e.newUser(t)
	m1, _ := e.seedMediaShaped(t, a.uid, media.PurposePost, suffixed)
	m2, _ := e.seedMediaShaped(t, a.uid, media.PurposePost, suffixed)
	av1, sa1 := e.seedMediaShaped(t, a.uid, media.PurposeAvatar, suffixed)
	av2, _ := e.seedMediaShaped(t, a.uid, media.PurposeAvatar, suffixed)

	// --- CreatePost: the refs carry the document's own names, opaque to the caller ---
	resp, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{
		IdempotencyKey: "suffix-post-key-00001", Text: "two pictures", MediaIds: []string{m1, m2},
	}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	post := resp.Msg.GetPost().GetPost()
	costs["CreatePost"] = e.costOf(t, "/dzeroth.posts.v1.PostService/CreatePost")
	for _, m := range post.GetMedia() {
		name := strings.TrimPrefix(m.GetUrl(), e.cfg.MediaPublicBaseURL+"/")
		thumb := strings.TrimPrefix(m.GetThumbUrl(), e.cfg.MediaPublicBaseURL+"/")
		if suffixed && (!hex32.MatchString(name) || !hex32.MatchString(thumb)) {
			t.Fatalf("suffixed ref = %q / %q", m.GetUrl(), m.GetThumbUrl())
		}
		if !suffixed && (strings.Contains(name, "-") || strings.Contains(thumb, "-")) {
			t.Fatalf("old-shape ref = %q / %q", m.GetUrl(), m.GetThumbUrl())
		}
	}

	// --- UpdateProfile replace: the retire job gets the old document's own URLs and retires it ---
	e.pull(t)
	first, err := e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "suffix-avatar-set-0001", AvatarMediaId: &av1}))
	if err != nil {
		t.Fatalf("UpdateProfile(set): %v", err)
	}
	if suffixed && !strings.Contains(first.Msg.GetProfile().GetAvatarUrl(), "-"+sa1+".jpg") {
		t.Fatalf("avatar url = %q, want the suffixed name", first.Msg.GetProfile().GetAvatarUrl())
	}
	e.pull(t)
	if _, err := e.identity.UpdateProfile(ctx, authed(a.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "suffix-avatar-repl-001", AvatarMediaId: &av2})); err != nil {
		t.Fatalf("UpdateProfile(replace): %v", err)
	}
	costs["UpdateProfile"] = e.costOf(t, rpcUpdateProfile)
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != media.JobKindProfileMediaRetired {
		t.Fatalf("messages = %v, want one profile_media_retired", msgs)
	}
	oldURL, _ := msgs[0]["oldUrl"].(string)
	if suffixed != (sa1 != "" && strings.Contains(oldURL, "-"+sa1)) {
		t.Fatalf("oldUrl = %q (suffixed=%v)", oldURL, suffixed)
	}
	before := len(e.jobLines())
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("retire delivery = %d", code)
	}
	costs["retire job"] = e.jobCost(media.JobKindProfileMediaRetired, before)
	if jl := e.lastRetireLine(t); jl["outcome"] != "retired" {
		t.Fatalf("retire outcome = %v, want retired", jl["outcome"])
	}
	if _, _, retired := e.mediaDocFields(t, av1); !retired {
		t.Fatal("the replaced avatar's document was not marked retired")
	}

	// --- DeletePost -> post_delete: objects of both shapes and the documents go ---
	e.pull(t)
	if _, err := e.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: "suffix-del-key-000001", PostId: post.GetPostId()})); err != nil {
		t.Fatalf("DeletePost: %v", err)
	}
	costs["DeletePost"] = e.costOf(t, "/dzeroth.posts.v1.PostService/DeletePost")
	jobs := e.pull(t)
	if len(jobs) != 1 || jobs[0]["kind"] != "post_delete" {
		t.Fatalf("job messages = %v", jobs)
	}
	before = len(e.jobLines())
	if code := e.deliver(t, jobs[0]); code != http.StatusNoContent {
		t.Fatalf("post_delete delivery = %d", code)
	}
	costs["post_delete job"] = e.jobCost("post_delete", before)
	if fsDocExists(t, e.fs, "media/"+m1) || fsDocExists(t, e.fs, "media/"+m2) {
		t.Fatal("post_delete did not remove the media documents")
	}
	return costs
}

func TestMediaNameSuffixChain_CostsMatchOldDocuments(t *testing.T) {
	oldCosts := runNameChain(t, false)
	newCosts := runNameChain(t, true)
	for step, want := range oldCosts {
		if got := newCosts[step]; got != want {
			t.Errorf("%s: suffixed docs cost reads/writes %v, old docs %v; W3-39 must add 0 reads and 0 writes", step, got, want)
		}
	}
	// And the documented ceilings (media_chain_integration_test.go): CreatePost with 2 images <= 5 reads, 6 writes;
	// UpdateProfile with an avatar <= 3 reads, 1 write; the retire job 2 reads, 1 write.
	if c := newCosts["CreatePost"]; c[0] > 5 || c[1] != 6 {
		t.Errorf("CreatePost = %v, want reads <= 5 and writes 6", c)
	}
	if c := newCosts["UpdateProfile"]; c[0] > 3 || c[1] != 1 {
		t.Errorf("UpdateProfile = %v, want reads <= 3 and writes 1", c)
	}
	if c := newCosts["retire job"]; c != [2]float64{2, 1} {
		t.Errorf("retire job = %v, want [2 1]", c)
	}
}
