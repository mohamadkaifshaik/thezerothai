package apiserver

import (
	"strings"
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// noSideEffectsProcedures lists every linked dzeroth Connect procedure whose proto method declares
// idempotency_level = NO_SIDE_EFFECTS: the same mechanical read-only signal degraded.Interceptor uses
// (req.Spec().IdempotencyLevel). Any service apiserver.go imports for registration is linked into this test
// binary, so a future read RPC shows up here without anyone editing this file.
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

// TestReadBudgetGuard_EveryNoSideEffectsProcedureIsCovered is the ADR-0010 D5 / T3.5 CI guard: the daily
// Firestore read budget must be enabled in the config Build wires, and every read-only (NO_SIDE_EFFECTS)
// procedure must be covered by it. The exemption list is empty and must stay explained: adding an entry
// requires editing allowedReadBudgetExemptions below with a reason, in review.
func TestReadBudgetGuard_EveryNoSideEffectsProcedureIsCovered(t *testing.T) {
	// allowedReadBudgetExemptions: procedure -> why it may skip the read budget. Empty by ADR-0010 D5.
	allowedReadBudgetExemptions := map[string]string{}

	cfg := config.Config{}
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 2000
	cfg.RateLimit.ReadBudgetPerIPNoProfilePerDay = 500
	cfg.RateLimit.CheckHandleCallsPerDay = 100
	rl := rateLimitConfig(cfg, nil)

	if rl.ReadBudget == nil {
		t.Fatal("read budget is disabled in the rate-limit config Build wires (ADR-0010 D5)")
	}
	for p := range rl.ReadBudgetExempt {
		if allowedReadBudgetExemptions[p] == "" {
			t.Errorf("procedure %s is on the read budget exemption list without an explanation", p)
		}
	}

	procs := noSideEffectsProcedures(t)
	if len(procs) == 0 {
		t.Fatal("found no NO_SIDE_EFFECTS procedures: the enumeration is broken, so the guard would pass vacuously")
	}
	for _, p := range procs {
		if !rl.ReadBudgetCovers(p) {
			t.Errorf("read-only procedure %s is not covered by the daily read budget (ADR-0010 D5): remove it from ReadBudgetExempt or explain the exemption", p)
		}
	}
}
