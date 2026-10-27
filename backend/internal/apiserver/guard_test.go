package apiserver

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// allowedReadBudgetChargeOnly: procedure -> why the read budget charges but never rejects it (ADR-0010 D5
// amendment, CLAUDE.md rule 10). Adding an entry here requires a reason and review; the wired
// ratelimit.Config.ReadBudgetChargeOnly must equal this set exactly.
var allowedReadBudgetChargeOnly = map[string]string{
	identityv1connect.IdentityServiceDeleteAccountProcedure:        "right to delete: must work for a user who spent the day's budget (App Store, Play, DPDP)",
	identityv1connect.IdentityServiceRequestAccountExportProcedure: "right to export: same reason; small read count, per-minute bucket still applies",
	identityv1connect.IdentityServiceGetAccountExportProcedure:     "polls the export RequestAccountExport started; must not be blocked while it is pending",
}

// noSideEffectsProcedures lists every linked dzeroth Connect procedure whose proto method declares
// idempotency_level = NO_SIDE_EFFECTS: the same mechanical read-only signal degraded.Interceptor uses
// (req.Spec().IdempotencyLevel). Any service apiserver.go imports for registration is linked into this test
// binary, so a future read RPC shows up here without anyone editing this file. It enumerates those linked
// descriptors rather than building the mux (equivalent in practice: apiserver.Build registers exactly the
// linked services).
func noSideEffectsProcedures(t *testing.T) []string {
	t.Helper()
	var procs []string
	protoregistry.GlobalFiles.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		if !strings.HasPrefix(string(fd.Package()), "dzeroth.") {
			return true
		}
		for i := 0; i < fd.Services().Len(); i++ {
			svc := fd.Services().Get(i)
			for j := 0; j < svc.Methods().Len(); j++ {
				m := svc.Methods().Get(j)
				opts, ok := m.Options().(*descriptorpb.MethodOptions)
				if ok && opts.GetIdempotencyLevel() == descriptorpb.MethodOptions_NO_SIDE_EFFECTS {
					procs = append(procs, "/"+string(svc.FullName())+"/"+string(m.Name()))
				}
			}
		}
		return true
	})
	return procs
}

// defaultRateLimitCfg is the config the guard inspects: the T3 defaults.
func defaultRateLimitCfg() config.Config {
	cfg := config.Config{}
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 2000
	cfg.RateLimit.ReadBudgetPerIPNoProfilePerDay = 500
	cfg.RateLimit.CheckHandleCallsPerDay = 100
	cfg.RateLimit.AccountOpsCallsPerDay = 20
	cfg.RateLimit.NotificationDevicesCallsPerDay = 10
	cfg.RateLimit.NotificationSeenCallsPerDay = 200
	// ADR-0010 T4 per-minute buckets (the config.Load defaults).
	cfg.RateLimit.TimelinePerUserPerMinute = 6
	cfg.RateLimit.UserTimelinePerMinute = 30
	cfg.RateLimit.PostCreatePerMinute = 10
	cfg.RateLimit.PostDeletePerMinute = 20
	cfg.RateLimit.ReportPerMinute = 5                // ADR-0016
	cfg.RateLimit.BookmarksPerUserPerMinute = 30     // ADR-0023 D4: Add and Remove share it
	cfg.RateLimit.BookmarksListPerUserPerMinute = 10 // ADR-0023 D4
	cfg.RateLimit.BookmarkMutationsPerDay = 1500     // W2-14 M-1: Add and Remove share one daily call cap
	// ADR-0024 D10 (the config.Load defaults).
	cfg.RateLimit.SuggestionsPerUserPerMinute = 10
	cfg.RateLimit.LikesListPerUserPerMinute = 10
	cfg.RateLimit.ProfileRelationshipPerUserPerMinute = 60
	cfg.RateLimit.SuggestionsCallsPerDay = 50
	cfg.RateLimit.ProfileUpdatesPerDay = 100 // W3-22 L-4
	return cfg
}

