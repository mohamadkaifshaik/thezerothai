package location

import (
	"bytes"
	_ "embed" // the area catalogue is compiled into the binary
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"sync"
	"unicode/utf8"
)

// The catalogue limits (design section 2.2). A bigger catalogue needs a design change (client paging, wire size).
const (
	// MaxAreas is the most entries the catalogue may hold.
	MaxAreas = 800
	// MaxCatalogBytes is the most bytes areas.json may take (CRLF counted as LF).
	MaxCatalogBytes = 160 * 1024
	// MaxNeighbours is the most curated neighbours an AREA may list.
	MaxNeighbours = 8
	// MaxNameRunes bounds a name and an alias (code points).
	MaxNameRunes = 40
	// MaxAliases is the most aliases one entry may carry.
	MaxAliases = 8
)

var (
	cityIDRe = regexp.MustCompile(`^in\.[a-z0-9]{2,12}$`)
	areaIDRe = regexp.MustCompile(`^in\.[a-z0-9]{2,12}\.[a-z0-9-]{2,40}$`)
)

//go:embed areas/areas.json
var embeddedAreas []byte

// ValidIDFormat reports whether id matches the city or neighbourhood id grammar (no lookup). Checked before any catalogue
// lookup so a malformed value is refused without being echoed.
func ValidIDFormat(id string) bool {
	return cityIDRe.MatchString(id) || areaIDRe.MatchString(id)
}

// catalogFile is the areas.json shape.
type catalogFile struct {
	Version int64       `json:"version"`
	Areas   []areaEntry `json:"areas"`
}

type areaEntry struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Kind       Kind     `json:"kind"`
	City       string   `json:"city"`
	Aliases    []string `json:"aliases"`
	Neighbours []string `json:"neighbours"`
	Retired    bool     `json:"retired"`
}

// StaticCatalog is the parsed, validated catalogue. It is immutable after ParseCatalog and safe for concurrent use.
type StaticCatalog struct {
	version int64
	areas   []Area // sorted by ID
	byID    map[string]int
}

var _ Catalog = (*StaticCatalog)(nil)

var (
	defaultOnce sync.Once
	defaultCat  *StaticCatalog
	defaultErr  error
)

// DefaultCatalog parses the embedded areas.json once. A parse or validation error fails boot (apiserver.Build returns
// it); the catalogue unit test catches it first.
func DefaultCatalog() (*StaticCatalog, error) {
	defaultOnce.Do(func() { defaultCat, defaultErr = ParseCatalog(embeddedAreas) })
	return defaultCat, defaultErr
}

// normalizeEOL turns CRLF into LF: a Windows checkout (core.autocrlf) holds areas.json with CRLF, CI with LF, and the
// size cap and the content hash must agree on both.
func normalizeEOL(b []byte) []byte { return bytes.ReplaceAll(b, []byte("\r\n"), []byte("\n")) }

// ParseCatalog decodes and validates a catalogue: the version, the id grammar, sorted unique ids, kinds, names and aliases,
// the CITY/AREA structure and the neighbour rules (symmetric, no self-reference, existing AREA ids of the same city, at
// most MaxNeighbours; a CITY has none), and the size caps.
func ParseCatalog(data []byte) (*StaticCatalog, error) {
	data = normalizeEOL(data)
	if len(data) > MaxCatalogBytes {
		return nil, fmt.Errorf("location: catalogue is %d bytes, above %d", len(data), MaxCatalogBytes)
	}
	var f catalogFile
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&f); err != nil {
		return nil, fmt.Errorf("location: decode catalogue: %w", err)
	}
	if f.Version < 1 {
		return nil, fmt.Errorf("location: catalogue version must be >= 1 (got %d)", f.Version)
	}
	if len(f.Areas) == 0 || len(f.Areas) > MaxAreas {
		return nil, fmt.Errorf("location: catalogue holds %d areas, want 1..%d", len(f.Areas), MaxAreas)
	}
	byID := make(map[string]int, len(f.Areas))
	for i, e := range f.Areas {
		if i > 0 && f.Areas[i-1].ID >= e.ID {
			return nil, fmt.Errorf("location: area %q is out of order or duplicated (areas must be sorted by id)", e.ID)
		}
		byID[e.ID] = i
	}
	for _, e := range f.Areas {
		if err := validateEntry(e, f.Areas, byID); err != nil {
			return nil, err
		}
	}
	c := &StaticCatalog{version: f.Version, areas: make([]Area, len(f.Areas)), byID: byID}
	for i, e := range f.Areas {
		city := f.Areas[byID[e.City]]
		c.areas[i] = Area{
			ID: e.ID, Name: e.Name, Kind: e.Kind, CityID: e.City, CityName: city.Name,
			Aliases: nonNil(e.Aliases), Neighbours: nonNil(e.Neighbours), Retired: e.Retired,
		}
	}
	return c, nil
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func validName(s string) bool {
	n := utf8.RuneCountInString(s)
	return utf8.ValidString(s) && n >= 1 && n <= MaxNameRunes
}

