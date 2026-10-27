//go:build integration

package apiserver

// W3-20: UpdateProfile extras (ADR-0024 D1-D3, D9) over the real Build chain with the Pub/Sub emulator for the
// post_delete job: the location and website (and name and bio) validation driven by the shared fixture
// testdata/profile_text (61 accept / 126 reject rows) over the wire, the per-account daily cap and the no-op skip of
// W3-22 L-4, the pin rules (own POST, QUOTE and REPLY pin; another user's post, a REPOST, a hidden, deleted, unknown or
// malformed id do not, with one identical answer), "" unpins, a takedown keeps the pin and a restore brings it back, the
// post_delete job clearing a pin (also while profile_extras is OFF: the clean-up is never gated), forged jobs doing
// nothing, and the request-log contract (pin_check carries the outcome only; profile_fields_changed carries names, never
// values).
//
// Already covered and not repeated: TestProfileExtras_Chain (bad banners and pins, all-fields write, kill switch,
// re-pin then delete the older post, forged job for a live pin, redelivery), TestProfileExtras_FlagGateAndKillSwitch.
// The tests below are the empty cells.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// newW320Life boots a lifecycle chain (Pub/Sub for the job messages) with every W3 flag, quotes and replies on, and wraps
// its chain in a w320Chain so the engagement, graph and media clients are on the same instance.
func newW320Life(t *testing.T, mutate func(*config.Config)) (*lifecycleEnv, *w320Chain) {
	t.Helper()
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		w320Base(c)
		w320AllW3On(c)
		c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
		c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
		if mutate != nil {
			mutate(c)
		}
	})
	return e, w320Wrap(e.chainEnv)
}

func w320Wrap(env *chainEnv) *w320Chain {
	return &w320Chain{bmChain: newW320BM(env), media: newW320Media(env)}
}

