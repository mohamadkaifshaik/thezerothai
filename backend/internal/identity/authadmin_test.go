package identity

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	fbauth "firebase.google.com/go/v4/auth"
)

func newAuthAdminHarness(t *testing.T) (*authAdmin, *fakeAuthClient, *syncBuffer, *opLog) {
	t.Helper()
	h := newHarness(t)
	return h.l.auth, h.auth, h.logs, h.log
}

func deleting(uid string) Profile {
	return Profile{UserID: uid, Status: AccountStatusDeleting, DeletionRequestedAt: time.Now(), DeletionJob: &DeletionJob{}}
}

// TestAuthAdmin_C1Targets: a target exists only for a document that says the user asked for the deletion (or
// export); every other state is refused with an ERROR and no Auth call.
func TestAuthAdmin_C1Targets(t *testing.T) {
	tests := []struct {
		name   string
		p      Profile
		wantOK bool
	}{
		{"deleting through DeleteAccount", deleting("u1"), true},
		{"active", Profile{UserID: "u1", Status: AccountStatusActive}, false},
		{"suspended", Profile{UserID: "u1", Status: AccountStatusSuspended}, false},
		{"unspecified status", Profile{UserID: "u1"}, false},
		{"deleting without request time", Profile{UserID: "u1", Status: AccountStatusDeleting, DeletionJob: &DeletionJob{}}, false},
		{"deleting without job state", Profile{UserID: "u1", Status: AccountStatusDeleting, DeletionRequestedAt: time.Now()}, false},
		{"no uid", Profile{Status: AccountStatusDeleting, DeletionRequestedAt: time.Now(), DeletionJob: &DeletionJob{}}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a, _, logs, ops := newAuthAdminHarness(t)
			target, err := a.deletionTarget(context.Background(), tt.p, 4)
			if tt.wantOK {
				if err != nil || target.uid != "u1" || target.seq != 4 {
					t.Fatalf("target = %+v, err = %v", target, err)
				}
				return
			}
			if !errors.Is(err, ErrAuthAdminRefused) || target != (deletionTarget{}) {
				t.Fatalf("err = %v, target = %+v; want a refusal and the zero target", err, target)
			}
			if ops.count("auth.") != 0 {
				t.Error("a refusal made an Auth call")
			}
			out := logs.String()
			if !strings.Contains(out, `"level":"ERROR"`) || !strings.Contains(out, "auth_admin_refused") || !strings.Contains(out, `"outcome":"refused"`) {
				t.Errorf("refusal log = %s", out)
			}
		})
	}
	t.Run("export target needs a PENDING doc with a uid", func(t *testing.T) {
		a, _, _, _ := newAuthAdminHarness(t)
		for _, e := range []ExportDoc{{UID: "u1", Status: ExportReady}, {UID: "u1", Status: ExportFailed}, {Status: ExportPending}} {
			if _, err := a.exportTarget(context.Background(), e); !errors.Is(err, ErrAuthAdminRefused) {
				t.Errorf("export %+v: err = %v, want refusal", e, err)
			}
		}
		if tg, err := a.exportTarget(context.Background(), ExportDoc{UID: "u1", Status: ExportPending}); err != nil || tg.uid != "u1" {
			t.Errorf("pending export: %+v, %v", tg, err)
		}
	})
}

