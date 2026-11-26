package messaging

import (
	"context"
	"strconv"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Commit caps after a session cut (removal-server design Q8, Plan 6 lane D PR 5). The three per-uid commit caps (the
// interceptor's "messages_commits_daily", and the service's "messages_commits_per_conversation_daily" and
// "messages_resets_daily") are keyed by the caller's current session cut as well, so sessions that signed in after a
// REMOTE device removal get fresh counters: a thief's drain from before the cut cannot block the removal commits that
// follow. A cut is only written with FEATURE_DEVICE_SIGN_OUT on for the remover (keys), so that is the gating.
//
// The cut comes from identity's cached profile (the same 60 s cache the cut interceptor and account status read), so the
// key adds no Firestore read to a request. No cut keeps today's key byte for byte, so a deploy resets nobody's counters.
// A key is never logged.

// SessionCutReader answers the caller's session cut (identity.SessionCuts.SessionsValidAfter, from the cached profile):
// zero for none or for a uid without a profile.
type SessionCutReader interface {
	SessionsValidAfter(ctx context.Context, uid string) (time.Time, error)
}

// fieldCapCutUnknown is the request-line field set when the cut lookup of a cap key failed (the old key is used). A bool,
// never a time or a uid.
const fieldCapCutUnknown = "cap_cut_unknown"

// CapKeyAfterCut is key for a caller without a session cut, and key + "|c" + the cut's Unix seconds for one with a cut,
// so every cut starts a fresh counter. The tag is short and is part of an in-memory map key only (never logged).
func CapKeyAfterCut(key string, cut time.Time) string {
	if cut.IsZero() {
		return key
	}
	return key + "|c" + strconv.FormatInt(cut.Unix(), 10)
}

// CommitCapKey builds a cap key of uid from base with the caller's cut read through cuts. A nil reader, or a failed
// lookup, keeps base (the stricter, pre-cut counter; the lookup failure is noted on the request line as
// cap_cut_unknown=true and the request goes on, account status reports the read failure itself).
func CommitCapKey(ctx context.Context, cuts SessionCutReader, uid, base string) string {
	if cuts == nil {
		return base
	}
	cut, err := cuts.SessionsValidAfter(ctx, uid)
	if err != nil {
		logger.SetRequestField(ctx, fieldCapCutUnknown, true)
		return base
	}
	return CapKeyAfterCut(base, cut)
}
