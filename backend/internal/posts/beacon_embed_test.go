package posts

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

const (
	testBeacon  = "0000000000000000555"
	testBeacon2 = "0000000000000000556"
)

var beaconStart = time.Date(2026, 11, 20, 16, 0, 0, 0, time.UTC)

// fakePlans is a BeaconPlans for unit tests: target answers EmbedTarget, live answers Previews (absent = unavailable).
type fakePlans struct {
	target      BeaconLive
	targetErr   error
	live        map[string]BeaconLive
	previewErr  error
	targetCalls int
	previewIDs  [][]string
}

func (f *fakePlans) EmbedTarget(_ context.Context, _, _ string) (BeaconLive, error) {
	f.targetCalls++
	return f.target, f.targetErr
}

func (f *fakePlans) Previews(_ context.Context, _ string, ids []string) (map[string]BeaconLive, error) {
	f.previewIDs = append(f.previewIDs, append([]string(nil), ids...))
	return f.live, f.previewErr
}

func liveCoffee() BeaconLive {
	return BeaconLive{
		BeaconID: testBeacon, Title: "Coffee", Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, StartAt: beaconStart,
		Status: beaconsv1.BeaconStatus_BEACON_STATUS_OPEN,
	}
}

func planEnv(plans *fakePlans) *createEnv {
	e := newCreateEnv()
	if plans != nil {
		e.svc.beacons = plans
	}
	return e
}

func TestCreate_BeaconEmbed_FlagAndShape(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		wire    bool // BeaconPlans wired
		in      CreateInput
		code    connect.Code
		reason  commonv1.ErrorReason
		field   string // metadata field or feature
		feature bool
	}{
		{"flag off", true, CreateInput{BeaconID: testBeacon}, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, PostBeaconFlagName, true},
		{"no plan reader wired", false, CreateInput{BeaconID: testBeacon, BeaconEmbedEnabled: true}, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, PostBeaconFlagName, true},
		{"not 19 digits", true, CreateInput{BeaconID: "123", BeaconEmbedEnabled: true}, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "beacon_id", false},
		{"a reply", true, CreateInput{BeaconID: testBeacon, BeaconEmbedEnabled: true, ReplyToPostID: rReply1, RepliesEnabled: true}, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "beacon_id", false},
		{"a quote", true, CreateInput{BeaconID: testBeacon, BeaconEmbedEnabled: true, QuoteOfPostID: rReply1, QuotesEnabled: true}, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "beacon_id", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			plans := &fakePlans{target: liveCoffee()}
			e := planEnv(nil)
			if tt.wire {
				e.svc.beacons = plans
			}
			tt.in.IdempotencyKey, tt.in.Text = key1, "join me"
			_, err := e.create(tt.in)
			ae := wantAPIError(t, err, tt.code, tt.reason)
			key := "field"
			if tt.feature {
				key = "feature"
			}
			if ae.Metadata[key] != tt.field {
				t.Fatalf("%s = %q, want %q", key, ae.Metadata[key], tt.field)
			}
			if plans.targetCalls != 0 || e.repo.createCalls != 0 {
				t.Fatalf("a refusal before any read did work: lookups=%d creates=%d", plans.targetCalls, e.repo.createCalls)
			}
		})
	}
	t.Run("a poll", func(t *testing.T) {
		t.Parallel()
		if err := validateBeaconShape(CreateInput{BeaconID: testBeacon}, true); err == nil {
			t.Fatal("a plan with a poll must be refused")
		}
		if err := validateBeaconShape(CreateInput{BeaconID: testBeacon}, false); err != nil {
			t.Fatal(err)
		}
		if err := validateBeaconShape(CreateInput{}, true); err != nil {
			t.Fatal("no beacon_id, nothing to validate")
		}
	})
}

