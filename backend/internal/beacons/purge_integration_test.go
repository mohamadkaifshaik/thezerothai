//go:build integration

package beacons

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// seedParticipant writes beacons/{id}/beaconParticipants/{uid} and the matching users/{uid}/beaconMemberships/{id} row.
func (e *repoEnv) seedParticipant(t *testing.T, beaconID, uid, state string, b Beacon) {
	t.Helper()
	ctx := context.Background()
	if _, err := e.client.Collection(beaconsCollection).Doc(beaconID).Collection(participantsSubcollection).Doc(uid).Set(ctx, map[string]any{"uid": uid, "state": state, "requestedAt": e.now}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.membershipRef(uid, beaconID).Set(ctx, membershipDoc{BeaconID: beaconID, Role: RoleParticipant, State: state, CommunityID: b.CommunityID, StartAt: b.StartAt, EndAt: b.EndAt}); err != nil {
		t.Fatal(err)
	}
}

// TestPurge_ErasesEveryTraceOfTheUser (R4): the user's organised beacons go with their participant docs, the user's
// participant docs on other beacons go, the user's membership rows go; other users' beacons, participant docs and
// membership rows (even those pointing at the erased beacons) survive, and nothing left names the uid.
func TestPurge_ErasesEveryTraceOfTheUser(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const doomed, friend, other = "doomed", "friend", "other"
	own1 := e.create(t, doomed, "integration-key-own1", e.beaconAt(doomed, itCommunity, e.now.Add(time.Hour))).Beacon
	own2 := e.create(t, doomed, "integration-key-own2", e.beaconAt(doomed, "", e.now.Add(2*time.Hour))).Beacon
	e.seedParticipant(t, own1.ID, friend, "accepted", own1)
	e.seedParticipant(t, own1.ID, other, "requested", own1)
	var friends []Beacon
	for i := range 3 {
		fb := e.create(t, friend, fmt.Sprintf("integration-key-fr%d", i), e.beaconAt(friend, "", e.now.Add(time.Duration(i+3)*time.Hour))).Beacon
		e.seedParticipant(t, fb.ID, doomed, "accepted", fb)
		e.seedParticipant(t, fb.ID, other, "accepted", fb)
		friends = append(friends, fb)
	}

	er := NewEraser(e.repo)
	var cp Checkpoint
	done := false
	for i := 0; !done; i++ {
		var err error
		cp, done, err = er.PurgeUser(ctx, doomed, cp)
		if err != nil {
			t.Fatalf("PurgeUser %d: %v", i, err)
		}
		if i > 10 {
			t.Fatal("eraser did not finish")
		}
	}

	exists := func(ref *firestore.DocumentRef) bool {
		_, err := ref.Get(ctx)
		return err == nil
	}
	for _, id := range []string{own1.ID, own2.ID} {
		if exists(e.client.Collection(beaconsCollection).Doc(id)) {
			t.Errorf("own beacon %s survived", id)
		}
		if exists(e.client.Collection(beaconsCollection).Doc(id).Collection(participantsSubcollection).Doc(friend)) {
			t.Errorf("participant doc under own beacon %s survived", id)
		}
	}
	for _, fb := range friends {
		if !exists(e.client.Collection(beaconsCollection).Doc(fb.ID)) {
			t.Errorf("friend's beacon %s was deleted", fb.ID)
		}
		if exists(e.client.Collection(beaconsCollection).Doc(fb.ID).Collection(participantsSubcollection).Doc(doomed)) {
			t.Errorf("doomed's participant doc on %s survived", fb.ID)
		}
		if !exists(e.client.Collection(beaconsCollection).Doc(fb.ID).Collection(participantsSubcollection).Doc(other)) {
			t.Errorf("other's participant doc on %s was deleted", fb.ID)
		}
	}
	rows, err := e.client.Collection(usersCollection).Doc(doomed).Collection(membershipsSubcollection).Documents(ctx).GetAll()
	if err != nil || len(rows) != 0 {
		t.Errorf("doomed membership rows left = %d, %v", len(rows), err)
	}
	// Friend's rows survive, the one pointing at own1 dangles without a uid (R3).
	if !exists(e.repo.membershipRef(friend, own1.ID)) || !exists(e.repo.membershipRef(friend, friends[0].ID)) {
		t.Error("friend's membership rows were deleted")
	}
	// Residue sweep: no document in the three collections names the uid in a field or in its id.
	all, err := e.client.Collection(beaconsCollection).Documents(ctx).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range all {
		if strings.Contains(fmt.Sprint(d.Data()), doomed) || strings.Contains(d.Ref.ID, doomed) {
			t.Errorf("beacon %s still names %s: %v", d.Ref.ID, doomed, d.Data())
		}
	}
	for _, col := range []string{participantsSubcollection, membershipsSubcollection} {
		docs, err := e.client.CollectionGroup(col).Documents(ctx).GetAll()
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range docs {
			if strings.Contains(fmt.Sprint(d.Data()), doomed) || strings.Contains(d.Ref.ID, doomed) || strings.Contains(d.Ref.Path, "/"+doomed+"/") {
				t.Errorf("%s doc %s still names %s", col, d.Ref.Path, doomed)
			}
		}
	}
	// A rerun writes nothing and finishes in two calls.
	cp, done, err = er.PurgeUser(ctx, doomed, Checkpoint{})
	if err != nil || done {
		t.Fatalf("rerun step 1 = %+v %v %v", cp, done, err)
	}
	if _, done, err = er.PurgeUser(ctx, doomed, cp); err != nil || !done {
		t.Fatalf("rerun step 2 = %v %v", done, err)
	}
}

// TestPurge_AdjustsCountsForAcceptedRows (R12, Review Focus 5): erasing an ACCEPTED participant decrements the beacon's
// acceptedCount and reopens a FULL beacon; erasing a mere requester leaves the beacon untouched; a rerun is a no-op.
func TestPurge_AdjustsCountsForAcceptedRows(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const doomed, host = "doomed-c", "host-c"
	full := e.beaconAt(host, "", e.now.Add(time.Hour))
	full.OpenSpots = 1
	fb := e.create(t, host, "integration-key-pc1", full).Beacon
	e.mustRequest(t, doomed, "integration-key-pc2", fb.ID)
	if _, err := e.respond(host, "integration-key-pc3", fb.ID, doomed, true, e.now); err != nil {
		t.Fatal(err)
	}
	rb := e.create(t, host, "integration-key-pc4", e.beaconAt(host, "", e.now.Add(2*time.Hour))).Beacon
	e.mustRequest(t, doomed, "integration-key-pc5", rb.ID)
	e.mustRequest(t, "other-c", "integration-key-pc6", rb.ID)
	// A cancelled FULL beacon with doomed accepted: the erasure must not resurrect it.
	cin := e.beaconAt(host, "", e.now.Add(3*time.Hour))
	cin.OpenSpots = 1
	cb := e.create(t, host, "integration-key-pc7", cin).Beacon
	e.mustRequest(t, doomed, "integration-key-pc8", cb.ID)
	if _, err := e.respond(host, "integration-key-pc9", cb.ID, doomed, true, e.now); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.Cancel(ctx, CancelParams{UID: host, BeaconID: cb.ID, IdemKey: idempotency.Key(host, rpcCancelBeacon, "integration-key-pca"), RequestHash: "h", Now: e.now}); err != nil {
		t.Fatal(err)
	}

	er := NewEraser(e.repo)
	var cp Checkpoint
	for done := false; !done; {
		var err error
		if cp, done, err = er.PurgeUser(ctx, doomed, cp); err != nil {
			t.Fatal(err)
		}
	}
	got, err := e.repo.Get(ctx, fb.ID)
	if err != nil || got.AcceptedCount != 0 || got.Status != StatusOpen {
		t.Fatalf("full beacon after erasure = count %d status %q, %v; want 0 open", got.AcceptedCount, got.Status, err)
	}
	if _, err := e.repo.GetParticipant(ctx, fb.ID, doomed); !errors.Is(err, ErrNotFound) {
		t.Fatalf("doomed's accepted row survived: %v", err)
	}
	rgot, err := e.repo.Get(ctx, rb.ID)
	if err != nil || rgot.AcceptedCount != 0 || rgot.Status != StatusOpen {
		t.Fatalf("requested-only beacon changed: count %d status %q, %v", rgot.AcceptedCount, rgot.Status, err)
	}
	if _, err := e.repo.GetParticipant(ctx, rb.ID, "other-c"); err != nil {
		t.Fatalf("another requester's row was deleted: %v", err)
	}
	cgot, err := e.repo.Get(ctx, cb.ID)
	if err != nil || cgot.Status != StatusCancelled || cgot.AcceptedCount != 0 {
		t.Fatalf("cancelled beacon after erasure = status %q count %d, %v; want cancelled 0", cgot.Status, cgot.AcceptedCount, err)
	}
	if _, done, err := er.PurgeUser(ctx, doomed, Checkpoint{Phase: phaseMemberships}); err != nil || !done {
		t.Fatalf("rerun = %v %v", done, err)
	}
	if got, _ := e.repo.Get(ctx, fb.ID); got.AcceptedCount != 0 {
		t.Fatalf("rerun changed the count: %d", got.AcceptedCount)
	}
}

// TestPurge_ManyParticipantsStayUnderTheBatchLimit: a beacon with more participant docs than one batch may hold is
// deleted across calls (participant pages first, the beacon and the organiser's row only once the last page is short),
// every batch stays under Firestore's 500 writes, and no participant doc is left under a deleted parent.
func TestPurge_ManyParticipantsStayUnderTheBatchLimit(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const org = "org-big"
	b := e.create(t, org, "integration-key-big", e.beaconAt(org, "", e.now.Add(time.Hour))).Beacon
	col := e.client.Collection(beaconsCollection).Doc(b.ID).Collection(participantsSubcollection)
	const total = participantsPage + 102
	for i := range total {
		uid := fmt.Sprintf("p-%04d", i)
		if _, err := col.Doc(uid).Set(ctx, map[string]any{"uid": uid, "state": "requested"}); err != nil {
			t.Fatal(err)
		}
	}
	count := func() int {
		docs, err := col.Select().Documents(ctx).GetAll()
		if err != nil {
			t.Fatal(err)
		}
		return len(docs)
	}
	deleted, more, err := e.repo.PurgeOrganisedPage(ctx, org)
	if err != nil || deleted != 0 || !more {
		t.Fatalf("call 1 = %d, %v, %v; want 0 beacons, more, nil", deleted, more, err)
	}
	if _, err := e.client.Collection(beaconsCollection).Doc(b.ID).Get(ctx); err != nil {
		t.Fatalf("beacon deleted before its participant docs: %v", err)
	}
	if n := count(); n != total-participantsPage {
		t.Fatalf("participant docs after call 1 = %d, want %d", n, total-participantsPage)
	}
	deleted, more, err = e.repo.PurgeOrganisedPage(ctx, org)
	if err != nil || deleted != 1 || more {
		t.Fatalf("call 2 = %d, %v, %v; want 1 beacon, no more, nil", deleted, more, err)
	}
	if _, err := e.client.Collection(beaconsCollection).Doc(b.ID).Get(ctx); err == nil {
		t.Fatal("beacon survived call 2")
	}
	if n := count(); n != 0 {
		t.Fatalf("participant docs left under the deleted parent = %d", n)
	}
	if _, err := e.repo.membershipRef(org, b.ID).Get(ctx); err == nil {
		t.Fatal("organiser membership row survived")
	}
}

// TestExport_MembershipsCarryOwnParticipantRow (D03): each membership row carries the user's own participant note and
// times (one GetAll per page); another participant's row on the same beacon never reaches the export.
func TestExport_MembershipsCarryOwnParticipantRow(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const me, other, host = "me-d03", "other-d03", "host-d03"
	hb := e.create(t, host, "integration-key-d03a", e.beaconAt(host, "", e.now.Add(time.Hour))).Beacon
	nb := e.create(t, host, "integration-key-d03b", e.beaconAt(host, "", e.now.Add(2*time.Hour))).Beacon
	responded := e.now.Add(time.Minute)
	for _, row := range []struct {
		beacon, uid, note string
		responded         time.Time
	}{
		{hb.ID, me, "my own note", responded},
		{hb.ID, other, "another person's note", responded},
	} {
		if _, err := e.repo.participantRef(row.beacon, row.uid).Set(ctx, participantDoc{
			UID: row.uid, State: PStateAccepted, Note: row.note, RequestedAt: e.now, RespondedAt: row.responded, ExpireAt: hb.ExpireAt,
		}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.repo.membershipRef(me, hb.ID).Set(ctx, membershipDoc{BeaconID: hb.ID, Role: RoleParticipant, State: PStateAccepted, StartAt: hb.StartAt, EndAt: hb.EndAt}); err != nil {
		t.Fatal(err)
	}
	// A membership row with no participant row (stale or partially purged) exports with empty fields.
	if _, err := e.repo.membershipRef(me, nb.ID).Set(ctx, membershipDoc{BeaconID: nb.ID, Role: RoleRequester, State: PStateRequested, StartAt: nb.StartAt, EndAt: nb.EndAt}); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := NewExporter(e.repo).ExportUser(ctx, me, &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Memberships []ExportedMembership `json:"memberships"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, buf.String())
	}
	got := map[string]ExportedMembership{}
	for _, m := range out.Memberships {
		got[m.BeaconID] = m
	}
	if m := got[hb.ID]; m.Note != "my own note" || m.RequestedAt == nil || !m.RequestedAt.Equal(e.now) || m.RespondedAt == nil || !m.RespondedAt.Equal(responded) {
		t.Errorf("participant membership = %+v", m)
	}
	if m, ok := got[nb.ID]; !ok || m.Note != "" || m.RequestedAt != nil || m.RespondedAt != nil {
		t.Errorf("membership without a participant row = %+v (present %v)", m, ok)
	}
	if s := buf.String(); strings.Contains(s, "another person's note") || strings.Contains(s, other) || strings.Contains(s, host) {
		t.Fatalf("export leaks another user's data: %s", s)
	}
}

// TestExport_WritesOrganisedBeaconsAndMemberships: the friend's export carries their 3 beacons and 2 memberships.
func TestExport_WritesOrganisedBeaconsAndMemberships(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const friend, host = "friend-x", "host-x"
	for i := range 3 {
		e.create(t, friend, fmt.Sprintf("integration-key-ex%d", i), e.beaconAt(friend, "", e.now.Add(time.Duration(i+1)*time.Hour)))
	}
	hb := e.create(t, host, "integration-key-host", e.beaconAt(host, itCommunity, e.now.Add(time.Hour))).Beacon
	e.seedParticipant(t, hb.ID, friend, "accepted", hb)
	var buf bytes.Buffer
	if err := NewExporter(e.repo).ExportUser(ctx, friend, &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Beacons     []ExportedBeacon     `json:"beacons"`
		Memberships []ExportedMembership `json:"memberships"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, buf.String())
	}
	if len(out.Beacons) != 3 || out.Beacons[0].Title != "Coffee" || out.Beacons[0].Status != string(StatusOpen) {
		t.Fatalf("beacons = %+v", out.Beacons)
	}
	// 3 organiser rows + 1 participant row.
	if len(out.Memberships) != 4 {
		t.Fatalf("memberships = %+v", out.Memberships)
	}
	participant := 0
	for _, m := range out.Memberships {
		if m.Role == RoleParticipant && m.BeaconID == hb.ID && m.CommunityID == itCommunity {
			participant++
		}
	}
	if participant != 1 {
		t.Fatalf("participant membership rows = %d, want 1", participant)
	}
	if strings.Contains(buf.String(), host) {
		t.Fatal("export names another user's uid")
	}
}
