//go:build integration

package apiserver

// T17: export privacy and access over the real Build chain (Firestore, Auth, Storage and Pub/Sub emulators).
//   - TestAccountLifecycle_ExportContentsGolden: the whole export of an account with relationships to six other
//     accounts, uids/handles/emails/ids/times normalized, compared with testdata/account_export_golden.json; plus the
//     privacy greps (ADR-0008 D12: who blocked the subject is never listed; no third party's email, muted[] or
//     blocked[] data, no internal field).
//   - TestAccountLifecycle_ExportQuotaRollover: the daily exports quota resets at the IST day boundary.
//   - TestAccountLifecycle_ExportWhileDeleting: an export that is still PENDING when the deletion starts is FAILED
//     with no object; a DELETING caller can neither request nor poll one.
//   - TestAccountLifecycle_FlagOffRPCs: with account_lifecycle off, all three RPCs answer FEATURE_DISABLED with 0 reads
//     and 0 writes.
// Run `go test -tags=integration ./internal/apiserver -run ExportContentsGolden -update-golden` to rewrite the golden.

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/account_export_golden.json")

// emailUser is newUser with a password-provider account whose email is verified (CreateProfile requires it), so the
// Auth record, and with it the export's account section, has an email. The Auth emulator hands out unverified
// accounts, so the test verifies the address through the admin API and signs in again for a token that carries the
// claim.
func (e *lifecycleEnv) emailUser(t *testing.T) (testUser, string) {
	t.Helper()
	email := fmt.Sprintf("t17-%d@example.test", rand.Int63())
	_, uid := mintToken(t, email)
	post := func(url string, body map[string]any, auth bool) []byte {
		raw, _ := json.Marshal(body)
		req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		if auth {
			req.Header.Set("Authorization", "Bearer owner")
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		out, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("%s: status %d: %s", url, resp.StatusCode, out)
		}
		return out
	}
	host := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	post(fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/projects/%s/accounts:update", host, e.cfg.ProjectID), map[string]any{"localId": uid, "emailVerified": true}, true)
	out := post(fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake-api-key", host), map[string]any{"email": email, "password": "correct horse battery staple", "returnSecureToken": true}, false)
	var signedIn struct {
		IDToken string `json:"idToken"`
	}
	if err := json.Unmarshal(out, &signedIn); err != nil || signedIn.IDToken == "" {
		t.Fatalf("sign in: %v: %s", err, out)
	}
	e.createProfile(t, signedIn.IDToken)
	return testUser{signedIn.IDToken, uid}, email
}

func (e *lifecycleEnv) profileOf(t *testing.T, u testUser) (handle, displayName string) {
	t.Helper()
	me, err := e.identity.GetMe(context.Background(), authed(u.token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	return me.Msg.GetProfile().GetHandle(), me.Msg.GetProfile().GetDisplayName()
}

// exportOf requests an export for u, runs the job and returns the object bytes.
func (e *lifecycleEnv) exportOf(t *testing.T, u testUser, key string) (id string, raw []byte) {
	t.Helper()
	ctx := context.Background()
	exp, err := e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: key}))
	if err != nil {
		t.Fatalf("RequestAccountExport: %v", err)
	}
	id = exp.Msg.GetExportId()
	for _, m := range e.pull(t) {
		if m["kind"] == "account_export" && m["exportId"] == id {
			if code := e.deliver(t, m); code != http.StatusNoContent {
				t.Fatalf("export delivery = %d", code)
			}
		}
	}
	rd, err := e.bucket.Object(id + ".json").NewReader(ctx)
	if err != nil {
		t.Fatalf("export object: %v", err)
	}
	defer rd.Close()
	raw, _ = io.ReadAll(rd)
	return id, raw
}

// normalizeExport replaces every value that varies between runs with a stable placeholder: known uids, handles and
// emails by the role of their owner, post ids by their position, every timestamp by "<time>".
func normalizeExport(t *testing.T, raw []byte, repl map[string]string) []byte {
	t.Helper()
	var doc any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("export is not valid JSON: %v\n%s", err, raw)
	}
	rfc3339 := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}`)
	var walk func(parent string, v any) any
	walk = func(parent string, v any) any {
		switch v := v.(type) {
		case map[string]any:
			for k, x := range v {
				if k == "id" && parent == "posts" {
					v[k] = "<post-id>"
					continue
				}
				v[k] = walk(k, x)
			}
			return v
		case []any:
			for i, x := range v {
				v[i] = walk(parent, x)
			}
			return v
		case string:
			if rfc3339.MatchString(v) {
				return "<time>"
			}
			s := v
			for from, to := range repl {
				s = strings.ReplaceAll(s, from, to)
			}
			return s
		}
		return v
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false) // keep the <uid:A> placeholders readable
	enc.SetIndent("", "  ")
	if err := enc.Encode(walk("", doc)); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestAccountLifecycle_ExportContentsGolden(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, relaxLimits)

	a, aEmail := e.emailUser(t)
	f, fEmail := e.emailUser(t) // A follows f
	g, _ := e.emailUser(t)      // g follows A
	x, xEmail := e.emailUser(t) // A blocks x
	y, yEmail := e.emailUser(t) // y blocks A: the blockedBy case
	z, zEmail := e.emailUser(t) // A mutes z
	w, wEmail := e.emailUser(t) // a stranger who blocks and mutes others
	v, _ := e.emailUser(t)

	key := func(s string) string { return "t17-" + s + "-" + a.uid[:10] }
	must := func(what string, err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}
	e.follow(t, a, f)
	e.follow(t, g, a)
	_, err := e.graph.Block(ctx, authed(a.token, &graphv1.BlockRequest{IdempotencyKey: key("blk-x"), UserId: x.uid}))
	must("A blocks x", err)
	_, err = e.graph.Block(ctx, authed(y.token, &graphv1.BlockRequest{IdempotencyKey: key("blk-y"), UserId: a.uid}))
	must("y blocks A", err)
	_, err = e.graph.Mute(ctx, authed(a.token, &graphv1.MuteRequest{IdempotencyKey: key("mute-z"), UserId: z.uid}))
	must("A mutes z", err)
	_, err = e.graph.Block(ctx, authed(w.token, &graphv1.BlockRequest{IdempotencyKey: key("blk-v"), UserId: v.uid}))
	must("w blocks v", err)
	_, err = e.graph.Mute(ctx, authed(w.token, &graphv1.MuteRequest{IdempotencyKey: key("mute-f"), UserId: f.uid}))
	must("w mutes f", err)

	fHandle, _ := e.profileOf(t, f)
	for i, text := range []string{
		"plain ascii post #golden",
		"unicode ünïcödé 日本語 \U0001F600 emoji and RTL שלום مرحبا",
		"hello @" + fHandle + " from A",
	} {
		_, err = e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: fmt.Sprintf("%s-%d", key("post"), i), Text: text}))
		must("CreatePost", err)
		time.Sleep(2 * time.Millisecond) // distinct createdAt, so the newest-first order is stable
	}

	_, raw := e.exportOf(t, a, key("export"))

	// --- who is who ---
	repl := map[string]string{}
	role := func(name string, u testUser, email string) {
		h, d := e.profileOf(t, u)
		repl[u.uid], repl[h], repl[email] = "<uid:"+name+">", "<handle:"+name+">", "<email:"+name+">"
		_ = d
	}
	role("A", a, aEmail)
	role("f", f, fEmail)
	role("g", g, "g-has-no-email-in-the-export")
	role("x", x, xEmail)
	role("z", z, zEmail)
	golden := normalizeExport(t, raw, repl)

	path := filepath.Join("testdata", "account_export_golden.json")
	if *updateGolden {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, golden, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("golden missing (run with -update-golden): %v", err)
	}
	if strings.ReplaceAll(string(want), "\r\n", "\n") != string(golden) {
		t.Errorf("export differs from %s.\n--- got\n%s\n--- want\n%s", path, golden, want)
	}

	// --- privacy greps over the RAW bytes (not the normalized form) ---
	yHandle, _ := e.profileOf(t, y)
	wHandle, _ := e.profileOf(t, w)
	vHandle, _ := e.profileOf(t, v)
	for _, leak := range []struct{ what, needle string }{
		{"the uid of the user who blocked the subject (ADR-0008 D12)", y.uid},
		{"the handle of the user who blocked the subject", yHandle},
		{"the email of the user who blocked the subject", yEmail},
		{"the uid of an unrelated user who blocks others", w.uid},
		{"the handle of an unrelated user", wHandle},
		{"an unrelated user's email", wEmail},
		{"the uid of someone the stranger blocks", v.uid},
		{"the handle of someone the stranger blocks", vHandle},
		{"the email of a followed user", fEmail},
		{"the email of a blocked user", xEmail},
		{"the email of a muted user", zEmail},
		{"the key blockedBy", `"blockedBy"`},
		{"an internal status field", `"status"`},
		{"snapshotVersion", `"snapshotVersion"`},
		{"deletionJob", `"deletionJob"`},
		{"handleLower", `"handleLower"`},
		{"a password hash", `"passwordHash"`},
		{"a password salt", `"passwordSalt"`},
	} {
		if strings.Contains(string(raw), leak.needle) {
			t.Errorf("the export contains %s (%q)", leak.what, leak.needle)
		}
	}
	// The subject's OWN relationships are in it: the blocked and muted users by uid and handle.
	var doc struct {
		Graph struct {
			Blocked   []map[string]any `json:"blocked"`
			Muted     []map[string]any `json:"muted"`
			Following []map[string]any `json:"following"`
			Followers []map[string]any `json:"followers"`
		} `json:"graph"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Graph.Blocked) != 1 || doc.Graph.Blocked[0]["userId"] != x.uid ||
		len(doc.Graph.Muted) != 1 || doc.Graph.Muted[0]["userId"] != z.uid ||
		len(doc.Graph.Following) != 1 || len(doc.Graph.Followers) != 1 {
		t.Errorf("the subject's own graph is wrong: %+v", doc.Graph)
	}
}

