package apiserver

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/reflect/protoregistry"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/publicid"
)

// pidUID is a Firebase-shaped uid; pidPub its public id (valid for identity.ValidPublicID).
func pidUID(n int) string { return fmt.Sprintf("FbUid%023d", n) }
func pidPub(n int) string { return fmt.Sprintf("u0%025d", n) }

// fakePublicIDs is identity.PublicIDs over a fixed table (users 1-5), counting calls.
type fakePublicIDs struct {
	mu    sync.Mutex
	calls int
}

func (f *fakePublicIDs) PublicIDsForUIDs(_ context.Context, uids []string) (map[string]string, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()
	out := map[string]string{}
	for _, u := range uids {
		for i := 1; i <= 5; i++ {
			if u == pidUID(i) {
				out[u] = pidPub(i)
			}
		}
	}
	return out, nil
}

func (f *fakePublicIDs) UIDsForPublicIDs(_ context.Context, ids []string) (map[string]string, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()
	out := map[string]string{}
	for _, p := range ids {
		for i := 1; i <= 5; i++ {
			if p == pidPub(i) {
				out[p] = pidUID(i)
			}
		}
	}
	return out, nil
}

func (f *fakePublicIDs) UIDForPublicID(ctx context.Context, id string) (string, error) {
	m, err := f.UIDsForPublicIDs(ctx, []string{id})
	if err != nil {
		return "", err
	}
	if uid, ok := m[id]; ok {
		return uid, nil
	}
	return "", identity.ErrNotFound
}

var _ identity.PublicIDs = (*fakePublicIDs)(nil)

func publicIDsRegistry(mode flags.Mode, allow ...string) *flags.Registry {
	s := flags.Spec{Name: identity.PublicIDsFlag, Mode: mode, Allowlist: map[string]struct{}{}}
	for _, u := range allow {
		s.Allowlist[u] = struct{}{}
	}
	return flags.NewRegistry(s)
}

func callerCtx(uid string) context.Context {
	if uid == "" {
		return context.Background()
	}
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid})
}

// TestPublicIDsInterceptor_PerCallerFlag: the wired interceptor translates exactly for the callers the flags registry
// enables public_ids for (the same Enabled(uid, public_ids) identity uses), never without a verified uid, and is the
// identity, with no lookup, while the flag is globally off.
func TestPublicIDsInterceptor_PerCallerFlag(t *testing.T) {
	flagged, other := pidUID(1), pidUID(2)
	for _, tc := range []struct {
		name      string
		reg       *flags.Registry
		caller    string
		translate bool
	}{
		{"globally off, would-be cohort caller", publicIDsRegistry(flags.Off, flagged), flagged, false},
		{"unknown flag (unset)", flags.NewRegistry(), flagged, false},
		{"allowlist, in the cohort", publicIDsRegistry(flags.Allowlist, flagged), flagged, true},
		{"allowlist, outside the cohort", publicIDsRegistry(flags.Allowlist, flagged), other, false},
		{"allowlist, no verified uid", publicIDsRegistry(flags.Allowlist, flagged), "", false},
		{"on", publicIDsRegistry(flags.On), other, true},
		{"on, no verified uid", publicIDsRegistry(flags.On), "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ids := &fakePublicIDs{}
			ic, err := publicIDsInterceptor(tc.reg, ids, time.Now)
			if err != nil {
				t.Fatal(err)
			}
			var seen string
			h := ic.WrapUnary(func(_ context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
				seen = r.Any().(*timelinev1.GetUserTimelineRequest).GetUserId()
				return connect.NewResponse(&timelinev1.GetUserTimelineResponse{}), nil
			})
			if _, err := h(callerCtx(tc.caller), connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: pidPub(3)})); err != nil {
				t.Fatal(err)
			}
			want := pidPub(3)
			if tc.translate {
				want = pidUID(3)
			}
			if seen != want {
				t.Errorf("handler saw %q, want %q", seen, want)
			}
			if !tc.translate && ids.calls != 0 {
				t.Errorf("lookups = %d with the flag off for the caller", ids.calls)
			}
		})
	}
}

