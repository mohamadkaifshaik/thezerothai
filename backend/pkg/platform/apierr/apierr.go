// Package apierr is the single place domain/service errors get shaped into Connect codes plus a
// dzeroth.common.v1.ErrorDetail (ADR-0002, CLAUDE.md "map errors to Connect codes at the handler
// boundary only"). Services return *apierr.Error (or a plain wrapped error for truly unexpected
// failures); the error-mapping interceptor (see pkg/platform/mw) converts it to a *connect.Error
// exactly once, right at the handler boundary.
package apierr

import (
	"errors"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/durationpb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

// Error is a service-layer error carrying everything needed to answer the client safely.
type Error struct {
	Code       connect.Code
	Reason     commonv1.ErrorReason
	Message    string // safe to show to the end user
	Metadata   map[string]string
	RetryAfter time.Duration
	cause      error // wrapped for logs only; never sent to the client
}

func New(code connect.Code, reason commonv1.ErrorReason, message string) *Error {
	return &Error{Code: code, Reason: reason, Message: message}
}

func (e *Error) Error() string { return e.Message }

func (e *Error) Unwrap() error { return e.cause }

// WithCause attaches the underlying error for logs (never exposed to the client).
func (e *Error) WithCause(err error) *Error {
	e.cause = err
	return e
}

// WithMeta sets a single metadata key (field name for validation errors, quota name, etc.).
func (e *Error) WithMeta(key, value string) *Error {
	if e.Metadata == nil {
		e.Metadata = make(map[string]string, 1)
	}
	e.Metadata[key] = value
	return e
}

func (e *Error) WithRetryAfter(d time.Duration) *Error {
	e.RetryAfter = d
	return e
}

// Validation is a convenience constructor for the most common error shape.
func Validation(field, message string) *Error {
	return New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, message).WithMeta("field", field)
}

// ToConnect converts err into a *connect.Error with an attached ErrorDetail. Unknown errors (not built
// with this package) become CodeInternal with a generic message — internals are never leaked to clients.
func ToConnect(err error) *connect.Error {
	if err == nil {
		return nil
	}
	var existing *connect.Error
	if errors.As(err, &existing) {
		return existing
	}
	var ae *Error
	if errors.As(err, &ae) {
		detail := &commonv1.ErrorDetail{
			Reason:   ae.Reason,
			Message:  ae.Message,
			Metadata: ae.Metadata,
		}
		if ae.RetryAfter > 0 {
			detail.RetryAfter = durationpb.New(ae.RetryAfter)
		}
		cerr := connect.NewError(ae.Code, errors.New(ae.Message))
		if d, derr := connect.NewErrorDetail(detail); derr == nil {
			cerr.AddDetail(d)
		}
		return cerr
	}
	return connect.NewError(connect.CodeInternal, errors.New("internal error"))
}