// TestAccountLifecycle_ExportQuotaRollover: one export per IST day. The server reads the real clock, so a stale
// `day` on quotas/{uid} stands in for yesterday; the exact IST boundary is quota's own unit test (TestTodayAt_ISTBoundary).
func TestAccountLifecycle_ExportQuotaRollover(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	u := e.newUser(t)
	req := func(k string) (*connect.Response[identityv1.RequestAccountExportResponse], error) {
		return e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: k}))
	}
	first, err := req("rollover-export-key-0001")
	if err != nil {
		t.Fatal(err)
	}
	_, err = req("rollover-export-key-0002")
	d := wireError(t, err, connect.CodeResourceExhausted)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED {
		t.Fatalf("second export the same day: %v", d)
	}
	if ra := d.GetRetryAfter().AsDuration(); ra <= 0 || ra > 24*time.Hour {
		t.Errorf("retry_after = %v, want (0, 24h] (to the next IST midnight)", ra)
	}
	// Midnight passes: yesterday's counter no longer counts.
	yesterday := quota.TodayAt(time.Now().Add(-24 * time.Hour))
	if _, err := e.fs.Doc("quotas/"+u.uid).Update(ctx, []firestore.Update{{Path: "day", Value: yesterday}}); err != nil {
		t.Fatal(err)
	}
	third, err := req("rollover-export-key-0003")
	if err != nil {
		t.Fatalf("export on the next IST day: %v", err)
	}
	if third.Msg.GetExportId() == first.Msg.GetExportId() {
		t.Error("the next day's export reused the previous export id")
	}
	snap, _ := e.fs.Doc("quotas/" + u.uid).Get(ctx)
	if day, _ := snap.DataAt("day"); day != quota.Today() {
		t.Errorf("quotas.day = %v after the rollover, want %s", day, quota.Today())
	}
	if n, _ := snap.DataAt("exports"); n != int64(1) {
		t.Errorf("quotas.exports = %v after the rollover, want 1 (reset, not accumulated)", n)
	}
	_, err = req("rollover-export-key-0004")
	wireError(t, err, connect.CodeResourceExhausted)
}

