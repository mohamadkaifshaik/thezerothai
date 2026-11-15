package location

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	uidA      = "uid-a"
	uidB      = "uid-b"
	areaIndi  = "in.blr.indiranagar"
	areaDoml  = "in.blr.domlur"
	cityBlr   = "in.blr"
	keyPrefix = "loc-test-key-"
)

var testCursorKey = []byte("0123456789abcdef0123456789abcdef")

// key is a valid idempotency key with a distinct suffix.
func key(s string) string { return keyPrefix + s + "-padpad" }

var grant = &Grant{CopyVersion: 1, AdultConfirmed: true}

type env struct {
	repo  *fakeRepo
	clock *fakeClock
	svc   Service
	cat   *StaticCatalog
}

func newEnv(t *testing.T, limits Limits) *env {
	t.Helper()
	cat := mustCatalog(t)
	if limits.ConsentChangesPerDay == 0 {
		limits.ConsentChangesPerDay = 10
	}
	e := &env{repo: newFakeRepo(), clock: &fakeClock{t: time.Date(2026, 11, 15, 6, 0, 0, 0, time.UTC)}, cat: cat}
	e.svc = New(Deps{Repo: e.repo, Catalog: cat, IDs: &fakeIDs{}, CursorKey: testCursorKey, Limits: limits, Now: e.clock.now})
	return e
}

// apiErr asserts err is an *apierr.Error with code and reason, and returns it.
func apiErr(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason) *apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != code || ae.Reason != reason {
		t.Fatalf("err = %v, want %v/%v", err, code, reason)
	}
	return ae
}

func wantValidation(t *testing.T, err error, field string) {
	t.Helper()
	if ae := apiErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION); ae.Metadata["field"] != field {
		t.Fatalf("field = %q, want %q", ae.Metadata["field"], field)
	}
}

// TestSetArea_Validation: every bad field is VALIDATION with its field name, before any repo access.
func TestSetArea_Validation(t *testing.T) {
	retired, err := ParseCatalog([]byte(`{"version": 1, "areas": [
		{"id": "in.blr", "name": "Bengaluru", "kind": "CITY", "city": "in.blr", "aliases": [], "neighbours": [], "retired": false},
		{"id": "in.blr.old", "name": "Old", "kind": "AREA", "city": "in.blr", "aliases": [], "neighbours": [], "retired": true}]}`))
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name  string
		cat   *StaticCatalog
		in    SetAreaInput
		field string
	}{
		{"short key", nil, SetAreaInput{Key: "short", AreaID: areaIndi}, "idempotency_key"},
		{"bad key chars", nil, SetAreaInput{Key: "loc-test-key-with space", AreaID: areaIndi}, "idempotency_key"},
		{"empty area", nil, SetAreaInput{Key: key("a"), AreaID: ""}, "area_id"},
		{"malformed area", nil, SetAreaInput{Key: key("a"), AreaID: "IN.BLR"}, "area_id"},
		{"unknown area", nil, SetAreaInput{Key: key("a"), AreaID: "in.blr.nowhere"}, "area_id"},
		{"retired area", retired, SetAreaInput{Key: key("a"), AreaID: "in.blr.old"}, "area_id"},
		{"consent not adult", nil, SetAreaInput{Key: key("a"), AreaID: areaIndi, Consent: &Grant{CopyVersion: 1}}, "consent"},
		{"consent old copy", nil, SetAreaInput{Key: key("a"), AreaID: areaIndi, Consent: &Grant{CopyVersion: 0, AdultConfirmed: true}}, "consent"},
		{"consent future copy", nil, SetAreaInput{Key: key("a"), AreaID: areaIndi, Consent: &Grant{CopyVersion: 2, AdultConfirmed: true}}, "consent"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, Limits{})
			if tt.cat != nil {
				e.svc = New(Deps{Repo: e.repo, Catalog: tt.cat, IDs: &fakeIDs{}, CursorKey: testCursorKey, Limits: Limits{ConsentChangesPerDay: 10}, Now: e.clock.now})
			}
			_, err := e.svc.SetArea(context.Background(), uidA, tt.in)
			wantValidation(t, err, tt.field)
			if e.repo.reads != 0 || len(e.repo.idem) != 0 {
				t.Fatalf("validation touched the repo")
			}
		})
	}
	e := newEnv(t, Limits{})
	_, err = e.svc.ClearArea(context.Background(), uidA, "bad")
	wantValidation(t, err, "idempotency_key")
}

