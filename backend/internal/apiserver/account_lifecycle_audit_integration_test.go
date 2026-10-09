//go:build integration

package apiserver

// Tester audit of the P8 acceptance criteria over the real Build chain (Firestore, Auth, Pub/Sub and Storage
// emulators): wire-level NOT_FOUND bytes, the budgets of replays and polls, degraded mode and the flag, the
// interceptor exemption for every mounted RPC, a resumed job after the Auth user is already gone, concurrent
// deliveries with exact counters, a double-submitted DeleteAccount, and the OIDC wall in front of the job routes.
// Helpers come from account_lifecycle_integration_test.go and posts_restricted_test.go.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// rawRPC posts a Connect JSON unary call and returns the HTTP status and the exact response bytes.
func (e *lifecycleEnv) rawRPC(t *testing.T, token, procedure string, body any) (int, []byte) {
	t.Helper()
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, e.url+procedure, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s: %v", procedure, err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

// pastGate moves deletionRequestedAt back so the 120 s start gate has passed.
func (e *lifecycleEnv) pastGate(t *testing.T, uid string) {
	t.Helper()
	if _, err := e.fs.Doc("users/"+uid).Update(context.Background(), []firestore.Update{{Path: "deletionRequestedAt", Value: time.Now().Add(-5 * time.Minute)}}); err != nil {
		t.Fatal(err)
	}
}

// deleteAuthUser removes uid from the Auth emulator (what the job's final Auth step does, done early).
func (e *lifecycleEnv) deleteAuthUser(t *testing.T, uid string) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"localId": uid})
	url := fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/projects/%s/accounts:delete", os.Getenv("FIREBASE_AUTH_EMULATOR_HOST"), e.cfg.ProjectID)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer owner")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("auth delete: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("auth delete: status %d: %s", resp.StatusCode, raw)
	}
}

func (e *lifecycleEnv) lineNum(t *testing.T, rpc string, i int, field string) float64 {
	t.Helper()
	lines := e.requestLinesFor(rpc)
	if i < 0 {
		i += len(lines)
	}
	if i < 0 || i >= len(lines) {
		t.Fatalf("%s: %d request lines, wanted index %d", rpc, len(lines), i)
	}
	v, _ := lines[i][field].(float64)
	return v
}

func intField(t *testing.T, e *lifecycleEnv, path, field string) int64 {
	t.Helper()
	snap, err := e.fs.Doc(path).Get(context.Background())
	if err != nil {
		t.Fatalf("get %s: %v", path, err)
	}
	v, err := snap.DataAt(field)
	if err != nil {
		t.Fatalf("%s.%s: %v", path, field, err)
	}
	n, _ := v.(int64)
	return n
}

