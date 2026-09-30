package logger

import (
	"errors"
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