// ipSetViolations asserts the ADR-0010 D5 A4/A8 sets (security L6): the IP key is wired, ReadBudgetIPEnforce is
// EMPTY (A8: the IP key never rejects; adding a procedure needs an ADR amendment), and the enforced and
// charge-only IP sets partition the profile-exempt procedures exactly, with no procedure in both. exempt is the
// set Build uses (profileExemptProcedures).
func ipSetViolations(rl ratelimit.Config, exempt map[string]struct{}) []string {
	var out []string
	if rl.ReadBudgetIP == nil {
		out = append(out, "ReadBudgetIP is not wired (ADR-0010 D5 A3-A4)")
	}
	if len(rl.ReadBudgetIPEnforce) != 0 {
		out = append(out, "ReadBudgetIPEnforce must be empty (ADR-0010 D5 A8: the IP key never rejects); adding a procedure needs an ADR amendment")
	}
	for p := range rl.ReadBudgetIPEnforce {
		if _, dup := rl.ReadBudgetIPChargeOnly[p]; dup {
			out = append(out, "procedure "+p+" is both IP-enforced and IP-charge-only")
		}
	}
	for p := range exempt {
		_, e := rl.ReadBudgetIPEnforce[p]
		_, c := rl.ReadBudgetIPChargeOnly[p]
		if !e && !c {
			out = append(out, "profile-exempt procedure "+p+" is not classified as IP-enforced or IP-charge-only")
		}
	}
	for _, set := range []map[string]struct{}{rl.ReadBudgetIPEnforce, rl.ReadBudgetIPChargeOnly} {
		for p := range set {
			if _, ok := exempt[p]; !ok {
				out = append(out, "procedure "+p+" is in an IP set but is not profile-exempt")
			}
		}
	}
	return out
}

// accountOpsViolations asserts every charge-only procedure has a DailyCaps entry named account_ops_daily (A6):
// without it GetAccountExport alone could read ~259k docs/day per uid.
func accountOpsViolations(rl ratelimit.Config) []string {
	var out []string
	for p := range rl.ReadBudgetChargeOnly {
		named, ok := rl.DailyCaps[p]
		if !ok || named.Cap == nil || named.Name != "account_ops_daily" {
			out = append(out, "charge-only procedure "+p+" has no account_ops_daily DailyCaps entry")
		}
	}
	return out
}

// readBudgetGuardViolations is the guard's logic, split from the enumeration so a mutation test can feed it a
// synthetic procedure list (a stand-in for a future NO_SIDE_EFFECTS RPC) and a deliberately broken config.
// Each returned string names the offending procedure or the disabled budget.
func readBudgetGuardViolations(rl ratelimit.Config, procs []string, allowedExemptions, allowedChargeOnly map[string]string) []string {
	var out []string
	if rl.ReadBudget == nil {
		out = append(out, "read budget is disabled in the rate-limit config Build wires (ADR-0010 D5)")
	}
	for p := range rl.ReadBudgetExempt {
		if allowedExemptions[p] == "" {
			out = append(out, "procedure "+p+" is on the read budget exemption list without an explanation")
		}
	}
	// Charge-only procedures (right to delete / export, CLAUDE.md rule 10) are charged but never rejected: the
	// wired set must equal the reviewed set, so neither a silent addition nor a silent removal passes.
	for p := range rl.ReadBudgetChargeOnly {
		if allowedChargeOnly[p] == "" {
			out = append(out, "procedure "+p+" is charge-only (never rejected by the read budget) without an explanation")
		}
	}
	for p := range allowedChargeOnly {
		if _, ok := rl.ReadBudgetChargeOnly[p]; !ok {
			out = append(out, "procedure "+p+" must be charge-only: the deletion/export path may never be blocked by the read budget")
		}
	}
	if len(procs) == 0 {
		out = append(out, "found no NO_SIDE_EFFECTS procedures: the enumeration is broken, so the guard would pass vacuously")
	}
	for _, p := range procs {
		if !rl.ReadBudgetCovers(p) {
			out = append(out, "read-only procedure "+p+" is not covered by the daily read budget (ADR-0010 D5)")
		}
	}
	return out
}

