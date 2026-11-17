package publicid

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"testing"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

// canonicalValid is a test-local copy of identity.ValidPublicID (backend/internal/identity/publicid.go): platform
// packages must not import modules, even in tests. "u" + 26 characters of lowercase Crockford base32, the first of
// them 0-7. PR 4b asserts !identity.ValidPublicID(Tombstone) where it wires the real validator.
func canonicalValid(s string) bool {
	const alphabet = "0123456789abcdefghjkmnpqrstvwxyz"
	if len(s) != 27 || s[0] != 'u' {
		return false
	}
	for i := 1; i < len(s); i++ {
		if !containsByte(alphabet, s[i]) {
			return false
		}
	}
	return containsByte(alphabet[:8], s[1])
}

func containsByte(s string, c byte) bool {
	for i := range len(s) {
		if s[i] == c {
			return true
		}
	}
	return false
}

// uidN is a Firebase-shaped uid (28 mixed-case characters); pubN its well-formed public id.
func uidN(n int) string { return fmt.Sprintf("FbUid%023d", n) }
func pubN(n int) string { return fmt.Sprintf("u0%025d", n) }

// fakeResolver answers from a fixed pair table and records every call.
type fakeResolver struct {
	mu       sync.Mutex
	uidToPub map[string]string
	pubToUID map[string]string
	err      error
	calls    [][]string
}

func newFakeResolver(pairs map[string]string) *fakeResolver {
	f := &fakeResolver{uidToPub: map[string]string{}, pubToUID: map[string]string{}}
	for uid, pub := range pairs {
		f.uidToPub[uid] = pub
		f.pubToUID[pub] = uid
	}
	return f
}

func (f *fakeResolver) lookup(ids []string, table map[string]string) (map[string]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, slices.Clone(ids))
	if f.err != nil {
		return nil, f.err
	}
	out := make(map[string]string, len(ids))
	for _, id := range ids {
		if v, ok := table[id]; ok {
			out[id] = v
		}
	}
	return out, nil
}

func (f *fakeResolver) PublicIDsForUIDs(_ context.Context, uids []string) (map[string]string, error) {
	return f.lookup(uids, f.uidToPub)
}

func (f *fakeResolver) UIDsForPublicIDs(_ context.Context, pubs []string) (map[string]string, error) {
	return f.lookup(pubs, f.pubToUID)
}

var errResolver = errors.New("resolver down")

// ---- a test-only API, built from hand-written descriptors (no file under proto/) ----

const testPkg = "dzeroth.pubtest.v1"

type fieldOpt func(*descriptorpb.FieldDescriptorProto)

func ref(k commonv1.UserRefKind) fieldOpt {
	return func(f *descriptorpb.FieldDescriptorProto) {
		opts := &descriptorpb.FieldOptions{}
		proto.SetExtension(opts, commonv1.E_UserRef, k)
		f.Options = opts
	}
}

func repeated() fieldOpt {
	return func(f *descriptorpb.FieldDescriptorProto) {
		f.Label = descriptorpb.FieldDescriptorProto_LABEL_REPEATED.Enum()
	}
}

func inOneof(i int32) fieldOpt {
	return func(f *descriptorpb.FieldDescriptorProto) { f.OneofIndex = proto.Int32(i) }
}

func fld(name string, num int32, typ descriptorpb.FieldDescriptorProto_Type, typeName string, opts ...fieldOpt) *descriptorpb.FieldDescriptorProto {
	f := &descriptorpb.FieldDescriptorProto{
		Name:     proto.String(name),
		JsonName: proto.String(name),
		Number:   proto.Int32(num),
		Type:     typ.Enum(),
		Label:    descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
	}
	if typeName != "" {
		f.TypeName = proto.String("." + testPkg + "." + typeName)
	}
	for _, o := range opts {
		o(f)
	}
	return f
}

const (
	tString  = descriptorpb.FieldDescriptorProto_TYPE_STRING
	tMessage = descriptorpb.FieldDescriptorProto_TYPE_MESSAGE
	tInt32   = descriptorpb.FieldDescriptorProto_TYPE_INT32
	tInt64   = descriptorpb.FieldDescriptorProto_TYPE_INT64

	kTranslate   = commonv1.UserRefKind_USER_REF_KIND_TRANSLATE
	kConditional = commonv1.UserRefKind_USER_REF_KIND_CONDITIONAL
	kPublicID    = commonv1.UserRefKind_USER_REF_KIND_PUBLIC_ID
	kNotUser     = commonv1.UserRefKind_USER_REF_KIND_NOT_USER
)

