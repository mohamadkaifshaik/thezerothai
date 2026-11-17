package publicid

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"

	// Every dzeroth proto package, linked so its descriptors are in protoregistry.GlobalFiles (the same list as
	// pkg/platform/userref's guard). TestGuard_LinksEveryProtoPackage checks it against proto/dzeroth.
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/userref"
)

// pendingRules are the CONDITIONAL fields of the real API whose rule has not landed yet: plans leave them untouched,
// so they would carry raw uids to a flagged caller. Empty since PR 4c, and the guard requires it to stay empty: an
// entry is a known uid leak and needs an explicit, reviewed change to this table and to the count check below.
var pendingRules = map[protoreflect.FullName]string{}

// wantConditional is the exact set of CONDITIONAL fields of the real API. Each has a production rule registered by
// internal/apiserver (public_ids_wiring.go, tested there over the real plans); this package cannot import those, so
// the guard builds the real plans with standInRules, which mirror them by enum number. A new CONDITIONAL field fails
// the guard until it is added here, given a stand-in, and given a real rule in apiserver.
var wantConditional = []protoreflect.FullName{
	"dzeroth.moderation.v1.ReportContentRequest.target_id",
	"dzeroth.notifications.v1.Notification.id",
}

// standInRules mirrors the production rules for wantConditional: target_id is a user id exactly when target_type is
// REPORT_TARGET_TYPE_ACCOUNT (2); Notification.id's last "_" segment is the actor's id for the actor-keyed types
// FOLLOW (1), REPOST (5), FOLLOW_REQUEST (7), FOLLOW_ACCEPTED (8) and BEACON_REQUEST (10), the whole id when it has no
// "_". Panics on a registration error (a bug in this table).
func standInRules() *Rules {
	r := NewRules()
	enumIs := func(parent protoreflect.Message, field string, nums ...protoreflect.EnumNumber) bool {
		fd := parent.Descriptor().Fields().ByName(protoreflect.Name(field))
		return fd != nil && slices.Contains(nums, parent.Get(fd).Enum())
	}
	must := func(err error) {
		if err != nil {
			panic(err)
		}
	}
	must(r.Register(wantConditional[0], func(parent protoreflect.Message, v string) (Span, bool) {
		return WholeValue(v), enumIs(parent, "target_type", 2)
	}))
	must(r.Register(wantConditional[1], func(parent protoreflect.Message, v string) (Span, bool) {
		if !enumIs(parent, "type", 1, 5, 7, 8, 10) {
			return Span{}, false
		}
		return Span{Start: strings.LastIndexByte(v, '_') + 1, End: len(v)}, true
	}))
	return r
}

// realRuleSet is the stand-in registry shared by the real-API tests, the populator and the oracle.
var realRuleSet = standInRules()

// unreachableAnnotated are annotated fields no RPC reaches, each with the reason. Empty today; an entry is a finding
// to report, not a way to quiet the guard.
var unreachableAnnotated = map[protoreflect.FullName]string{}

// wantFill is the exact set of PUBLIC_ID fields the walker fills outbound.
var wantFill = []protoreflect.FullName{
	"dzeroth.common.v1.AuthorSnapshot.public_id",
	"dzeroth.identity.v1.Profile.public_id",
}

func realPlans(t testing.TB) *Plans {
	t.Helper()
	plans, err := BuildPlans(DzerothServices(protoregistry.GlobalFiles), realRuleSet)
	if err != nil {
		t.Fatalf("BuildPlans over the real API: %v", err)
	}
	return plans
}

func dzerothFiles() []protoreflect.FileDescriptor {
	var out []protoreflect.FileDescriptor
	protoregistry.GlobalFiles.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		if strings.HasPrefix(string(fd.Package()), "dzeroth.") {
			out = append(out, fd)
		}
		return true
	})
	return out
}

// eachAnnotated calls fn for every field of every dzeroth message (nested included) that carries user_ref, read
// independently of the plan builder.
func eachAnnotated(fn func(protoreflect.FieldDescriptor, commonv1.UserRefKind)) {
	var walk func(ms protoreflect.MessageDescriptors)
	walk = func(ms protoreflect.MessageDescriptors) {
		for i := range ms.Len() {
			md := ms.Get(i)
			fields := md.Fields()
			for j := range fields.Len() {
				if k, ok := userref.Kind(fields.Get(j)); ok {
					fn(fields.Get(j), k)
				}
			}
			walk(md.Messages())
		}
	}
	for _, fd := range dzerothFiles() {
		walk(fd.Messages())
	}
}

func TestGuard_LinksEveryProtoPackage(t *testing.T) {
	entries, err := os.ReadDir(filepath.Join("..", "..", "..", "..", "proto", "dzeroth"))
	if err != nil {
		t.Fatalf("read proto/dzeroth: %v", err)
	}
	var want, got []string
	for _, e := range entries {
		if e.IsDir() {
			want = append(want, "dzeroth."+e.Name()+".v1")
		}
	}
	for _, fd := range dzerothFiles() {
		if p := string(fd.Package()); !slices.Contains(got, p) {
			got = append(got, p)
		}
	}
	slices.Sort(want)
	slices.Sort(got)
	if !slices.Equal(got, want) {
		t.Fatalf("linked dzeroth packages = %v, want %v (add the missing blank import)", got, want)
	}
}