func TestCreate_BeaconEmbed_TargetRules(t *testing.T) {
	t.Parallel()
	community := liveCoffee()
	community.CommunityID = testCommunityID
	tests := []struct {
		name      string
		target    BeaconLive
		targetErr error
		in        CreateInput
		code      connect.Code
		reason    commonv1.ErrorReason
		meta      map[string]string
	}{
		{"missing, hidden or not yours", BeaconLive{}, ErrBeaconNotFound, CreateInput{}, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil},
		{"ended", BeaconLive{}, ErrBeaconEnded, CreateInput{}, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, map[string]string{"reason": "ended"}},
		{"cancelled", BeaconLive{}, ErrBeaconCancelled, CreateInput{}, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, map[string]string{"reason": "cancelled"}},
		{"beacons flag off for the caller passes through", BeaconLive{},
			apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "off").WithMeta("feature", "beacons"),
			CreateInput{}, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": "beacons"}},
		{"community plan in a plain post", community, nil, CreateInput{}, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "beacon_id"}},
		{"community plan in another community", community, nil, CreateInput{CommunityID: "9999999999999999999", CommunitiesEnabled: true}, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "beacon_id"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := gatedEnv(&fakeGate{name: "Go"})
			e.svc.beacons = &fakePlans{target: tt.target, targetErr: tt.targetErr}
			tt.in.IdempotencyKey, tt.in.Text, tt.in.BeaconID, tt.in.BeaconEmbedEnabled = key1, "join me", testBeacon, true
			_, err := e.create(tt.in)
			ae := wantAPIError(t, err, tt.code, tt.reason)
			for k, v := range tt.meta {
				if ae.Metadata[k] != v {
					t.Fatalf("metadata %s = %q, want %q", k, ae.Metadata[k], v)
				}
			}
			if e.repo.createCalls != 0 {
				t.Fatal("a refused plan must write nothing")
			}
		})
	}
	t.Run("an unexpected error is internal and redacted", func(t *testing.T) {
		t.Parallel()
		e := planEnv(&fakePlans{targetErr: errors.New("firestore down")})
		_, err := e.create(CreateInput{IdempotencyKey: key1, Text: "x", BeaconID: testBeacon, BeaconEmbedEnabled: true})
		if err == nil || connect.CodeOf(err) == connect.CodeNotFound || strings.Contains(err.Error(), testBeacon) {
			t.Fatalf("err = %v, want a redacted internal error", err)
		}
	})
}

func TestCreate_BeaconEmbed_StoresSnapshotAndHashesTheID(t *testing.T) {
	t.Parallel()
	// A public plan in a community post is allowed; a community plan in its own community is allowed.
	for _, tc := range []struct {
		name string
		cid  string
		in   CreateInput
	}{
		{"public plan, plain post", "", CreateInput{}},
		{"public plan, community post", "", CreateInput{CommunityID: testCommunityID, CommunitiesEnabled: true}},
		{"community plan, its community", testCommunityID, CreateInput{CommunityID: testCommunityID, CommunitiesEnabled: true}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			live := liveCoffee()
			live.CommunityID = tc.cid
			e := gatedEnv(&fakeGate{name: "Go"})
			e.svc.beacons = &fakePlans{target: live}
			tc.in.IdempotencyKey, tc.in.Text, tc.in.BeaconID, tc.in.BeaconEmbedEnabled = key1, "coffee at 4", testBeacon, true
			p, err := e.create(tc.in)
			if err != nil {
				t.Fatal(err)
			}
			want := &BeaconSnapshot{Title: "Coffee", Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, StartAt: beaconStart, CommunityID: tc.cid}
			if p.BeaconID != testBeacon || p.Beacon == nil || *p.Beacon != *want {
				t.Fatalf("post plan = %q %+v, want %q %+v", p.BeaconID, p.Beacon, testBeacon, want)
			}
			// The stored doc round-trips the snapshot.
			back := toDoc(p).toPost(p.ID)
			if back.BeaconID != testBeacon || back.Beacon == nil || *back.Beacon != *want {
				t.Fatalf("doc round trip = %q %+v", back.BeaconID, back.Beacon)
			}
		})
	}

	// The request hash covers the plan only when one is set: a request without one hashes as before, another plan under the
	// same key is IDEMPOTENCY_KEY_REUSED, the same request replays.
	plain := planEnv(&fakePlans{target: liveCoffee()})
	if _, err := plain.create(CreateInput{IdempotencyKey: key1, Text: "same"}); err != nil {
		t.Fatal(err)
	}
	h0 := plain.repo.lastCreate.RequestHash
	e := planEnv(&fakePlans{target: liveCoffee()})
	in := CreateInput{IdempotencyKey: key1, Text: "same", BeaconID: testBeacon, BeaconEmbedEnabled: true}
	if _, err := e.create(in); err != nil {
		t.Fatal(err)
	}
	if e.repo.lastCreate.RequestHash == h0 {
		t.Fatal("the hash must change when a plan is set")
	}
	if _, err := e.create(in); err != nil {
		t.Fatalf("replay: %v", err)
	}
	in.BeaconID = testBeacon2
	_, err := e.create(in)
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	in.BeaconID, in.BeaconEmbedEnabled = "", false
	_, err = e.create(in)
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
}

