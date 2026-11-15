package location

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// rulesFixture is the shared testdata/location/area_rules.json (also read by the app's area_search tests).
var rulesFixture = filepath.Join("..", "..", "..", "testdata", "location", "area_rules.json")

func mustCatalog(t *testing.T) *StaticCatalog {
	t.Helper()
	c, err := DefaultCatalog()
	if err != nil {
		t.Fatalf("the embedded catalogue does not load (boot would fail): %v", err)
	}
	return c
}

// TestCatalog_EmbeddedIsValid: the shipped areas.json parses and validates (every structural rule lives in ParseCatalog),
// is within the caps, and every CITY has at least one neighbourhood.
func TestCatalog_EmbeddedIsValid(t *testing.T) {
	c := mustCatalog(t)
	if c.Len() == 0 || c.Len() > MaxAreas {
		t.Fatalf("catalogue holds %d areas, want 1..%d", c.Len(), MaxAreas)
	}
	if n := len(normalizeEOL(embeddedAreas)); n > MaxCatalogBytes {
		t.Fatalf("areas.json is %d bytes, above %d", n, MaxCatalogBytes)
	}
	hoods := map[string]int{}
	all, _ := c.Page("", MaxAreas)
	for _, a := range all {
		if a.Kind == KindArea {
			hoods[a.CityID]++
		}
	}
	for _, a := range all {
		if a.Kind == KindCity && hoods[a.ID] == 0 {
			t.Errorf("city %s has no neighbourhoods", a.ID)
		}
		if a.Kind == KindArea && (a.CityName == "" || a.CityName == a.Name && a.CityID != a.ID) {
			t.Errorf("area %s: city name %q not resolved", a.ID, a.CityName)
		}
	}
}

// TestCatalog_IDsLock: ids.lock is append-only and matches areas.json both ways (an id is never deleted or renamed).
func TestCatalog_IDsLock(t *testing.T) {
	c := mustCatalog(t)
	raw, err := os.ReadFile(filepath.Join("areas", "ids.lock"))
	if err != nil {
		t.Fatal(err)
	}
	locked := map[string]bool{}
	for _, line := range strings.Split(string(normalizeEOL(raw)), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			if locked[line] {
				t.Errorf("ids.lock lists %s twice", line)
			}
			locked[line] = true
			if _, ok := c.Lookup(line); !ok {
				t.Errorf("id %s is in ids.lock but missing from areas.json: ids are permanent (mark it retired instead)", line)
			}
		}
	}
	all, _ := c.Page("", MaxAreas)
	for _, a := range all {
		if !locked[a.ID] {
			t.Errorf("id %s is in areas.json but not in ids.lock: append it there", a.ID)
		}
	}
}

// TestCatalog_VersionHash: areas.sha256 holds one "<version> <sha256 of areas.json>" line per catalogue version, versions
// strictly increasing. A content change without a new line (and so without a version bump) fails, and so does a version
// in areas.json that is not the last line's.
func TestCatalog_VersionHash(t *testing.T) {
	c := mustCatalog(t)
	raw, err := os.ReadFile(filepath.Join("areas", "areas.sha256"))
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(normalizeEOL(embeddedAreas))
	got := hex.EncodeToString(sum[:])
	var lastVersion int64
	var lastHash string
	for _, line := range strings.Split(strings.TrimSpace(string(normalizeEOL(raw))), "\n") {
		parts := strings.Fields(line)
		if len(parts) != 2 {
			t.Fatalf("areas.sha256 line %q: want \"<version> <sha256>\"", line)
		}
		v, err := strconv.ParseInt(parts[0], 10, 64)
		if err != nil || v <= lastVersion {
			t.Fatalf("areas.sha256 versions must increase (got %q after %d)", parts[0], lastVersion)
		}
		lastVersion, lastHash = v, parts[1]
	}
	if lastVersion != c.Version() {
		t.Errorf("areas.json version %d, but areas.sha256 ends at version %d: append \"%d %s\"", c.Version(), lastVersion, c.Version(), got)
	}
	if lastHash != got {
		t.Errorf("areas.json changed (sha256 %s) without a version bump: bump \"version\" and append \"<new version> %s\" to areas.sha256", got, got)
	}
}