// TestSetArea_ConsentFlow: set without consent => consent_required; a grant appends one GRANTED record; a change of area
// under the consent appends nothing; the same area is a no-op; clear withdraws; the next set needs consent again.
func TestSetArea_ConsentFlow(t *testing.T) {
	e := newEnv(t, Limits{})
	ctx := context.Background()
	_, err := e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("1"), AreaID: areaIndi})
	if ae := apiErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED); ae.Metadata["reason"] != "consent_required" {
		t.Fatalf("reason = %q", ae.Metadata["reason"])
	}
	st, err := e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("2"), AreaID: areaIndi, Consent: grant})
	if err != nil {
		t.Fatal(err)
	}
	if st.Area == nil || st.Area.ID != areaIndi || st.Area.CityName != "Bengaluru" || st.Consent.Action != ActionGranted ||
		st.Consent.CopyVersion != 1 || st.Consent.AdultConfirmedAt.IsZero() || st.RequiredCopyVersion != 1 {
		t.Fatalf("after grant: %+v", st)
	}
	if n := len(e.repo.consents[uidA]); n != 1 {
		t.Fatalf("consent records = %d, want 1", n)
	}
	// A change of area: no new record (no location history); the consent in the request is ignored.
	st, err = e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("3"), AreaID: areaDoml, Consent: grant})
	if err != nil || st.Area.ID != areaDoml || len(e.repo.consents[uidA]) != 1 {
		t.Fatalf("change: %+v, %v, records %d", st, err, len(e.repo.consents[uidA]))
	}
	writes := e.repo.writes
	if _, err := e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("4"), AreaID: areaDoml}); err != nil || e.repo.writes != writes {
		t.Fatalf("same area wrote: %v", err)
	}
	st, err = e.svc.ClearArea(ctx, uidA, key("5"))
	if err != nil || st.Area != nil || st.Consent.Action != ActionWithdrawn || !st.Consent.AdultConfirmedAt.IsZero() {
		t.Fatalf("clear: %+v, %v", st, err)
	}
	// A second clear (no area): success, no record.
	if st, err = e.svc.ClearArea(ctx, uidA, key("6")); err != nil || st.Consent.Action != ActionWithdrawn || len(e.repo.consents[uidA]) != 2 {
		t.Fatalf("second clear: %+v, %v", st, err)
	}
	_, err = e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("7"), AreaID: areaIndi})
	_ = apiErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	// A CITY area is settable too.
	if st, err := e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("8"), AreaID: cityBlr, Consent: grant}); err != nil || st.Area.Kind != KindCity {
		t.Fatalf("city: %+v, %v", st, err)
	}
}

// TestSetArea_CopyVersionBump: a stored consent below the server minimum is not current; the request must carry a grant
// at the new copy version, which appends a new GRANTED record.
func TestSetArea_CopyVersionBump(t *testing.T) {
	e := newEnv(t, Limits{})
	ctx := context.Background()
	if _, err := e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("1"), AreaID: areaIndi, Consent: grant}); err != nil {
		t.Fatal(err)
	}
	e.svc = New(Deps{Repo: e.repo, Catalog: e.cat, IDs: &fakeIDs{n: 100}, CursorKey: testCursorKey, Limits: Limits{MinCopyVersion: 2, ConsentChangesPerDay: 10}, Now: e.clock.now})
	st, err := e.svc.GetSettings(ctx, uidA)
	if err != nil || st.RequiredCopyVersion != 2 || st.Consent.CopyVersion != 1 {
		t.Fatalf("settings: %+v, %v", st, err)
	}
	// The stored area is below the new minimum: other modules (Nearby) must not use it.
	if id, ok, err := e.svc.MyArea(ctx, uidA); err != nil || ok || id != "" {
		t.Fatalf("MyArea below the minimum = %q, %v, %v", id, ok, err)
	}
	_, err = e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("2"), AreaID: areaDoml})
	_ = apiErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	_, err = e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("3"), AreaID: areaDoml, Consent: grant}) // copy 1 < 2
	wantValidation(t, err, "consent")
	st, err = e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("4"), AreaID: areaDoml, Consent: &Grant{CopyVersion: 2, AdultConfirmed: true}})
	if err != nil || st.Consent.CopyVersion != 2 || len(e.repo.consents[uidA]) != 2 {
		t.Fatalf("re-grant: %+v, %v", st, err)
	}
	if id, ok, err := e.svc.MyArea(ctx, uidA); err != nil || !ok || id != areaDoml {
		t.Fatalf("MyArea after the re-grant = %q, %v, %v", id, ok, err)
	}
}

