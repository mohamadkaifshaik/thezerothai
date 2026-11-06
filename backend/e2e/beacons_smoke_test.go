//go:build integration

package e2e

// Beacons ("Plans") E2E smoke (docs/beacons-plan.md PR 8). The same test body runs in two modes:
//
//   - Emulator mode (default, `make test-int`): boots the real handler via newTestServerCfg with FEATURE_BEACONS
//     on, mints two Firebase Auth emulator users and creates their profiles. Fully self-contained.
//   - Remote mode (dev URL / prod `candidate`): set E2E_BEACONS_BASE_URL plus E2E_BEACONS_ID_TOKEN_A and
//     E2E_BEACONS_ID_TOKEN_B (fresh ID tokens for two pre-provisioned smoke accounts that already have profiles
//     and are on the FEATURE_BEACONS allowlist). No emulator env is needed.
//
// The loop: A creates a public plan, B lists public and sees it, B gets it (can_request), B requests with a note,
// A lists REQUESTED (B, note), A accepts, A lists ACCEPTED (B), B gets it (can_leave, accepted_count 1), B leaves
// (accepted_count 0), A cancels, B gets it (CANCELLED), A's ListMyBeacons UPCOMING shows it CANCELLED, A cancels
// again (idempotent success). About 14 requests per run (under the < 100-request smoke cap). Re-runnable: every
// run creates a fresh plan and cancels it, so A never accumulates OPEN plans against BEACONS_MAX_OPEN_PER_USER and
// B never keeps a pending request against BEACONS_MAX_PENDING_REQUESTS.

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"testing"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// beaconsSmokeMode is what the environment decides: remote (a URL and two tokens) or emulator (nothing set).
type beaconsSmokeMode struct {
	baseURL, tokenA, tokenB string
	remote                  bool
}

// resolveBeaconsSmokeMode reads the three E2E_BEACONS_* variables through getenv. A URL without both tokens is an
// error, never a silent fall back to emulator mode (Review Focus 4).
func resolveBeaconsSmokeMode(getenv func(string) string) (beaconsSmokeMode, error) {
	base := getenv("E2E_BEACONS_BASE_URL")
	if base == "" {
		return beaconsSmokeMode{}, nil
	}
	tokA, tokB := getenv("E2E_BEACONS_ID_TOKEN_A"), getenv("E2E_BEACONS_ID_TOKEN_B")
	if tokA == "" || tokB == "" {
		return beaconsSmokeMode{}, errors.New("E2E_BEACONS_BASE_URL is set but E2E_BEACONS_ID_TOKEN_A / E2E_BEACONS_ID_TOKEN_B are not")
	}
	return beaconsSmokeMode{baseURL: base, tokenA: tokA, tokenB: tokB, remote: true}, nil
}

// TestE2E_BeaconsSmoke_RemoteNeedsTokens pins the guard: a remote URL with a missing token fails loud.
func TestE2E_BeaconsSmoke_RemoteNeedsTokens(t *testing.T) {
	t.Parallel()
	for name, env := range map[string]map[string]string{
		"no tokens": {"E2E_BEACONS_BASE_URL": "https://api.example"},
		"only A":    {"E2E_BEACONS_BASE_URL": "https://api.example", "E2E_BEACONS_ID_TOKEN_A": "a"},
		"only B":    {"E2E_BEACONS_BASE_URL": "https://api.example", "E2E_BEACONS_ID_TOKEN_B": "b"},
	} {
		if _, err := resolveBeaconsSmokeMode(func(k string) string { return env[k] }); err == nil {
			t.Errorf("%s: want an error, got none", name)
		}
	}
	m, err := resolveBeaconsSmokeMode(func(string) string { return "" })
	if err != nil || m.remote {
		t.Fatalf("nothing set: want emulator mode, got %+v, %v", m, err)
	}
	all := map[string]string{"E2E_BEACONS_BASE_URL": "https://api.example", "E2E_BEACONS_ID_TOKEN_A": "a", "E2E_BEACONS_ID_TOKEN_B": "b"}
	m, err = resolveBeaconsSmokeMode(func(k string) string { return all[k] })
	if err != nil || !m.remote || m.baseURL != "https://api.example" {
		t.Fatalf("all set: want remote mode, got %+v, %v", m, err)
	}
}