// TestValidIDFormat_SharedFixture runs the id cases of testdata/location/area_rules.json.
func TestValidIDFormat_SharedFixture(t *testing.T) {
	raw, err := os.ReadFile(rulesFixture)
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		IDs struct {
			Valid []struct {
				ID   string `json:"id"`
				Kind Kind   `json:"kind"`
			} `json:"valid"`
			Invalid []string `json:"invalid"`
		} `json:"ids"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.IDs.Valid) == 0 || len(fx.IDs.Invalid) == 0 {
		t.Fatal("the fixture has no id cases")
	}
	for _, v := range fx.IDs.Valid {
		re := areaIDRe
		if v.Kind == KindCity {
			re = cityIDRe
		}
		if !ValidIDFormat(v.ID) || !re.MatchString(v.ID) {
			t.Errorf("%q (%s) should be valid", v.ID, v.Kind)
		}
	}
	for _, id := range fx.IDs.Invalid {
		if ValidIDFormat(id) {
			t.Errorf("%q should be invalid", id)
		}
	}
}

// TestParseCatalog_Rejects: each structural rule fails the parse, naming the problem.
func TestParseCatalog_Rejects(t *testing.T) {
	city := `{"id": "in.blr", "name": "Bengaluru", "kind": "CITY", "city": "in.blr", "aliases": [], "neighbours": [], "retired": false}`
	a := func(id, nb string) string {
		return `{"id": "` + id + `", "name": "X", "kind": "AREA", "city": "in.blr", "aliases": [], "neighbours": [` + nb + `], "retired": false}`
	}
	doc := func(version string, areas ...string) []byte {
		return []byte(`{"version": ` + version + `, "areas": [` + strings.Join(areas, ",") + `]}`)
	}
	tests := []struct {
		name string
		data []byte
		want string
	}{
		{"version zero", doc("0", city), "version"},
		{"empty", doc("1"), "holds 0 areas"},
		{"unsorted", doc("1", city, a("in.blr.zz", ""), a("in.blr.aa", "")), "out of order"},
		{"duplicate", doc("1", city, a("in.blr.aa", ""), a("in.blr.aa", "")), "out of order"},
		{"bad id", doc("1", city, a("in.blr.A", "")), "does not match"},
		{"bad kind", doc("1", strings.Replace(city, `"CITY"`, `"TOWN"`, 1)), "neither AREA nor CITY"},
		{"city with neighbours", doc("1", strings.Replace(city, `"neighbours": []`, `"neighbours": ["in.blr.aa"]`, 1), a("in.blr.aa", "")), "no neighbours"},
		{"area without city", doc("1", a("in.blr.aa", "")), "not a CITY"},
		{"self neighbour", doc("1", city, a("in.blr.aa", `"in.blr.aa"`)), "itself"},
		{"missing neighbour", doc("1", city, a("in.blr.aa", `"in.blr.zz"`)), "does not exist"},
		{"city as neighbour", doc("1", city, a("in.blr.aa", `"in.blr"`)), "not an AREA"},
		{"asymmetric", doc("1", city, a("in.blr.aa", `"in.blr.bb"`), a("in.blr.bb", "")), "symmetric"},
		{"duplicate neighbour", doc("1", city, a("in.blr.aa", `"in.blr.bb", "in.blr.bb"`), a("in.blr.bb", `"in.blr.aa"`)), "twice"},
		{"empty name", doc("1", strings.Replace(city, `"Bengaluru"`, `""`, 1)), "name"},
		{"unknown field", doc("1", strings.Replace(city, `"retired"`, `"lat": 1, "retired"`, 1)), "unknown field"},
		{"too big", append(doc("1", city), make([]byte, MaxCatalogBytes)...), "bytes"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ParseCatalog(tt.data)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("ParseCatalog = %v, want an error containing %q", err, tt.want)
			}
		})
	}
	// Nine neighbours: refused before any of them is looked up.
	var nine []string
	for i := 1; i <= 9; i++ {
		nine = append(nine, `"in.blr.n`+strconv.Itoa(i)+`"`)
	}
	if _, err := ParseCatalog(doc("1", city, a("in.blr.aa", strings.Join(nine, ",")))); err == nil || !strings.Contains(err.Error(), "at most 8") {
		t.Errorf("nine neighbours: %v", err)
	}
}

// TestParseCatalog_CRLF: a CRLF checkout parses like LF (the Windows autocrlf case).
func TestParseCatalog_CRLF(t *testing.T) {
	crlf := []byte(strings.ReplaceAll(string(normalizeEOL(embeddedAreas)), "\n", "\r\n"))
	c, err := ParseCatalog(crlf)
	if err != nil || c.Len() != mustCatalog(t).Len() {
		t.Fatalf("CRLF catalogue: %v", err)
	}
}

// TestCatalog_LookupPickablePage: retired areas resolve but are not pickable; Page walks the ids in order.
func TestCatalog_LookupPickablePage(t *testing.T) {
	data := []byte(`{"version": 3, "areas": [
		{"id": "in.blr", "name": "Bengaluru", "kind": "CITY", "city": "in.blr", "aliases": [], "neighbours": [], "retired": false},
		{"id": "in.blr.aa", "name": "Aa", "kind": "AREA", "city": "in.blr", "aliases": ["A"], "neighbours": ["in.blr.bb"], "retired": false},
		{"id": "in.blr.bb", "name": "Bb", "kind": "AREA", "city": "in.blr", "aliases": [], "neighbours": ["in.blr.aa"], "retired": true}]}`)
	c, err := ParseCatalog(data)
	if err != nil {
		t.Fatal(err)
	}
	if c.Version() != 3 || !c.Pickable("in.blr.aa") || c.Pickable("in.blr.bb") || c.Pickable("in.blr.zz") {
		t.Fatalf("version/pickable wrong")
	}
	if b, ok := c.Lookup("in.blr.bb"); !ok || !b.Retired || b.CityName != "Bengaluru" {
		t.Fatalf("retired lookup = %+v, %v", b, ok)
	}
	p1, more := c.Page("", 2)
	if len(p1) != 2 || !more || p1[0].ID != "in.blr" || p1[1].ID != "in.blr.aa" {
		t.Fatalf("page 1 = %v, %v", p1, more)
	}
	p2, more := c.Page(p1[1].ID, 2)
	if len(p2) != 1 || more || p2[0].ID != "in.blr.bb" {
		t.Fatalf("page 2 = %v, %v", p2, more)
	}
	if p, more := c.Page("in.blr.bb", 2); len(p) != 0 || more {
		t.Fatalf("past the end = %v, %v", p, more)
	}
}