// TestReadBudgetGuard_EveryNoSideEffectsProcedureIsCovered is the ADR-0010 D5 / T3.5 CI guard: the daily
// Firestore read budget must be enabled in the config Build wires, and every read-only (NO_SIDE_EFFECTS)
// procedure must be covered by it. The exemption list is empty and must stay explained: adding an entry
// requires editing allowedReadBudgetExemptions below with a reason, in review.
func TestReadBudgetGuard_EveryNoSideEffectsProcedureIsCovered(t *testing.T) {
	// allowedReadBudgetExemptions: procedure -> why it may skip the read budget. Empty by ADR-0010 D5.
	allowedReadBudgetExemptions := map[string]string{}

	rl := RateLimitConfig(defaultRateLimitCfg())
	for _, v := range readBudgetGuardViolations(rl, noSideEffectsProcedures(t), allowedReadBudgetExemptions, allowedReadBudgetChargeOnly) {
		t.Error(v)
	}
	for _, v := range ipSetViolations(rl, profileExemptProcedures()) {
		t.Error(v)
	}
	for _, v := range accountOpsViolations(rl) {
		t.Error(v)
	}
}

// TestIPSetsAndAccountOpsGuard_MutationChecks proves the A4/A6 guards can fail.
func TestIPSetsAndAccountOpsGuard_MutationChecks(t *testing.T) {
	const newExempt = "/dzeroth.posts.v1.PostService/SomethingExempt"
	exempt := profileExemptProcedures()
	withNew := map[string]struct{}{newExempt: {}}
	for p := range exempt {
		withNew[p] = struct{}{}
	}
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		exempt map[string]struct{}
		want   string // "" = no violation
		fn     func(ratelimit.Config, map[string]struct{}) []string
	}{
		{"unmutated IP sets", func(*ratelimit.Config) {}, exempt, "", ipSetViolations},
		{"new exempt procedure is unclassified", func(*ratelimit.Config) {}, withNew, "profile-exempt procedure " + newExempt, ipSetViolations},
		{"IP budget unwired", func(c *ratelimit.Config) { c.ReadBudgetIP = nil }, exempt, "ReadBudgetIP is not wired", ipSetViolations},
		{"a procedure is moved to IP-enforced (A8 forbids)", func(c *ratelimit.Config) {
			p := identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure
			delete(c.ReadBudgetIPChargeOnly, p)
			c.ReadBudgetIPEnforce[p] = struct{}{}
		}, exempt, "ReadBudgetIPEnforce must be empty", ipSetViolations},
		{"CreateProfile becomes enforced too", func(c *ratelimit.Config) {
			c.ReadBudgetIPEnforce[identityv1connect.IdentityServiceCreateProfileProcedure] = struct{}{}
		}, exempt, "both IP-enforced and IP-charge-only", ipSetViolations},
		{"IP set names a non-exempt procedure", func(c *ratelimit.Config) {
			c.ReadBudgetIPChargeOnly[identityv1connect.IdentityServiceGetMeProcedure] = struct{}{}
		}, exempt, "is not profile-exempt", ipSetViolations},
		{"unmutated account ops", func(*ratelimit.Config) {}, nil, "", func(c ratelimit.Config, _ map[string]struct{}) []string { return accountOpsViolations(c) }},
		{"account op loses its daily cap", func(c *ratelimit.Config) {
			delete(c.DailyCaps, identityv1connect.IdentityServiceGetAccountExportProcedure)
		}, nil, "charge-only procedure " + identityv1connect.IdentityServiceGetAccountExportProcedure, func(c ratelimit.Config, _ map[string]struct{}) []string { return accountOpsViolations(c) }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(tt.fn(rl, tt.exempt), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}

// TestAccountOps_21stCallIsRateLimitedEvenOverTheReadBudget (A6): through the wired config, DeleteAccount is
// never rejected by the read budget (the uid is over it), but the shared account_ops_daily cap stops the 21st
// call of the IST day across the three account operations.
func TestAccountOps_21stCallIsRateLimitedEvenOverTheReadBudget(t *testing.T) {
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	rl := RateLimitConfig(cfg)
	rl.ReadBudget.Charge("uid-ops", 5000) // far over the read budget
	procs := []string{
		identityv1connect.IdentityServiceDeleteAccountProcedure,
		identityv1connect.IdentityServiceRequestAccountExportProcedure,
		identityv1connect.IdentityServiceGetAccountExportProcedure,
	}
	setUID := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: "uid-ops", SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(setUID, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range procs {
		mux.Handle(p, connect.NewUnaryHandler(p,
			func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				return connect.NewResponse(&commonv1.ErrorDetail{}), nil
			}, opts))
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	invoke := func(proc string) error {
		c := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+proc)
		_, err := c.CallUnary(context.Background(), connect.NewRequest(&commonv1.ErrorDetail{}))
		return err
	}
	for i := 0; i < 20; i++ {
		if err := invoke(procs[i%3]); err != nil {
			t.Fatalf("account op %d must pass (charge-only on the read budget): %v", i+1, err)
		}
	}
	err := invoke(procs[0])
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
		t.Fatalf("21st account op: err = %v, want ResourceExhausted", err)
	}
}

// TestReadBudgetGuard_MutationChecks proves the guard can fail (tester mutation check, T3 gap 1): each case
// breaks the wiring the way a careless change would and asserts a violation naming the culprit is reported.
func TestReadBudgetGuard_MutationChecks(t *testing.T) {
	const newRPC = "/dzeroth.posts.v1.PostService/GetPost" // a future NO_SIDE_EFFECTS RPC, synthetic
	real := noSideEffectsProcedures(t)
	if len(real) == 0 {
		t.Fatal("no real NO_SIDE_EFFECTS procedures found")
	}
	procs := append(append([]string{}, real...), newRPC)

	tests := []struct {
		name      string
		mutate    func(*ratelimit.Config)
		allowed   map[string]string
		allowedCO map[string]string // nil = allowedReadBudgetChargeOnly
		want      []string          // substrings that must appear in the violations
	}{
		{"unmutated config passes", func(*ratelimit.Config) {}, nil, nil, nil},
		{"read budget disabled", func(c *ratelimit.Config) { c.ReadBudget = nil }, nil,
			nil, []string{"read budget is disabled", newRPC, real[0]}},
		{"exemption without a reason", func(c *ratelimit.Config) {
			c.ReadBudgetExempt = map[string]struct{}{newRPC: {}}
		}, nil, nil, []string{"procedure " + newRPC + " is on the read budget exemption list without an explanation"}},
		{"explained exemption still leaves the procedure uncovered", func(c *ratelimit.Config) {
			c.ReadBudgetExempt = map[string]struct{}{newRPC: {}}
		}, map[string]string{newRPC: "because"}, nil, []string{"read-only procedure " + newRPC + " is not covered"}},
		{"real procedure exempted", func(c *ratelimit.Config) {
			c.ReadBudgetExempt = map[string]struct{}{real[0]: {}}
		}, nil, nil, []string{real[0]}},
		{"deletion path loses its charge-only entry", func(c *ratelimit.Config) {
			c.ReadBudgetChargeOnly = nil
		}, nil, nil, []string{"procedure " + identityv1connect.IdentityServiceDeleteAccountProcedure + " must be charge-only"}},
		{"export path loses its charge-only entry", func(c *ratelimit.Config) {
			delete(c.ReadBudgetChargeOnly, identityv1connect.IdentityServiceRequestAccountExportProcedure)
		}, nil, nil, []string{"procedure " + identityv1connect.IdentityServiceRequestAccountExportProcedure + " must be charge-only"}},
		{"new charge-only entry without a reason", func(c *ratelimit.Config) {
			c.ReadBudgetChargeOnly[newRPC] = struct{}{}
		}, nil, nil, []string{"procedure " + newRPC + " is charge-only (never rejected by the read budget) without an explanation"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			allowedCO := tt.allowedCO
			if allowedCO == nil {
				allowedCO = allowedReadBudgetChargeOnly
			}
			got := strings.Join(readBudgetGuardViolations(rl, procs, tt.allowed, allowedCO), "\n")
			if tt.want == nil && got != "" {
				t.Fatalf("unexpected violations:\n%s", got)
			}
			for _, w := range tt.want {
				if !strings.Contains(got, w) {
					t.Errorf("violations do not mention %q:\n%s", w, got)
				}
			}
		})
	}
	// An empty enumeration must fail rather than pass vacuously.
	if v := readBudgetGuardViolations(RateLimitConfig(defaultRateLimitCfg()), nil, nil, allowedReadBudgetChargeOnly); len(v) == 0 {
		t.Error("empty procedure list must be a violation")
	}
}

// TestCheckHandleAvailability_101stCallIsRateLimited (T3 acceptance): through the config Build actually
// wires (RateLimitConfig), a profile-less uid's 101st CheckHandleAvailability call in one IST day is
// RATE_LIMITED with limit_name check_handle_daily; the first 100 succeed; another uid is unaffected.
func TestCheckHandleAvailability_101stCallIsRateLimited(t *testing.T) {
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.CheckHandlePerUserPerMinute = 100000 // isolate the daily cap from the per-minute bucket
	cfg.RateLimit.PerIPPerMinute = 100000
	proc := identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure
	rl := RateLimitConfig(cfg)

	const uidHeader = "X-Test-UID"
	setUID := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get(uidHeader), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	handled := 0
	h := connect.NewUnaryHandler(proc,
		func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
			handled++
			return connect.NewResponse(&commonv1.ErrorDetail{}), nil
		}, connect.WithInterceptors(setUID, ratelimit.Interceptor(rl)))
	mux := http.NewServeMux()
	mux.Handle(proc, h)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	call := func(uid string) error {
		c := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+proc)
		req := connect.NewRequest(&commonv1.ErrorDetail{})
		req.Header().Set(uidHeader, uid)
		_, err := c.CallUnary(context.Background(), req)
		return err
	}
	for i := 1; i <= 100; i++ {
		if err := call("uid-noprofile"); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	err := call("uid-noprofile")
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
		t.Fatalf("101st call: err = %v, want ResourceExhausted", err)
	}
	limit := ""
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok {
				limit = ed.GetMetadata()["limit"]
				if ed.GetReason() != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED {
					t.Errorf("reason = %v, want RATE_LIMITED", ed.GetReason())
				}
			}
		}
	}
	if limit != "check_handle_daily" {
		t.Errorf("limit = %q, want check_handle_daily", limit)
	}
	if handled != 100 {
		t.Errorf("handler ran %d times, want 100 (the rejected call must not reach it)", handled)
	}
	if err := call("uid-other"); err != nil {
		t.Errorf("another uid must be unaffected: %v", err)
	}
}

