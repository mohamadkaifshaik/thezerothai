package publicid

import (
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

func TestBuildPlans_TestAPI(t *testing.T) {
	api := newTestAPI(t)
	if got := api.plans.Methods(); got != 4 {
		t.Errorf("Methods = %d, want 4", got)
	}
	for _, tc := range []struct {
		name              string
		planned, hasSteps bool
	}{
		{"Author", true, true},
		{"Post", true, true},
		{"Req", true, true},
		{"Report", true, true},
		{"Choice", true, true},
		{"Plain", true, false},
		{"Post.MetaEntry", false, false}, // map entries are walked through their map field, never planned as types
		{"Nope", false, false},
	} {
		planned, hasSteps := api.plans.Lookup(protoreflect.FullName(testPkg + "." + tc.name))
		if planned != tc.planned || hasSteps != tc.hasSteps {
			t.Errorf("Lookup(%s) = (%v, %v), want (%v, %v)", tc.name, planned, hasSteps, tc.planned, tc.hasSteps)
		}
	}
	want := map[string]StepKind{
		"Author.user_id":   StepTranslate,
		"Author.public_id": StepFillPublicID,
		"Post.ids":         StepTranslateRepeated,
		"Post.owner_id":    StepTranslate,
		"Req.user_id":      StepTranslate,
		"Report.target_id": StepConditional,
		"Report.tagged":    StepConditional,
		"Choice.user_id":   StepTranslate,
	}
	got := api.plans.Covered()
	if len(got) != len(want) {
		t.Errorf("Covered = %v, want %d entries", got, len(want))
	}
	for name, k := range want {
		if got[protoreflect.FullName(testPkg+"."+name)] != k {
			t.Errorf("Covered[%s] = %v, want %v", name, got[protoreflect.FullName(testPkg+"."+name)], k)
		}
	}
	msgs := api.plans.Messages()
	if len(msgs) != 6 {
		t.Errorf("Messages = %v, want the 6 test types", msgs)
	}
}

// TestBuildPlans_RecursiveTypeWithoutRefsIsNil: a self-recursive type with no user reference gets a nil plan, and a
// recursive type with one (Post.embedded) descends into itself.
func TestBuildPlans_RecursiveTypes(t *testing.T) {
	api := newTestAPI(t)
	post := api.plans.byName[testPkg+".Post"]
	found := false
	for _, s := range post.steps {
		if s.fd.Name() == "embedded" {
			found = s.sub == post && s.kind == StepDescend
		}
	}
	if !found {
		t.Error("Post.embedded: want a descend step into Post's own plan")
	}
	if api.plans.byName[testPkg+".Plain"] != nil {
		t.Error("Plain (recursive, no refs) should have a nil plan")
	}
}

func TestStepKind_String(t *testing.T) {
	for k, want := range map[StepKind]string{
		StepTranslate: "translate", StepTranslateRepeated: "translateRepeated", StepDescend: "descend",
		StepDescendRepeated: "descendRepeated", StepDescendMapValue: "descendMapValue",
		StepFillPublicID: "fillPublicID", StepConditional: "conditional", 0: "StepKind(0)", 99: "StepKind(99)",
	} {
		if got := k.String(); got != want {
			t.Errorf("%d.String() = %q, want %q", k, got, want)
		}
	}
}

func findMsg(fdp *descriptorpb.FileDescriptorProto, name string) *descriptorpb.DescriptorProto {
	for _, m := range fdp.MessageType {
		if m.GetName() == name {
			return m
		}
	}
	panic("no message " + name)
}

func findField(m *descriptorpb.DescriptorProto, name string) *descriptorpb.FieldDescriptorProto {
	for _, f := range m.Field {
		if f.GetName() == name {
			return f
		}
	}
	panic("no field " + name)
}

func annotate(f *descriptorpb.FieldDescriptorProto, k commonv1.UserRefKind) { ref(k)(f) }

// TestBuildPlans_FailsClosed: every construction failure the design lists, on the test API.
func TestBuildPlans_FailsClosed(t *testing.T) {
	for _, tc := range []struct {
		name    string
		mutate  func(*descriptorpb.FileDescriptorProto)
		rules   func(testing.TB) *Rules
		wantErr string
	}{
		{"streaming method", func(f *descriptorpb.FileDescriptorProto) {
			f.Service[0].Method[2].ServerStreaming = proto.Bool(true)
		}, reportRules, "is streaming"},
		{"client streaming method", func(f *descriptorpb.FileDescriptorProto) {
			f.Service[0].Method[2].ClientStreaming = proto.Bool(true)
		}, reportRules, "is streaming"},
		{"annotated int", func(f *descriptorpb.FileDescriptorProto) {
			annotate(findField(findMsg(f, "Post"), "count"), kTranslate)
		}, reportRules, "only string and repeated string"},
		{"annotated message field", func(f *descriptorpb.FileDescriptorProto) {
			annotate(findField(findMsg(f, "Post"), "author"), kTranslate)
		}, reportRules, "only string and repeated string"},
		{"annotated map field", func(f *descriptorpb.FileDescriptorProto) {
			annotate(findField(findMsg(f, "Post"), "meta"), kTranslate)
		}, reportRules, "map"},
		{"annotated map key", func(f *descriptorpb.FileDescriptorProto) {
			annotate(findMsg(f, "Post").NestedType[1].Field[0], kTranslate)
		}, reportRules, "map"},
		{"annotated scalar map value", func(f *descriptorpb.FileDescriptorProto) {
			annotate(findMsg(f, "Post").NestedType[1].Field[1], kTranslate)
		}, reportRules, "map"},
		{"unspecified kind", func(f *descriptorpb.FileDescriptorProto) {
			annotate(findField(findMsg(f, "Plain"), "x"), commonv1.UserRefKind_USER_REF_KIND_UNSPECIFIED)
		}, reportRules, "UNSPECIFIED"},
		{"conditional without rule", nil, func(testing.TB) *Rules { return nil }, "has no registered rule"},
		{"rule for a field that is not conditional", nil, func(t testing.TB) *Rules {
			r := reportRules(t)
			if err := r.Register(testPkg+".Plain.x", func(protoreflect.Message, string) (Span, bool) { return Span{}, false }); err != nil {
				t.Fatal(err)
			}
			return r
		}, "not a CONDITIONAL field"},
		{"pass-through for an unreachable field", nil, func(t testing.TB) *Rules {
			r := reportRules(t)
			if err := r.PassThroughUntilRuleLands("dzeroth.other.v1.X.y", "later"); err != nil {
				t.Fatal(err)
			}
			return r
		}, "not a CONDITIONAL field"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fdp := testFile()
			if tc.mutate != nil {
				tc.mutate(fdp)
			}
			fd := compile(t, fdp)
			_, err := BuildPlans([]protoreflect.ServiceDescriptor{fd.Services().Get(0)}, tc.rules(t))
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("BuildPlans error = %v, want one containing %q", err, tc.wantErr)
			}
		})
	}
}

