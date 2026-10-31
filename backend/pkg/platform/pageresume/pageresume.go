// Package pageresume is the resume rule for paging a bounded id array that changes between two pages (ADR-0024 D6, reused by
// ADR-0030 for list members). The array is held newest last, a page is a slice counted from the newest end (position 0 =
// newest), and the cursor remembers where the next page starts in three ways, so an add, a remove, a re-add or a trim between
// two pages neither skips nor repeats a row. Pure: no I/O.
package pageresume

// Anchor is the cursor of such a page sequence.
type Anchor struct {
	// Next is the first id not yet scanned (the entry just older than Last).
	Next string
	// Last is the last id the previous page scanned, kept or dropped.
	Last string
	// NextIndex is Next's position counted from the newest end (0 = newest) when the token was issued: the last
	// fallback, used only when both anchors are gone.
	NextIndex int
}

// Index is the position, counted from the newest end of items (0 = newest), where the next page starts. items is newest last,
// as stored. A position at or past len(items) means the sequence has ended.
//
//  1. Next, when it is still in items and sits OLDER than Last (or Last is gone): resume at it.
//  2. Else Last, when it is still in items: resume at the entry just older than it.
//  3. Else the recorded offset from the newest end.
//
// Why: a trim only removes the oldest entries, so the anchors never move relative to each other; a removal of Next is rule 2
// landing exactly where Next stood; a re-add of Next moves it above Last (newer), which rule 1 refuses, so it is not shown
// twice. Two changes at the boundary in one window can skip or repeat the rows changed there, no more.
func Index(items []string, a Anchor) int {
	n := len(items)
	pos := func(id string) int { // position from the newest end, -1 when absent
		for i := n - 1; i >= 0; i-- {
			if items[i] == id {
				return n - 1 - i
			}
		}
		return -1
	}
	pn, pl := pos(a.Next), pos(a.Last)
	switch {
	case pn >= 0 && (pl < 0 || pn > pl):
		return pn
	case pl >= 0:
		return pl + 1
	default:
		return a.NextIndex
	}
}
