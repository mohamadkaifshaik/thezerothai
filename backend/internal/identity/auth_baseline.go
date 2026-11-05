// auth_baseline.go is the warn-only sign-in identity audit. At sign-up CreateProfile stores, on users/{uid}, a hash of
// each FEDERATED subject id (google.com, apple.com) the caller's Firebase Auth record held then. With
// AUTH_IDENTITY_AUDIT on, GetMe compares the verified token against it and logs a WARN when the federated identity that
// signed in is not one the account started with. That is the trace of a stolen ID token being used to link an
// attacker's federated identity to the uid.
//
// Only federated subjects are baselined. The password provider's "subject" is the email itself and anonymous ids are
// ephemeral, so neither is stored or compared — keeping any form of the email, hashed or not, out of the users document
// (PII lives in Firebase Auth). Federated subject ids are opaque, high-entropy provider account ids.
//
// It is detection only: nothing here rejects, blocks or alters a response, and nothing here reads anything (the
// baseline is written from the Auth record checkSignup already fetched, and read back from the profile GetMe already
// loads).
//
// Caveats before the flag is ever turned on, because this project auto-links by email:
//   - A legitimate same-email link adds a federated subject the baseline has never seen, which is indistinguishable
//     here from the attack, so it WARNs. This covers a password account that later signs in with Google at the same
//     address AND a provider switch at the same email (e.g. a Google account that later adds Apple) — tune the alert
//     for both. The audit runs on every GetMe, cache hit included, so one genuinely-linked account warns on every
//     home load, not once per sign-in; size the de-dup / baseline-refresh work accordingly.
//   - Intentionally out of scope now that no email is baselined: a takeover that ends in a password sign-in (an
//     attacker adds a password provider, or changes the email). The audit skips non-federated sign-ins, so it cannot
//     see these; the earlier email-continuity version could. The PII tradeoff (no email at rest) is why.
//
// So this needs a de-dup / baseline-refresh design and a log-based alert before enabling; until then it is an
// off-by-default scaffold.
package identity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"

	fbauth "firebase.google.com/go/v4/auth"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// AuthBaseline is users/{uid}.authBaseline. Subjects holds SHA-256 hex digests of federated subject ids; raw ids are
// never stored, and no email (hashed or otherwise) is stored. The hashes are only ever compared and, truncated, logged.
type AuthBaseline struct {
	// Subjects maps a federated provider id ("google.com", "apple.com") to the hashes of its subject ids.
	Subjects map[string][]string `firestore:"subjects,omitempty" json:"s,omitempty"`
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// isFederatedProvider reports whether a provider id is one whose subject is an opaque, high-entropy account id (so it is
// safe to baseline). The password provider's subject is the email and anonymous ids are ephemeral: both are excluded.
func isFederatedProvider(provider string) bool {
	return provider == authn.SignInProviderGoogle || provider == authn.SignInProviderApple
}

// baselineFromRecord builds the baseline from the Auth record checkSignup already holds. Never nil for a non-nil
// record, so a password-only account still has a (subject-less) baseline, and a federated identity linked later is then
// unknown.
func baselineFromRecord(rec *fbauth.UserRecord) *AuthBaseline {
	b := &AuthBaseline{}
	if rec == nil {
		return b
	}
	for _, p := range rec.ProviderUserInfo {
		if p == nil || !isFederatedProvider(p.ProviderID) || p.UID == "" {
			continue
		}
		if b.Subjects == nil {
			b.Subjects = map[string][]string{}
		}
		b.Subjects[p.ProviderID] = append(b.Subjects[p.ProviderID], sha256Hex(p.UID))
	}
	return b
}

// encodeAuthBaseline keeps Profile comparable (UpdateProfile detects a no-op with ==), like HomeTabsEnc.
func encodeAuthBaseline(b *AuthBaseline) string {
	if b == nil {
		return ""
	}
	out, err := json.Marshal(b)
	if err != nil {
		return ""
	}
	return string(out)
}

func decodeAuthBaseline(enc string) *AuthBaseline {
	if enc == "" {
		return nil
	}
	var b AuthBaseline
	if err := json.Unmarshal([]byte(enc), &b); err != nil {
		return nil
	}
	return &b
}

// WithAuthIdentityAudit turns the GetMe identity audit on (AUTH_IDENTITY_AUDIT). Off by default, and then the
// comparison does not run at all. log receives the WARN; nil means slog.Default.
func WithAuthIdentityAudit(on bool, log *slog.Logger) Option {
	return func(s *service) { s.authAudit, s.authAuditLog = on, log }
}

// auditAuthIdentity compares the caller's verified token with the baseline of the profile GetMe already holds and logs
// one WARN auth_identity_unrecognized when a federated sign-in's subject is not in the baseline for its provider. It has
// no return value on purpose: it cannot fail or influence GetMe. 0 reads. A non-federated sign-in (password, anonymous)
// is not audited, because its subject is not baselined.
func (s *service) auditAuthIdentity(ctx context.Context, p Profile) {
	if !s.authAudit {
		return
	}
	claims, ok := authn.ClaimsFromContext(ctx)
	if !ok || claims.UID != p.UserID || !isFederatedProvider(claims.SignInProvider) {
		return
	}
	log := orDefault(s.authAuditLog)
	base := decodeAuthBaseline(p.AuthBaselineEnc)
	if base == nil {
		log.DebugContext(ctx, "auth_baseline_absent", append([]any{"uid_hash", logger.HashUID(p.UserID)}, logger.TraceAttrs(ctx)...)...)
		return
	}

	known := base.Subjects[claims.SignInProvider]
	subjectUnknown := false
	var unknownHash string
	for _, sub := range claims.Identities[claims.SignInProvider] {
		h := sha256Hex(sub)
		found := false
		for _, k := range known {
			if k == h {
				found = true
				break
			}
		}
		if !found {
			subjectUnknown, unknownHash = true, logger.HashUID(sub)
		}
	}
	if !subjectUnknown {
		return
	}
	log.WarnContext(ctx, "auth_identity_unrecognized", append([]any{
		"uid_hash", logger.HashUID(p.UserID),
		"sign_in_provider", claims.SignInProvider,
		"token_subject_hash", unknownHash,
	}, logger.TraceAttrs(ctx)...)...)
}