func mapEntry(name, valueType string, valueTypeName string, valueOpts ...fieldOpt) *descriptorpb.DescriptorProto {
	vt := tString
	if valueType == "message" {
		vt = tMessage
	}
	return &descriptorpb.DescriptorProto{
		Name:    proto.String(name),
		Options: &descriptorpb.MessageOptions{MapEntry: proto.Bool(true)},
		Field: []*descriptorpb.FieldDescriptorProto{
			fld("key", 1, tString, ""),
			fld("value", 2, vt, valueTypeName, valueOpts...),
		},
	}
}

// testFile is the base test API:
//
//	Author  { user_id TRANSLATE; public_id PUBLIC_ID; name }
//	Post    { id; author Author; mentions repeated Author; embedded Post; map<string,Author> authors;
//	          ids repeated TRANSLATE; oneof target { owner_id TRANSLATE; handle }; count int64; meta map<string,string> }
//	Report  { target_type int32; target_id CONDITIONAL; tagged repeated CONDITIONAL }
//	Plain   { x; nested Plain; not_user NOT_USER }
//	Req     { post Post; user_id TRANSLATE }
//	Choice  { oneof who { user_id TRANSLATE; public_id PUBLIC_ID } }
//	service Svc { Get(Req) Post; Report(Report) Plain; Ping(Plain) Plain; Pick(Choice) Choice }
func testFile() *descriptorpb.FileDescriptorProto {
	return &descriptorpb.FileDescriptorProto{
		Name:    proto.String("dzeroth/pubtest/v1/pubtest.proto"),
		Package: proto.String(testPkg),
		Syntax:  proto.String("proto3"),
		MessageType: []*descriptorpb.DescriptorProto{
			{Name: proto.String("Author"), Field: []*descriptorpb.FieldDescriptorProto{
				fld("user_id", 1, tString, "", ref(kTranslate)),
				fld("public_id", 2, tString, "", ref(kPublicID)),
				fld("name", 3, tString, ""),
			}},
			{
				Name: proto.String("Post"),
				Field: []*descriptorpb.FieldDescriptorProto{
					fld("id", 1, tString, ""),
					fld("author", 2, tMessage, "Author"),
					fld("mentions", 3, tMessage, "Author", repeated()),
					fld("embedded", 4, tMessage, "Post"),
					fld("authors", 5, tMessage, "Post.AuthorsEntry", repeated()),
					fld("ids", 6, tString, "", repeated(), ref(kTranslate)),
					fld("owner_id", 7, tString, "", inOneof(0), ref(kTranslate)),
					fld("handle", 8, tString, "", inOneof(0)),
					fld("count", 9, tInt64, ""),
					fld("meta", 10, tMessage, "Post.MetaEntry", repeated()),
				},
				NestedType: []*descriptorpb.DescriptorProto{
					mapEntry("AuthorsEntry", "message", "Author"),
					mapEntry("MetaEntry", "string", ""),
				},
				OneofDecl: []*descriptorpb.OneofDescriptorProto{{Name: proto.String("target")}},
			},
			{Name: proto.String("Report"), Field: []*descriptorpb.FieldDescriptorProto{
				fld("target_type", 1, tInt32, ""),
				fld("target_id", 2, tString, "", ref(kConditional)),
				fld("tagged", 3, tString, "", repeated(), ref(kConditional)),
			}},
			{Name: proto.String("Plain"), Field: []*descriptorpb.FieldDescriptorProto{
				fld("x", 1, tString, ""),
				fld("nested", 2, tMessage, "Plain"),
				fld("not_user", 3, tString, "", ref(kNotUser)),
			}},
			{Name: proto.String("Req"), Field: []*descriptorpb.FieldDescriptorProto{
				fld("post", 1, tMessage, "Post"),
				fld("user_id", 2, tString, "", ref(kTranslate)),
			}},
			{
				Name: proto.String("Choice"),
				Field: []*descriptorpb.FieldDescriptorProto{
					fld("user_id", 1, tString, "", inOneof(0), ref(kTranslate)),
					fld("public_id", 2, tString, "", inOneof(0), ref(kPublicID)),
				},
				OneofDecl: []*descriptorpb.OneofDescriptorProto{{Name: proto.String("who")}},
			},
		},
		Service: []*descriptorpb.ServiceDescriptorProto{{
			Name: proto.String("Svc"),
			Method: []*descriptorpb.MethodDescriptorProto{
				method("Get", "Req", "Post"),
				method("Report", "Report", "Plain"),
				method("Ping", "Plain", "Plain"),
				method("Pick", "Choice", "Choice"),
			},
		}},
	}
}