// TestAccountLifecycle_ExportWireContract: budgets of the first request, its replay and the poll, and the Q6
// guarantee on the wire: an unknown id, another user's id, a malformed id and an expired export (document still
// present, TTL lag) produce byte-identical responses.
func TestAccountLifecycle_ExportWireContract(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	a, b := e.newUser(t), e.newUser(t)
	const reqRPC = "/dzeroth.identity.v1.IdentityService/RequestAccountExport"
	const getRPC = "/dzeroth.identity.v1.IdentityService/GetAccountExport"

	first, err := e.identity.RequestAccountExport(ctx, authed(a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "wire-export-key-0001"}))
	if err != nil {
		t.Fatal(err)
	}
	id := first.Msg.GetExportId()
	if e.lineNum(t, reqRPC, 0, "fs_writes") != 2 || e.lineNum(t, reqRPC, 0, "fs_reads") > 3 {
		t.Errorf("first request: %v, want writes 2 and reads <= 3 (interceptor + quotas)", e.requestLinesFor(reqRPC))
	}
	if _, err := e.identity.RequestAccountExport(ctx, authed(a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "wire-export-key-0001"})); err != nil {
		t.Fatalf("replay: %v", err)
	}
	if e.lineNum(t, reqRPC, 1, "fs_writes") != 0 || e.lineNum(t, reqRPC, 1, "fs_reads") > 3 {
		t.Errorf("replay: %v, want writes 0 and reads <= 3 (quotas + exports; the status read is cached)", e.requestLinesFor(reqRPC))
	}

	// The owner's poll while PENDING: 1 fresh read (the interceptor's is cached), no write, no URL.
	got, err := e.identity.GetAccountExport(ctx, authed(a.token, &identityv1.GetAccountExportRequest{ExportId: id}))
	if err != nil || got.Msg.GetStatus() != identityv1.ExportStatus_EXPORT_STATUS_PENDING || got.Msg.GetDownloadUrl() != "" {
		t.Fatalf("owner poll = %v, %v", got, err)
	}
	if e.lineNum(t, getRPC, 0, "fs_writes") != 0 || e.lineNum(t, getRPC, 0, "fs_reads") > 2 {
		t.Errorf("poll: %v, want writes 0 and reads <= 2", e.requestLinesFor(getRPC))
	}

	// Expire a's export while the document is still there.
	expired := first.Msg.GetExportId()
	if _, err := e.fs.Doc("exports/"+expired).Update(ctx, []firestore.Update{{Path: "expireAt", Value: time.Now().Add(-time.Hour)}}); err != nil {
		t.Fatal(err)
	}
	// A second export for b (a different user's id) to ask a for.
	bs, err := e.identity.RequestAccountExport(ctx, authed(b.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "wire-export-key-0002"}))
	if err != nil {
		t.Fatal(err)
	}

	type probe struct {
		name, token, id string
	}
	probes := []probe{
		{"unknown id", a.token, strings.Repeat("ab", 32)},
		{"another user's export", a.token, bs.Msg.GetExportId()},
		{"expired export, document present", a.token, expired},
		{"malformed id", a.token, "not-an-export-id"},
		{"empty id", a.token, ""},
	}
	var want []byte
	for i, p := range probes {
		status, body := e.rawRPC(t, p.token, getRPC, map[string]string{"exportId": p.id})
		if status != http.StatusNotFound {
			t.Errorf("%s: HTTP %d, want 404 (%s)", p.name, status, body)
		}
		if i == 0 {
			want = body
			if !strings.Contains(string(body), `"not_found"`) {
				t.Errorf("%s: body = %s", p.name, body)
			}
			continue
		}
		if !bytes.Equal(body, want) {
			t.Errorf("%s: response differs from the unknown-id response:\n got  %s\n want %s", p.name, body, want)
		}
	}
	// b still sees b's own export (the probe above did not disturb it).
	if _, err := e.identity.GetAccountExport(ctx, authed(b.token, &identityv1.GetAccountExportRequest{ExportId: bs.Msg.GetExportId()})); err != nil {
		t.Errorf("owner of the other export: %v", err)
	}
}