// TestSetArea_CopyVersionWindow: a grant is accepted only for MinCopyVersion <= copy_version <= CurrentCopyVersion, and
// the settings carry both bounds.
func TestSetArea_CopyVersionWindow(t *testing.T) {
	e := newEnv(t, Limits{MinCopyVersion: 2, CurrentCopyVersion: 3})
	ctx := context.Background()
	for _, tc := range []struct {
		copy int
		ok   bool
	}{{1, false}, {2, true}, {3, true}, {4, false}} {
		_, err := e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("w" + strconv.Itoa(tc.copy)), AreaID: areaIndi, Consent: &Grant{CopyVersion: tc.copy, AdultConfirmed: true}})
		if tc.ok && err != nil {
			t.Fatalf("copy %d: %v", tc.copy, err)
		}
		if !tc.ok {
			wantValidation(t, err, "consent")
		}
	}
	st, err := e.svc.GetSettings(ctx, uidA)
	if err != nil || st.RequiredCopyVersion != 2 || st.CurrentCopyVersion != 3 {
		t.Fatalf("settings bounds: %+v, %v", st, err)
	}
}

// TestNew_DefensiveDefaults: zero limits fall back to a usable service (copy versions 1/1, 10 consent changes a day),
// and a current copy version below the minimum is raised to it.
func TestNew_DefensiveDefaults(t *testing.T) {
	s := New(Deps{}).(*service)
	if l := s.d.Limits; l.MinCopyVersion != 1 || l.CurrentCopyVersion != 1 || l.ConsentChangesPerDay != 10 {
		t.Fatalf("defaults = %+v", l)
	}
	s = New(Deps{Limits: Limits{MinCopyVersion: 3, CurrentCopyVersion: 2, ConsentChangesPerDay: 4}}).(*service)
	if l := s.d.Limits; l.MinCopyVersion != 3 || l.CurrentCopyVersion != 3 || l.ConsentChangesPerDay != 4 {
		t.Fatalf("raised = %+v", l)
	}
}

// TestSetArea_DailyConsentCap: grants are refused once LOCATION_CONSENT_CHANGES_PER_DAY records exist since IST midnight;
// ClearArea is never limited; the next IST day allows again.
func TestSetArea_DailyConsentCap(t *testing.T) {
	e := newEnv(t, Limits{ConsentChangesPerDay: 3})
	ctx := context.Background()
	for i, k := range []string{"g1", "c1", "g2"} {
		var err error
		if k[0] == 'g' {
			_, err = e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key(k), AreaID: areaIndi, Consent: grant})
		} else {
			_, err = e.svc.ClearArea(ctx, uidA, key(k))
		}
		if err != nil {
			t.Fatalf("step %d: %v", i, err)
		}
	}
	// 3 records today: the clear still works, the next grant is refused.
	if _, err := e.svc.ClearArea(ctx, uidA, key("c2")); err != nil {
		t.Fatalf("clear at the cap: %v", err)
	}
	_, err := e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("g3"), AreaID: areaIndi, Consent: grant})
	if ae := apiErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED); ae.Metadata["limit"] != "location_consent_changes" {
		t.Fatalf("limit = %q", ae.Metadata["limit"])
	}
	// 06:00 UTC is 11:30 IST; 18:30 UTC is the next IST midnight.
	e.clock.t = time.Date(2026, 11, 15, 18, 30, 0, 0, time.UTC)
	if _, err := e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("g4"), AreaID: areaIndi, Consent: grant}); err != nil {
		t.Fatalf("next IST day: %v", err)
	}
	if got := istMidnight(time.Date(2026, 11, 15, 18, 29, 0, 0, time.UTC)); !got.Equal(time.Date(2026, 11, 14, 18, 30, 0, 0, time.UTC)) {
		t.Fatalf("istMidnight = %v", got)
	}
}