// bookmarkMutationProcedures are the two bookmark RPCs that write an idempotency doc even when they change nothing
// (an already bookmarked Add, a Remove of a missing bookmark) and reserve no quota; they share one daily call cap.
var bookmarkMutationProcedures = []string{
	engagementv1connect.EngagementServiceAddBookmarkProcedure,
	engagementv1connect.EngagementServiceRemoveBookmarkProcedure,
}

// bookmarkMutationViolations asserts the W2-14 M-1 wiring (mirrors the graph_mutation_daily shape): AddBookmark and
// RemoveBookmark each have a DailyCaps entry named bookmark_mutation_daily, both entries hold the SAME DailyCap
// (one counter per uid, so Add + Remove draw on one budget), and ListBookmarks (a read, covered by the read budget)
// has none.
func bookmarkMutationViolations(rl ratelimit.Config) []string {
	var out []string
	var first *ratelimit.DailyCap
	for _, p := range bookmarkMutationProcedures {
		named, ok := rl.DailyCaps[p]
		switch {
		case !ok || named.Cap == nil || named.Name != "bookmark_mutation_daily":
			out = append(out, "bookmark mutation "+p+" has no bookmark_mutation_daily DailyCaps entry")
		case first == nil:
			first = named.Cap
		case named.Cap != first:
			out = append(out, "bookmark mutation "+p+" does not share the bookmark_mutation_daily DailyCap with the other bookmark mutation")
		}
	}
	if _, ok := rl.DailyCaps[engagementv1connect.EngagementServiceListBookmarksProcedure]; ok {
		out = append(out, "ListBookmarks must not be on the bookmark_mutation_daily cap (a read: the read budget covers it)")
	}
	return out
}

