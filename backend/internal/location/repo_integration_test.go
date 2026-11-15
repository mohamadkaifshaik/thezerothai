//go:build integration

package location

import (
	"bytes"
	"context"
	"encoding/json"

	"fmt"
	"math/rand"
	"os"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

type repoEnv struct {
	client *firestore.Client
	repo   *FirestoreRepo
	svc    Service
	clock  *fakeClock
}

func newRepoEnv(t *testing.T, perDay int) *repoEnv {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int63()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	clock := &fakeClock{t: time.Date(2026, 11, 15, 6, 0, 0, 0, time.UTC)}
	repo := NewFirestoreRepo(client, idempotency.New(client))
	svc := New(Deps{Repo: repo, Catalog: mustCatalog(t), IDs: node, CursorKey: testCursorKey, Limits: Limits{ConsentChangesPerDay: perDay}, Now: clock.now})
	return &repoEnv{client: client, repo: repo, svc: svc, clock: clock}
}

func uniqueUID(t *testing.T) string { return fmt.Sprintf("loc-it-%d", rand.Int63()) }

// docs reads the raw area doc (nil when absent) and every consent record of uid.
func (e *repoEnv) docs(t *testing.T, uid string) (map[string]any, []map[string]any) {
	t.Helper()
	ctx := context.Background()
	var area map[string]any
	if snap, err := e.repo.areaRef(uid).Get(ctx); err == nil {
		area = snap.Data()
	}
	snaps, err := e.repo.consents(uid).OrderBy(firestore.DocumentID, firestore.Asc).Limit(100).Documents(ctx).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	out := make([]map[string]any, 0, len(snaps))
	for _, s := range snaps {
		out = append(out, s.Data())
	}
	return area, out
}

// TestRepo_SetChangeClear: the documents and consent records after each step are exactly as specified (design section 4).
func TestRepo_SetChangeClear(t *testing.T) {
	e := newRepoEnv(t, 10)
	ctx := context.Background()
	uid := uniqueUID(t)
	if _, err := e.svc.SetArea(ctx, uid, SetAreaInput{Key: key("n"), AreaID: areaIndi}); err == nil {
		t.Fatalf("set without consent = %v", err)
	}
	if a, c := e.docs(t, uid); a != nil || len(c) != 0 {
		t.Fatalf("a refused set wrote: %v %v", a, c)
	}
	if _, err := e.svc.SetArea(ctx, uid, SetAreaInput{Key: key("g"), AreaID: areaIndi, Consent: grant}); err != nil {
		t.Fatal(err)
	}
	a, c := e.docs(t, uid)
	if a["areaId"] != areaIndi || a["consentCopyVersion"] != int64(1) || len(c) != 1 || c[0]["action"] != ActionGranted ||
		c[0]["adultConfirmed"] != true || c[0]["purpose"] != PurposePlansNearby {
		t.Fatalf("after grant: %v %v", a, c)
	}
	if _, ok := c[0]["areaId"]; ok {
		t.Fatal("a consent record holds an area id")
	}
	if p, ok := a["purposes"].([]any); !ok || len(p) != 1 || p[0] != PurposePlansNearby {
		t.Fatalf("purposes = %v", a["purposes"])
	}
	e.clock.t = e.clock.t.Add(time.Minute)
	if _, err := e.svc.SetArea(ctx, uid, SetAreaInput{Key: key("c"), AreaID: areaDoml}); err != nil {
		t.Fatal(err)
	}
	a2, c2 := e.docs(t, uid)
	if a2["areaId"] != areaDoml || len(c2) != 1 || !a2["updatedAt"].(time.Time).After(a["updatedAt"].(time.Time)) ||
		!a2["consentedAt"].(time.Time).Equal(a["consentedAt"].(time.Time)) {
		t.Fatalf("after change: %v %v", a2, c2)
	}
	st, err := e.svc.ClearArea(ctx, uid, key("x"))
	if err != nil || st.Consent.Action != ActionWithdrawn {
		t.Fatalf("clear: %+v, %v", st, err)
	}
	a3, c3 := e.docs(t, uid)
	if a3 != nil || len(c3) != 2 || c3[1]["action"] != ActionWithdrawn || c3[1]["copyVersion"] != int64(1) {
		t.Fatalf("after clear: %v %v", a3, c3)
	}
	got, err := e.svc.GetSettings(ctx, uid)
	if err != nil || got.Area != nil || got.Consent.Action != ActionWithdrawn {
		t.Fatalf("settings after clear: %+v, %v", got, err)
	}
	if _, err := e.svc.ClearArea(ctx, uid, key("y")); err != nil {
		t.Fatal(err)
	}
	if _, c4 := e.docs(t, uid); len(c4) != 2 {
		t.Fatalf("a clear without an area appended a record: %d", len(c4))
	}
}

// TestRepo_IdempotentRetry: the same key and body again writes nothing (same updatedAt, same records); another body is
// KEY_REUSED.
func TestRepo_IdempotentRetry(t *testing.T) {
	e := newRepoEnv(t, 10)
	ctx := context.Background()
	uid := uniqueUID(t)
	in := SetAreaInput{Key: key("r"), AreaID: areaIndi, Consent: grant}
	if _, err := e.svc.SetArea(ctx, uid, in); err != nil {
		t.Fatal(err)
	}
	a, c := e.docs(t, uid)
	e.clock.t = e.clock.t.Add(time.Minute)
	st, err := e.svc.SetArea(ctx, uid, in)
	if err != nil || st.Area == nil || st.Area.ID != areaIndi {
		t.Fatalf("replay: %+v, %v", st, err)
	}
	a2, c2 := e.docs(t, uid)
	if !a2["updatedAt"].(time.Time).Equal(a["updatedAt"].(time.Time)) || len(c2) != len(c) {
		t.Fatalf("the replay wrote: %v %v", a2, c2)
	}
	if _, err := e.svc.SetArea(ctx, uid, SetAreaInput{Key: key("r"), AreaID: areaDoml, Consent: grant}); err == nil {
		t.Fatal("another body with the same key was accepted")
	}
}

// TestRepo_ConcurrentSetArea: racing first grants with different keys leave one area doc and exactly one GRANTED record
// (the area doc read makes them conflict; the loser re-runs under the winner's consent).
func TestRepo_ConcurrentSetArea(t *testing.T) {
	e := newRepoEnv(t, 10)
	ctx := context.Background()
	uid := uniqueUID(t)
	var wg sync.WaitGroup
	errs := make([]error, 4)
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			area := areaIndi
			if i%2 == 1 {
				area = areaDoml
			}
			_, errs[i] = e.svc.SetArea(ctx, uid, SetAreaInput{Key: key(fmt.Sprintf("race%d", i)), AreaID: area, Consent: grant})
		}(i)
	}
	wg.Wait()
	ok := 0
	for _, err := range errs {
		if err == nil {
			ok++
		}
	}
	a, c := e.docs(t, uid)
	if ok == 0 || a == nil || len(c) != 1 || c[0]["action"] != ActionGranted {
		t.Fatalf("race: %d ok (%v), area %v, records %d", ok, errs, a, len(c))
	}
}