// TestBuildPlans_PassThroughLeavesFieldUntouched: a CONDITIONAL field marked pass-through gets no step.
func TestBuildPlans_PassThroughLeavesFieldUntouched(t *testing.T) {
	fd := compile(t, testFile())
	r := NewRules()
	for _, f := range []protoreflect.FullName{testPkg + ".Report.target_id", testPkg + ".Report.tagged"} {
		if err := r.PassThroughUntilRuleLands(f, "rule lands in a later PR"); err != nil {
			t.Fatal(err)
		}
	}
	plans, err := BuildPlans([]protoreflect.ServiceDescriptor{fd.Services().Get(0)}, r)
	if err != nil {
		t.Fatal(err)
	}
	if planned, hasSteps := plans.Lookup(testPkg + ".Report"); !planned || hasSteps {
		t.Errorf("Report Lookup = (%v, %v), want planned with a nil plan", planned, hasSteps)
	}
	if got := len(r.PassThrough()); got != 2 {
		t.Errorf("PassThrough has %d entries, want 2", got)
	}
}

func TestRules_Registration(t *testing.T) {
	noop := func(protoreflect.Message, string) (Span, bool) { return Span{}, false }
	const f = protoreflect.FullName("dzeroth.x.v1.M.f")
	for _, tc := range []struct {
		name string
		run  func(r *Rules) error
	}{
		{"nil rule", func(r *Rules) error { return r.Register(f, nil) }},
		{"invalid name", func(r *Rules) error { return r.Register("not a name", noop) }},
		{"double register", func(r *Rules) error {
			_ = r.Register(f, noop)
			return r.Register(f, noop)
		}},
		{"rule then pass-through", func(r *Rules) error {
			_ = r.Register(f, noop)
			return r.PassThroughUntilRuleLands(f, "x")
		}},
		{"pass-through then rule", func(r *Rules) error {
			_ = r.PassThroughUntilRuleLands(f, "x")
			return r.Register(f, noop)
		}},
		{"pass-through twice", func(r *Rules) error {
			_ = r.PassThroughUntilRuleLands(f, "x")
			return r.PassThroughUntilRuleLands(f, "x")
		}},
		{"pass-through without reason", func(r *Rules) error { return r.PassThroughUntilRuleLands(f, "") }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := tc.run(NewRules()); err == nil {
				t.Fatal("want an error")
			}
		})
	}
}

// TestFillPublicID_NotInOneof: Choice keeps its TRANSLATE and PUBLIC_ID fields in one oneof, so it gets no fill step
// (filling would switch the arm), while Author gets one.
func TestFillPublicID_NotInOneof(t *testing.T) {
	api := newTestAPI(t)
	for _, s := range api.plans.byName[testPkg+".Choice"].steps {
		if s.kind == StepFillPublicID {
			t.Fatal("Choice: fill step planned across a oneof")
		}
	}
}

func TestDzerothServices_FiltersPackage(t *testing.T) {
	var files protoregistry.Files
	if err := files.RegisterFile(compile(t, testFile())); err != nil {
		t.Fatal(err)
	}
	other := testFile()
	other.Name = proto.String("other/v1/other.proto")
	other.Package = proto.String("other.v1")
	// Type names point at the dzeroth test package; rewrite them for the copy.
	for _, m := range other.MessageType {
		rewrite(m)
	}
	for _, md := range other.Service[0].Method {
		md.InputType = proto.String(strings.Replace(md.GetInputType(), testPkg, "other.v1", 1))
		md.OutputType = proto.String(strings.Replace(md.GetOutputType(), testPkg, "other.v1", 1))
	}
	if err := files.RegisterFile(compile(t, other)); err != nil {
		t.Fatal(err)
	}
	svcs := DzerothServices(&files)
	if len(svcs) != 1 || svcs[0].FullName() != testPkg+".Svc" {
		t.Fatalf("DzerothServices = %v, want only %s.Svc", svcs, testPkg)
	}
}

func rewrite(m *descriptorpb.DescriptorProto) {
	for _, f := range m.Field {
		if f.TypeName != nil {
			f.TypeName = proto.String(strings.Replace(f.GetTypeName(), testPkg, "other.v1", 1))
		}
	}
	for _, n := range m.NestedType {
		rewrite(n)
	}
}
