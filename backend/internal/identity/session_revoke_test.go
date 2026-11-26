package identity

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

// The H1 refresh-token revoke on a session cut: RevokeSessionsAt reads users/{uid} fresh, applies the C1 precondition
// (a cut at or after the one asked) through authAdmin.sessionRevokeTarget, then makes one RevokeRefreshTokens call. One C3
// NOTICE line per call (op revoke_sessions, job session_cut, actor caller), never a raw uid.

const revokeUID = "raw-uid-revoke-31"

type revokeHarness struct {
	svc  *service
	repo *fakeRepo
	auth *fakeAuthClient
	ops  *opLog
	logs *syncBuffer
}

func newRevokeHarness(t *testing.T, withAuth bool) *revokeHarness {
	t.Helper()
	h := &revokeHarness{repo: newFakeRepo(), ops: &opLog{}, logs: &syncBuffer{}}
	h.auth = newFakeAuthClient(h.ops)
	var opts []Option
	if withAuth {
		opts = append(opts, WithSignupAuth(h.auth, slog.New(slog.NewJSONHandler(h.logs, &slog.HandlerOptions{Level: slog.LevelDebug}))))
	}
	h.svc = New(h.repo, NewCache(time.Minute), time.Hour, opts...).(*service)
	if h.svc.sessionAuth != nil {
		h.svc.sessionAuth.notFound = func(err error) bool { return errors.Is(err, errFakeUserNotFound) }
	}
	return h
}

// TestAuthAdmin_SessionRevokeTarget: a target exists only for a profile whose stored cut is at or after the cut asked;
// every other state is an ERROR refusal (actor caller) with no Auth call and the zero target.
func TestAuthAdmin_SessionRevokeTarget(t *testing.T) {
	tests := []struct {
		name   string
		p      Profile
		cut    time.Time
		wantOK bool
	}{
		{"stored cut equals the cut asked", Profile{UserID: "u1", SessionsValidAfter: cutT1}, cutT1, true},
		{"stored cut is later (another removal moved it)", Profile{UserID: "u1", SessionsValidAfter: cutT2}, cutT1, true},
		{"no stored cut", Profile{UserID: "u1"}, cutT1, false},
		{"stored cut is older than the cut asked", Profile{UserID: "u1", SessionsValidAfter: cutT0}, cutT1, false},
		{"no cut asked", Profile{UserID: "u1", SessionsValidAfter: cutT1}, time.Time{}, false},
		{"no uid", Profile{SessionsValidAfter: cutT1}, cutT1, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newRevokeHarness(t, true)
			target, err := h.svc.sessionAuth.sessionRevokeTarget(context.Background(), tt.p, tt.cut)
			if tt.wantOK {
				if err != nil || target.uid != "u1" {
					t.Fatalf("target = %+v, err = %v", target, err)
				}
				return
			}
			if !errors.Is(err, ErrAuthAdminRefused) || target != (sessionRevokeTarget{}) {
				t.Fatalf("err = %v, target = %+v; want a refusal and the zero target", err, target)
			}
			if h.ops.count("auth.") != 0 {
				t.Error("a refusal made an Auth call")
			}
			lines := revokeLines(h.logs)
			if len(lines) != 1 || lines[0]["level"] != "ERROR" || lines[0]["auth_admin_op"] != "revoke_sessions" ||
				lines[0]["account_job"] != "session_cut" || lines[0]["actor"] != "caller" || lines[0]["outcome"] != "refused" {
				t.Errorf("refusal log = %s", h.logs.String())
			}
		})
	}
}

