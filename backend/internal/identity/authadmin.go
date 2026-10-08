// authadmin.go is the one narrow Firebase Auth admin wrapper (ADR-0011 IAM controls C1-C3). The runtime service
// account holds a custom role that can get, update (disable, revoke) and delete any Firebase Auth user, and IAM
// cannot scope that to one user. So the code confines it:
//
//   - C1: a mutation is only ever made for a uid whose own document, read fresh in this invocation, says it asked
//     for it. A deletionTarget exists only for a users/{uid} that is DELETING with deletionRequestedAt and job
//     state set (DeleteAccount, which acts on the caller's token uid and has no uid field, is the only writer of
//     that state); an exportTarget only for a PENDING exports doc (RequestAccountExport created it for the
//     caller). A message's uid is never trusted. Anything else is refused: no Auth call, ERROR auth_admin_refused.
//   - C1 amendment (M2, 2026-10-08): a signupTarget, built from the verified ID token's own uid only (never from
//     request data), authorizes one read-only `get` of the caller's own Auth record at the CreateProfile boundary,
//     and only when users/{uid} does not exist. It refuses a deleted or disabled Auth user.
//   - C2: this file is the only caller of AuthClient. Its four operations take only those target types, which
//     only this package can construct; no method takes a bare uid string. TestAuthAdminConfinement fails CI if
//     another package outside cmd/opsctl calls the Admin SDK's Auth methods.
//   - C3: one NOTICE line per operation (auth_admin_op, outcome, uid_hash, account_job, seq, actor, trace), never
//     a raw uid, email or provider data.
package identity

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	fbauth "firebase.google.com/go/v4/auth"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// Audit vocabulary (C3).
const (
	authOpDisableRevoke = "disable_revoke"
	authOpDelete        = "delete"
	authOpGet           = "get"

	authOutcomeOK       = "ok"
	authOutcomeNotFound = "not_found"
	authOutcomeError    = "error"
	authOutcomeRefused  = "refused"
	// authOutcomeDisabled: the sign-up check found the Auth user present but disabled (suspended or mid-deletion).
	authOutcomeDisabled = "disabled"

	actorJob = "job"
	// actorCaller is the sign-up check: the authenticated caller's own request, not a job.
	actorCaller = "caller"

	// signupAuthTimeout bounds the one Auth lookup in CreateProfile (CLAUDE.md: every outbound call has a deadline).
	signupAuthTimeout = 3 * time.Second
)

// Sentinels of the sign-up check; the service maps them to Connect codes.
var (
	// errSignupRefused: the caller's Auth user is deleted or disabled, so no profile may be created.
	errSignupRefused = errors.New("identity: sign-up refused: auth user missing or disabled")
	// errSignupUnavailable: the Auth lookup failed (outage, timeout); fail closed, the client may retry.
	errSignupUnavailable = errors.New("identity: sign-up check unavailable")
)

// deletionTarget authorizes disableAndRevoke and deleteUser for one uid. Only newDeletionTarget builds it.
type deletionTarget struct {
	uid string
	seq int64
}

// exportTarget authorizes getUserRecord for one uid. Only newExportTarget builds it.
type exportTarget struct {
	uid string
}

// signupTarget authorizes checkSignup for one uid. Only newSignupTarget builds it, and its only caller passes the
// uid of the verified ID token (service.CreateProfile's uid argument comes from the token, never the request body).
type signupTarget struct {
	uid string
}

// newSignupTarget builds the target for the authenticated caller's own token uid.
func newSignupTarget(tokenUID string) signupTarget { return signupTarget{uid: tokenUID} }

// accountRecord is the part of a Firebase Auth record the export's `account` section carries.
type accountRecord struct {
	Email        string    `json:"email,omitempty"`
	EmailVerify  bool      `json:"emailVerified"`
	Providers    []string  `json:"providers"`
	CreatedAt    time.Time `json:"createdAt,omitzero"`
	LastSignInAt time.Time `json:"lastSignInAt,omitzero"`
}