// TestPublicIDsInterceptor_OffAllocatesNothing: with the real flag check, a caller outside the cohort and the
// globally-off chain both cost no allocation. (Percent mode is not covered: flags' bucket hash allocates once per
// check, and the rollout plan has no percent stage for public_ids.)
func TestPublicIDsInterceptor_OffAllocatesNothing(t *testing.T) {
	for name, reg := range map[string]*flags.Registry{
		"globally off":   publicIDsRegistry(flags.Off),
		"outside cohort": publicIDsRegistry(flags.Allowlist, pidUID(1)),
	} {
		t.Run(name, func(t *testing.T) {
			ic, err := publicIDsInterceptor(reg, &fakePublicIDs{}, time.Now)
			if err != nil {
				t.Fatal(err)
			}
			resp := connect.NewResponse(&timelinev1.GetUserTimelineResponse{})
			h := ic.WrapUnary(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) { return resp, nil })
			ctx := callerCtx(pidUID(2))
			req := connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: pidUID(3)})
			if n := testing.AllocsPerRun(200, func() { _, _ = h(ctx, req) }); n != 0 {
				t.Errorf("allocs = %v, want 0", n)
			}
		})
	}
}

// TestPublicIDsInterceptor_ReportTarget: with the flag on, an ACCOUNT report's target_id gets the edge semantics (known
// public id -> uid, so moderation's self-report check and ReportID see the uid; unknown well-formed id and the
// placeholder pass through; a raw uid is VALIDATION "target_id" before the handler), and every other target type is
// left exactly as sent, even when it happens to look like a public id or a uid.
func TestPublicIDsInterceptor_ReportTarget(t *testing.T) {
	ic, err := publicIDsInterceptor(publicIDsRegistry(flags.On), &fakePublicIDs{}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	const (
		account = moderationv1.ReportTargetType_REPORT_TARGET_TYPE_ACCOUNT
		post    = moderationv1.ReportTargetType_REPORT_TARGET_TYPE_POST
		message = moderationv1.ReportTargetType_REPORT_TARGET_TYPE_MESSAGE
	)
	msgTarget := strings.Repeat("a", 32) + ":" + strings.Repeat("b", 32)
	for _, tc := range []struct {
		name    string
		typ     moderationv1.ReportTargetType
		sent    string
		handler string // what the handler sees
		field   string // non-empty: VALIDATION naming this field, and the handler must not run
	}{
		{"account, known public id", account, pidPub(1), pidUID(1), ""},
		{"account, the caller's own public id (self-report check sees the uid)", account, pidPub(2), pidUID(2), ""},
		{"account, unknown public id passes through", account, pidPub(9), pidPub(9), ""},
		{"account, placeholder passes through", account, publicid.Tombstone, publicid.Tombstone, ""},
		{"account, raw uid", account, pidUID(1), "", "target_id"},
		{"account, empty stays empty", account, "", "", ""},
		{"post id", post, "1234567890123456789", "1234567890123456789", ""},
		{"post type with a public-id-shaped value", post, pidPub(1), pidPub(1), ""},
		{"message target", message, msgTarget, msgTarget, ""},
		{"unspecified type with a uid", moderationv1.ReportTargetType_REPORT_TARGET_TYPE_UNSPECIFIED, pidUID(1), pidUID(1), ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ran, seen := false, ""
			h := ic.WrapUnary(func(_ context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
				ran, seen = true, r.Any().(*moderationv1.ReportContentRequest).GetTargetId()
				return connect.NewResponse(&moderationv1.ReportContentResponse{ReportId: "r1"}), nil
			})
			res, err := h(callerCtx(pidUID(2)), connect.NewRequest(&moderationv1.ReportContentRequest{TargetType: tc.typ, TargetId: tc.sent}))
			if tc.field != "" {
				var ae *apierr.Error
				if ran || !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != tc.field {
					t.Fatalf("ran=%v err=%v, want VALIDATION %s before the handler", ran, err, tc.field)
				}
				return
			}
			if err != nil || !ran || seen != tc.handler {
				t.Fatalf("handler saw %q (ran=%v, err %v), want %q", seen, ran, err, tc.handler)
			}
			if got := res.Any().(*moderationv1.ReportContentResponse).GetReportId(); got != "r1" {
				t.Errorf("report_id = %q, want it untouched", got)
			}
		})
	}
}

