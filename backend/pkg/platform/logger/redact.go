package logger

import (
	"errors"
	"regexp"
	"strings"
)

// redactedError carries an error's message with identifiers replaced by their HashUID. It deliberately has
// no Unwrap: mw's reportError walks the Unwrap chain (CauseChain) and would re-append the raw cause, with the
// raw ids, to the ERROR log line. errors.Is/As still reach the original through the Is/As methods, so
// sentinel and status-code checks keep working for whoever handles the error downstream.
type redactedError struct {
	msg   string
	cause error
}

func (e *redactedError) Error() string        { return e.msg }
func (e *redactedError) Is(target error) bool { return errors.Is(e.cause, target) }
func (e *redactedError) As(target any) bool   { return errors.As(e.cause, target) }

// RedactErr returns err with every occurrence of each id (uids, in practice) in its full message replaced by
// HashUID(id), so an error that ends up in an ERROR log line (mw.reportError logs the whole cause chain) never
// exposes a raw uid or an "A blocked B" pair, including inside Firestore's own error text (document paths).
// nil in, nil out. Empty ids are ignored.
func RedactErr(err error, ids ...string) error {
	if err == nil {
		return nil
	}
	msg := CauseChain(err)
	for _, id := range ids {
		if id != "" {
			msg = strings.ReplaceAll(msg, id, HashUID(id))
		}
	}
	return &redactedError{msg: msg, cause: err}
}

// CauseChain flattens err's full errors.Unwrap chain into one message: err.Error() plus any cause text not
// already contained in it. *apierr.Error deliberately keeps its cause out of Error() (client-safe message
// only), so logging needs this walk to see it; fmt.Errorf("%w") already folds the cause in and is not
// duplicated.
func CauseChain(err error) string {
	msg := err.Error()
	for cause := errors.Unwrap(err); cause != nil; cause = errors.Unwrap(cause) {
		if causeMsg := cause.Error(); !strings.Contains(msg, causeMsg) {
			msg += ": " + causeMsg
		}
	}
	return msg
}

var (
	// docPathRe matches a Firestore document path as the SDK prints it in errors ("documents/users/<uid>/...").
	docPathRe = regexp.MustCompile(`documents/\S+`)
	// edgeIDRe matches a composite edge/like doc id "<uid>_<uid>" (uids are 20-128 chars of [A-Za-z0-9-] and never
	// contain "_", ADR-0008 A3).
	edgeIDRe = regexp.MustCompile(`[A-Za-z0-9-]{20,128}_[A-Za-z0-9-]{20,128}`)
	// hexIDRe matches a 64-char hex id (an export id, or an object path "<id>.json").
	hexIDRe = regexp.MustCompile(`[0-9a-f]{64}`)
)

// ScrubErr is RedactErr plus a pattern pass for identifiers the caller cannot list: third-party uids inside
// Firestore document paths (documents/...), composite edge ids and 64-hex export ids, each replaced by
// "<redacted>". Use it on any error that leaves a job or an eraser for a log line. errors.Is/As still reach err.
func ScrubErr(err error, ids ...string) error {
	if err == nil {
		return nil
	}
	// Patterns first: once an id is hashed, the 16-char hash would no longer look like half of an edge id.
	msg := CauseChain(err)
	msg = docPathRe.ReplaceAllString(msg, "<redacted>")
	msg = edgeIDRe.ReplaceAllString(msg, "<redacted>")
	msg = hexIDRe.ReplaceAllString(msg, "<redacted>")
	for _, id := range ids {
		if id != "" {
			msg = strings.ReplaceAll(msg, id, HashUID(id))
		}
	}
	return &redactedError{msg: msg, cause: err}
}
