//go:build integration

package beacons

import (
	"context"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
)

// TestRepo_ListByAudienceActivityFilter (F29): per activity and per audience, the filter is in the query, so a filtered
// page is full when enough matches exist further on (no client-side emptying), it resumes after (startAt, id), cancelled
// beacons stay out, and an empty activity keeps the unfiltered behaviour.
func TestRepo_ListByAudienceActivityFilter(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	// Each audience gets, an hour apart: meal, coffee, meal, coffee, meal, coffee (cancelled), walk.
	activities := []Activity{ActivityMeal, ActivityCoffee, ActivityMeal, ActivityCoffee, ActivityMeal, ActivityCoffee, ActivityWalk}
	type audience struct {
		name string
		cid  string
	}
	byAudience := map[string]map[Activity][]string{}
	for ai, aud := range []audience{{"community", itCommunity}, {"public", ""}} {
		byAudience[aud.name] = map[Activity][]string{}
		for i, act := range activities {
			b := e.beaconAt("org-act", aud.cid, e.now.Add(time.Duration(i+1)*time.Hour))
			b.Activity = act
			got := e.create(t, "org-act", fmt.Sprintf("integration-key-act%d%02d", ai, i), b).Beacon
			if i == 5 {
				e.setField(t, got.ID, firestore.Update{Path: "status", Value: string(StatusCancelled)})
				continue
			}
			byAudience[aud.name][act] = append(byAudience[aud.name][act], got.ID)
		}
	}
	for _, aud := range []audience{{"community", itCommunity}, {"public", ""}} {
		for _, tc := range []struct {
			activity Activity
			want     int
		}{{ActivityMeal, 3}, {ActivityCoffee, 2}, {ActivityWalk, 1}, {ActivityStudy, 0}, {"", 6}} {
			t.Run(fmt.Sprintf("%s/%q", aud.name, tc.activity), func(t *testing.T) {
				rows, err := e.repo.ListByAudience(ctx, ListQuery{CommunityID: aud.cid, Activity: tc.activity, From: e.now, Limit: 10})
				if err != nil {
					t.Fatal(err)
				}
				if len(rows) != tc.want {
					t.Fatalf("rows = %v, want %d", idsOf(rows), tc.want)
				}
				for _, b := range rows {
					if b.CommunityID != aud.cid || (tc.activity != "" && b.Activity != tc.activity) {
						t.Fatalf("row %s: community %q activity %q", b.ID, b.CommunityID, b.Activity)
					}
				}
				if tc.activity != "" && fmt.Sprint(idsOf(rows)) != fmt.Sprint(byAudience[aud.name][tc.activity]) {
					t.Fatalf("rows = %v, want %v (soonest first)", idsOf(rows), byAudience[aud.name][tc.activity])
				}
			})
		}
	}
	t.Run("filtered paging resumes after the last row", func(t *testing.T) {
		want := byAudience["community"][ActivityMeal]
		page1, err := e.repo.ListByAudience(ctx, ListQuery{CommunityID: itCommunity, Activity: ActivityMeal, From: e.now, Limit: 2})
		if err != nil || fmt.Sprint(idsOf(page1)) != fmt.Sprint(want[:2]) {
			t.Fatalf("page 1 = %v, %v, want %v", idsOf(page1), err, want[:2])
		}
		last := page1[len(page1)-1]
		page2, err := e.repo.ListByAudience(ctx, ListQuery{CommunityID: itCommunity, Activity: ActivityMeal, From: e.now, AfterStartAt: last.StartAt, AfterID: last.ID, Limit: 2})
		if err != nil || fmt.Sprint(idsOf(page2)) != fmt.Sprint(want[2:]) {
			t.Fatalf("page 2 = %v, %v, want %v", idsOf(page2), err, want[2:])
		}
	})
}