// TestPublicIDsInterceptor_RefusesNil: a missing dependency refuses to start rather than serve untranslated.
func TestPublicIDsInterceptor_RefusesNil(t *testing.T) {
	if _, err := publicIDsInterceptor(publicIDsRegistry(flags.On), nil, time.Now); err == nil {
		t.Error("nil lookups: want an error")
	}
	if _, err := publicIDsInterceptor(nil, &fakePublicIDs{}, time.Now); err == nil {
		t.Error("nil flags: want an error")
	}
}

// TestPublicIDPlans_BuildOverTheServedAPI: the plans Build wires build over every linked dzeroth service with the
// wiring's rules, and the validator rejects the tombstone. Logs the startup cost (paid on every start, flag or not).
func TestPublicIDPlans_BuildOverTheServedAPI(t *testing.T) {
	if identity.ValidPublicID(publicid.Tombstone) {
		t.Fatal("identity.ValidPublicID accepts the tombstone")
	}
	start := time.Now()
	plans, err := publicIDPlans()
	took := time.Since(start)
	if err != nil {
		t.Fatal(err)
	}
	if plans.Methods() == 0 {
		t.Fatal("no methods planned")
	}
	t.Logf("startup: %d methods, %d message types planned in %v", plans.Methods(), len(plans.Messages()), took)
}

