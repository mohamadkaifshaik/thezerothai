package apiserver

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/reflect/protoregistry"

	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
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

// TestPublicIDsInterceptor_ReportTargetPassesThrough: ReportContentRequest.target_id is CONDITIONAL with no rule yet
// (PR 4c), so with the flag on it is left untouched whatever it holds.
func TestPublicIDsInterceptor_ReportTargetPassesThrough(t *testing.T) {
	ic, err := publicIDsInterceptor(publicIDsRegistry(flags.On), &fakePublicIDs{}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	var seen string
	h := ic.WrapUnary(func(_ context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
		seen = r.Any().(*moderationv1.ReportContentRequest).GetTargetId()
		return connect.NewResponse(&moderationv1.ReportContentResponse{}), nil
	})
	for _, v := range []string{pidUID(1), pidPub(1)} {
		if _, err := h(callerCtx(pidUID(2)), connect.NewRequest(&moderationv1.ReportContentRequest{
			TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_ACCOUNT, TargetId: v,
		})); err != nil || seen != v {
			t.Errorf("target %q: handler saw %q, err %v", v, seen, err)
		}
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