// TestAuthAdmin_C3Audit: exactly one NOTICE line per operation with the documented fields, never a raw uid or
// email, and a refusal-free outcome vocabulary.
func TestAuthAdmin_C3Audit(t *testing.T) {
	const uid = "raw-uid-777"
	const email = "private.person@example.com"
	ctx := context.Background()

	tests := []struct {
		name       string
		run        func(a *authAdmin) error
		setup      func(c *fakeAuthClient)
		wantOp     string
		wantResult string
		wantErr    bool
		wantCalls  []string
	}{
		{"disable ok", func(a *authAdmin) error { return a.disableAndRevoke(ctx, deletionTarget{uid: uid, seq: 2}) }, nil,
			"disable_revoke", "ok", false, []string{"auth.UpdateUser", "auth.RevokeRefreshTokens"}},
		{"disable of a user that is gone", func(a *authAdmin) error { return a.disableAndRevoke(ctx, deletionTarget{uid: uid, seq: 2}) },
			func(c *fakeAuthClient) { c.missing = true }, "disable_revoke", "not_found", false, []string{"auth.UpdateUser"}},
		{"disable fails", func(a *authAdmin) error { return a.disableAndRevoke(ctx, deletionTarget{uid: uid, seq: 2}) },
			func(c *fakeAuthClient) { c.err["UpdateUser"] = errors.New("boom for " + uid) }, "disable_revoke", "error", true, []string{"auth.UpdateUser"}},
		{"revoke fails", func(a *authAdmin) error { return a.disableAndRevoke(ctx, deletionTarget{uid: uid, seq: 2}) },
			func(c *fakeAuthClient) { c.err["RevokeRefreshTokens"] = errors.New("boom") }, "disable_revoke", "error", true, []string{"auth.UpdateUser", "auth.RevokeRefreshTokens"}},
		{"delete ok", func(a *authAdmin) error { return a.deleteUser(ctx, deletionTarget{uid: uid, seq: 3}) }, nil, "delete", "ok", false, []string{"auth.DeleteUser"}},
		{"delete of a user that is gone", func(a *authAdmin) error { return a.deleteUser(ctx, deletionTarget{uid: uid, seq: 3}) },
			func(c *fakeAuthClient) { c.missing = true }, "delete", "not_found", false, []string{"auth.DeleteUser"}},
		{"delete fails", func(a *authAdmin) error { return a.deleteUser(ctx, deletionTarget{uid: uid, seq: 3}) },
			func(c *fakeAuthClient) { c.err["DeleteUser"] = errors.New("boom " + uid) }, "delete", "error", true, []string{"auth.DeleteUser"}},
		{"get ok", func(a *authAdmin) error { _, err := a.getUserRecord(ctx, exportTarget{uid: uid}); return err }, nil, "get", "ok", false, []string{"auth.GetUser"}},
		{"get of a user that is gone", func(a *authAdmin) error { _, err := a.getUserRecord(ctx, exportTarget{uid: uid}); return err },
			func(c *fakeAuthClient) { c.missing = true }, "get", "not_found", false, []string{"auth.GetUser"}},
		{"get fails", func(a *authAdmin) error { _, err := a.getUserRecord(ctx, exportTarget{uid: uid}); return err },
			func(c *fakeAuthClient) { c.err["GetUser"] = errors.New("boom") }, "get", "error", true, []string{"auth.GetUser"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a, auth, logs, ops := newAuthAdminHarness(t)
			auth.users[uid] = &fbauth.UserRecord{UserInfo: &fbauth.UserInfo{UID: uid, Email: email}}
			if tt.setup != nil {
				tt.setup(auth)
			}
			err := tt.run(a)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if got := ops.all(); strings.Join(got, ",") != strings.Join(tt.wantCalls, ",") {
				t.Errorf("SDK calls = %v, want %v", got, tt.wantCalls)
			}
			lines := logs.records("auth_admin_op")
			if len(lines) != 1 {
				t.Fatalf("%d audit lines, want exactly 1: %s", len(lines), logs.String())
			}
			l := lines[0]
			if l["level"] != "NOTICE" && l["level"] != "INFO+2" { // slog's own name for LevelNotice before logger.New renames it
				t.Errorf("level = %v, want NOTICE (INFO+2 before the logger renames it)", l["level"])
			}
			if l["auth_admin_op"] != tt.wantOp || l["outcome"] != tt.wantResult || l["actor"] != "job" || l["uid_hash"] == "" || l["account_job"] == nil {
				t.Errorf("audit line = %v, want op %s outcome %s", l, tt.wantOp, tt.wantResult)
			}
			if all := logs.String(); strings.Contains(all, uid) || strings.Contains(all, email) {
				t.Errorf("the audit trail leaks a raw uid or email: %s", all)
			}
			if err != nil && strings.Contains(err.Error(), uid) {
				t.Errorf("error leaks the raw uid: %v", err)
			}
		})
	}
}

func TestAuthAdmin_AccountRecord(t *testing.T) {
	a, auth, _, _ := newAuthAdminHarness(t)
	auth.users["u1"] = &fbauth.UserRecord{
		UserInfo:         &fbauth.UserInfo{UID: "u1", Email: "a@example.com"},
		EmailVerified:    true,
		ProviderUserInfo: []*fbauth.UserInfo{{ProviderID: "google.com"}, nil, {ProviderID: "password"}},
		UserMetadata:     &fbauth.UserMetadata{CreationTimestamp: 1_700_000_000_000, LastLogInTimestamp: 1_700_000_100_000},
	}
	rec, err := a.getUserRecord(context.Background(), exportTarget{uid: "u1"})
	if err != nil {
		t.Fatal(err)
	}
	if rec.Email != "a@example.com" || !rec.EmailVerify || strings.Join(rec.Providers, ",") != "google.com,password" ||
		!rec.CreatedAt.Equal(time.UnixMilli(1_700_000_000_000)) || !rec.LastSignInAt.Equal(time.UnixMilli(1_700_000_100_000)) {
		t.Errorf("record = %+v", rec)
	}
}

// TestJobs_OneAuditLinePerAuthMutation: through a whole chain, each Auth SDK mutation round has exactly one audit
// line, and no log line anywhere carries the raw uid or the email.
func TestJobs_OneAuditLinePerAuthMutation(t *testing.T) {
	h := newHarness(t)
	h.seedActive("raw-uid-42", "Alice")
	h.auth.users["raw-uid-42"] = &fbauth.UserRecord{UserInfo: &fbauth.UserInfo{UID: "raw-uid-42", Email: "alice.private@example.com"}}
	if _, err := h.l.DeleteAccount(context.Background(), "raw-uid-42", delKey); err != nil {
		t.Fatal(err)
	}
	h.drain(20)

	lines := h.logs.records("auth_admin_op")
	disables, deletes := 0, 0
	for _, l := range lines {
		switch l["auth_admin_op"] {
		case "disable_revoke":
			disables++
		case "delete":
			deletes++
		}
	}
	if disables != h.log.count("auth.UpdateUser") || deletes != h.log.count("auth.DeleteUser") || deletes != 1 || len(lines) != disables+deletes {
		t.Errorf("audit lines: disable_revoke=%d delete=%d total=%d; SDK: UpdateUser=%d DeleteUser=%d", disables, deletes, len(lines), h.log.count("auth.UpdateUser"), h.log.count("auth.DeleteUser"))
	}
	if all := h.logs.String(); strings.Contains(all, "raw-uid-42") || strings.Contains(all, "alice.private@example.com") {
		t.Errorf("a log line carries the raw uid or email:\n%s", all)
	}
}

func TestJobs_DisableFailureRetries(t *testing.T) {
	h := newHarness(t)
	h.seedDeleting("u1", "Alice", 10*time.Second) // inside the gate: only the disable runs
	h.auth.err["UpdateUser"] = errors.New("auth down")
	if code := h.deliver(JobMessage{Kind: JobKindAccountDelete, UID: "u1", Seq: 0}, 1); code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", code)
	}
}
