package location

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fakeStore is a Purger and ExportSource over one user's data.
type fakeStore struct {
	area     *StoredArea
	consents []ConsentRecord // id order
	afters   []string
	failArea error
}

func (f *fakeStore) DeleteArea(context.Context, string) error {
	if f.failArea != nil {
		return f.failArea
	}
	f.area = nil
	return nil
}

func (f *fakeStore) page(after string, limit int) []ConsentRecord {
	f.afters = append(f.afters, after)
	var out []ConsentRecord
	for _, c := range f.consents {
		if c.ID > after && len(out) < limit {
			out = append(out, c)
		}
	}
	return out
}

func (f *fakeStore) PurgeConsentsPage(_ context.Context, _, after string, limit int) (string, int, error) {
	page := f.page(after, limit)
	if len(page) == 0 {
		return after, 0, nil
	}
	keep := f.consents[:0]
	for _, c := range f.consents {
		if c.ID > page[len(page)-1].ID || c.ID <= after {
			keep = append(keep, c)
		}
	}
	f.consents = keep
	return page[len(page)-1].ID, len(page), nil
}

func (f *fakeStore) Area(context.Context, string) (*StoredArea, error) { return f.area, nil }

func (f *fakeStore) ExportConsentsPage(_ context.Context, _, after string, limit int) ([]ConsentRecord, error) {
	return f.page(after, limit), nil
}

func records(n int) []ConsentRecord {
	out := make([]ConsentRecord, n)
	for i := range out {
		out[i] = ConsentRecord{ID: strconv.Itoa(1_000_000 + i), Purpose: PurposePlansNearby, Action: ActionGranted, CopyVersion: 1}
	}
	return out
}

// TestEraser_PhasesAndCheckpoint: phase 0 deletes the area doc, then consents go purgePage at a time with the checkpoint
// carrying the last id; a resumed run from the JSON checkpoint finishes; a re-run of a finished account is a no-op.
func TestEraser_PhasesAndCheckpoint(t *testing.T) {
	st := &fakeStore{area: &StoredArea{AreaID: areaIndi}, consents: records(purgePage + 5)}
	e := NewEraser(st)
	ctx := context.Background()
	cp, done, err := e.PurgeUser(ctx, uidA, Checkpoint{})
	if err != nil || done || st.area != nil || cp.Phase != 1 || cp.Deleted != purgePage || cp.AfterID == "" {
		t.Fatalf("first run: %+v, %v, %v", cp, done, err)
	}
	raw, _ := json.Marshal(cp)
	var resumed Checkpoint
	if err := json.Unmarshal(raw, &resumed); err != nil {
		t.Fatal(err)
	}
	cp, done, err = e.PurgeUser(ctx, uidA, resumed)
	if err != nil || !done || cp.Deleted != purgePage+5 || len(st.consents) != 0 {
		t.Fatalf("second run: %+v, %v, %v (left %d)", cp, done, err, len(st.consents))
	}
	if cp, done, err = e.PurgeUser(ctx, uidA, Checkpoint{}); err != nil || !done || cp.Deleted != 0 {
		t.Fatalf("re-run: %+v, %v, %v", cp, done, err)
	}
	boom := errors.New("boom")
	if _, _, err := NewEraser(&fakeStore{failArea: boom}).PurgeUser(ctx, uidA, Checkpoint{}); !errors.Is(err, boom) {
		t.Fatalf("area failure = %v", err)
	}
}

// TestExporter_Golden: the section for a user with an area and two consent records, byte for byte, against
// testdata/export_location.golden.json. Change the file only for an intended format change: it is the contract of the
// `location` section in the account export.
func TestExporter_Golden(t *testing.T) {
	at := time.Date(2026, 11, 15, 9, 0, 0, 0, time.UTC)
	src := &fakeStore{
		area: &StoredArea{AreaID: areaIndi, Purposes: []string{PurposePlansNearby}, ConsentCopyVersion: 1, ConsentedAt: at, UpdatedAt: at.Add(time.Hour)},
		consents: []ConsentRecord{
			{ID: "0000000000000000101", Purpose: PurposePlansNearby, Action: ActionGranted, CopyVersion: 1, AdultConfirmed: true, At: at.Add(-24 * time.Hour)},
			{ID: "0000000000000000102", Purpose: PurposePlansNearby, Action: ActionWithdrawn, CopyVersion: 1, At: at.Add(-time.Hour)},
			{ID: "0000000000000000103", Purpose: PurposePlansNearby, Action: ActionGranted, CopyVersion: 1, AdultConfirmed: true, At: at},
		},
	}
	var buf bytes.Buffer
	if err := NewExporter(src, mustCatalog(t)).ExportUser(context.Background(), uidA, &buf); err != nil {
		t.Fatal(err)
	}
	want, err := os.ReadFile("testdata/export_location.golden.json")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.ReplaceAll(buf.String(), "\r\n", "\n"); got != strings.ReplaceAll(string(want), "\r\n", "\n") {
		t.Errorf("export =\n%s\nwant\n%s", got, want)
	}
}

// TestExporter_EmptyAndPaging: no data is {"area":null,"consents":[]}; a full page is followed by a request after its last
// id; every record is exported once, in id order.
func TestExporter_EmptyAndPaging(t *testing.T) {
	var buf bytes.Buffer
	if err := NewExporter(&fakeStore{}, nil).ExportUser(context.Background(), uidA, &buf); err != nil || buf.String() != "{\"area\":null,\"consents\":[]}\n" {
		t.Fatalf("empty export = %q, %v", buf.String(), err)
	}
	src := &fakeStore{consents: records(exportPage + 1)}
	buf.Reset()
	if err := NewExporter(src, nil).ExportUser(context.Background(), uidA, &buf); err != nil {
		t.Fatal(err)
	}
	if len(src.afters) != 2 || src.afters[0] != "" || src.afters[1] != src.consents[exportPage-1].ID {
		t.Errorf("page cursors = %q", src.afters)
	}
	var out struct {
		Consents []ExportedConsent `json:"consents"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil || len(out.Consents) != exportPage+1 {
		t.Fatalf("export is not the full log: %d rows, %v", len(out.Consents), err)
	}
}
