package engagement

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// W2-14 L-3: a bookmark write that exhausted its transaction re-runs (Aborted) or its 5 s txTimeout is a retryable
// UNAVAILABLE logged as outcome=contention, never an INTERNAL that would reach Error Reporting and the rollback trigger.
func TestBookmarkWrites_ContentionIsRetryableNotInternal(t *testing.T) {
	calls := map[string]func(e *bmEnv) error{
		"add": func(e *bmEnv) error { _, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA); return err },
		"remove": func(e *bmEnv) error {
			_, err := e.m.RemoveBookmark(e.ctx, "viewer", keyOK, pidA)
			return err
		},
	}
	setErr := func(e *bmEnv, err error) { e.bm.addErr, e.bm.rmErr = err, err }
	errs := map[string]error{
		"aborted after the re-runs":    status.Error(codes.Aborted, "too much contention on these documents"),
		"aborted, wrapped":             fmt.Errorf("engagement: idempotency lookup: %w", status.Error(codes.Aborted, "contention")),
		"txTimeout as a gRPC status":   status.Error(codes.DeadlineExceeded, "context deadline exceeded"),
		"txTimeout as a context error": fmt.Errorf("wait: %w", context.DeadlineExceeded),
	}
	for callName, call := range calls {
		for errName, cause := range errs {
			t.Run(callName+"/"+errName, func(t *testing.T) {
				e := newBMEnv(t, 48*time.Hour)
				setErr(e, cause)
				var fields *logger.RequestInfo
				e.ctx, fields = logger.WithRequestInfo(e.ctx)
				err := call(e)
				ae := requireCode(t, err, connect.CodeUnavailable)
				if ae.RetryAfter <= 0 {
					t.Errorf("RetryAfter = %v, want a retry hint", ae.RetryAfter)
				}
				if got, _ := fields.Get(fieldOutcome); got != outcomeContention {
					t.Errorf("outcome = %v, want %q", got, outcomeContention)
				}
			})
		}
	}
}

// A caller that left is CANCELED / DEADLINE_EXCEEDED, not a server fault and not contention: the transaction's own
// timeout is a child context and leaves the request context alive, the client's is the request context.
func TestBookmarkWrites_CallerGoneIsNotAServerFault(t *testing.T) {
	for name, tt := range map[string]struct {
		mkctx func(context.Context) (context.Context, context.CancelFunc)
		want  connect.Code
	}{
		"canceled": {func(c context.Context) (context.Context, context.CancelFunc) {
			c, cancel := context.WithCancel(c)
			cancel()
			return c, cancel
		}, connect.CodeCanceled},
		"deadline passed": {func(c context.Context) (context.Context, context.CancelFunc) {
			return context.WithDeadline(c, time.Now().Add(-time.Second))
		}, connect.CodeDeadlineExceeded},
	} {
		t.Run(name, func(t *testing.T) {
			e := newBMEnv(t, 48*time.Hour)
			ctx, cancel := tt.mkctx(e.ctx)
			defer cancel()
			err := mapBookmarkErr(ctx, "add bookmark", "viewer", pidA, status.Error(codes.DeadlineExceeded, "ctx"))
			_ = requireCode(t, err, tt.want)
		})
	}
}

// Anything else stays an INTERNAL (a redacted plain error, reaching Error Reporting), with the raw uid AND the
// bookmarked post id gone from the whole cause chain (W2-14 I-4): a Firestore error embeds document paths.
func TestBookmarkWrites_InternalErrorRedactsUIDAndPostID(t *testing.T) {
	const uid = "uid-secret-1"
	path := fmt.Errorf("rpc error: code = Internal desc = commit users/%s/bookmarks/%s", uid, pidA)
	err := mapBookmarkErr(context.Background(), "add bookmark", uid, pidA, path)
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v, want a plain redacted error (INTERNAL at the handler)", err)
	}
	for _, raw := range []string{uid, pidA} {
		if strings.Contains(err.Error(), raw) {
			t.Errorf("Error() = %q still contains %q", err.Error(), raw)
		}
	}
	if !strings.Contains(err.Error(), logger.HashUID(uid)) || !strings.Contains(err.Error(), logger.HashUID(pidA)) {
		t.Errorf("Error() = %q, want both ids replaced by their hashes", err.Error())
	}
	if !errors.Is(err, path) {
		t.Error("the redacted error must still unwrap to its cause")
	}
}

// The list's failure paths redact the post ids too: the page cursor's document and the ids GetMany was asked for.
func TestListBookmarks_ErrorsRedactPostIDs(t *testing.T) {
	t.Run("GetMany fails", func(t *testing.T) {
		e := newListEnv(t)
		e.seed(2)
		e.rd.getManyErr = fmt.Errorf("batch get posts/%s posts/%s failed", pid(1), pid(2))
		_, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		if err == nil {
			t.Fatal("want an error")
		}
		for _, id := range []string{pid(1), pid(2), caller} {
			if strings.Contains(err.Error(), id) {
				t.Errorf("error %q still contains %q", err.Error(), id)
			}
		}
	})
	t.Run("query fails past the first page", func(t *testing.T) {
		e := newListEnv(t)
		e.seed(25)
		p1, err := e.m.ListBookmarks(e.ctx, caller, 20, "")
		if err != nil || p1.NextPageToken == "" {
			t.Fatalf("page 1: %v %q", err, p1.NextPageToken)
		}
		// The 20th row (pid(6)) is the cursor's document; a Firestore error would name it.
		e.bm.listErr = fmt.Errorf("start after users/%s/bookmarks/%s: unavailable", caller, pid(6))
		_, err = e.m.ListBookmarks(e.ctx, caller, 20, p1.NextPageToken)
		if err == nil {
			t.Fatal("want an error")
		}
		if strings.Contains(err.Error(), pid(6)) || strings.Contains(err.Error(), "users/"+caller) {
			t.Errorf("error %q still contains the cursor's post id or the raw uid", err.Error())
		}
	})
}