type authAdmin struct {
	client AuthClient
	log    *slog.Logger
	// notFound classifies "the Firebase Auth user does not exist"; fbauth.IsUserNotFound, replaced in tests (the
	// SDK's error type cannot be built outside the SDK).
	notFound func(error) bool
}

func newAuthAdmin(client AuthClient, log *slog.Logger) *authAdmin {
	return &authAdmin{client: client, log: log, notFound: fbauth.IsUserNotFound}
}

// refuse logs the C1 refusal at ERROR (Error Reporting emails the founder at $0) and returns ErrAuthAdminRefused.
func (a *authAdmin) refuse(ctx context.Context, op, job, why, uid string, seq int64) error {
	err := fmt.Errorf("auth_admin_refused: %w: %s", ErrAuthAdminRefused, why)
	mw.ReportError(ctx, a.log.With(append([]any{
		"auth_admin_op", op, "outcome", authOutcomeRefused, "reason", why,
		"uid_hash", logger.HashUID(uid), "account_job", job, "seq", seq, "actor", actorJob,
	}, logger.TraceAttrs(ctx)...)...), "auth_admin_refused", err)
	return err
}

// deletionTarget applies C1 to a freshly read profile. Zero state on any refusal.
func (a *authAdmin) deletionTarget(ctx context.Context, p Profile, seq int64) (deletionTarget, error) {
	switch {
	case p.UserID == "":
		return deletionTarget{}, a.refuse(ctx, authOpDisableRevoke, "delete", "no uid", "", seq)
	case p.Status != AccountStatusDeleting:
		return deletionTarget{}, a.refuse(ctx, authOpDisableRevoke, "delete", "account is not DELETING", p.UserID, seq)
	case p.DeletionRequestedAt.IsZero() || p.DeletionJob == nil:
		return deletionTarget{}, a.refuse(ctx, authOpDisableRevoke, "delete", "deletion was never requested through DeleteAccount", p.UserID, seq)
	}
	return deletionTarget{uid: p.UserID, seq: seq}, nil
}

// exportTarget applies C1 to a freshly read exports doc: it must be PENDING with a uid.
func (a *authAdmin) exportTarget(ctx context.Context, e ExportDoc) (exportTarget, error) {
	if e.UID == "" || e.Status != ExportPending {
		return exportTarget{}, a.refuse(ctx, authOpGet, "export", "export is not PENDING for a user", e.UID, 0)
	}
	return exportTarget{uid: e.UID}, nil
}

// audit writes the C3 line. job is "delete" or "export".
func (a *authAdmin) audit(ctx context.Context, op, outcome, job, uid string, seq int64) {
	a.log.Log(ctx, logger.LevelNotice, "auth_admin_op", append([]any{
		"auth_admin_op", op, "outcome", outcome, "uid_hash", logger.HashUID(uid),
		"account_job", job, "seq", seq, "actor", actorJob,
	}, logger.TraceAttrs(ctx)...)...)
}

// outcomeOf classifies an Auth call result: a user that is already gone is success for disable and delete.
func (a *authAdmin) outcomeOf(err error) string {
	switch {
	case err == nil:
		return authOutcomeOK
	case a.notFound(err):
		return authOutcomeNotFound
	default:
		return authOutcomeError
	}
}

// disableAndRevoke disables the Firebase Auth user and revokes its refresh tokens (two SDK calls, one audit line).
// A user that no longer exists counts as done. Idempotent; 0 Firestore operations.
func (a *authAdmin) disableAndRevoke(ctx context.Context, t deletionTarget) error {
	disabled := true
	_, err := a.client.UpdateUser(ctx, t.uid, (&fbauth.UserToUpdate{}).Disabled(disabled))
	if err == nil {
		err = a.client.RevokeRefreshTokens(ctx, t.uid)
	}
	outcome := a.outcomeOf(err)
	a.audit(ctx, authOpDisableRevoke, outcome, "delete", t.uid, t.seq)
	if outcome == authOutcomeNotFound {
		return nil
	}
	if err != nil {
		return logger.RedactErr(fmt.Errorf("identity: disable auth user: %w", err), t.uid)
	}
	return nil
}

