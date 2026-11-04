package media

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// panicAttrs panics on the first object read of a finalize, before the screening claim.
type panicAttrs struct{ *fakeObjects }

func (panicAttrs) UploadAttrs(context.Context, string) (objstore.Attrs, error) { panic("boom " + uidA) }

// panicPublish panics after screening, with the claim held and the Vision units spent.
type panicPublish struct{ *fakeObjects }

func (panicPublish) Publish(context.Context, string, int64, string, string) error {
	panic("boom " + uidA)
}

// wantWorkerPanicReported checks the call failed and the service reported the panic once, under op, with the panic's real
// type and a stack that reaches site, and without its value, which may hold a uid. Through the real chain an image worker's
// INTERNAL gets a second entry from mw.ErrorMapping; this one is the entry that has the stack of the panic.
func wantWorkerPanicReported(t *testing.T, err error, logs *bytes.Buffer, op, site string) {
	t.Helper()
	if err == nil {
		t.Fatal("the call succeeded")
	}
	if strings.Contains(logs.String(), "boom") {
		t.Fatalf("log carries the panic value: %s", logs.String())
	}
	var found int
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) != nil || rec["level"] != "ERROR" {
			continue
		}
		found++
		stack, _ := rec["stack_trace"].(string)
		msg, _ := rec["msg"].(string)
		if rec["rpc"] != op || !strings.Contains(stack, site) || !strings.Contains(msg, "panic of type string") {
			t.Fatalf("error record = %v", rec)
		}
	}
	if found != 1 {
		t.Fatalf("%d ERROR records, want 1: %s", found, logs.String())
	}
}

func wantPlainError(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if errors.As(err, &ae) {
		t.Fatalf("err = %v, want a plain error (INTERNAL on the wire)", err)
	}
}

// The per-image goroutines of FinalizeUpload run outside the interceptor's recover, so a panic there would end the whole
// instance and every request on it.
func TestFinalize_PanicBeforeClaimFailsTheCallOnly(t *testing.T) {
	var logs bytes.Buffer
	e := newEnv(t, envOpts{
		objects: func(f *fakeObjects) Objects { return panicAttrs{f} },
		log:     slog.New(slog.NewJSONHandler(&logs, nil)),
	})
	tg := e.upload(t, uidA, PurposePost, "a")
	_, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	wantPlainError(t, err)
	wantWorkerPanicReported(t, err, &logs, finalizeWorkerOp, "UploadAttrs")
	if len(e.obj.public) != 0 || e.repo.docs[tg.MediaID].Status != string(StatusPending) {
		t.Fatal("nothing is published and the image stays retryable")
	}
}

// A panic with the claim held gives the claim back at once, and the units Vision already billed still reach the counter.
func TestFinalize_PanicAfterClaimReleasesItAndKeepsTheSpend(t *testing.T) {
	var logs bytes.Buffer
	e := newEnv(t, envOpts{
		objects: func(f *fakeObjects) Objects { return panicPublish{f} },
		log:     slog.New(slog.NewJSONHandler(&logs, nil)),
	})
	tg := e.upload(t, uidA, PurposePost, "a")
	_, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	wantPlainError(t, err)
	wantWorkerPanicReported(t, err, &logs, finalizeWorkerOp, "Publish")
	d := e.repo.docs[tg.MediaID]
	if d.Status != string(StatusPending) || d.ScreeningUntil != nil {
		t.Fatalf("status %q, claim until %v: the image must stay retryable with its claim released", d.Status, d.ScreeningUntil)
	}
	if e.repo.vision[monthKey(testNow)] == 0 {
		t.Fatal("the Vision units spent before the panic were lost")
	}
}

// The same for the Vision goroutines. A Vision call with no answer is an outage to the caller: UNAVAILABLE, publish nothing,
// and the image stays retryable.
func TestFinalize_PanicOnVisionWorkerFailsTheCallOnly(t *testing.T) {
	var logs bytes.Buffer
	e := newEnv(t, envOpts{log: slog.New(slog.NewJSONHandler(&logs, nil))})
	tg := e.upload(t, uidA, PurposePost, "a")
	e.mod.onCall = func() error { panic("boom " + uidA) }
	_, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	wantWorkerPanicReported(t, err, &logs, screenWorkerOp, "SafeSearch")
	_ = wantAPI(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if len(e.obj.public) != 0 || e.repo.docs[tg.MediaID].Status != string(StatusPending) {
		t.Fatal("nothing is published and the image stays retryable")
	}
}
