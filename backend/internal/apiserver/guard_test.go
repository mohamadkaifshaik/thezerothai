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
	return cfg
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

	rl := rateLimitConfig(defaultRateLimitCfg(), nil)
	for _, v := range readBudgetGuardViolations(rl, noSideEffectsProcedures(t), allowedReadBudgetExemptions, allowedReadBudgetChargeOnly) {
		t.Error(v)
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
			rl := rateLimitConfig(defaultRateLimitCfg(), nil)
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
	if v := readBudgetGuardViolations(rateLimitConfig(defaultRateLimitCfg(), nil), nil, nil, allowedReadBudgetChargeOnly); len(v) == 0 {
		t.Error("empty procedure list must be a violation")
	}
}

// TestCheckHandleAvailability_101stCallIsRateLimited (T3 acceptance): through the config Build actually
// wires (rateLimitConfig), a profile-less uid's 101st CheckHandleAvailability call in one IST day is
// RATE_LIMITED with limit_name check_handle_daily; the first 100 succeed; another uid is unaffected.
func TestCheckHandleAvailability_101stCallIsRateLimited(t *testing.T) {
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.CheckHandlePerUserPerMinute = 100000 // isolate the daily cap from the per-minute bucket
	cfg.RateLimit.PerIPPerMinute = 100000
	proc := identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure
	rl := rateLimitConfig(cfg, authn.ProfileExemptProcedures(proc))

	const uidHeader = "X-Test-UID"
	setUID := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get(uidHeader)}), req)
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