// TestBeaconToProto_FailsClosed: the audience-leak guard. Live fields reach the wire only from this response's hydration;
// the frozen snapshot never does.
func TestBeaconToProto_FailsClosed(t *testing.T) {
	t.Parallel()
	frozen := &BeaconSnapshot{Title: "FROZEN SECRET TITLE", StartAt: beaconStart.Add(-48 * time.Hour)}
	post := func(kind Kind) *Post {
		return &Post{ID: pidMine, Kind: kind, BeaconID: testBeacon, Beacon: frozen}
	}
	live := liveCoffee()
	live.Status = beaconsv1.BeaconStatus_BEACON_STATUS_CANCELLED
	tests := []struct {
		name string
		p    *Post
		vs   ViewerSet
		want *postsv1.BeaconPreview // nil = field unset
	}{
		{"no plan", &Post{ID: pidMine, Kind: KindPost}, ViewerSet{}, nil},
		{"never hydrated: unavailable", post(KindPost), ViewerSet{}, &postsv1.BeaconPreview{BeaconId: testBeacon, Unavailable: true}},
		{"hydrated but the viewer cannot see it", post(KindPost), ViewerSet{}.WithBeacons(map[string]BeaconLive{}), &postsv1.BeaconPreview{BeaconId: testBeacon, Unavailable: true}},
		{"hydration failed (nil map)", post(KindPost), ViewerSet{}.WithBeacons(nil), &postsv1.BeaconPreview{BeaconId: testBeacon, Unavailable: true}},
		{"another plan only", post(KindPost), ViewerSet{}.WithBeacons(map[string]BeaconLive{testBeacon2: live}), &postsv1.BeaconPreview{BeaconId: testBeacon, Unavailable: true}},
		{"kill switch strips", post(KindPost), ViewerSet{}.WithBeacons(map[string]BeaconLive{testBeacon: live}).WithBeaconsGloballyOff(), nil},
		{"a repost row has no card", post(KindRepost), ViewerSet{}.WithBeacons(map[string]BeaconLive{testBeacon: live}), nil},
		{"a quote row has no card", post(KindQuote), ViewerSet{}.WithBeacons(map[string]BeaconLive{testBeacon: live}), nil},
		{"cancelled plan renders cancelled", post(KindPost), ViewerSet{}.WithBeacons(map[string]BeaconLive{testBeacon: live}),
			&postsv1.BeaconPreview{BeaconId: testBeacon, Title: "Coffee", Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Status: beaconsv1.BeaconStatus_BEACON_STATUS_CANCELLED}},
		{"survives BookmarksOnly", post(KindPost), ViewerSet{}.WithBeacons(map[string]BeaconLive{testBeacon: live}).BookmarksOnly(),
			&postsv1.BeaconPreview{BeaconId: testBeacon, Title: "Coffee", Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Status: beaconsv1.BeaconStatus_BEACON_STATUS_CANCELLED}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := ToViewAt(tt.p, tt.vs, "viewer", time.Now()).GetPost().GetBeacon()
			if tt.want == nil {
				if got != nil {
					t.Fatalf("beacon = %v, want unset", got)
				}
				return
			}
			if got == nil || got.GetBeaconId() != tt.want.GetBeaconId() || got.GetUnavailable() != tt.want.GetUnavailable() ||
				got.GetTitle() != tt.want.GetTitle() || got.GetActivity() != tt.want.GetActivity() || got.GetStatus() != tt.want.GetStatus() {
				t.Fatalf("beacon = %v, want %v", got, tt.want)
			}
			if got.GetUnavailable() && (got.GetTitle() != "" || got.GetStartAt() != nil || got.GetCommunityId() != "") {
				t.Fatalf("an unavailable card leaked fields: %v", got)
			}
			if strings.Contains(got.String(), "FROZEN") {
				t.Fatal("the frozen snapshot reached the wire")
			}
			if !got.GetUnavailable() && !got.GetStartAt().AsTime().Equal(beaconStart) {
				t.Fatalf("start_at = %v, want the live value", got.GetStartAt().AsTime())
			}
		})
	}
}