// w320Deliver posts one job message body (as a push subscription would) to the jobs endpoint of the chain at url.
func w320Deliver(t *testing.T, url string, msg any) int {
	t.Helper()
	raw, _ := json.Marshal(msg)
	body, _ := json.Marshal(map[string]any{"message": map[string]any{"data": base64.StdEncoding.EncodeToString(raw), "messageId": "1"}, "subscription": "s", "deliveryAttempt": 1})
	resp, err := http.Post(url+"/internal/pubsub/jobs", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("deliver: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

// The shared profile text fixture (testdata/profile_text/*.json, W3-22 L-2 and L-3), loaded the way the identity runner
// does and driven over the WIRE: every row is one UpdateProfile through the production chain (interceptors, flag gate,
// validators, repo), so what the Dart client's mirrored rules and the server disagree on shows up here. `host` (the
// website's displayed host, a client-side value) is not on the wire and is not compared; identity's own runner checks it.
type w320TextAccept struct {
	Name   string `json:"name"`
	Raw    string `json:"raw"`
	Stored string `json:"stored"`
}

type w320TextReject struct {
	Name string `json:"name"`
	Raw  string `json:"raw"`
	Why  string `json:"why"`
}

type w320TextFile struct {
	Field  string           `json:"field"`
	Accept []w320TextAccept `json:"accept"`
	Reject []w320TextReject `json:"reject"`
}

var w320ProfileTextDir = filepath.Join("..", "..", "..", "testdata", "profile_text")

// w320LoadProfileText decodes one fixture file and applies the README's runner rule: count the "raw": keys of the file text
// and fail when fewer rows decoded (a renamed key must not silently shrink the suite).
func w320LoadProfileText(t *testing.T, field string) w320TextFile {
	t.Helper()
	path := filepath.Join(w320ProfileTextDir, field+".json")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture %s: %v", path, err)
	}
	var f w320TextFile
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	if f.Field != field {
		t.Fatalf("%s declares field %q, want %q", path, f.Field, field)
	}
	if want := bytes.Count(b, []byte(`"raw":`)); len(f.Accept)+len(f.Reject) != want || want == 0 || len(f.Accept) == 0 || len(f.Reject) == 0 {
		t.Fatalf("%s: decoded %d accept + %d reject rows, the file has %d", path, len(f.Accept), len(f.Reject), want)
	}
	return f
}

// TestW320_SharedProfileTextOverTheWire: ticket W3-20 "website and location validation tables", driven by the shared
// fixture instead of a private table (display name and bio ride along: same file format, same validators). An accepted row
// is stored as the fixture's `stored` value and GetProfile of ANOTHER user returns the same; a rejected row is
// INVALID_ARGUMENT VALIDATION with metadata field=<field>, changes nothing and costs no write. The row counts are
// asserted against the file so the suite cannot shrink silently.
func TestW320_SharedProfileTextOverTheWire(t *testing.T) {
	w := newW320Chain(t, w320AllW3On)
	viewer := w.user(t)

	type fieldKind struct {
		field string
		req   func(v *string) *identityv1.UpdateProfileRequest
		get   func(*identityv1.Profile) string
	}
	kinds := []fieldKind{
		{"location", func(v *string) *identityv1.UpdateProfileRequest { return &identityv1.UpdateProfileRequest{Location: v} }, (*identityv1.Profile).GetLocation},
		{"website", func(v *string) *identityv1.UpdateProfileRequest { return &identityv1.UpdateProfileRequest{Website: v} }, (*identityv1.Profile).GetWebsite},
		{"display_name", func(v *string) *identityv1.UpdateProfileRequest {
			return &identityv1.UpdateProfileRequest{DisplayName: v}
		}, (*identityv1.Profile).GetDisplayName},
		{"bio", func(v *string) *identityv1.UpdateProfileRequest { return &identityv1.UpdateProfileRequest{Bio: v} }, (*identityv1.Profile).GetBio},
	}
	var accepted, rejected int
	for _, k := range kinds {
		f := w320LoadProfileText(t, k.field)
		u := w.user(t) // one account per field: its stored value is what a refused row must leave alone
		t.Run(k.field, func(t *testing.T) {
			for i, row := range f.Accept {
				t.Run(fmt.Sprintf("accept/%02d %s", i, row.Name), func(t *testing.T) {
					raw := row.Raw
					got, err := w.w320Update(u, k.req(&raw))
					if err != nil {
						t.Fatalf("UpdateProfile(%q): %v, want it stored as %q", raw, err, row.Stored)
					}
					if k.get(got) != row.Stored {
						t.Errorf("response %s = %q, want %q", k.field, k.get(got), row.Stored)
					}
					if seen := k.get(w.w320Profile(t, viewer, u.uid)); seen != row.Stored {
						t.Errorf("GetProfile (another viewer) %s = %q, want %q", k.field, seen, row.Stored)
					}
					accepted++
				})
			}
			for i, row := range f.Reject {
				t.Run(fmt.Sprintf("reject/%02d %s", i, row.Name), func(t *testing.T) {
					raw := row.Raw
					before := k.get(w.w320Profile(t, viewer, u.uid))
					_, err := w.w320Update(u, k.req(&raw))
					w320Reason(t, fmt.Sprintf("UpdateProfile(%q) [%s]", raw, row.Why), err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, k.field)
					if wr := num(w.line(t, rpcUpdateProfile), "fs_writes"); wr != 0 {
						t.Errorf("a refused %s wrote %d documents", k.field, wr)
					}
					if seen := k.get(w.w320Profile(t, viewer, u.uid)); seen != before {
						t.Errorf("a refused %s changed the profile: %q -> %q", k.field, before, seen)
					}
					rejected++
				})
			}
		})
	}
	t.Logf("shared profile text over the wire: %d accepted rows, %d rejected rows", accepted, rejected)
	if accepted != 61 || rejected != 126 {
		t.Errorf("ran %d accept and %d reject rows; the fixture at W3-22 L-2/L-3 holds 61 and 126 (a fixture change must update this count on purpose)", accepted, rejected)
	}
}

// TestW320_UpdateProfileDailyCapAndNoOpWrites: W3-22 L-4 through the production chain. (a) A request that changes nothing
// costs 1 read and 0 writes (a changed one 1 and 1), UpdatedAt does not move, and the request log names no changed
// field. (b) The (cap+1)-th UpdateProfile of the day is RESOURCE_EXHAUSTED RATE_LIMITED limit=profile_update_daily at 0
// reads and 0 writes, another user and GetMe are untouched, and a no-op call counts against the cap like any other.
func TestW320_UpdateProfileDailyCapAndNoOpWrites(t *testing.T) {
	const dailyCap = 4
	w := newW320Chain(t, func(c *config.Config) {
		w320AllW3On(c)
		c.RateLimit.ProfileUpdatesPerDay = dailyCap
	})
	u, other := w.user(t), w.user(t)
	w.w320Warm(t, u)

	if _, err := w.w320Update(u, &identityv1.UpdateProfileRequest{Bio: w320Str("first bio"), Location: w320Str("Pune")}); err != nil {
		t.Fatal(err)
	}
	c := w.lineBudget(t, rpcUpdateProfile)
	budgettest.Assert(t, "UpdateProfile, a real change (warm interceptor)", c, budgettest.Budget{Reads: 1, Writes: 1})
	if c.Reads() != 1 || c.Writes() != 1 {
		t.Errorf("a real change = %d reads / %d writes, want 1 / 1", c.Reads(), c.Writes())
	}
	stamp := w.w320Field(t, "users/"+u.uid, "updatedAt")

	if _, err := w.w320Update(u, &identityv1.UpdateProfileRequest{Bio: w320Str("  first bio  "), Location: w320Str("Pune")}); err != nil {
		t.Fatal(err)
	}
	c = w.lineBudget(t, rpcUpdateProfile)
	budgettest.Assert(t, "UpdateProfile, the same values again (trim-equal)", c, budgettest.Budget{Reads: 1})
	if c.Writes() != 0 || c.Reads() != 1 {
		t.Errorf("a no-op = %d reads / %d writes, want 1 / 0", c.Reads(), c.Writes())
	}
	if v, has := w.line(t, rpcUpdateProfile)["profile_fields_changed"]; has {
		t.Errorf("a no-op logged profile_fields_changed = %v", v)
	}
	if after := w.w320Field(t, "users/"+u.uid, "updatedAt"); fmt.Sprint(after) != fmt.Sprint(stamp) {
		t.Errorf("updatedAt moved on a no-op: %v -> %v", stamp, after)
	}
	t.Logf("W320BUDGET rpc=%q case=%q reads=%d writes=%d deletes=%d ceil_reads=%d ceil_writes=%d", rpcUpdateProfile, "no-op re-send (L-4)", c.Reads(), c.Writes(), c.Deletes(), 1, 0)

	// Calls 3 and 4 (a change, then an empty request) spend the rest of the day.
	if _, err := w.w320Update(u, &identityv1.UpdateProfileRequest{Bio: w320Str("second bio")}); err != nil {
		t.Fatal(err)
	}
	if _, err := w.w320Update(u, &identityv1.UpdateProfileRequest{}); err != nil {
		t.Fatalf("an empty request (call %d of %d): %v", dailyCap, dailyCap, err)
	}
	_, err := w.w320Update(u, &identityv1.UpdateProfileRequest{Bio: w320Str("one too many")})
	w320Reason(t, "UpdateProfile call cap+1", err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "")
	if d := w320Detail(err); d != nil && d.GetMetadata()["limit"] != "profile_update_daily" {
		t.Errorf("limit = %q, want profile_update_daily", d.GetMetadata()["limit"])
	}
	w.w320AssertNothing(t, "a capped UpdateProfile", rpcUpdateProfile)
	if seen := w.w320Profile(t, other, u.uid).GetBio(); seen != "second bio" {
		t.Errorf("the capped call changed the bio: %q", seen)
	}
	if _, err := w.w320Update(other, &identityv1.UpdateProfileRequest{Bio: w320Str("another user is not capped")}); err != nil {
		t.Errorf("another user shares the counter: %v", err)
	}
	if got := w.enabledFeatures(t, u); got == nil {
		t.Error("GetMe returned no capabilities for the capped user")
	}
}

// pinWorld is the data of the pin matrix.
type w320PinWorld struct {
	a, b                                       bmUser
	own, quote, reply, repost, theirs, deleted string
}

func w320SeedPinWorld(t *testing.T, w *w320Chain) w320PinWorld {
	t.Helper()
	ctx := context.Background()
	p := w320PinWorld{a: w.user(t), b: w.user(t)}
	p.theirs = w.post(t, p.b, "b's post")
	p.own = w.post(t, p.a, "a's own post")
	q, err := w.posts.CreatePost(ctx, authed(p.a.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w320-q"), Text: "a quotes b", QuoteOfPostId: p.theirs}))
	if err != nil {
		t.Fatalf("quote: %v", err)
	}
	p.quote = q.Msg.GetPost().GetPost().GetPostId()
	r, err := w.posts.CreatePost(ctx, authed(p.a.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("w320-r"), Text: "a replies to b", ReplyToPostId: p.theirs}))
	if err != nil {
		t.Fatalf("reply: %v", err)
	}
	p.reply = r.Msg.GetPost().GetPost().GetPostId()
	rp, err := w.eng.RepostPost(ctx, authed(p.a.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w320-rp"), PostId: p.theirs}))
	if err != nil {
		t.Fatalf("repost: %v", err)
	}
	p.repost = rp.Msg.GetRepostPostId()
	p.deleted = w.post(t, p.a, "a post that will be deleted")
	if _, err := w.posts.DeletePost(ctx, authed(p.a.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("w320-d"), PostId: p.deleted})); err != nil {
		t.Fatalf("delete: %v", err)
	}
	return p
}

// TestW320_PinRules: ADR-0024 D3. A caller pins their own POST, QUOTE or REPLY; every other id is one VALIDATION
// field=pinned_post_id answer with one identical message (no existence oracle) and pin_check=rejected in the request log;
// "" unpins; a takedown or a suspended author hides the post and refuses a NEW pin (a cold instance, so no cache hides
// the change) while an existing pin is kept (a takedown does not unpin: a restore brings the pin back).
func TestW320_PinRules(t *testing.T) {
	ctx := context.Background()
	e, w := newW320Life(t, nil)
	p := w320SeedPinWorld(t, w)

	pin := func(id string) (*identityv1.Profile, error) {
		return w.w320Update(p.a, &identityv1.UpdateProfileRequest{PinnedPostId: &id})
	}
	pinLine := func() any { return lastRequestLine(t, e, rpcUpdateProfile)["pin_check"] }

	for _, c := range []struct{ name, id string }{{"own POST", p.own}, {"own QUOTE", p.quote}, {"own REPLY", p.reply}} {
		name, id := c.name, c.id
		got, err := pin(id)
		if err != nil || got.GetPinnedPostId() != id {
			t.Errorf("pin %s: %v, %v", name, got.GetPinnedPostId(), err)
		}
		if pinLine() != "ok" {
			t.Errorf("pin %s: pin_check = %v, want ok", name, pinLine())
		}
	}
	if seen := w.w320Profile(t, p.b, p.a.uid).GetPinnedPostId(); seen != p.reply {
		t.Errorf("a viewer sees pinned_post_id = %q, want the last pin %q", seen, p.reply)
	}

	// Hidden posts: a takedown and a suspended-author hide. Boot a cold chain so the posts cache cannot answer for the
	// moment before the change (the checker is cache-first; the staleness bound is documented on CanPin).
	hidden, suspended := w.post(t, p.a, "to be taken down"), w.post(t, p.a, "author suspended")
	for id, mod := range map[string]string{hidden: "TAKEN_DOWN", suspended: "SUSPENDED_AUTHOR"} {
		if _, err := w.fs.Doc("posts/"+id).Set(ctx, map[string]any{"moderation": mod}, firestore.MergeAll); err != nil {
			t.Fatal(err)
		}
	}
	cw := newW320Chain(t, func(c *config.Config) {
		w320AllW3On(c)
		c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
		c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
	})
	rejected := []struct{ name, id string }{
		{"another user's post", p.theirs},
		{"a REPOST (of anything)", p.repost},
		{"a deleted post", p.deleted},
		{"a taken-down post", hidden},
		{"a post of a suspended author", suspended},
		{"an id that never existed", "0000000000000000042"},
		{"a malformed id", "nope"},
		{"a path-shaped id", "../posts/x"},
		{"a numeric id of the wrong length", "12345"},
	}
	var messages []string
	for _, tc := range rejected {
		for chainName, ch := range map[string]*w320Chain{"warm chain": w, "cold chain": cw} {
			if chainName == "warm chain" && (tc.id == hidden || tc.id == suspended) {
				continue // the warm chain cached these as visible when it created them; the cold chain proves the rule
			}
			id := tc.id
			_, err := ch.w320Update(p.a, &identityv1.UpdateProfileRequest{PinnedPostId: &id})
			w320Reason(t, tc.name+" on "+chainName, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "pinned_post_id")
			if d := w320Detail(err); d != nil {
				messages = append(messages, d.GetMessage())
			}
		}
	}
	for _, m := range messages[1:] {
		if m != messages[0] {
			t.Errorf("rejection messages differ (an existence oracle): %q vs %q", m, messages[0])
		}
	}
	if got := cw.line(t, rpcUpdateProfile)["pin_check"]; got != "rejected" {
		t.Errorf("pin_check on a refusal = %v, want rejected", got)
	}
	if seen := w.w320Profile(t, p.b, p.a.uid).GetPinnedPostId(); seen != p.reply {
		t.Errorf("refused pins changed the stored pin: %q, want %q", seen, p.reply)
	}

	// "" unpins; the log names the field and carries no pin_check; the stored field is empty.
	got, err := pin("")
	if err != nil || got.GetPinnedPostId() != "" {
		t.Fatalf(`pin "": %v, %v`, got, err)
	}
	line := lastRequestLine(t, e, rpcUpdateProfile)
	if _, has := line["pin_check"]; has || line["profile_fields_changed"] != "pinned_post" {
		t.Errorf(`unpin log: pin_check=%v profile_fields_changed=%v, want no pin_check and "pinned_post"`, line["pin_check"], line["profile_fields_changed"])
	}
	if v := fsDocField(t, e, "users/"+p.a.uid, "pinnedPostId"); v != "" && v != nil {
		t.Errorf("stored pinnedPostId = %v after an unpin", v)
	}
	// Unpinning when nothing is pinned is harmless.
	if got, err := pin(""); err != nil || got.GetPinnedPostId() != "" {
		t.Errorf(`pin "" twice: %v, %v`, got, err)
	}
}

// TestW320_TakedownKeepsThePinRestoreBringsItBack: ADR-0024 D3 "Takedown": a takedown does not unpin (no post_delete job
// runs for it), GetPost answers NOT_FOUND while hidden, and after a restore the same pin is live again with no write to
// the profile in between. A suspended author's post behaves the same.
func TestW320_TakedownKeepsThePinRestoreBringsItBack(t *testing.T) {
	ctx := context.Background()
	e, w := newW320Life(t, nil)
	a, b := w.user(t), w.user(t)
	pid := w.post(t, a, "the pinned post")
	if _, err := w.w320Update(a, &identityv1.UpdateProfileRequest{PinnedPostId: &pid}); err != nil {
		t.Fatal(err)
	}
	e.pull(t) // drain any earlier job messages
	before := fsDocField(t, e, "users/"+a.uid, "updatedAt")

	for _, mod := range []string{"TAKEN_DOWN", "SUSPENDED_AUTHOR"} {
		if _, err := w.fs.Doc("posts/"+pid).Set(ctx, map[string]any{"moderation": mod}, firestore.MergeAll); err != nil {
			t.Fatal(err)
		}
		hiddenView := newW320Chain(t, w320AllW3On) // cold: no cached copy of the visible post
		_, err := hiddenView.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: pid}))
		wireError(t, err, connect.CodeNotFound)
		if got := hiddenView.w320Profile(t, b, a.uid).GetPinnedPostId(); got != pid {
			t.Errorf("%s: pinned_post_id = %q, want the stored pin %q (the client hides the row on GetPost NOT_FOUND)", mod, got, pid)
		}
		if v := fsDocField(t, e, "users/"+a.uid, "pinnedPostId"); v != pid {
			t.Errorf("%s: stored pinnedPostId = %v, want the pin kept (%s)", mod, v, pid)
		}
		if msgs := e.pull(t); len(msgs) != 0 {
			t.Errorf("%s published job messages %v: a takedown is not a delete", mod, msgs)
		}
		// Restore.
		if _, err := w.fs.Doc("posts/"+pid).Set(ctx, map[string]any{"moderation": ""}, firestore.MergeAll); err != nil {
			t.Fatal(err)
		}
		live := newW320Chain(t, w320AllW3On)
		if _, err := live.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: pid})); err != nil {
			t.Errorf("%s: GetPost after the restore: %v", mod, err)
		}
		if got := live.w320Profile(t, b, a.uid).GetPinnedPostId(); got != pid {
			t.Errorf("%s: after the restore pinned_post_id = %q, want %q", mod, got, pid)
		}
	}
	if after := fsDocField(t, e, "users/"+a.uid, "updatedAt"); fmt.Sprint(after) != fmt.Sprint(before) {
		t.Errorf("users/%s updatedAt moved %v -> %v: a takedown and a restore write nothing to the profile", a.uid, before, after)
	}
}