// deleteUser deletes the Firebase Auth user; one that no longer exists counts as done.
func (a *authAdmin) deleteUser(ctx context.Context, t deletionTarget) error {
	err := a.client.DeleteUser(ctx, t.uid)
	outcome := a.outcomeOf(err)
	a.audit(ctx, authOpDelete, outcome, "delete", t.uid, t.seq)
	if outcome == authOutcomeNotFound {
		return nil
	}
	if err != nil {
		return logger.RedactErr(fmt.Errorf("identity: delete auth user: %w", err), t.uid)
	}
	return nil
}

// getUserRecord reads the export's `account` section. A user that no longer exists yields an empty record.
func (a *authAdmin) getUserRecord(ctx context.Context, t exportTarget) (accountRecord, error) {
	rec, err := a.client.GetUser(ctx, t.uid)
	outcome := a.outcomeOf(err)
	a.audit(ctx, authOpGet, outcome, "export", t.uid, 0)
	if outcome == authOutcomeNotFound {
		return accountRecord{Providers: []string{}}, nil
	}
	if err != nil {
		return accountRecord{}, logger.RedactErr(fmt.Errorf("identity: get auth user: %w", err), t.uid)
	}
	out := accountRecord{Email: rec.Email, EmailVerify: rec.EmailVerified, Providers: []string{}}
	for _, p := range rec.ProviderUserInfo {
		if p != nil {
			out.Providers = append(out.Providers, p.ProviderID)
		}
	}
	if rec.UserMetadata != nil {
		if rec.UserMetadata.CreationTimestamp > 0 {
			out.CreatedAt = time.UnixMilli(rec.UserMetadata.CreationTimestamp).UTC()
		}
		if rec.UserMetadata.LastLogInTimestamp > 0 {
			out.LastSignInAt = time.UnixMilli(rec.UserMetadata.LastLogInTimestamp).UTC()
		}
	}
	return out, nil
}

// checkSignup is the M2 CreateProfile-boundary check (ADR-0011 amendment 2026-10-08): the caller's verified ID token
// can outlive its Auth user (VerifyIDToken does not check revocation or deletion outside the emulator), so before a
// first profile is created the Auth record of the token's own uid must exist and be enabled. 1 Auth read, 0
// Firestore ops. Returns errSignupRefused for a deleted or disabled user and errSignupUnavailable for any other
// failure (fail closed). One C3 NOTICE line per call (op `get`, job `signup`, outcome ok|not_found|disabled|error).
func (a *authAdmin) checkSignup(ctx context.Context, t signupTarget) error {
	if t.uid == "" {
		return a.refuse(ctx, authOpGet, "signup", "no uid", "", 0)
	}
	ctx, cancel := context.WithTimeout(ctx, signupAuthTimeout)
	defer cancel()
	rec, err := a.client.GetUser(ctx, t.uid)
	outcome := a.outcomeOf(err)
	if outcome == authOutcomeOK && (rec == nil || rec.Disabled) {
		outcome = authOutcomeDisabled
	}
	a.log.Log(ctx, logger.LevelNotice, "auth_admin_op", append([]any{
		"auth_admin_op", authOpGet, "outcome", outcome, "uid_hash", logger.HashUID(t.uid),
		"account_job", "signup", "seq", int64(0), "actor", actorCaller,
	}, logger.TraceAttrs(ctx)...)...)
	switch outcome {
	case authOutcomeOK:
		return nil
	case authOutcomeNotFound, authOutcomeDisabled:
		return errSignupRefused
	default:
		return fmt.Errorf("%w: %w", errSignupUnavailable, logger.RedactErr(fmt.Errorf("identity: get auth user for sign-up: %w", err), t.uid))
	}
}