// TestAccountLifecycle_DegradedAndFlagOff: DEGRADED_MODE=readonly rejects DeleteAccount and RequestAccountExport
// (both mutating, Q8) without writing, lets the poll through; and an accepted deletion still completes when the
// instance running the job has the account_lifecycle flag off AND is read-only (Q8, Q9).
func TestAccountLifecycle_DegradedAndFlagOff(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	u, doomed := e.newUser(t), e.newUser(t)

	ro := &lifecycleEnv{chainEnv: newChain(t, func(c *config.Config) {
		c.FeatureAccountLifecycle = flags.Spec{Name: "account_lifecycle", Mode: flags.On}
		c.JobsTopic, c.ExportBucket = e.cfg.JobsTopic, e.cfg.ExportBucket
		c.Degraded = config.DegradedReadonly
	}), cfg: e.cfg}

	_, err := ro.identity.DeleteAccount(ctx, authed(u.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "degraded-delete-key-01"}))
	if d := wireError(t, err, connect.CodeUnavailable); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE {
		t.Errorf("DeleteAccount reason = %v", d.GetReason())
	}
	_, err = ro.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "degraded-export-key-01"}))
	if d := wireError(t, err, connect.CodeUnavailable); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE {
		t.Errorf("RequestAccountExport reason = %v", d.GetReason())
	}
	if _, err := ro.identity.GetAccountExport(ctx, authed(u.token, &identityv1.GetAccountExportRequest{ExportId: strings.Repeat("0", 64)})); err == nil {
		t.Error("an unknown export id answered OK")
	} else {
		wireError(t, err, connect.CodeNotFound) // reached the handler: reads are not degraded
	}
	snap, _ := e.fs.Doc("users/" + u.uid).Get(ctx)
	if st, _ := snap.DataAt("status"); st != "ACTIVE" {
		t.Errorf("a rejected DeleteAccount changed status to %v", st)
	}
	if docs, err := e.fs.Collection("exports").Where("uid", "==", u.uid).Limit(1).Documents(ctx).GetAll(); err != nil || len(docs) != 0 {
		t.Errorf("a rejected RequestAccountExport left an exports doc: %d, %v", len(docs), err)
	}
	if q, err := e.fs.Doc("quotas/" + u.uid).Get(ctx); err == nil {
		if n, derr := q.DataAt("exports"); derr == nil {
			t.Errorf("a rejected RequestAccountExport reserved quota: exports = %v", n)
		}
	}

	// An accepted deletion finishes on an instance that is read-only with the flag off.
	if _, err := e.identity.DeleteAccount(ctx, authed(doomed.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "degraded-delete-key-02"})); err != nil {
		t.Fatal(err)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 {
		t.Fatalf("messages = %v", msgs)
	}
	e.pastGate(t, doomed.uid)
	off := &lifecycleEnv{chainEnv: newChain(t, func(c *config.Config) {
		c.FeatureAccountLifecycle = flags.Spec{Name: "account_lifecycle", Mode: flags.Off}
		c.JobsTopic, c.ExportBucket = e.cfg.JobsTopic, e.cfg.ExportBucket
		c.Degraded = config.DegradedReadonly
	}), cfg: e.cfg}
	if code := off.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery on a read-only, flag-off instance = %d, want 204", code)
	}
	if fsDocExists(t, e.fs, "users/"+doomed.uid) {
		t.Error("the deletion did not finish with the flag off and DEGRADED_MODE=readonly")
	}
	if present, _ := e.authUser(t, doomed.uid); present {
		t.Error("the Firebase Auth user survived")
	}
}