type beaconsSmokeEnv struct {
	beacons  beaconsv1connect.BeaconServiceClient
	identity identityv1connect.IdentityServiceClient
	tokenA   string
	tokenB   string
	uidA     string
	uidB     string
}

func setupBeaconsSmoke(t *testing.T) beaconsSmokeEnv {
	t.Helper()
	ctx := context.Background()
	mode, err := resolveBeaconsSmokeMode(os.Getenv)
	if err != nil {
		t.Fatal(err)
	}
	if mode.remote {
		env := beaconsSmokeEnv{
			beacons:  beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, mode.baseURL),
			identity: identityv1connect.NewIdentityServiceClient(http.DefaultClient, mode.baseURL),
			tokenA:   mode.tokenA,
			tokenB:   mode.tokenB,
		}
		meA, err := env.identity.GetMe(ctx, authedRequest(mode.tokenA, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe(A): %v", err)
		}
		meB, err := env.identity.GetMe(ctx, authedRequest(mode.tokenB, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe(B): %v", err)
		}
		env.uidA, env.uidB = meA.Msg.GetProfile().GetUserId(), meB.Msg.GetProfile().GetUserId()
		return env
	}

	skipIfNoEmulators(t)
	_, baseURL := newTestServerCfg(t, func(c *config.Config) {
		c.FeatureBeacons = flags.Spec{Name: "beacons", Mode: flags.On}
	})
	env := beaconsSmokeEnv{
		beacons:  beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, baseURL),
		identity: identityv1connect.NewIdentityServiceClient(http.DefaultClient, baseURL),
	}
	create := func(label string) (token, uid string) {
		token, uid = newAnonymousIDToken(t)
		_, err := env.identity.CreateProfile(ctx, authedRequest(token, &identityv1.CreateProfileRequest{
			IdempotencyKey: fmt.Sprintf("e2e-beacons-create-%s-%d", label, rand.Int63()),
			Handle:         uniqueHandle("b8" + label),
			DisplayName:    "Beacons Smoke " + label,
		}))
		if err != nil {
			t.Fatalf("CreateProfile(%s): %v", label, err)
		}
		return token, uid
	}
	env.tokenA, env.uidA = create("a")
	env.tokenB, env.uidB = create("b")
	return env
}

// beaconKey returns a fresh key per call so re-runs never replay a previous run's cached response.
func beaconKey(op string) string { return fmt.Sprintf("e2e-beacons-%s-%d", op, rand.Int63()) }

func (e beaconsSmokeEnv) get(t *testing.T, token, id, step string) *beaconsv1.BeaconView {
	t.Helper()
	res, err := e.beacons.GetBeacon(context.Background(), authedRequest(token, &beaconsv1.GetBeaconRequest{BeaconId: id}))
	if err != nil {
		t.Fatalf("%s: GetBeacon: %v", step, err)
	}
	return res.Msg.GetView()
}

func (e beaconsSmokeEnv) participants(t *testing.T, id string, filter beaconsv1.ParticipantFilter) []*beaconsv1.Participant {
	t.Helper()
	res, err := e.beacons.ListParticipants(context.Background(), authedRequest(e.tokenA, &beaconsv1.ListParticipantsRequest{BeaconId: id, Filter: filter, Limit: 50}))
	if err != nil {
		t.Fatalf("ListParticipants(%v): %v", filter, err)
	}
	return res.Msg.GetParticipants()
}