// TestRepo_DailyCapInTransaction: the real count() refuses the grant at the cap; ClearArea still works.
func TestRepo_DailyCapInTransaction(t *testing.T) {
	e := newRepoEnv(t, 2)
	ctx := context.Background()
	uid := uniqueUID(t)
	if _, err := e.svc.SetArea(ctx, uid, SetAreaInput{Key: key("g1"), AreaID: areaIndi, Consent: grant}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.ClearArea(ctx, uid, key("c1")); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.SetArea(ctx, uid, SetAreaInput{Key: key("g2"), AreaID: areaIndi, Consent: grant}); err == nil {
		t.Fatal("the third consent record of the day was accepted")
	}
	if _, err := e.svc.ClearArea(ctx, uid, key("c2")); err != nil {
		t.Fatalf("clear at the cap: %v", err)
	}
	e.clock.t = time.Date(2026, 11, 15, 18, 31, 0, 0, time.UTC) // the next IST day
	if _, err := e.svc.SetArea(ctx, uid, SetAreaInput{Key: key("g3"), AreaID: areaIndi, Consent: grant}); err != nil {
		t.Fatalf("next IST day: %v", err)
	}
}

// TestRepo_PurgeAndExport: the export section reads the real documents; the eraser leaves no area doc and no consent.
func TestRepo_PurgeAndExport(t *testing.T) {
	e := newRepoEnv(t, 10)
	ctx := context.Background()
	uid := uniqueUID(t)
	for i, k := range []string{"g1", "c1", "g2"} {
		var err error
		if k[0] == 'g' {
			_, err = e.svc.SetArea(ctx, uid, SetAreaInput{Key: key(k), AreaID: areaIndi, Consent: grant})
		} else {
			_, err = e.svc.ClearArea(ctx, uid, key(k))
		}
		if err != nil {
			t.Fatalf("step %d: %v", i, err)
		}
	}
	var buf bytes.Buffer
	if err := NewExporter(e.repo, mustCatalog(t)).ExportUser(ctx, uid, &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Area     *ExportedArea     `json:"area"`
		Consents []ExportedConsent `json:"consents"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.Area == nil || out.Area.AreaID != areaIndi || out.Area.Name != "Indiranagar" || out.Area.CityName != "Bengaluru" ||
		len(out.Consents) != 3 || out.Consents[0].Action != ActionGranted || out.Consents[1].Action != ActionWithdrawn ||
		out.Consents[0].ID >= out.Consents[1].ID {
		t.Fatalf("export = %s", buf.String())
	}
	cp, done, err := NewEraser(e.repo).PurgeUser(ctx, uid, Checkpoint{})
	if err != nil || !done || cp.Deleted != 3 {
		t.Fatalf("purge: %+v, %v, %v", cp, done, err)
	}
	if a, c := e.docs(t, uid); a != nil || len(c) != 0 {
		t.Fatalf("residue after purge: %v %v", a, c)
	}
	if _, done, err := NewEraser(e.repo).PurgeUser(ctx, uid, cp); err != nil || !done {
		t.Fatalf("re-run: %v, %v", done, err)
	}
}