// TestAccountLifecycle_RestrictedCallersOnlyReachDeleteAccount walks every RPC of every service the chain mounts: a
// SUSPENDED or DELETING caller is rejected with ACCOUNT_RESTRICTED everywhere except DeleteAccount (and the two
// pre-profile procedures, which the account-status interceptor skips by design). It guards Build's wiring of
// RestrictedAllowedProcedures against a second exemption sneaking in.
func TestAccountLifecycle_RestrictedCallersOnlyReachDeleteAccount(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)

	var procedures []string
	protoregistry.GlobalFiles.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		if !strings.HasPrefix(string(fd.Package()), "dzeroth.") || strings.HasPrefix(string(fd.Package()), "dzeroth.common") {
			return true
		}
		for i := 0; i < fd.Services().Len(); i++ {
			svc := fd.Services().Get(i)
			for j := 0; j < svc.Methods().Len(); j++ {
				m := svc.Methods().Get(j)
				if !m.IsStreamingClient() && !m.IsStreamingServer() {
					procedures = append(procedures, "/"+string(svc.FullName())+"/"+string(m.Name()))
				}
			}
		}
		return true
	})
	exempt := profileExemptProcedures()
	if len(exempt) != 2 {
		t.Fatalf("the pre-profile exemption set has %d procedures, want exactly CreateProfile and CheckHandleAvailability", len(exempt))
	}

	for _, status := range []string{"SUSPENDED", "DELETING"} {
		t.Run(status, func(t *testing.T) {
			u := e.newUser(t)
			upd := []firestore.Update{{Path: "status", Value: status}}
			if status == "DELETING" {
				upd = append(upd, firestore.Update{Path: "deletionRequestedAt", Value: time.Now()},
					firestore.Update{Path: "deletionJob", Value: map[string]any{"seq": int64(0), "step": "", "progressAt": time.Now()}})
			}
			if _, err := e.fs.Doc("users/"+u.uid).Update(ctx, upd); err != nil {
				t.Fatal(err)
			}
			fresh := &lifecycleEnv{chainEnv: newChainSharing(t, e), cfg: e.cfg} // no cached ACTIVE profile
			mounted, restricted := 0, 0
			for _, p := range procedures {
				if _, ok := exempt[p]; ok || p == identityv1connect.IdentityServiceDeleteAccountProcedure {
					continue
				}
				code, body := fresh.rawRPC(t, u.token, p, map[string]any{})
				if code == http.StatusNotFound && strings.Contains(string(body), "unimplemented") {
					continue // a generated service this build does not mount
				}
				mounted++
				var out struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				}
				_ = json.Unmarshal(body, &out)
				if code != http.StatusForbidden || out.Code != "permission_denied" || out.Message != "account is restricted" {
					t.Errorf("%s as %s: HTTP %d %s, want 403 permission_denied \"account is restricted\"", p, status, code, body)
					continue
				}
				restricted++
			}
			if mounted < 10 {
				t.Fatalf("only %d RPCs were reachable; the walk is not covering the chain (procedures: %v)", mounted, procedures)
			}
			t.Logf("%s: %d of %d mounted RPCs rejected the restricted caller", status, restricted, mounted)

			// DeleteAccount is the one that goes through; it makes the caller DELETING (or replays).
			if _, err := fresh.identity.DeleteAccount(ctx, authed(u.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "restricted-walk-key-" + status})); err != nil {
				t.Errorf("DeleteAccount as %s: %v", status, err)
			}
			snap, _ := e.fs.Doc("users/" + u.uid).Get(ctx)
			if st, _ := snap.DataAt("status"); st != "DELETING" {
				t.Errorf("status after DeleteAccount = %v", st)
			}
		})
	}
}

// reference builds the account the concurrency tests erase: a with 3 followees and 3 followers, and 2 posts.
type referenceAccount struct {
	a         testUser
	followees []testUser
	followers []testUser
}

func (e *lifecycleEnv) reference(t *testing.T) referenceAccount {
	t.Helper()
	r := referenceAccount{a: e.newUser(t)}
	for range 3 {
		f, g := e.newUser(t), e.newUser(t)
		e.follow(t, r.a, f)
		e.follow(t, g, r.a)
		r.followees, r.followers = append(r.followees, f), append(r.followers, g)
	}
	for i := range 2 {
		if _, err := e.posts.CreatePost(context.Background(), authed(r.a.token, &postsv1.CreatePostRequest{IdempotencyKey: fmt.Sprintf("reference-post-key-%04d", i), Text: fmt.Sprintf("post %d", i)})); err != nil {
			t.Fatalf("CreatePost: %v", err)
		}
	}
	return r
}

// requireErased checks the end state of a reference deletion: nothing of a's remains and every counterpart's counter
// is exactly right (0), never double-decremented.
func (e *lifecycleEnv) requireErased(t *testing.T, r referenceAccount) {
	t.Helper()
	ctx := context.Background()
	for _, path := range []string{"users/" + r.a.uid, "graph/" + r.a.uid, "quotas/" + r.a.uid} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived", path)
		}
	}
	if present, _ := e.authUser(t, r.a.uid); present {
		t.Error("the Firebase Auth user survived")
	}
	for _, q := range []struct{ col, field string }{{"posts", "authorId"}, {"follows", "followerId"}, {"follows", "followeeId"}, {"handles", "uid"}} {
		docs, err := e.fs.Collection(q.col).Where(q.field, "==", r.a.uid).Limit(5).Documents(ctx).GetAll()
		if err != nil || len(docs) != 0 {
			t.Errorf("%s.%s == deleted uid: %d docs, err %v", q.col, q.field, len(docs), err)
		}
	}
	for i, f := range r.followees {
		if got := intField(t, e, "users/"+f.uid, "followersCount"); got != 0 {
			t.Errorf("followee %d followersCount = %d, want exactly 0 (a double decrement or a missed one)", i, got)
		}
	}
	for i, g := range r.followers {
		if got := intField(t, e, "users/"+g.uid, "followingCount"); got != 0 {
			t.Errorf("follower %d followingCount = %d, want exactly 0", i, got)
		}
		snap, _ := e.fs.Doc("graph/" + g.uid).Get(ctx)
		if following, _ := snap.DataAt("following"); following != nil {
			for _, u := range following.([]any) {
				if u == r.a.uid {
					t.Errorf("follower %d still lists the deleted user in following[]", i)
				}
			}
		}
	}
}