// TestSetArea_Idempotency: a retry with the same key and body replays (nothing written); another body is KEY_REUSED.
func TestSetArea_Idempotency(t *testing.T) {
	e := newEnv(t, Limits{})
	ctx := context.Background()
	in := SetAreaInput{Key: key("same"), AreaID: areaIndi, Consent: grant}
	first, err := e.svc.SetArea(ctx, uidA, in)
	if err != nil {
		t.Fatal(err)
	}
	writes := e.repo.writes
	again, err := e.svc.SetArea(ctx, uidA, in)
	if err != nil || e.repo.writes != writes || again.Area.ID != first.Area.ID || len(e.repo.consents[uidA]) != 1 {
		t.Fatalf("replay: %+v, %v", again, err)
	}
	_, err = e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("same"), AreaID: areaDoml, Consent: grant})
	_ = apiErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	// The same key under another uid is another record (keys are hashed with the uid).
	if _, err := e.svc.SetArea(ctx, uidB, SetAreaInput{Key: key("same"), AreaID: areaDoml, Consent: grant}); err != nil {
		t.Fatalf("other uid: %v", err)
	}
}

// TestSetArea_RequestHashIsKeyed: the stored idempotency requestHash mixes in the client key, so it is not the
// enumerable hash of the area id alone (DPDP: the idempotency doc must not reveal the area).
func TestSetArea_RequestHashIsKeyed(t *testing.T) {
	e := newEnv(t, Limits{})
	in := SetAreaInput{Key: key("hash"), AreaID: areaIndi, Consent: grant}
	if _, err := e.svc.SetArea(context.Background(), uidA, in); err != nil {
		t.Fatal(err)
	}
	keyless := idempotency.HashRequest(fmt.Sprintf("area=%s|consent=%t|copy=%d|adult=%t", areaIndi, true, 1, true))
	stored := e.repo.idem[idempotency.Key(uidA, rpcSetArea, in.Key)]
	if stored == "" || stored == keyless || stored != setHash(in) {
		t.Fatalf("stored hash %q; keyless %q", stored, keyless)
	}
	other := in
	other.Key = key("other")
	if setHash(other) == setHash(in) {
		t.Fatal("two keys gave the same hash for one body")
	}
}

// TestMapErr_AreaPlaceholder: an internal error that names the area id carries "<area>" instead (not a hash, which the
// small catalogue would let anyone reverse), the uid is hashed, and errors.Is still reaches the cause.
func TestMapErr_AreaPlaceholder(t *testing.T) {
	e := newEnv(t, Limits{})
	cause := errors.New("write users/" + uidA + "/locationArea/current failed for " + areaIndi)
	e.repo.err = cause
	_, err := e.svc.SetArea(context.Background(), uidA, SetAreaInput{Key: key("redact"), AreaID: areaIndi, Consent: grant})
	if err == nil || strings.Contains(err.Error(), areaIndi) || strings.Contains(err.Error(), uidA) || !strings.Contains(err.Error(), "<area>") {
		t.Fatalf("err = %v", err)
	}
	if strings.Contains(err.Error(), logger.HashUID(areaIndi)) {
		t.Fatalf("the area id was hashed, not replaced: %v", err)
	}
	if !errors.Is(err, cause) {
		t.Fatalf("errors.Is lost the cause: %v", err)
	}
}

