package search

// The people half of the query grammar (ADR-0028 D1 step 4). Steps 1 to 3 are parseQuery (query.go), shared with
// SearchPosts: one parser. The client parser (app/lib/features/search/domain/search_query.dart) applies the same rules
// in the same order and both are checked against testdata/search_query_grammar.json. Nothing here reads Firestore: a
// rejected or unsupported query costs 0 reads.

const (
	// minPrefixLen and maxHandleLen bound a people prefix: handles are 3 to 15 characters, a prefix 2 to 15.
	minPrefixLen = 2
	maxHandleLen = 15
)

// peopleResult is how SearchPeople reads a query; the fixture spells them invalid, too_short, unsupported and prefix.
type peopleResult int

const (
	// peopleInvalid: VALIDATION `query`.
	peopleInvalid peopleResult = iota
	// peopleTooShort: VALIDATION `query` ("too short"), a handle-class rest of one character; `a` and `@a` alike.
	peopleTooShort
	// peopleUnsupported: an empty answer with unsupported_query = true, 0 reads (a `#` sigil, or a rest that is not
	// [a-z0-9_]{1,15}).
	peopleUnsupported
	// peoplePrefix: a handle prefix of 2 to 15 characters; nothing else is searched.
	peoplePrefix
)

// handlePrefix classifies a valid query for SearchPeople and returns the prefix when the result is peoplePrefix.
func (q query) handlePrefix() (peopleResult, string) {
	if q.sigil == '#' || len(q.body) > maxHandleLen || !isHandleClass(q.body) {
		return peopleUnsupported, ""
	}
	if len(q.body) < minPrefixLen {
		return peopleTooShort, ""
	}
	return peoplePrefix, q.body
}

// parsePeopleQuery is parseQuery plus handlePrefix; a query parseQuery refuses is peopleInvalid.
func parsePeopleQuery(raw string) (peopleResult, string) {
	q, err := parseQuery(raw)
	if err != nil {
		return peopleInvalid, ""
	}
	return q.handlePrefix()
}

// isHandleClass reports whether s is non-empty and made only of [a-z0-9_] (pkg/platform/handle's alphabet).
func isHandleClass(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '_' {
			return false
		}
	}
	return true
}