// TestAccountLifecycle_AuthUserAlreadyGone (T7: "Given the Auth user is already deleted, then both Auth steps report
// done", plus the crash-after-Auth-delete resume): the real Admin SDK's not-found classification against the Auth
// emulator, then the rest of the job finishes.
func TestAccountLifecycle_AuthUserAlreadyGone(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	r := e.reference(t)

	if _, err := e.identity.DeleteAccount(ctx, authed(r.a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "gone-delete-key-0001"})); err != nil {
		t.Fatal(err)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 {
		t.Fatalf("messages = %v", msgs)
	}
	e.deleteAuthUser(t, r.a.uid) // a previous attempt got as far as the final Auth step, then died
	e.pastGate(t, r.a.uid)

	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery with the Auth user already gone = %d, want 204", code)
	}
	e.requireErased(t, r)
	if rest := e.pull(t); len(rest) != 0 {
		t.Errorf("a finished job published %v", rest)
	}
	for _, l := range e.jobLines() {
		if l["outcome"] == "error" {
			t.Errorf("an Auth NotFound was treated as an error: %v", l)
		}
	}
}

// TestAccountLifecycle_ConcurrentDeliveries (T8: "two concurrent deliveries of the same message, then the final state
// is complete and the counters are exact"): four deliveries of the same message race over the real Erasers; each
// round must end erased with every counter exactly 0. A 500 is allowed (Pub/Sub redelivers it), a hang or a wrong
// counter is not.
func TestAccountLifecycle_ConcurrentDeliveries(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	const rounds, racers = 3, 4
	for round := range rounds {
		r := e.reference(t)
		if _, err := e.identity.DeleteAccount(ctx, authed(r.a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: fmt.Sprintf("race-delete-key-%04d", round)})); err != nil {
			t.Fatal(err)
		}
		msgs := e.pull(t)
		if len(msgs) != 1 {
			t.Fatalf("round %d: messages = %v", round, msgs)
		}
		e.pastGate(t, r.a.uid)

		codes := make([]int, racers)
		var wg sync.WaitGroup
		start := make(chan struct{})
		for i := range racers {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				codes[i] = e.deliver(t, msgs[0])
			}()
		}
		close(start)
		wg.Wait()
		redeliveries := 0
		for i, c := range codes {
			for c != http.StatusNoContent && redeliveries < 6 { // what Pub/Sub does with a non-2xx
				redeliveries++
				c = e.deliver(t, msgs[0])
			}
			if c != http.StatusNoContent {
				t.Errorf("round %d racer %d never reached 204 (last %d)", round, i, c)
			}
		}
		t.Logf("round %d: first codes %v, %d redeliveries", round, codes, redeliveries)
		e.requireErased(t, r)
	}
}