func validateEntry(e areaEntry, all []areaEntry, byID map[string]int) error {
	if !validName(e.Name) {
		return fmt.Errorf("location: area %q: name must be 1-%d code points", e.ID, MaxNameRunes)
	}
	if len(e.Aliases) > MaxAliases {
		return fmt.Errorf("location: area %q: at most %d aliases", e.ID, MaxAliases)
	}
	for _, a := range e.Aliases {
		if !validName(a) {
			return fmt.Errorf("location: area %q: alias must be 1-%d code points", e.ID, MaxNameRunes)
		}
	}
	switch e.Kind {
	case KindCity:
		if !cityIDRe.MatchString(e.ID) {
			return fmt.Errorf("location: city id %q does not match %s", e.ID, cityIDRe)
		}
		if e.City != e.ID {
			return fmt.Errorf("location: city %q: city must equal its own id", e.ID)
		}
		if len(e.Neighbours) > 0 {
			return fmt.Errorf("location: city %q: a CITY has no neighbours", e.ID)
		}
		return nil
	case KindArea:
	default:
		return fmt.Errorf("location: area %q: kind %q is neither AREA nor CITY", e.ID, e.Kind)
	}
	if !areaIDRe.MatchString(e.ID) {
		return fmt.Errorf("location: area id %q does not match %s", e.ID, areaIDRe)
	}
	ci, ok := byID[e.City]
	if !ok || all[ci].Kind != KindCity {
		return fmt.Errorf("location: area %q: city %q is not a CITY entry", e.ID, e.City)
	}
	if len(e.ID) <= len(e.City)+1 || e.ID[:len(e.City)+1] != e.City+"." {
		return fmt.Errorf("location: area %q: id must start with its city %q", e.ID, e.City)
	}
	if len(e.Neighbours) > MaxNeighbours {
		return fmt.Errorf("location: area %q: at most %d neighbours", e.ID, MaxNeighbours)
	}
	seen := map[string]bool{}
	for _, n := range e.Neighbours {
		switch ni, ok := byID[n]; {
		case n == e.ID:
			return fmt.Errorf("location: area %q lists itself as a neighbour", e.ID)
		case seen[n]:
			return fmt.Errorf("location: area %q lists neighbour %q twice", e.ID, n)
		case !ok:
			return fmt.Errorf("location: area %q: neighbour %q does not exist", e.ID, n)
		case all[ni].Kind != KindArea:
			return fmt.Errorf("location: area %q: neighbour %q is not an AREA", e.ID, n)
		case !contains(all[ni].Neighbours, e.ID):
			return fmt.Errorf("location: area %q: neighbour %q does not list it back (the relation is symmetric)", e.ID, n)
		}
		seen[n] = true
	}
	return nil
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// Lookup implements Catalog.
func (c *StaticCatalog) Lookup(id string) (Area, bool) {
	i, ok := c.byID[id]
	if !ok {
		return Area{}, false
	}
	return c.areas[i], true
}

// Pickable implements Catalog.
func (c *StaticCatalog) Pickable(id string) bool {
	a, ok := c.Lookup(id)
	return ok && !a.Retired
}

// Version implements Catalog.
func (c *StaticCatalog) Version() int64 { return c.version }

// Len is the number of entries, retired included.
func (c *StaticCatalog) Len() int { return len(c.areas) }

// Page returns at most limit areas with an id after `after` ("" = from the start), in id order, and whether more follow.
func (c *StaticCatalog) Page(after string, limit int) ([]Area, bool) {
	start := 0
	if after != "" {
		start = sort.Search(len(c.areas), func(i int) bool { return c.areas[i].ID > after })
	}
	end := min(start+max(limit, 0), len(c.areas))
	return c.areas[start:end], end < len(c.areas)
}