// TestBookmarkMutationDailyCap_Guard proves the M-1 guard passes on the shipped wiring and can fail.
func TestBookmarkMutationDailyCap_Guard(t *testing.T) {
	remove := engagementv1connect.EngagementServiceRemoveBookmarkProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string // "" = no violation
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"remove loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, remove) }, "bookmark mutation " + remove},
		{"remove has a nil cap", func(c *ratelimit.Config) {
			c.DailyCaps[remove] = ratelimit.NamedDailyCap{Name: "bookmark_mutation_daily"}
		}, "bookmark mutation " + remove},
		{"remove is renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[remove]
			n.Name = "graph_mutation_daily"
			c.DailyCaps[remove] = n
		}, "bookmark mutation " + remove},
		{"remove gets its own counter", func(c *ratelimit.Config) {
			c.DailyCaps[remove] = ratelimit.NamedDailyCap{Name: "bookmark_mutation_daily", Cap: ratelimit.NewDailyCap(1500)}
		}, "does not share"},
		{"list joins the cap", func(c *ratelimit.Config) {
			c.DailyCaps[engagementv1connect.EngagementServiceListBookmarksProcedure] = c.DailyCaps[remove]
		}, "ListBookmarks must not"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(bookmarkMutationViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}

// TestBookmarkMutationDailyCap_StopsTheCapPlusFirstCall (W2-14 M-1): through the wired interceptor, AddBookmark and
// RemoveBookmark draw on ONE per-uid daily budget, so the (cap+1)-th call of the day is ResourceExhausted whichever
// of the two it is, and another user is untouched (the name is asserted by the guard test above).
func TestBookmarkMutationDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 10
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.BookmarksPerUserPerMinute = 100000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	cfg.RateLimit.BookmarkMutationsPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range bookmarkMutationProcedures {
		mux.Handle(p, connect.NewUnaryHandler(p,
			func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				return connect.NewResponse(&commonv1.ErrorDetail{}), nil
			}, opts))
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	invoke := func(uid, proc string) error {
		c := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+proc)
		req := connect.NewRequest(&commonv1.ErrorDetail{})
		req.Header().Set("X-Test-Uid", uid)
		_, err := c.CallUnary(context.Background(), req)
		return err
	}
	for i := 0; i < dailyCap; i++ {
		if err := invoke("uid-bm", bookmarkMutationProcedures[i%2]); err != nil {
			t.Fatalf("bookmark mutation %d must pass: %v", i+1, err)
		}
	}
	for _, p := range bookmarkMutationProcedures {
		err := invoke("uid-bm", p)
		var ce *connect.Error
		if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
			t.Fatalf("%s after %d calls: err = %v, want ResourceExhausted", p, dailyCap, err)
		}
	}
	if err := invoke("uid-other", bookmarkMutationProcedures[1]); err != nil {
		t.Fatalf("another user must not share the counter: %v", err)
	}
}