// TestAccountLifecycle_ConcurrentDeleteAccount: a double-submit (a retry storm after a lost response) of
// DeleteAccount, with different and equal idempotency keys, commits exactly one write and every caller sees the
// same deletion_requested_at.
func TestAccountLifecycle_ConcurrentDeleteAccount(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	u := e.newUser(t)
	keys := []string{"storm-delete-key-0001", "storm-delete-key-0001", "storm-delete-key-0002", "storm-delete-key-0003", "storm-delete-key-0002", "storm-delete-key-0004"}
	times := make([]time.Time, len(keys))
	errs := make([]error, len(keys))
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i, k := range keys {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			resp, err := e.identity.DeleteAccount(ctx, authed(u.token, &identityv1.DeleteAccountRequest{IdempotencyKey: k}))
			if err == nil {
				times[i] = resp.Msg.GetDeletionRequestedAt().AsTime()
			}
			errs[i] = err
		}()
	}
	close(start)
	wg.Wait()
	for i := range keys {
		if errs[i] != nil {
			t.Fatalf("call %d: %v", i, errs[i])
		}
		if !times[i].Equal(times[0]) {
			t.Errorf("call %d deletion_requested_at = %v, call 0 = %v", i, times[i], times[0])
		}
	}
	var writes float64
	for _, l := range e.requestLinesFor("/dzeroth.identity.v1.IdentityService/DeleteAccount") {
		w, _ := l["fs_writes"].(float64)
		writes += w
	}
	if writes != 1 {
		t.Errorf("total fs_writes over %d concurrent DeleteAccount calls = %v, want exactly 1", len(keys), writes)
	}
	for _, m := range e.pull(t) {
		if m["kind"] != "account_delete" || m["uid"] != u.uid || m["seq"] != float64(0) {
			t.Errorf("unexpected job message %v", m)
		}
	}
}

// TestAccountLifecycle_JobRoutesNeedOIDC (T8: "Given a delivery without a valid OIDC token, then 401 and 0 reads"):
// with the verifier configured, neither job route does anything for an unauthenticated or garbage-token caller, even
// when the body is a perfectly valid message for a user who is past the start gate.
func TestAccountLifecycle_JobRoutesNeedOIDC(t *testing.T) {
	ctx := context.Background()
	open := newLifecycleEnv(t)
	u := open.newUser(t)
	if _, err := open.identity.DeleteAccount(ctx, authed(u.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "oidc-delete-key-0001"})); err != nil {
		t.Fatal(err)
	}
	msgs := open.pull(t)
	open.pastGate(t, u.uid)

	walled := &lifecycleEnv{chainEnv: newChain(t, func(c *config.Config) {
		c.FeatureAccountLifecycle = flags.Spec{Name: "account_lifecycle", Mode: flags.On}
		c.JobsTopic, c.ExportBucket = open.cfg.JobsTopic, open.cfg.ExportBucket
		c.InternalOIDCAudience = "https://api.example.test"
		c.InternalOIDCAllowedEmails = []string{"pubsub-push@demo.iam.gserviceaccount.com"}
	}), cfg: open.cfg}

	body, _ := json.Marshal(map[string]any{"message": map[string]any{"data": msgs[0]["_data"], "messageId": "1"}, "subscription": "s", "deliveryAttempt": 1})
	for _, path := range []string{"/internal/pubsub/jobs", "/api/internal/pubsub/jobs", "/internal/cron/daily-maintenance", "/api/internal/cron/daily-maintenance"} {
		for name, auth := range map[string]string{"no header": "", "garbage bearer": "Bearer not.a.jwt", "an Auth emulator ID token": "Bearer " + u.token} {
			req, _ := http.NewRequest(http.MethodPost, walled.url+path, bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			if auth != "" {
				req.Header.Set("Authorization", auth)
			}
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			if resp.StatusCode != http.StatusUnauthorized {
				t.Errorf("POST %s with %s = %d, want 401", path, name, resp.StatusCode)
			}
		}
	}
	if !fsDocExists(t, open.fs, "users/"+u.uid) {
		t.Fatal("an unauthenticated job request erased the user")
	}
	if present, disabled := open.authUser(t, u.uid); !present || disabled {
		t.Errorf("an unauthenticated job request touched the Auth user: present=%v disabled=%v", present, disabled)
	}
	if lines := walled.jobLines(); len(lines) != 0 {
		t.Errorf("a rejected request reached the handler: %v", lines)
	}
}