// TestGuard_RealAPIPlans: plans build over the real API (so no streaming method, no badly placed annotation, every
// CONDITIONAL field has a rule or a pending mark), every RPC input and output is planned, every annotated field is
// reachable from an RPC, every reachable TRANSLATE field is in a step, and the fill set is exactly wantFill.
func TestGuard_RealAPIPlans(t *testing.T) {
	plans := realPlans(t)
	services := DzerothServices(protoregistry.GlobalFiles)
	rpcs, withSteps := 0, 0
	for _, sd := range services {
		ms := sd.Methods()
		for i := range ms.Len() {
			md := ms.Get(i)
			rpcs++
			for _, msg := range []protoreflect.MessageDescriptor{md.Input(), md.Output()} {
				planned, hasSteps := plans.Lookup(msg.FullName())
				if !planned {
					t.Errorf("%s: %s has no plan", md.FullName(), msg.FullName())
				}
				if hasSteps {
					withSteps++
				}
			}
		}
	}
	if rpcs == 0 || rpcs != plans.Methods() {
		t.Fatalf("rpcs = %d, plans.Methods = %d", rpcs, plans.Methods())
	}

	covered := plans.Covered()
	var conditional []protoreflect.FullName
	eachAnnotated(func(fd protoreflect.FieldDescriptor, kind commonv1.UserRefKind) {
		name := fd.FullName()
		reachable, _ := plans.Lookup(fd.ContainingMessage().FullName())
		if reason, listed := unreachableAnnotated[name]; listed {
			if reachable {
				t.Errorf("%s is listed unreachable (%s) but an RPC reaches it; remove the entry", name, reason)
			}
			return
		}
		if !reachable {
			t.Errorf("%s (%v) is annotated but no RPC reaches it", name, kind)
			return
		}
		switch kind {
		case commonv1.UserRefKind_USER_REF_KIND_TRANSLATE:
			if k := covered[name]; k != StepTranslate && k != StepTranslateRepeated {
				t.Errorf("%s: TRANSLATE but plan step = %v", name, k)
			}
		case commonv1.UserRefKind_USER_REF_KIND_CONDITIONAL:
			conditional = append(conditional, name)
			if covered[name] != StepConditional {
				t.Errorf("%s: CONDITIONAL without a conditional step", name)
			}
		case commonv1.UserRefKind_USER_REF_KIND_PUBLIC_ID:
			if k, ok := covered[name]; ok && k != StepFillPublicID {
				t.Errorf("%s: PUBLIC_ID in step %v", name, k)
			}
		default:
			if k, ok := covered[name]; ok {
				t.Errorf("%s (%v) is in step %v; only TRANSLATE, CONDITIONAL and filled PUBLIC_ID fields may be", name, kind, k)
			}
		}
	})
	// Zero pending CONDITIONAL fields: every one has a rule. Raising this number is a reviewed decision to ship a field
	// that carries raw uids to flagged callers; it must name the field and the change that closes it.
	if len(pendingRules) != 0 {
		t.Errorf("pendingRules has %d entries %v; every CONDITIONAL field must have a rule", len(pendingRules), pendingRules)
	}
	slices.Sort(conditional)
	if !slices.Equal(conditional, wantConditional) {
		t.Errorf("CONDITIONAL fields = %v, want %v (a new one needs a stand-in here and a real rule in apiserver)", conditional, wantConditional)
	}

	var fill []protoreflect.FullName
	for name, k := range covered {
		if k == StepFillPublicID {
			fill = append(fill, name)
		}
	}
	slices.Sort(fill)
	if !slices.Equal(fill, wantFill) {
		t.Errorf("fill set = %v, want %v", fill, wantFill)
	}
	nonNil := 0
	for _, name := range plans.Messages() {
		if _, hasSteps := plans.Lookup(name); hasSteps {
			nonNil++
		}
	}
	t.Logf("real API: %d RPCs, %d planned message types (%d with steps), %d RPC inputs/outputs with steps, %d covered fields, conditional %v",
		rpcs, len(plans.Messages()), nonNil, withSteps, len(covered), conditional)
}

// TestGuard_RealAPIMissingRuleFails: the real API does not build (fail closed) when any CONDITIONAL field lacks a rule,
// so dropping a registration cannot slip through.
func TestGuard_RealAPIMissingRuleFails(t *testing.T) {
	if _, err := BuildPlans(DzerothServices(protoregistry.GlobalFiles), nil); err == nil || !strings.Contains(err.Error(), "has no registered rule") {
		t.Fatalf("BuildPlans without rules = %v, want a missing-rule error", err)
	}
	for _, keep := range wantConditional {
		r := NewRules()
		if err := r.Register(keep, realRuleSet.rules[keep]); err != nil {
			t.Fatal(err)
		}
		if _, err := BuildPlans(DzerothServices(protoregistry.GlobalFiles), r); err == nil || !strings.Contains(err.Error(), "has no registered rule") {
			t.Errorf("BuildPlans with only %s = %v, want the missing-rule error for the other field", keep, err)
		}
	}
}