// TestW320_PostDeleteJobClearsThePin: the job's identity step (ADR-0024 D3) clears exactly the deleted post's pin, a
// redelivery is harmless, and it does so while profile_extras is OFF everywhere (D9: "never gated" - otherwise a pin could
// outlive its post after a kill-switch flip). Forged messages change nothing: another user's uid, a different post id, a
// REPOST id, a live pinned post.
func TestW320_PostDeleteJobClearsThePin(t *testing.T) {
	ctx := context.Background()
	e, w := newW320Life(t, nil)
	a, b := w.user(t), w.user(t)
	pinned, other := w.post(t, a, "pinned, will be deleted"), w.post(t, a, "another post")
	bs := w.post(t, b, "b's post")
	if _, err := w.w320Update(a, &identityv1.UpdateProfileRequest{PinnedPostId: &pinned}); err != nil {
		t.Fatal(err)
	}
	if _, err := w.w320Update(b, &identityv1.UpdateProfileRequest{PinnedPostId: &bs}); err != nil {
		t.Fatal(err)
	}
	e.pull(t)

	// A second instance with profile_extras OFF everywhere receives the jobs.
	off := newChain(t, func(c *config.Config) {
		w320Base(c)
		c.FeatureAccountLifecycle = flags.Spec{Name: "account_lifecycle", Mode: flags.On}
		c.JobsTopic, c.ExportBucket = e.cfg.JobsTopic, e.cfg.ExportBucket
		c.FeatureProfileExtras = flags.Spec{Name: "profile_extras", Mode: flags.Off}
	})
	stored := func(uid string) any { return fsDocField(t, e, "users/"+uid, "pinnedPostId") }

	// Forged messages: nothing moves.
	for name, msg := range map[string]map[string]any{
		"live pinned post, right uid":         {"kind": "post_delete", "uid": a.uid, "postId": pinned},
		"another uid, a's pinned post id":     {"kind": "post_delete", "uid": b.uid, "postId": pinned},
		"right uid, a different live post id": {"kind": "post_delete", "uid": a.uid, "postId": other},
		"unknown post id":                     {"kind": "post_delete", "uid": a.uid, "postId": "0000000000000000042"},
	} {
		if code := w320Deliver(t, off.url, msg); code != http.StatusNoContent {
			t.Errorf("%s: delivery = %d, want 204 (an ack, not a retry storm)", name, code)
		}
		if stored(a.uid) != pinned || stored(b.uid) != bs {
			t.Fatalf("%s changed a pin: a=%v b=%v", name, stored(a.uid), stored(b.uid))
		}
	}

	// A real delete of the pinned post, the job delivered to the instance where profile_extras is OFF.
	if _, err := w.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("w320-del"), PostId: pinned})); err != nil {
		t.Fatal(err)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "post_delete" || msgs[0]["postId"] != pinned {
		t.Fatalf("job messages = %v", msgs)
	}
	raw, _ := base64.StdEncoding.DecodeString(msgs[0]["_data"].(string))
	var real map[string]any
	_ = json.Unmarshal(raw, &real)
	for i := 0; i < 2; i++ { // the delivery and a redelivery
		if code := w320Deliver(t, off.url, real); code != http.StatusNoContent {
			t.Fatalf("delivery %d = %d", i, code)
		}
	}
	if v := stored(a.uid); v != "" && v != nil {
		t.Errorf("a's stored pin = %v after its post was deleted (profile_extras off): the clean-up must not be gated", v)
	}
	if stored(b.uid) != bs {
		t.Errorf("b's pin = %v: another user's pin was touched", stored(b.uid))
	}
	// A REPOST delete never has a pin to clear and writes nothing.
	rp, err := w.eng.RepostPost(ctx, authed(a.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("w320-rp"), PostId: bs}))
	if err != nil {
		t.Fatal(err)
	}
	e.pull(t)
	if _, err := w.eng.UndoRepost(ctx, authed(a.token, &engagementv1.UndoRepostRequest{IdempotencyKey: contractKey("w320-urp"), PostId: bs})); err != nil {
		t.Fatalf("UndoRepost(%s): %v", rp.Msg.GetRepostPostId(), err)
	}
	for _, m := range e.pull(t) {
		if code := w320Deliver(t, off.url, map[string]any{"kind": m["kind"], "uid": m["uid"], "postId": m["postId"]}); code != http.StatusNoContent {
			t.Errorf("repost job delivery = %d", code)
		}
	}
	if stored(b.uid) != bs {
		t.Errorf("b's pin = %v after a repost clean-up", stored(b.uid))
	}
}