func TestRevokeSessionsAt(t *testing.T) {
	cases := []struct {
		name string
		// stored is the profile's cut (nil profile when noProfile).
		stored    time.Time
		noProfile bool
		cut       time.Time
		setup     func(c *fakeAuthClient)
		wantErr   error // nil = success; errAny = some error
		wantCalls int
		wantOut   string // the C3 line's outcome
	}{
		{name: "a cut on the account: one revoke", stored: cutT1, cut: cutT1, wantCalls: 1, wantOut: "ok"},
		{name: "a later cut on the account still revokes", stored: cutT2, cut: cutT1, wantCalls: 1, wantOut: "ok"},
		{name: "no cut on the account is a C1 refusal", cut: cutT1, wantErr: ErrAuthAdminRefused, wantOut: "refused"},
		{name: "an older cut on the account is a C1 refusal", stored: cutT0, cut: cutT1, wantErr: ErrAuthAdminRefused, wantOut: "refused"},
		{name: "no profile: success with no Auth call", noProfile: true, cut: cutT1, wantOut: "not_found"},
		{name: "the Auth user is gone: success", stored: cutT1, cut: cutT1, setup: func(c *fakeAuthClient) { c.missing = true },
			wantCalls: 1, wantOut: "not_found"},
		{name: "the Auth call fails: an error to retry", stored: cutT1, cut: cutT1,
			setup:   func(c *fakeAuthClient) { c.err["RevokeRefreshTokens"] = errors.New("auth down for " + revokeUID) },
			wantErr: errAny, wantCalls: 1, wantOut: "error"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newRevokeHarness(t, true)
			if !tc.noProfile {
				h.repo.profiles[revokeUID] = Profile{UserID: revokeUID, SessionsValidAfter: tc.stored}
			}
			if tc.setup != nil {
				tc.setup(h.auth)
			}
			err := h.svc.RevokeSessionsAt(context.Background(), revokeUID, tc.cut)
			switch {
			case tc.wantErr == nil && err != nil:
				t.Fatalf("err = %v, want success", err)
			case tc.wantErr == errAny && err == nil, tc.wantErr != nil && tc.wantErr != errAny && !errors.Is(err, tc.wantErr):
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
			if got := h.ops.count("auth.RevokeRefreshTokens"); got != tc.wantCalls || h.ops.count("auth.") != tc.wantCalls {
				t.Errorf("Auth calls = %v, want %d RevokeRefreshTokens and nothing else", h.ops.all(), tc.wantCalls)
			}
			lines := revokeLines(h.logs)
			if len(lines) != 1 {
				t.Fatalf("%d revoke_sessions lines, want exactly 1: %s", len(lines), h.logs.String())
			}
			l := lines[0]
			if l["outcome"] != tc.wantOut || l["actor"] != "caller" || l["account_job"] != "session_cut" || l["uid_hash"] == "" {
				t.Errorf("audit line = %v, want outcome %s", l, tc.wantOut)
			}
			if tc.wantOut != "refused" && l["level"] != "NOTICE" && l["level"] != "INFO+2" {
				t.Errorf("level = %v, want NOTICE", l["level"])
			}
			if strings.Contains(h.logs.String(), revokeUID) {
				t.Errorf("the audit trail carries the raw uid: %s", h.logs.String())
			}
			if err != nil && strings.Contains(err.Error(), revokeUID) {
				t.Errorf("the error carries the raw uid: %v", err)
			}
		})
	}
}

// revokeLines returns every JSON log line of the revoke op (the NOTICE audit line and the ERROR refusal, whose msg carries
// the reason).
func revokeLines(b *syncBuffer) []map[string]any {
	var out []map[string]any
	for _, line := range strings.Split(b.String(), "\n") {
		var m map[string]any
		if line != "" && json.Unmarshal([]byte(line), &m) == nil && m["auth_admin_op"] == authOpRevokeSessions {
			out = append(out, m)
		}
	}
	return out
}

// errAny marks a case that wants some error.
var errAny = errors.New("any error")

// TestRevokeSessionsAt_ReadsFresh: the C1 check reads users/{uid} on every call, never the 60 s cache, so a cut written by
// another instance a moment ago is seen.
func TestRevokeSessionsAt_ReadsFresh(t *testing.T) {
	h := newRevokeHarness(t, true)
	h.repo.profiles[revokeUID] = Profile{UserID: revokeUID}
	if _, err := h.svc.SessionsValidAfter(context.Background(), revokeUID); err != nil { // warms the cache without a cut
		t.Fatal(err)
	}
	h.repo.profiles[revokeUID] = Profile{UserID: revokeUID, SessionsValidAfter: cutT1}
	reads := h.repo.getProfileCalls
	if err := h.svc.RevokeSessionsAt(context.Background(), revokeUID, cutT1); err != nil {
		t.Fatalf("RevokeSessionsAt = %v; a stale cached copy without the cut refused it", err)
	}
	if h.repo.getProfileCalls != reads+1 || h.ops.count("auth.RevokeRefreshTokens") != 1 {
		t.Errorf("reads %d -> %d, revokes %d; want one fresh read and one revoke", reads, h.repo.getProfileCalls, h.ops.count("auth.RevokeRefreshTokens"))
	}
}

// TestRevokeSessionsAt_NotWiredIsAnError: without the Auth wrapper (WithSignupAuth) a revoke is an error, never a silent
// success that would let keys note revokeDone.
func TestRevokeSessionsAt_NotWiredIsAnError(t *testing.T) {
	h := newRevokeHarness(t, false)
	h.repo.profiles[revokeUID] = Profile{UserID: revokeUID, SessionsValidAfter: cutT1}
	if err := h.svc.RevokeSessionsAt(context.Background(), revokeUID, cutT1); err == nil {
		t.Fatal("an unwired revoke succeeded")
	}
}