// TestGetSettings: never consented (UNSPECIFIED, 2 reads), area set (1 read), after a withdrawal (the record).
func TestGetSettings(t *testing.T) {
	e := newEnv(t, Limits{})
	ctx := context.Background()
	st, err := e.svc.GetSettings(ctx, uidA)
	if err != nil || st.Area != nil || st.Consent.Action != "" || e.repo.reads != 2 {
		t.Fatalf("never: %+v, %v, reads %d", st, err, e.repo.reads)
	}
	if _, err := e.svc.SetArea(ctx, uidA, SetAreaInput{Key: key("1"), AreaID: areaIndi, Consent: grant}); err != nil {
		t.Fatal(err)
	}
	e.repo.reads = 0
	if st, err = e.svc.GetSettings(ctx, uidA); err != nil || st.Area == nil || st.Consent.Action != ActionGranted || e.repo.reads != 1 {
		t.Fatalf("set: %+v, %v, reads %d", st, err, e.repo.reads)
	}
	if id, ok, err := e.svc.MyArea(ctx, uidA); err != nil || !ok || id != areaIndi {
		t.Fatalf("MyArea = %q, %v, %v", id, ok, err)
	}
	if _, err := e.svc.ClearArea(ctx, uidA, key("2")); err != nil {
		t.Fatal(err)
	}
	if st, err = e.svc.GetSettings(ctx, uidA); err != nil || st.Area != nil || st.Consent.Action != ActionWithdrawn {
		t.Fatalf("withdrawn: %+v, %v", st, err)
	}
	if _, ok, err := e.svc.MyArea(ctx, uidA); err != nil || ok {
		t.Fatalf("MyArea after clear = %v, %v", ok, err)
	}
	e.repo.err = errors.New("boom " + uidA)
	if _, err := e.svc.GetSettings(ctx, uidA); err == nil || strings.Contains(err.Error(), uidA) {
		t.Fatalf("repo error not redacted: %v", err)
	}
}

// TestListAreas: paging covers the catalogue once in id order; the limit is clamped; known_version answers not_modified;
// a token is bound to the caller and the catalogue version.
func TestListAreas(t *testing.T) {
	e := newEnv(t, Limits{})
	ctx := context.Background()
	var ids []string
	token := ""
	for pages := 0; ; pages++ {
		p, err := e.svc.ListAreas(ctx, uidA, ListAreasInput{Limit: 7, PageToken: token})
		if err != nil {
			t.Fatal(err)
		}
		if p.Version != e.cat.Version() || p.NotModified {
			t.Fatalf("page %d: %+v", pages, p)
		}
		for _, a := range p.Areas {
			ids = append(ids, a.ID)
		}
		if p.Next == "" {
			break
		}
		token = p.Next
		if pages > 100 {
			t.Fatal("paging does not end")
		}
	}
	if len(ids) != e.cat.Len() {
		t.Fatalf("paged %d areas, want %d", len(ids), e.cat.Len())
	}
	for i := 1; i < len(ids); i++ {
		if ids[i-1] >= ids[i] {
			t.Fatalf("not in id order at %d: %s, %s", i, ids[i-1], ids[i])
		}
	}
	for _, tc := range []struct{ limit, want int }{{0, min(200, e.cat.Len())}, {-3, min(200, e.cat.Len())}, {9999, min(500, e.cat.Len())}, {1, 1}} {
		p, err := e.svc.ListAreas(ctx, uidA, ListAreasInput{Limit: tc.limit})
		if err != nil || len(p.Areas) != tc.want {
			t.Errorf("limit %d: %d areas, %v; want %d", tc.limit, len(p.Areas), err, tc.want)
		}
	}
	p, err := e.svc.ListAreas(ctx, uidA, ListAreasInput{KnownVersion: e.cat.Version()})
	if err != nil || !p.NotModified || len(p.Areas) != 0 || p.Next != "" {
		t.Fatalf("not_modified: %+v, %v", p, err)
	}
	first, _ := e.svc.ListAreas(ctx, uidA, ListAreasInput{Limit: 1})
	_, err = e.svc.ListAreas(ctx, uidB, ListAreasInput{PageToken: first.Next})
	wantValidation(t, err, "page_token")
	stale := cursor.EncodeAt(testCursorKey, areasBinding(uidA, e.cat.Version()-1), cursor.Cursor{CreatedAt: time.Unix(0, 0), DocID: cityBlr}, e.clock.t)
	_, err = e.svc.ListAreas(ctx, uidA, ListAreasInput{PageToken: stale})
	wantValidation(t, err, "page_token")
	_, err = e.svc.ListAreas(ctx, uidA, ListAreasInput{PageToken: "garbage"})
	wantValidation(t, err, "page_token")
}