func TestE2E_BeaconsSmoke_RequestAcceptLeaveCancel(t *testing.T) {
	env := setupBeaconsSmoke(t)
	ctx := context.Background()

	// 1. A creates a public plan an hour from now with two seats.
	created, err := env.beacons.CreateBeacon(ctx, authedRequest(env.tokenA, &beaconsv1.CreateBeaconRequest{
		IdempotencyKey:  beaconKey("create"),
		Audience:        &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Activity:        beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE,
		Title:           "Smoke coffee",
		Venue:           "Food court",
		StartAt:         timestamppb.New(time.Now().Add(time.Hour)),
		DurationMinutes: 30,
		OpenSpots:       2,
		Cost:            beaconsv1.BeaconCost_BEACON_COST_FREE,
		ChatPreference:  beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET,
	}))
	if err != nil {
		t.Fatalf("CreateBeacon: %v", err)
	}
	id := created.Msg.GetView().GetBeacon().GetBeaconId()
	if id == "" || created.Msg.GetView().GetBeacon().GetStatus() != beaconsv1.BeaconStatus_BEACON_STATUS_OPEN || !created.Msg.GetView().GetViewer().GetCanManage() {
		t.Fatalf("CreateBeacon: view = %v, want an OPEN plan the caller manages", created.Msg.GetView())
	}
	// Whatever happens below, the plan ends CANCELLED so a re-run starts clean.
	t.Cleanup(func() {
		if _, err := env.beacons.CancelBeacon(ctx, authedRequest(env.tokenA, &beaconsv1.CancelBeaconRequest{IdempotencyKey: beaconKey("cleanup-cancel"), BeaconId: id})); err != nil {
			t.Errorf("cleanup CancelBeacon: %v", err)
		}
	})

	// 2. B lists the public plans and finds it (scanning a few pages on a shared environment).
	found := false
	for page, token := 0, ""; page < 5 && !found; page++ {
		res, err := env.beacons.ListBeacons(ctx, authedRequest(env.tokenB, &beaconsv1.ListBeaconsRequest{
			Audience: &beaconsv1.ListBeaconsRequest_Public{Public: true}, Limit: 50, PageToken: token,
		}))
		if err != nil {
			t.Fatalf("ListBeacons(public): %v", err)
		}
		for _, v := range res.Msg.GetViews() {
			if v.GetBeacon().GetBeaconId() == id {
				found = true
				if v.GetViewer().GetRole() != beaconsv1.ViewerRole_VIEWER_ROLE_NONE || !v.GetViewer().GetCanRequest() {
					t.Fatalf("ListBeacons: B's viewer state = %v, want NONE with can_request", v.GetViewer())
				}
			}
		}
		if token = res.Msg.GetNextPageToken(); token == "" {
			break
		}
	}
	if !found {
		t.Fatalf("ListBeacons(public): the new plan is not in the first pages")
	}

	// 3. B gets it: can_request, nothing else.
	if v := env.get(t, env.tokenB, id, "before request").GetViewer(); !v.GetCanRequest() || v.GetCanWithdraw() || v.GetCanLeave() || v.GetCanManage() {
		t.Fatalf("GetBeacon(B) before request: viewer = %v, want can_request only", v)
	}

	// 4. B requests with a note.
	reqRes, err := env.beacons.RequestToJoin(ctx, authedRequest(env.tokenB, &beaconsv1.RequestToJoinRequest{IdempotencyKey: beaconKey("request"), BeaconId: id, Note: "Smoke note"}))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if v := reqRes.Msg.GetViewer(); v.GetParticipantState() != beaconsv1.ParticipantState_PARTICIPANT_STATE_REQUESTED || !v.GetCanWithdraw() {
		t.Fatalf("RequestToJoin: viewer = %v, want REQUESTED with can_withdraw", v)
	}

	// 5. A lists the requests: B, with the note.
	reqs := env.participants(t, id, beaconsv1.ParticipantFilter_PARTICIPANT_FILTER_REQUESTED)
	if len(reqs) != 1 || reqs[0].GetUser().GetUserId() != env.uidB || reqs[0].GetNote() != "Smoke note" || reqs[0].GetState() != beaconsv1.ParticipantState_PARTICIPANT_STATE_REQUESTED {
		t.Fatalf("ListParticipants(REQUESTED) = %v, want B with the note", reqs)
	}

	// 6. A accepts; the plan stays OPEN (one of two seats taken).
	acc, err := env.beacons.RespondToJoinRequest(ctx, authedRequest(env.tokenA, &beaconsv1.RespondToJoinRequestRequest{
		IdempotencyKey: beaconKey("accept"), BeaconId: id, UserId: env.uidB, Response: beaconsv1.JoinResponse_JOIN_RESPONSE_ACCEPT,
	}))
	if err != nil {
		t.Fatalf("RespondToJoinRequest(ACCEPT): %v", err)
	}
	if b := acc.Msg.GetView().GetBeacon(); b.GetAcceptedCount() != 1 || b.GetStatus() != beaconsv1.BeaconStatus_BEACON_STATUS_OPEN {
		t.Fatalf("after accept: beacon = %v, want accepted_count 1 and OPEN", b)
	}

	// 7. A lists who is going: B.
	going := env.participants(t, id, beaconsv1.ParticipantFilter_PARTICIPANT_FILTER_ACCEPTED)
	if len(going) != 1 || going[0].GetUser().GetUserId() != env.uidB || going[0].GetState() != beaconsv1.ParticipantState_PARTICIPANT_STATE_ACCEPTED {
		t.Fatalf("ListParticipants(ACCEPTED) = %v, want B", going)
	}

	// 8. B gets it: going, can_leave, one seat taken.
	view := env.get(t, env.tokenB, id, "after accept")
	if v := view.GetViewer(); v.GetParticipantState() != beaconsv1.ParticipantState_PARTICIPANT_STATE_ACCEPTED || !v.GetCanLeave() || v.GetCanRequest() {
		t.Fatalf("GetBeacon(B) after accept: viewer = %v, want ACCEPTED with can_leave", v)
	}
	if view.GetBeacon().GetAcceptedCount() != 1 {
		t.Fatalf("GetBeacon(B) after accept: accepted_count = %d, want 1", view.GetBeacon().GetAcceptedCount())
	}

	// 9. B leaves; the seat opens again.
	if _, err := env.beacons.LeaveBeacon(ctx, authedRequest(env.tokenB, &beaconsv1.LeaveBeaconRequest{IdempotencyKey: beaconKey("leave"), BeaconId: id})); err != nil {
		t.Fatalf("LeaveBeacon: %v", err)
	}
	view = env.get(t, env.tokenB, id, "after leave")
	if view.GetBeacon().GetAcceptedCount() != 0 || view.GetViewer().GetCanLeave() {
		t.Fatalf("GetBeacon(B) after leave: beacon = %v viewer = %v, want accepted_count 0 and no can_leave", view.GetBeacon(), view.GetViewer())
	}

	// 10. A cancels; B sees CANCELLED; A's upcoming plans list it as CANCELLED.
	if _, err := env.beacons.CancelBeacon(ctx, authedRequest(env.tokenA, &beaconsv1.CancelBeaconRequest{IdempotencyKey: beaconKey("cancel"), BeaconId: id})); err != nil {
		t.Fatalf("CancelBeacon: %v", err)
	}
	if s := env.get(t, env.tokenB, id, "after cancel").GetBeacon().GetStatus(); s != beaconsv1.BeaconStatus_BEACON_STATUS_CANCELLED {
		t.Fatalf("GetBeacon(B) after cancel: status = %v, want CANCELLED", s)
	}
	mine, err := env.beacons.ListMyBeacons(ctx, authedRequest(env.tokenA, &beaconsv1.ListMyBeaconsRequest{
		Role: beaconsv1.MyBeaconsRole_MY_BEACONS_ROLE_ORGANISER, Window: beaconsv1.MyBeaconsWindow_MY_BEACONS_WINDOW_UPCOMING, Limit: 50,
	}))
	if err != nil {
		t.Fatalf("ListMyBeacons: %v", err)
	}
	seen := false
	for _, v := range mine.Msg.GetViews() {
		if v.GetBeacon().GetBeaconId() == id {
			seen = true
			if v.GetBeacon().GetStatus() != beaconsv1.BeaconStatus_BEACON_STATUS_CANCELLED {
				t.Fatalf("ListMyBeacons: status = %v, want CANCELLED", v.GetBeacon().GetStatus())
			}
		}
	}
	if !seen {
		t.Fatalf("ListMyBeacons(ORGANISER, UPCOMING) does not list the cancelled plan: %v", mine.Msg.GetViews())
	}

	// 11. A cancels again with a fresh key: an idempotent success, so the cleanup above is safe on any path.
	if _, err := env.beacons.CancelBeacon(ctx, authedRequest(env.tokenA, &beaconsv1.CancelBeaconRequest{IdempotencyKey: beaconKey("cancel-again"), BeaconId: id})); err != nil {
		t.Fatalf("CancelBeacon again: %v, want success", err)
	}
}