func TestHydrateBeacons(t *testing.T) {
	t.Parallel()
	pa := &Post{ID: "1", Kind: KindPost, BeaconID: testBeacon}
	pb := &Post{ID: "2", Kind: KindPost, BeaconID: testBeacon} // same plan twice
	pc := &Post{ID: "3", Kind: KindPost, BeaconID: testBeacon2}
	plain := &Post{ID: "4", Kind: KindPost}
	repost := &Post{ID: "5", Kind: KindRepost, BeaconID: testBeacon2}
	on := pvFlags{on: map[string]bool{PostBeaconFlagName: true}}

	t.Run("one deduplicated batch for the page", func(t *testing.T) {
		t.Parallel()
		plans := &fakePlans{live: map[string]BeaconLive{testBeacon: liveCoffee()}}
		vs := HydrateBeacons(context.Background(), on, plans, ViewerSet{}, "u", pa, pb, plain, repost, nil, pc)
		if len(plans.previewIDs) != 1 || strings.Join(plans.previewIDs[0], ",") != testBeacon+","+testBeacon2 {
			t.Fatalf("Previews calls = %v, want one batch of the two distinct plans", plans.previewIDs)
		}
		if b := ToView(pa, vs, "u").GetPost().GetBeacon(); b.GetUnavailable() || b.GetTitle() != "Coffee" {
			t.Fatalf("card = %v", b)
		}
		if b := ToView(pc, vs, "u").GetPost().GetBeacon(); !b.GetUnavailable() {
			t.Fatalf("a plan the batch did not return must be unavailable: %v", b)
		}
	})
	t.Run("no plan on the page: no read", func(t *testing.T) {
		t.Parallel()
		plans := &fakePlans{}
		HydrateBeacons(context.Background(), on, plans, ViewerSet{}, "u", plain, repost)
		if len(plans.previewIDs) != 0 {
			t.Fatal("a page without plans must not read")
		}
	})
	t.Run("kill switch: no read, field stripped", func(t *testing.T) {
		t.Parallel()
		plans := &fakePlans{live: map[string]BeaconLive{testBeacon: liveCoffee()}}
		vs := HydrateBeacons(context.Background(), pvFlags{off: map[string]bool{PostBeaconFlagName: true}}, plans, ViewerSet{}, "u", pa)
		if len(plans.previewIDs) != 0 || ToView(pa, vs, "u").GetPost().GetBeacon() != nil {
			t.Fatalf("calls=%v card=%v", plans.previewIDs, ToView(pa, vs, "u").GetPost().GetBeacon())
		}
	})
	t.Run("no flag checker fails closed", func(t *testing.T) {
		t.Parallel()
		vs := HydrateBeacons(context.Background(), nil, &fakePlans{live: map[string]BeaconLive{testBeacon: liveCoffee()}}, ViewerSet{}, "u", pa)
		if ToView(pa, vs, "u").GetPost().GetBeacon() != nil {
			t.Fatal("expected the field stripped")
		}
	})
	t.Run("no plan reader or a failed read: unavailable, never an error", func(t *testing.T) {
		t.Parallel()
		for name, plans := range map[string]BeaconPlans{"nil": nil, "error": &fakePlans{previewErr: errors.New("boom")}} {
			vs := HydrateBeacons(context.Background(), on, plans, ViewerSet{}, "u", pa)
			if b := ToView(pa, vs, "u").GetPost().GetBeacon(); !b.GetUnavailable() || b.GetBeaconId() != testBeacon {
				t.Fatalf("%s: card = %v, want the unavailable form", name, b)
			}
		}
	})
}