// TestAccountLifecycle_ExportWhileDeleting: DeleteAccount arrives while an export is PENDING. The export job refuses
// to compose (FAILED, no object, no Auth call that reveals anything), a DELETING caller can no longer request or poll
// an export (ACCOUNT_RESTRICTED, 0 writes), and the deletion still erases the failed export doc.
func TestAccountLifecycle_ExportWhileDeleting(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	a := e.newUser(t)
	exp, err := e.identity.RequestAccountExport(ctx, authed(a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "while-deleting-export-01"}))
	if err != nil {
		t.Fatal(err)
	}
	exportMsgs := e.pull(t)
	if _, err := e.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "while-deleting-delete-001"})); err != nil {
		t.Fatal(err)
	}
	deleteMsgs := e.pull(t)

	for _, m := range exportMsgs {
		if code := e.deliver(t, m); code != http.StatusNoContent {
			t.Fatalf("export delivery while DELETING = %d, want 204 (acked, not retried forever)", code)
		}
	}
	snap, err := e.fs.Doc("exports/" + exp.Msg.GetExportId()).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st, _ := snap.DataAt("status"); st != "FAILED" {
		t.Errorf("export status = %v, want FAILED", st)
	}
	if _, err := e.bucket.Object(exp.Msg.GetExportId() + ".json").Attrs(ctx); err == nil {
		t.Error("an object exists for an export of a DELETING account")
	}

	_, err = e.identity.RequestAccountExport(ctx, authed(a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "while-deleting-export-02"}))
	if d := wireError(t, err, connect.CodePermissionDenied); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_ACCOUNT_RESTRICTED {
		t.Errorf("RequestAccountExport while DELETING: reason %v", d.GetReason())
	}
	_, err = e.identity.GetAccountExport(ctx, authed(a.token, &identityv1.GetAccountExportRequest{ExportId: exp.Msg.GetExportId()}))
	if d := wireError(t, err, connect.CodePermissionDenied); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_ACCOUNT_RESTRICTED {
		t.Errorf("GetAccountExport while DELETING: reason %v", d.GetReason())
	}
	if docs, err := e.fs.Collection("exports").Where("uid", "==", a.uid).Limit(5).Documents(ctx).GetAll(); err != nil || len(docs) != 1 {
		t.Errorf("exports docs for the account = %d (%v), want only the FAILED one", len(docs), err)
	}

	e.pastGate(t, a.uid)
	for _, m := range deleteMsgs {
		for code := 0; code != http.StatusNoContent; {
			code = e.deliver(t, m)
		}
	}
	if fsDocExists(t, e.fs, "exports/"+exp.Msg.GetExportId()) || fsDocExists(t, e.fs, "users/"+a.uid) {
		t.Error("the deletion left the export doc or the user doc")
	}
	e.requireNoResidue(t, a.uid)
}

