//go:build integration

package beacons

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

const (
	itCommunity = "1234567890123456789"
	itKeyA      = "integration-key-aaaa"
	itKeyB      = "integration-key-bbbb"
)

type repoEnv struct {
	client *firestore.Client
	repo   *FirestoreRepo
	node   *snowflake.Node
	now    time.Time
}

func newRepoEnv(t *testing.T) *repoEnv {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int63()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	repo := NewFirestoreRepo(client, quota.New(client), idempotency.New(client))
	repo.now = func() time.Time { return now }
	return &repoEnv{client: client, repo: repo, node: node, now: now}
}

// beaconAt is a valid beacon (as the service would hand the repo) starting at start.
func (e *repoEnv) beaconAt(uid, communityID string, start time.Time) Beacon {
	return Beacon{
		OrganiserID: uid, CommunityID: communityID, Activity: ActivityCoffee, Title: "Coffee", Venue: "Food court",
		StartAt: start, EndAt: start.Add(25 * time.Minute), DurationMin: 25, OpenSpots: 3,
		Cost: CostEveryonePaysOwn, ChatPref: ChatQuiet,
	}
}

// create writes b with a cap no test reaches; createWithCap is for the cap proofs.
func (e *repoEnv) create(t *testing.T, uid, key string, b Beacon) CreateResult {
	t.Helper()
	return e.createWithCap(t, uid, key, b, 50)
}