// TestServer_BeaconEmbed: CreatePost passes the flag decision and the id through, the response card is hydrated for the
// creator, and GetPost renders the live card or "unavailable" for the viewer.
func TestServer_BeaconEmbed(t *testing.T) {
	t.Parallel()
	plans := &fakePlans{target: liveCoffee(), live: map[string]BeaconLive{testBeacon: liveCoffee()}}
	e := planEnv(plans)
	flags := pvFlags{on: map[string]bool{FlagName: true, PostBeaconFlagName: true}}
	srv := NewServer(e.svc, flags)
	srv.SetBeaconPlans(plans)
	resp, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key1, Text: "coffee?", BeaconId: testBeacon}))
	if err != nil {
		t.Fatal(err)
	}
	b := resp.Msg.GetPost().GetPost().GetBeacon()
	if b.GetBeaconId() != testBeacon || b.GetUnavailable() || b.GetTitle() != "Coffee" || b.GetStatus() != beaconsv1.BeaconStatus_BEACON_STATUS_OPEN {
		t.Fatalf("create response card = %v", b)
	}
	id := resp.Msg.GetPost().GetPost().GetPostId()

	// GetPost: the viewer cannot see the plan any more.
	plans.live = map[string]BeaconLive{}
	got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: id}))
	if err != nil {
		t.Fatal(err)
	}
	if b := got.Msg.GetPost().GetPost().GetBeacon(); !b.GetUnavailable() || b.GetTitle() != "" {
		t.Fatalf("GetPost card = %v, want unavailable", b)
	}

	// The creator's flag off for the caller: CreatePost is FEATURE_DISABLED before any lookup.
	off := NewServer(e.svc, pvFlags{on: map[string]bool{FlagName: true}})
	before := plans.targetCalls
	_, err = off.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: "fedcba9876543210", Text: "x", BeaconId: testBeacon}))
	_ = wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if plans.targetCalls != before {
		t.Fatal("a flag-off request must not reach the plan reader")
	}

	// The kill switch (globally off) strips the card from GetPost.
	kill := NewServer(e.svc, pvFlags{on: map[string]bool{FlagName: true}, off: map[string]bool{PostBeaconFlagName: true}})
	got, err = kill.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: id}))
	if err != nil || got.Msg.GetPost().GetPost().GetBeacon() != nil {
		t.Fatalf("kill switch: card = %v, err = %v", got.Msg.GetPost().GetPost().GetBeacon(), err)
	}
}

func TestExportedPost_BeaconIDIsOmittedWithoutOne(t *testing.T) {
	t.Parallel()
	plain, _ := json.Marshal(exportedPost{ID: "1"})
	if strings.Contains(string(plain), "beaconId") {
		t.Fatalf("a post without a plan must export byte for byte as before: %s", plain)
	}
	with, _ := json.Marshal(exportedPost{ID: "1", BeaconID: testBeacon})
	if !strings.Contains(string(with), `"beaconId":"`+testBeacon+`"`) {
		t.Fatalf("export = %s", with)
	}
}
