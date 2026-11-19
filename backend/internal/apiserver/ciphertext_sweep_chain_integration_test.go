//go:build integration

package apiserver

// The ciphertext retention sweep over the real Build chain: it runs as the last step of /internal/cron/daily-maintenance
// and blanks an encrypted message whose ctExpireAt has passed, leaving a younger one alone. The emulator project is shared
// with other tests, so the assertions are per document.

import (
	"bytes"
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
)

func TestCiphertextSweepChain_DailyStepBlanksExpired(t *testing.T) {
	testCiphertextSweepOnRoute(t, func(e *lifecycleEnv) { e.runDailyMaintenance(t) })
}

// The hourly tick: /internal/cron/trends-refresh answers as before (the refresh's status) and then blanks the expired message.
func TestCiphertextSweepChain_HourlyTrendsTickBlanksExpired(t *testing.T) {
	testCiphertextSweepOnRoute(t, func(e *lifecycleEnv) {
		if got := postRoute(t, e.url+"/internal/cron/trends-refresh", http.MethodPost); got != http.StatusNoContent {
			t.Fatalf("trends-refresh = %d, want 204", got)
		}
	})
}

func testCiphertextSweepOnRoute(t *testing.T, call func(e *lifecycleEnv)) {
	t.Helper()
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, nil)
	conv := fmt.Sprintf("%016x%016x", rand.Uint64(), rand.Uint64())
	col := e.fs.Collection("conversations").Doc(conv).Collection("messages")
	now := time.Now().UTC().Truncate(time.Microsecond)
	seed := func(id string, expireAt time.Time) {
		t.Helper()
		m := messaging.MsgDoc{SenderID: "uid-sweep-sender", State: "VISIBLE", RequestHash: "h", CreatedAt: expireAt.Add(-messaging.CiphertextRetention),
			Ciphertext: []byte("ct"), Commitment: bytes.Repeat([]byte{1}, 32), MlsGen: 1, MlsEpoch: 1, MlsKey: "1:1", CtExpireAt: expireAt}
		if _, err := col.Doc(id).Set(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	seed("expired", now.Add(-time.Minute))
	seed("young", now.Add(time.Hour))

	call(e)

	get := func(id string) map[string]any {
		t.Helper()
		snap, err := col.Doc(id).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return snap.Data()
	}
	old := get("expired")
	for _, f := range []string{"ciphertext", "commitment", "ctExpireAt"} {
		if _, has := old[f]; has {
			t.Errorf("the expired message kept %s", f)
		}
	}
	if old["ctRemoved"] != true || old["mlsKey"] != "1:1" || old["state"] != "VISIBLE" || old["senderId"] != "uid-sweep-sender" {
		t.Errorf("the expired message after the sweep = %v", old)
	}
	if y := get("young"); y["ctRemoved"] != nil || len(y["ciphertext"].([]byte)) == 0 || y["ctExpireAt"] == nil {
		t.Errorf("the young message was touched: %v", y)
	}
}