// TestW320_ExtrasRequestLogNeverCarriesValues: profile_fields_changed lists field NAMES only, pin_check carries the outcome
// only; no log line of the process contains the location text, the website or the banner URL that was written.
func TestW320_ExtrasRequestLogNeverCarriesValues(t *testing.T) {
	e, w := newW320Life(t, nil)
	a := w.user(t)
	banner := e.seedMedia(t, a.uid, media.PurposeBanner)
	pid := w.post(t, a, "pin me")
	const (
		loc  = "Zzyzx w320 Road"
		site = "https://w320-unique-host.example/secret-path"
	)
	got, err := w.w320Update(a, &identityv1.UpdateProfileRequest{BannerMediaId: &banner, Location: w320Str(loc), Website: w320Str(site), PinnedPostId: &pid})
	if err != nil {
		t.Fatal(err)
	}
	line := lastRequestLine(t, e, rpcUpdateProfile)
	if line["profile_fields_changed"] != "banner,location,website,pinned_post" || line["pin_check"] != "ok" {
		t.Errorf("log fields: %v / %v", line["profile_fields_changed"], line["pin_check"])
	}
	for _, secret := range []string{loc, "w320-unique-host", "secret-path", got.GetBannerUrl()} {
		if secret != "" && e.logContains(secret) {
			t.Errorf("the process log contains the value %q", secret)
		}
	}
	// Re-sending the same values changes nothing, so the log names no field (and the cache keeps the profile).
	if _, err := w.w320Update(a, &identityv1.UpdateProfileRequest{Location: w320Str(loc), Website: w320Str(site)}); err != nil {
		t.Fatal(err)
	}
	if v, has := lastRequestLine(t, e, rpcUpdateProfile)["profile_fields_changed"]; has {
		t.Errorf("an unchanged re-send logged profile_fields_changed = %v", v)
	}
}