// TestAccountLifecycle_FlagOffRPCs: with the account_lifecycle flag off, the three RPCs answer FEATURE_DISABLED before
// any Firestore access, and nothing is written.
func TestAccountLifecycle_FlagOffRPCs(t *testing.T) {
	ctx := context.Background()
	on := newLifecycleEnv(t)
	u := on.newUser(t)
	off := &lifecycleEnv{chainEnv: newChain(t, func(c *config.Config) {
		c.FeatureAccountLifecycle = flags.Spec{Name: "account_lifecycle", Mode: flags.Off}
		c.JobsTopic, c.ExportBucket = on.cfg.JobsTopic, on.cfg.ExportBucket
	}), cfg: on.cfg}

	const svc = "/dzeroth.identity.v1.IdentityService/"
	calls := map[string]func() error{
		"DeleteAccount": func() error {
			_, err := off.identity.DeleteAccount(ctx, authed(u.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "flag-off-delete-key-001"}))
			return err
		},
		"RequestAccountExport": func() error {
			_, err := off.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "flag-off-export-key-001"}))
			return err
		},
		"GetAccountExport": func() error {
			_, err := off.identity.GetAccountExport(ctx, authed(u.token, &identityv1.GetAccountExportRequest{ExportId: strings.Repeat("0", 64)}))
			return err
		},
	}
	for name, call := range calls {
		d := wireError(t, call(), connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
			t.Errorf("%s with the flag off: reason %v", name, d.GetReason())
		}
		lines := off.requestLinesFor(svc + name)
		if len(lines) != 1 || lines[0]["fs_writes"].(float64) != 0 {
			t.Errorf("%s with the flag off: request lines %v, want 1 line and 0 writes", name, lines)
		}
	}
	snap, _ := on.fs.Doc("users/" + u.uid).Get(ctx)
	if st, _ := snap.DataAt("status"); st != "ACTIVE" {
		t.Errorf("a flagged-off DeleteAccount changed status to %v", st)
	}
}