func (e *repoEnv) createWithCap(t *testing.T, uid, key string, b Beacon, maxOpen int) CreateResult {
	t.Helper()
	res, err := e.repo.Create(context.Background(), CreateParams{
		UID: uid, ID: e.node.Generate(), IdemKey: idempotency.Key(uid, rpcCreateBeacon, key),
		RequestHash: idempotency.HashRequest("title=" + b.Title + "|start=" + b.StartAt.String()), Beacon: b, MaxOpenPerUser: maxOpen,
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	return res
}

func (e *repoEnv) setField(t *testing.T, id string, updates ...firestore.Update) {
	t.Helper()
	if _, err := e.client.Collection(beaconsCollection).Doc(id).Update(context.Background(), updates); err != nil {
		t.Fatal(err)
	}
}

func TestRepo_CreateWritesBeaconMembershipAndIdem(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	start := e.now.Add(time.Hour)
	res := e.create(t, "org-1", itKeyA, e.beaconAt("org-1", itCommunity, start))
	if res.Outcome != Written {
		t.Fatalf("outcome = %v, want Written", res.Outcome)
	}
	b := res.Beacon
	if b.Status != StatusOpen || b.AcceptedCount != 0 || !b.ExpireAt.Equal(start.Add(ExpireAfterStart)) || !b.EndAt.Equal(start.Add(25*time.Minute)) {
		t.Fatalf("stored beacon = %+v", b)
	}
	got, err := e.repo.Get(ctx, b.ID)
	if err != nil || got.OrganiserID != "org-1" || got.CommunityID != itCommunity || got.Status != StatusOpen {
		t.Fatalf("Get = %+v, %v", got, err)
	}
	snap, err := e.client.Collection(beaconsCollection).Doc(b.ID).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if snap.Data()["eligibility"] != EligibilityEveryone {
		t.Fatalf("eligibility = %v, want everyone", snap.Data()["eligibility"])
	}
	m, err := e.repo.membershipRef("org-1", b.ID).Get(ctx)
	if err != nil {
		t.Fatalf("membership: %v", err)
	}
	if m.Data()["role"] != RoleOrganiser || m.Data()["state"] != string(StatusOpen) || m.Data()["beaconId"] != b.ID {
		t.Fatalf("membership = %v", m.Data())
	}
	if _, ok := m.Data()["organiserId"]; ok {
		t.Fatal("membership row must not hold a uid field (R3)")
	}
	// Replay: same key, same body answers the same id and writes nothing.
	again := e.create(t, "org-1", itKeyA, e.beaconAt("org-1", itCommunity, start))
	if again.Outcome != Replayed || again.Beacon.ID != b.ID {
		t.Fatalf("replay = %+v", again)
	}
	docs, err := e.client.Collection(beaconsCollection).Where("organiserId", "==", "org-1").Documents(ctx).GetAll()
	if err != nil || len(docs) != 1 {
		t.Fatalf("beacons after replay = %d, %v, want 1", len(docs), err)
	}
}

func TestRepo_CreateKeyReused(t *testing.T) {
	e := newRepoEnv(t)
	start := e.now.Add(time.Hour)
	e.create(t, "org-2", itKeyA, e.beaconAt("org-2", "", start))
	other := e.beaconAt("org-2", "", start)
	other.Title = "Lunch"
	_, err := e.repo.Create(context.Background(), CreateParams{
		UID: "org-2", ID: e.node.Generate(), IdemKey: idempotency.Key("org-2", rpcCreateBeacon, itKeyA),
		RequestHash: idempotency.HashRequest("title=Lunch|start=" + start.String()), Beacon: other, MaxOpenPerUser: 5,
	})
	if !errors.Is(err, ErrKeyReused) {
		t.Fatalf("err = %v, want ErrKeyReused", err)
	}
}

// TestRepo_CreateCapCountsOnlyLive: ended beacons still carry status open in storage; the cap counts only those whose
// endAt is ahead of now (R2).
func TestRepo_CreateCapCountsOnlyLive(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	t.Run("ended beacons do not count", func(t *testing.T) {
		for i := range 5 {
			e.create(t, "org-3", fmt.Sprintf("integration-key-end%d", i), e.beaconAt("org-3", "", e.now.Add(-time.Duration(i+2)*time.Hour)))
		}
		res := e.createWithCap(t, "org-3", itKeyB, e.beaconAt("org-3", "", e.now.Add(time.Hour)), 5)
		if res.Outcome != Written {
			t.Fatalf("6th create with 5 ended = %v, want Written", res.Outcome)
		}
	})
	t.Run("live beacons count", func(t *testing.T) {
		for i := range 5 {
			e.create(t, "org-4", fmt.Sprintf("integration-key-liv%d", i), e.beaconAt("org-4", "", e.now.Add(time.Duration(i+1)*time.Hour)))
		}
		_, err := e.repo.Create(ctx, CreateParams{
			UID: "org-4", ID: e.node.Generate(), IdemKey: idempotency.Key("org-4", rpcCreateBeacon, itKeyB),
			RequestHash: "h", Beacon: e.beaconAt("org-4", "", e.now.Add(9*time.Hour)), MaxOpenPerUser: 5,
		})
		if !errors.Is(err, ErrOpenLimit) {
			t.Fatalf("err = %v, want ErrOpenLimit", err)
		}
		docs, err := e.client.Collection(beaconsCollection).Where("organiserId", "==", "org-4").Documents(ctx).GetAll()
		if err != nil || len(docs) != 5 {
			t.Fatalf("beacons after refusal = %d, %v, want 5 (nothing written)", len(docs), err)
		}
	})
	t.Run("a cancelled beacon does not count", func(t *testing.T) {
		for i := range 5 {
			e.create(t, "org-5", fmt.Sprintf("integration-key-can%d", i), e.beaconAt("org-5", "", e.now.Add(time.Duration(i+1)*time.Hour)))
		}
		docs, _ := e.client.Collection(beaconsCollection).Where("organiserId", "==", "org-5").Documents(ctx).GetAll()
		e.setField(t, docs[0].Ref.ID, firestore.Update{Path: "status", Value: string(StatusCancelled)})
		if res := e.createWithCap(t, "org-5", itKeyB, e.beaconAt("org-5", "", e.now.Add(9*time.Hour)), 5); res.Outcome != Written {
			t.Fatalf("create with one cancelled = %v, want Written", res.Outcome)
		}
	})
}

func TestRepo_UpdateRules(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	b := e.create(t, "org-6", itKeyA, e.beaconAt("org-6", itCommunity, e.now.Add(time.Hour))).Beacon
	update := func(uid, key string, spots *int, title *string, now time.Time) (UpdateResult, error) {
		return e.repo.Update(ctx, UpdateParams{
			UID: uid, BeaconID: b.ID, IdemKey: idempotency.Key(uid, rpcUpdateBeacon, key), RequestHash: idempotency.HashRequest(key),
			OpenSpots: spots, Title: title, Now: now,
		})
	}
	t.Run("another caller is not the organiser", func(t *testing.T) {
		title := "x"
		if _, err := update("someone", "integration-key-u001", nil, &title, e.now); !errors.Is(err, ErrNotOrganiser) {
			t.Fatalf("err = %v, want ErrNotOrganiser", err)
		}
	})
	t.Run("open_spots below accepted_count is a validation error", func(t *testing.T) {
		e.setField(t, b.ID, firestore.Update{Path: "acceptedCount", Value: 2})
		one := 1
		_, err := update("org-6", "integration-key-u002", &one, nil, e.now)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Metadata["field"] != "open_spots" {
			t.Fatalf("err = %v, want VALIDATION open_spots", err)
		}
	})
	t.Run("lowering to accepted_count turns FULL, raising turns OPEN", func(t *testing.T) {
		two, four := 2, 4
		res, err := update("org-6", "integration-key-u003", &two, nil, e.now)
		if err != nil || res.Outcome != Written || res.Beacon.Status != StatusFull || res.Beacon.OpenSpots != 2 {
			t.Fatalf("lower = %+v, %v, want full/2", res.Beacon, err)
		}
		res, err = update("org-6", "integration-key-u004", &four, nil, e.now)
		if err != nil || res.Beacon.Status != StatusOpen || res.Beacon.OpenSpots != 4 {
			t.Fatalf("raise = %+v, %v, want open/4", res.Beacon, err)
		}
	})
	t.Run("nothing to change writes only the idempotency doc", func(t *testing.T) {
		four := 4
		res, err := update("org-6", "integration-key-u005", &four, nil, e.now)
		if err != nil || res.Outcome != Unchanged {
			t.Fatalf("no-op = %v, %v, want Unchanged", res.Outcome, err)
		}
		res, err = update("org-6", "integration-key-u005", &four, nil, e.now)
		if err != nil || res.Outcome != Replayed {
			t.Fatalf("replay = %v, %v, want Replayed", res.Outcome, err)
		}
	})
	t.Run("ended is ErrEnded", func(t *testing.T) {
		title := "Late"
		if _, err := update("org-6", "integration-key-u006", nil, &title, b.EndAt); !errors.Is(err, ErrEnded) {
			t.Fatalf("err = %v, want ErrEnded", err)
		}
	})
	t.Run("missing is ErrNotFound", func(t *testing.T) {
		title := "x"
		_, err := e.repo.Update(ctx, UpdateParams{UID: "org-6", BeaconID: e.node.Generate(), IdemKey: idempotency.Key("org-6", rpcUpdateBeacon, "integration-key-u007"), RequestHash: "h", Title: &title, Now: e.now})
		if !errors.Is(err, ErrNotFound) {
			t.Fatalf("err = %v, want ErrNotFound", err)
		}
	})
}

func TestRepo_CancelRules(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	b := e.create(t, "org-7", itKeyA, e.beaconAt("org-7", "", e.now.Add(time.Hour))).Beacon
	cancel := func(uid, key string, now time.Time) (CancelResult, error) {
		return e.repo.Cancel(ctx, CancelParams{UID: uid, BeaconID: b.ID, IdemKey: idempotency.Key(uid, rpcCancelBeacon, key), RequestHash: idempotency.HashRequest(b.ID), Now: now})
	}
	t.Run("ended is ErrEnded and stays open in storage", func(t *testing.T) {
		if _, err := cancel("org-7", "integration-key-c001", b.EndAt.Add(time.Second)); !errors.Is(err, ErrEnded) {
			t.Fatalf("err = %v, want ErrEnded", err)
		}
		got, _ := e.repo.Get(ctx, b.ID)
		if got.Status != StatusOpen {
			t.Fatalf("status after refused cancel = %q, want open", got.Status)
		}
	})
	t.Run("cancel writes status and membership state", func(t *testing.T) {
		res, err := cancel("org-7", "integration-key-c002", e.now)
		if err != nil || res.Outcome != Written || res.Beacon.Status != StatusCancelled {
			t.Fatalf("cancel = %+v, %v", res, err)
		}
		m, err := e.repo.membershipRef("org-7", b.ID).Get(ctx)
		if err != nil || m.Data()["state"] != string(StatusCancelled) {
			t.Fatalf("membership state = %v, %v, want cancelled", m.Data()["state"], err)
		}
	})
	t.Run("second cancel is Unchanged", func(t *testing.T) {
		res, err := cancel("org-7", "integration-key-c003", e.now)
		if err != nil || res.Outcome != Unchanged || res.Beacon.Status != StatusCancelled {
			t.Fatalf("second cancel = %+v, %v, want Unchanged", res, err)
		}
	})
	t.Run("another caller is not the organiser", func(t *testing.T) {
		if _, err := cancel("someone", "integration-key-c004", e.now); !errors.Is(err, ErrNotOrganiser) {
			t.Fatalf("err = %v, want ErrNotOrganiser", err)
		}
	})
}

func TestRepo_GetMissingIsNotFound(t *testing.T) {
	e := newRepoEnv(t)
	if _, err := e.repo.Get(context.Background(), e.node.Generate()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

// TestRepo_ListByAudienceOrderAndPaging: open and full beacons of one audience from `from` on, soonest first, resuming
// after (startAt, id); cancelled and already-started beacons are left out; another audience is invisible.
func TestRepo_ListByAudienceOrderAndPaging(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	var ids []string
	for i := range 7 {
		b := e.create(t, "org-8", fmt.Sprintf("integration-key-l%03d", i), e.beaconAt("org-8", itCommunity, e.now.Add(time.Duration(i+1)*time.Hour))).Beacon
		ids = append(ids, b.ID)
	}
	e.setField(t, ids[2], firestore.Update{Path: "status", Value: string(StatusCancelled)})
	e.setField(t, ids[3], firestore.Update{Path: "status", Value: string(StatusFull)})
	e.create(t, "org-8", "integration-key-past", e.beaconAt("org-8", itCommunity, e.now.Add(-time.Hour)))
	e.create(t, "org-8", "integration-key-publ", e.beaconAt("org-8", "", e.now.Add(2*time.Hour)))

	page1, err := e.repo.ListByAudience(ctx, ListQuery{CommunityID: itCommunity, From: e.now, Limit: 3})
	if err != nil {
		t.Fatal(err)
	}
	want1 := []string{ids[0], ids[1], ids[3]}
	if got := idsOf(page1); fmt.Sprint(got) != fmt.Sprint(want1) {
		t.Fatalf("page 1 = %v, want %v", got, want1)
	}
	last := page1[len(page1)-1]
	page2, err := e.repo.ListByAudience(ctx, ListQuery{CommunityID: itCommunity, From: e.now, AfterStartAt: last.StartAt, AfterID: last.ID, Limit: 3})
	if err != nil {
		t.Fatal(err)
	}
	want2 := []string{ids[4], ids[5], ids[6]}
	if got := idsOf(page2); fmt.Sprint(got) != fmt.Sprint(want2) {
		t.Fatalf("page 2 = %v, want %v", got, want2)
	}
	last = page2[len(page2)-1]
	page3, err := e.repo.ListByAudience(ctx, ListQuery{CommunityID: itCommunity, From: e.now, AfterStartAt: last.StartAt, AfterID: last.ID, Limit: 3})
	if err != nil || len(page3) != 0 {
		t.Fatalf("page 3 = %v, %v, want empty", idsOf(page3), err)
	}
	public, err := e.repo.ListByAudience(ctx, ListQuery{CommunityID: "", From: e.now, Limit: 10})
	if err != nil || len(public) != 1 || public[0].CommunityID != "" {
		t.Fatalf("public page = %v, %v, want the one public beacon", idsOf(public), err)
	}
}

func idsOf(bs []Beacon) []string {
	out := make([]string, 0, len(bs))
	for _, b := range bs {
		out = append(out, b.ID)
	}
	return out
}
