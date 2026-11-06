//go:build integration

package beacons

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
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