func method(name, in, out string) *descriptorpb.MethodDescriptorProto {
	return &descriptorpb.MethodDescriptorProto{
		Name:       proto.String(name),
		InputType:  proto.String("." + testPkg + "." + in),
		OutputType: proto.String("." + testPkg + "." + out),
	}
}

func compile(t testing.TB, fdp *descriptorpb.FileDescriptorProto) protoreflect.FileDescriptor {
	t.Helper()
	fd, err := protodesc.NewFile(fdp, protoregistry.GlobalFiles)
	if err != nil {
		t.Fatalf("compile test proto: %v", err)
	}
	return fd
}

// reportRule is the test rule for Report: target_id is a user id when target_type == 2; a tagged value "<tag>_<id>"
// holds the id after its last "_".
func reportRules(t testing.TB) *Rules {
	t.Helper()
	r := NewRules()
	if err := r.Register(testPkg+".Report.target_id", func(parent protoreflect.Message, v string) (Span, bool) {
		fd := parent.Descriptor().Fields().ByName("target_type")
		return WholeValue(v), parent.Get(fd).Int() == 2
	}); err != nil {
		t.Fatal(err)
	}
	if err := r.Register(testPkg+".Report.tagged", func(_ protoreflect.Message, v string) (Span, bool) {
		for i := len(v) - 1; i >= 0; i-- {
			if v[i] == '_' {
				return Span{Start: i + 1, End: len(v)}, true
			}
		}
		return Span{}, false
	}); err != nil {
		t.Fatal(err)
	}
	return r
}

type testAPI struct {
	file  protoreflect.FileDescriptor
	plans *Plans
}

func newTestAPI(t testing.TB) *testAPI {
	t.Helper()
	fd := compile(t, testFile())
	plans, err := BuildPlans([]protoreflect.ServiceDescriptor{fd.Services().Get(0)}, reportRules(t))
	if err != nil {
		t.Fatalf("BuildPlans: %v", err)
	}
	return &testAPI{file: fd, plans: plans}
}

func (a *testAPI) msg(name string) *dynamicpb.Message {
	return dynamicpb.NewMessage(a.file.Messages().ByName(protoreflect.Name(name)))
}

func newTranslatorT(t testing.TB, plans *Plans, r Resolver, batch int) *Translator {
	t.Helper()
	tr, err := NewTranslator(plans, r, canonicalValid, batch)
	if err != nil {
		t.Fatalf("NewTranslator: %v", err)
	}
	return tr
}

// setStr sets a singular string field by name.
func setStr(m protoreflect.Message, name, v string) {
	m.Set(m.Descriptor().Fields().ByName(protoreflect.Name(name)), protoreflect.ValueOfString(v))
}

func getStr(m protoreflect.Message, name string) string {
	return m.Get(m.Descriptor().Fields().ByName(protoreflect.Name(name))).String()
}

func setMsg(m protoreflect.Message, name string, v protoreflect.Message) {
	m.Set(m.Descriptor().Fields().ByName(protoreflect.Name(name)), protoreflect.ValueOfMessage(v))
}

func getMsg(m protoreflect.Message, name string) protoreflect.Message {
	return m.Get(m.Descriptor().Fields().ByName(protoreflect.Name(name))).Message()
}

func list(m protoreflect.Message, name string) protoreflect.List {
	return m.Mutable(m.Descriptor().Fields().ByName(protoreflect.Name(name))).List()
}

func strs(l protoreflect.List) []string {
	out := make([]string, l.Len())
	for i := range l.Len() {
		out[i] = l.Get(i).String()
	}
	return out
}
