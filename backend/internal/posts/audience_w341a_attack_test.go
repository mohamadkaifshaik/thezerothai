package posts

// W3-41a tester probes (ADR-0025 note W3-36 L-2) on the timeline's audience: NewSnapshotAudience, whose block test is
// the caller's graph snapshot alone, with the caller's blockedBy set overflowed.

import (
	"errors"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// The ADR says block is decided first: "a P who blocks A is still dropped everywhere". With A's blockedBy overflowed the
// snapshot cannot say whether P blocks A (P is absent from BlockedBy because the set overflowed), so a path that keeps
// the row must not rest on BlockedBy[P] alone. The own-profile surface keeps A's REPOST of P as a PROTECTED row, which
// shows P's author snapshot to a user P may block.
func TestW341aAttack_OwnProfileRepostWithBlockedByOverflow(t *testing.T) {
	const viewer, prot = "uid-viewer", "uid-prot"
	p := post("2", viewer)
	p.Kind, p.RepostOfID, p.EmbeddedAuthorID = KindRepost, "1", prot
	p.Embedded = &Embedded{PostID: "1", Author: AuthorSnapshot{UserID: prot, Handle: "prot"}, Text: "secret"}

	aud := NewSnapshotAudience(&fakeProtected{set: fakeSet{prot: true}})
	snap := graph.Snapshot{BlockedByOverflow: true} // P blocks the viewer, but the overflowed set does not list P
	d, err := aud.Decide(t.Context(), viewer, snap, p, SurfaceOwnProfile)
	if err != nil {
		t.Fatal(err)
	}
	if d.Verdict == Show {
		t.Errorf("own REPOST of P kept (verdict %v, embed %v) although the viewer's blockedBy overflowed: block is not decided first", d.Verdict, d.Embed)
	}
}

// A protected-set error is an error on both owner surfaces, for every REPOST/QUOTE shape: never Show, never Withheld.
func TestW341aAttack_OwnSurfacesFailClosedOnSetError(t *testing.T) {
	const viewer, prot, other = "uid-viewer", "uid-prot", "uid-other"
	boom := errors.New("set unavailable")
	repost := func(author string) *Post {
		p := post("2", author)
		p.Kind, p.RepostOfID, p.EmbeddedAuthorID = KindRepost, "1", prot
		p.Embedded = &Embedded{PostID: "1", Author: AuthorSnapshot{UserID: prot, Handle: "prot"}, Text: "secret"}
		return p
	}
	quote := repost(other)
	quote.Kind = KindQuote
	for _, tc := range []struct {
		name string
		p    *Post
		surf Surface
	}{
		{"own list, REPOST by R of P", repost(other), SurfaceOwnList},
		{"own list, QUOTE by R of P", quote, SurfaceOwnList},
		{"own list, post by P", post("1", prot), SurfaceOwnList},
		{"own profile, own REPOST of P", repost(viewer), SurfaceOwnProfile},
	} {
		t.Run(tc.name, func(t *testing.T) {
			aud := NewSnapshotAudience(&fakeProtected{err: boom})
			d, err := aud.Decide(t.Context(), viewer, graph.Snapshot{}, tc.p, tc.surf)
			if err == nil {
				t.Fatalf("verdict %v, want the set error", d.Verdict)
			}
		})
	}
}

// A REPOST by R of P in the caller's own list: Withheld whichever of R and P is protected, never Show, and a P who
// blocks the caller is a Drop (block first) when the block is in the snapshot. (A mute of P is blockCause's job in
// engagement, covered by the emulator tests, not Decide's.)
func TestW341aAttack_OwnListRepostByOtherShapes(t *testing.T) {
	const viewer, prot, r = "uid-viewer", "uid-prot", "uid-r"
	repost := post("2", r)
	repost.Kind, repost.RepostOfID, repost.EmbeddedAuthorID = KindRepost, "1", prot
	repost.Embedded = &Embedded{PostID: "1", Author: AuthorSnapshot{UserID: prot, Handle: "prot"}, Text: "secret"}
	for _, tc := range []struct {
		name string
		set  fakeSet
		snap graph.Snapshot
		want Verdict
	}{
		{"P protected, caller unapproved", fakeSet{prot: true}, graph.Snapshot{}, Withheld},
		{"R protected, P public, caller does not follow R", fakeSet{r: true}, graph.Snapshot{}, Withheld},
		{"both protected", fakeSet{r: true, prot: true}, graph.Snapshot{}, Withheld},
		{"P protected, caller follows P only", fakeSet{prot: true}, following(prot), Show},
		{"P protected, P blocks caller", fakeSet{prot: true}, graph.Snapshot{BlockedBy: map[string]bool{prot: true}}, Drop},
		{"P protected, caller blocks R", fakeSet{prot: true}, graph.Snapshot{Blocked: map[string]bool{r: true}}, Drop},
		{"nobody protected", fakeSet{}, graph.Snapshot{}, Show},
	} {
		t.Run(tc.name, func(t *testing.T) {
			aud := NewSnapshotAudience(&fakeProtected{set: tc.set})
			d, err := aud.Decide(t.Context(), viewer, tc.snap, repost, SurfaceOwnList)
			if err != nil {
				t.Fatal(err)
			}
			if d.Verdict != tc.want {
				t.Errorf("verdict = %v, want %v", d.Verdict, tc.want)
			}
		})
	}
}