// BenchmarkPublicIDPlans is the startup cost of the plans.
func BenchmarkPublicIDPlans(b *testing.B) {
	b.ReportAllocs()
	for b.Loop() {
		if _, err := publicIDPlans(); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkPublicIDsInterceptor_OutsideCohort is the per-request cost for a caller with the flag off (the real flag
// check against an allowlist).
func BenchmarkPublicIDsInterceptor_OutsideCohort(b *testing.B) {
	ic, err := publicIDsInterceptor(publicIDsRegistry(flags.Allowlist, pidUID(1)), &fakePublicIDs{}, time.Now)
	if err != nil {
		b.Fatal(err)
	}
	resp := connect.NewResponse(&timelinev1.GetUserTimelineResponse{})
	h := ic.WrapUnary(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) { return resp, nil })
	ctx := callerCtx(pidUID(2))
	req := connect.NewRequest(&timelinev1.GetUserTimelineRequest{UserId: pidUID(3)})
	b.ReportAllocs()
	for b.Loop() {
		if _, err := h(ctx, req); err != nil {
			b.Fatal(err)
		}
	}
}

// publicIDInboundRPCs is every procedure whose request carries a translated user id (a plan with steps), sorted. The
// parity suite (public_ids_parity_integration_test.go) drives exactly this list minus publicIDParityExcluded.
func publicIDInboundRPCs(t testing.TB) []string {
	t.Helper()
	plans, err := publicIDPlans()
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, sd := range publicid.DzerothServices(protoregistry.GlobalFiles) {
		ms := sd.Methods()
		for i := range ms.Len() {
			md := ms.Get(i)
			if _, has := plans.Lookup(md.Input().FullName()); has {
				out = append(out, "/"+string(sd.FullName())+"/"+string(md.Name()))
			}
		}
	}
	sort.Strings(out)
	return out
}

// publicIDParityExcluded are inbound-translating RPCs left out of the unknown-id parity half of the suite (the
// malformed-id half covers every RPC), each with the reason. Not a way to quiet a parity failure: a difference between
// the two forms is a bug to report.
var publicIDParityExcluded = map[string]string{
	"/dzeroth.articles.v1.ArticleService/SaveArticle": "Article.author_id is ignored on input (the author is the caller), " +
		"and each save writes a new revision with its own updated_at, so two calls never answer the same bytes; " +
		"the malformed-id half and the interceptor unit tests cover the field",
}

// TestPublicIDParity_CoversEveryInboundRPC: every exclusion names an inbound-translating RPC with a reason, so the
// generic parity list cannot silently shrink; a new RPC with a user id field joins the suite by itself.
func TestPublicIDParity_CoversEveryInboundRPC(t *testing.T) {
	rpcs := publicIDInboundRPCs(t)
	if len(rpcs) == 0 {
		t.Fatal("no inbound-translating RPC")
	}
	in := map[string]bool{}
	for _, r := range rpcs {
		in[r] = true
	}
	for proc, reason := range publicIDParityExcluded {
		if !in[proc] || reason == "" {
			t.Errorf("exclusion %s (reason %q) is not an inbound-translating RPC or has no reason", proc, reason)
		}
	}
	t.Logf("%d inbound-translating RPCs, %d excluded from unknown-id parity: %v", len(rpcs), len(publicIDParityExcluded), rpcs)
}

// TestTombstoneIsOneID: the edge's tombstone and the one notifications puts in push payloads and exports are the same
// id, so a client sees one "account unavailable" id whatever path it came by.
func TestTombstoneIsOneID(t *testing.T) {
	if notifications.TombstonePublicID != publicid.Tombstone {
		t.Fatalf("notifications.TombstonePublicID = %q, publicid.Tombstone = %q", notifications.TombstonePublicID, publicid.Tombstone)
	}
}

// pidStoredNotificationID is a stored row id of the shape the fan-out builds (notifications.notificationID) for every
// listed type, with actor as the actor's uid; "" for a type no row has.
func pidStoredNotificationID(ty notifications.Type, actor string) string {
	const post, beacon = "1234567890123456789", "9876543210987654321"
	switch ty {
	case notifications.TypeFollow, notifications.TypeFollowRequest, notifications.TypeFollowAccepted:
		return string(ty) + "_" + actor
	case notifications.TypeRepost:
		return "repost_" + post + "_" + actor
	case notifications.TypeBeaconRequest:
		return "beacon_request_" + beacon + "_" + actor
	case notifications.TypeMention, notifications.TypeReply, notifications.TypeQuote:
		return string(ty) + "_" + post
	case notifications.TypeLike:
		return "like_" + post + "_2026111812"
	case notifications.TypeBeaconAccepted, notifications.TypeBeaconCancelled:
		return string(ty) + "_" + beacon
	case notifications.TypeBeaconUpdated:
		return string(ty) + "_" + beacon + "_1763460000000"
	}
	return ""
}

// TestPublicIDRules_RealPlans: the plans Build serves, with the registered rules, through the Translator (fake
// resolver). Every NotificationType value on a listed row: the row id equals notifications.WireNotificationID (the push's
// notificationId) for an actor with a public id and for one without (placeholder segment), only the actor-keyed types
// change, and no uid survives. Every ReportTargetType value: only ACCOUNT translates target_id.
func TestPublicIDRules_RealPlans(t *testing.T) {
	plans, err := publicIDPlans()
	if err != nil {
		t.Fatal(err)
	}
	tr, err := publicid.NewTranslator(plans, &fakePublicIDs{}, identity.ValidPublicID, identity.MaxPublicIDLookups)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	t.Run("notification ids", func(t *testing.T) {
		values := notificationsv1.NotificationType(0).Descriptor().Values()
		keyed := 0
		for i := range values.Len() {
			p := notificationsv1.NotificationType(values.Get(i).Number())
			ty := notifications.TypeFromProto(p)
			for _, actor := range []struct {
				uid, pub string
			}{{pidUID(1), pidPub(1)}, {pidUID(9), ""}} { // user 9 has no public id
				stored := pidStoredNotificationID(ty, actor.uid)
				if stored == "" {
					// UNSPECIFIED and the push-only MESSAGE: never a listed row; a uid-shaped id stays as sent.
					stored = "follow_" + actor.uid
				}
				resp := &notificationsv1.ListNotificationsResponse{Notifications: []*notificationsv1.Notification{{
					Id: stored, Type: p, Actor: &commonv1.AuthorSnapshot{UserId: actor.uid},
				}}}
				if _, err := tr.TranslateResponse(ctx, nil, resp); err != nil {
					t.Fatalf("%v: %v", p, err)
				}
				got := resp.GetNotifications()[0].GetId()
				if ty == "" {
					if got != stored {
						t.Errorf("%v: id %q -> %q, want untouched", p, stored, got)
					}
					continue
				}
				if want := notifications.WireNotificationID(stored, ty, actor.pub); got != want {
					t.Errorf("%v: listed id %q, push id %q", p, got, want)
				}
				if ty.ActorKeyedID() {
					keyed++
					if strings.Contains(got, actor.uid) {
						t.Errorf("%v: the actor's uid survived in %q", p, got)
					}
				} else if got != stored {
					t.Errorf("%v: a row id naming no actor changed: %q -> %q", p, stored, got)
				}
			}
		}
		if keyed != 2*5 {
			t.Errorf("actor-keyed cases = %d, want the 5 actor-keyed types twice", keyed)
		}
	})

	// The "handler-set public_id wins" rule: notifications never sets AuthorSnapshot.public_id, but if a handler did, the
	// row id's actor segment would take the same value as the actor's user_id (one id per uid within a response).
	t.Run("notification id follows a handler-set public_id", func(t *testing.T) {
		stored := "follow_" + pidUID(1)
		resp := &notificationsv1.ListNotificationsResponse{Notifications: []*notificationsv1.Notification{{
			Id: stored, Type: notificationsv1.NotificationType_NOTIFICATION_TYPE_FOLLOW,
			Actor: &commonv1.AuthorSnapshot{UserId: pidUID(1), PublicId: pidPub(3)},
		}}}
		if _, err := tr.TranslateResponse(ctx, nil, resp); err != nil {
			t.Fatal(err)
		}
		n := resp.GetNotifications()[0]
		if n.GetId() != "follow_"+pidPub(3) || n.GetActor().GetUserId() != pidPub(3) || n.GetActor().GetPublicId() != pidPub(3) {
			t.Errorf("row = (%q, %q, %q), want the handler's public id in all three", n.GetId(), n.GetActor().GetUserId(), n.GetActor().GetPublicId())
		}
	})

	t.Run("report targets", func(t *testing.T) {
		values := moderationv1.ReportTargetType(0).Descriptor().Values()
		for i := range values.Len() {
			p := moderationv1.ReportTargetType(values.Get(i).Number())
			for _, sent := range []string{pidPub(1), "1234567890123456789", strings.Repeat("a", 32) + ":" + strings.Repeat("b", 32)} {
				req := &moderationv1.ReportContentRequest{TargetType: p, TargetId: sent}
				_, err := tr.TranslateRequest(ctx, req)
				switch {
				case p != moderationv1.ReportTargetType_REPORT_TARGET_TYPE_ACCOUNT:
					if err != nil || req.GetTargetId() != sent {
						t.Errorf("%v %q: -> %q, %v; want untouched", p, sent, req.GetTargetId(), err)
					}
				case sent == pidPub(1):
					if err != nil || req.GetTargetId() != pidUID(1) {
						t.Errorf("%v %q: -> %q, %v; want the uid", p, sent, req.GetTargetId(), err)
					}
				default:
					if err == nil {
						t.Errorf("%v %q: accepted a non-public id as an account target", p, sent)
					}
				}
			}
		}
	})
}