// profileUpdateViolations asserts the W3-22 L-4 wiring: UpdateProfile has a DailyCaps entry named profile_update_daily
// with its own counter (no other procedure draws on it, so a busy account page cannot lock out account operations or
// the graph, and the reverse), and no other procedure carries the profile_update_daily name.
func profileUpdateViolations(rl ratelimit.Config) []string {
	var out []string
	update := identityv1connect.IdentityServiceUpdateProfileProcedure
	named, ok := rl.DailyCaps[update]
	if !ok || named.Cap == nil || named.Name != "profile_update_daily" {
		return append(out, "UpdateProfile has no profile_update_daily DailyCaps entry")
	}
	for p, other := range rl.DailyCaps {
		switch {
		case p == update:
		case other.Cap == named.Cap:
			out = append(out, "procedure "+p+" shares the profile_update_daily DailyCap")
		case other.Name == "profile_update_daily":
			out = append(out, "procedure "+p+" is named profile_update_daily; only UpdateProfile may be")
		}
	}
	return out
}

// TestProfileUpdateDailyCap_Guard proves the L-4 guard passes on the shipped wiring and can fail.
func TestProfileUpdateDailyCap_Guard(t *testing.T) {
	update := identityv1connect.IdentityServiceUpdateProfileProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string // "" = no violation
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"update loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, update) }, "UpdateProfile has no profile_update_daily"},
		{"update has a nil cap", func(c *ratelimit.Config) {
			c.DailyCaps[update] = ratelimit.NamedDailyCap{Name: "profile_update_daily"}
		}, "UpdateProfile has no profile_update_daily"},
		{"update is renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[update]
			n.Name = "account_ops_daily"
			c.DailyCaps[update] = n
		}, "UpdateProfile has no profile_update_daily"},
		{"change handle joins the counter", func(c *ratelimit.Config) {
			c.DailyCaps[identityv1connect.IdentityServiceChangeHandleProcedure] = c.DailyCaps[update]
		}, "shares the profile_update_daily DailyCap"},
		{"account export borrows the name", func(c *ratelimit.Config) {
			c.DailyCaps[identityv1connect.IdentityServiceGetAccountExportProcedure] = ratelimit.NamedDailyCap{Name: "profile_update_daily", Cap: ratelimit.NewDailyCap(5)}
		}, "only UpdateProfile may be"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(profileUpdateViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}

// TestProfileUpdateDailyCap_StopsTheCapPlusFirstCall (W3-22 L-4): through the wired interceptor, the (cap+1)-th
// UpdateProfile call of the day is RATE_LIMITED with limit=profile_update_daily, another user is untouched, and
// GetMe (no daily cap of its own) still passes for the capped user.
func TestProfileUpdateDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 4
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	cfg.RateLimit.ProfileUpdatesPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	update := identityv1connect.IdentityServiceUpdateProfileProcedure
	getMe := identityv1connect.IdentityServiceGetMeProcedure
	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range []string{update, getMe} {
		mux.Handle(p, connect.NewUnaryHandler(p,
			func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				return connect.NewResponse(&commonv1.ErrorDetail{}), nil
			}, opts))
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	invoke := func(uid, proc string) error {
		c := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+proc)
		req := connect.NewRequest(&commonv1.ErrorDetail{})
		req.Header().Set("X-Test-Uid", uid)
		_, err := c.CallUnary(context.Background(), req)
		return err
	}
	for i := 1; i <= dailyCap; i++ {
		if err := invoke("uid-edit", update); err != nil {
			t.Fatalf("UpdateProfile call %d must pass: %v", i, err)
		}
	}
	err := invoke("uid-edit", update)
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
		t.Fatalf("call %d: err = %v, want ResourceExhausted", dailyCap+1, err)
	}
	limit := ""
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok {
				if ed.GetReason() != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED {
					t.Errorf("reason = %v, want RATE_LIMITED", ed.GetReason())
				}
				limit = ed.GetMetadata()["limit"]
			}
		}
	}
	if limit != "profile_update_daily" {
		t.Errorf("limit = %q, want profile_update_daily", limit)
	}
	if err := invoke("uid-other", update); err != nil {
		t.Errorf("another user must not share the counter: %v", err)
	}
	if err := invoke("uid-edit", getMe); err != nil {
		t.Errorf("GetMe has no daily call cap and must pass for the capped user: %v", err)
	}
}
