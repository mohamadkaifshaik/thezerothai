package publicid

import (
	"bytes"
	"context"
	"fmt"
	"math/rand/v2"
	"slices"
	"sync"
	"testing"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/userref"
)

// The known uid set for the property tests: uidN(1..6) have public ids, uidN(100) has none.
var (
	mappedUIDs = []string{uidN(1), uidN(2), uidN(3), uidN(4), uidN(5), uidN(6)}
	unmapped   = uidN(100)
)

func propertyPairs() map[string]string {
	p := map[string]string{}
	for i, u := range mappedUIDs {
		p[u] = pubN(i + 1)
	}
	return p
}

var (
	realOnce  sync.Once
	realTr    *Translator
	realRoots []protoreflect.MessageDescriptor
	// realPlansShared is the plans behind realTr.
	realPlansShared *Plans
	realErr         error
)

// realAPI builds the real plans once per test binary and lists every RPC input and output type, sorted and distinct.
func realAPI(t testing.TB) (*Translator, []protoreflect.MessageDescriptor) {
	t.Helper()
	realOnce.Do(func() {
		services := DzerothServices(protoregistry.GlobalFiles)
		plans, err := BuildPlans(services, realRuleSet)
		if err != nil {
			realErr = err
			return
		}
		// A non-recording resolver: a long -fuzz run must not grow a call log.
		w := warmResolver{uidToPub: propertyPairs(), pubToUID: map[string]string{}}
		for u, p := range w.uidToPub {
			w.pubToUID[p] = u
		}
		realPlansShared = plans
		realTr, realErr = NewTranslator(plans, w, canonicalValid, 500)
		seen := map[protoreflect.FullName]bool{}
		for _, sd := range services {
			for i := range sd.Methods().Len() {
				md := sd.Methods().Get(i)
				for _, m := range []protoreflect.MessageDescriptor{md.Input(), md.Output()} {
					if !seen[m.FullName()] {
						seen[m.FullName()] = true
						realRoots = append(realRoots, m)
					}
				}
			}
		}
		slices.SortFunc(realRoots, func(a, b protoreflect.MessageDescriptor) int {
			return compareNames(a.FullName(), b.FullName())
		})
	})
	if realErr != nil {
		t.Fatal(realErr)
	}
	return realTr, realRoots
}

func compareNames(a, b protoreflect.FullName) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// populator fills a message through protoreflect: every TRANSLATE string gets a uid from uids (round robin), every
// CONDITIONAL string (set after its siblings) a uid in the span its stand-in rule (realRuleSet) names, or a value
// outside the uid set when the rule says it holds no user id, every other string a value outside the uid set, every
// scalar a non-zero value, and messages, lists (2 elements) and maps (2 entries) recurse to maxDepth. variant picks the arm of each oneof (arm variant mod n); with r set, fields are
// skipped and arms picked at random instead. A PUBLIC_ID field next to a set singular TRANSLATE field (both outside
// oneofs) is pre-filled with the public id the walker will write, so the oracle can leave PUBLIC_ID alone.
type populator struct {
	uids     []string
	next     int
	variant  int
	r        *rand.Rand
	maxDepth int
	pubOf    func(string) string
	// populated, when set, records every field the populator set (so a test can prove the plan's fields were reached).
	populated map[protoreflect.FullName]bool
}

func (p *populator) uid() string {
	u := p.uids[p.next%len(p.uids)]
	p.next++
	return u
}

func realOneof(fd protoreflect.FieldDescriptor) protoreflect.OneofDescriptor {
	if o := fd.ContainingOneof(); o != nil && !o.IsSynthetic() {
		return o
	}
	return nil
}

func (p *populator) fill(m protoreflect.Message, depth int) {
	md := m.Descriptor()
	arms := map[protoreflect.FullName]int{}
	oneofs := md.Oneofs()
	for i := range oneofs.Len() {
		o := oneofs.Get(i)
		if o.IsSynthetic() {
			continue
		}
		n := o.Fields().Len()
		if p.r != nil {
			arms[o.FullName()] = p.r.IntN(n)
		} else {
			arms[o.FullName()] = p.variant % n
		}
	}
	fields := md.Fields()
	for i := range fields.Len() {
		fd := fields.Get(i)
		if o := realOneof(fd); o != nil && o.Fields().Get(arms[o.FullName()]) != fd {
			continue
		}
		if p.r != nil && p.r.IntN(4) == 0 {
			continue
		}
		if k, _ := userref.Kind(fd); k == commonv1.UserRefKind_USER_REF_KIND_PUBLIC_ID || k == commonv1.UserRefKind_USER_REF_KIND_CONDITIONAL {
			continue // after the loop
		}
		p.field(m, fd, depth)
	}
	for i := range fields.Len() {
		fd := fields.Get(i)
		if k, _ := userref.Kind(fd); k != commonv1.UserRefKind_USER_REF_KIND_CONDITIONAL {
			continue
		}
		if o := realOneof(fd); o != nil && o.Fields().Get(arms[o.FullName()]) != fd {
			continue
		}
		if p.r != nil && p.r.IntN(4) == 0 {
			continue
		}
		p.conditional(m, fd)
	}
	for i := range fields.Len() {
		fd := fields.Get(i)
		if k, _ := userref.Kind(fd); k != commonv1.UserRefKind_USER_REF_KIND_PUBLIC_ID {
			continue
		}
		if o := realOneof(fd); o != nil {
			if o.Fields().Get(arms[o.FullName()]) == fd {
				m.Set(fd, protoreflect.ValueOfString("literal-public-id-"+string(fd.Name())))
			}
			continue
		}
		if src := soleTranslateSibling(md); src != nil && m.Has(src) {
			m.Set(fd, protoreflect.ValueOfString(p.pubOf(m.Get(src).String())))
		} else if p.r == nil || p.r.IntN(2) == 0 {
			m.Set(fd, protoreflect.ValueOfString("literal-public-id-"+string(fd.Name())))
		}
	}
}

// conditional sets a CONDITIONAL field once its siblings are set: a probe value tells where the stand-in rule puts the
// user id, and a uid goes there; a value outside the uid set when the rule says the field holds none.
func (p *populator) conditional(m protoreflect.Message, fd protoreflect.FieldDescriptor) {
	if p.populated != nil {
		p.populated[fd.FullName()] = true
	}
	rule := realRuleSet.rules[fd.FullName()]
	value := func() string {
		probe := "s-" + string(fd.Name()) + "_probe"
		if rule != nil {
			if sp, ok := rule(m, probe); ok && sp.Start < sp.End {
				return probe[:sp.Start] + p.uid() + probe[sp.End:]
			}
		}
		return "s-" + string(fd.Name()) + "-0"
	}
	if fd.IsList() {
		l := m.Mutable(fd).List()
		l.Append(protoreflect.ValueOfString(value()))
		l.Append(protoreflect.ValueOfString(""))
		return
	}
	m.Set(fd, protoreflect.ValueOfString(value()))
}

func soleTranslateSibling(md protoreflect.MessageDescriptor) protoreflect.FieldDescriptor {
	var found protoreflect.FieldDescriptor
	n := 0
	for i := range md.Fields().Len() {
		fd := md.Fields().Get(i)
		if userref.Translate(fd) {
			n++
			found = fd
		}
	}
	if n != 1 || found.IsList() || realOneof(found) != nil {
		return nil
	}
	return found
}

func (p *populator) field(m protoreflect.Message, fd protoreflect.FieldDescriptor, depth int) {
	if p.populated != nil {
		p.populated[fd.FullName()] = true
	}
	switch {
	case fd.IsMap():
		vfd := fd.MapValue()
		if vfd.Message() != nil && depth >= p.maxDepth {
			return
		}
		mp := m.Mutable(fd).Map()
		for i := range 2 {
			key := p.mapKey(fd.MapKey(), i)
			if vfd.Message() != nil {
				v := mp.NewValue()
				p.fill(v.Message(), depth+1)
				mp.Set(key, v)
			} else {
				mp.Set(key, p.scalar(vfd, i))
			}
		}
	case fd.IsList():
		if fd.Message() != nil && depth >= p.maxDepth {
			return
		}
		l := m.Mutable(fd).List()
		for i := range 2 {
			if fd.Message() != nil {
				v := l.NewElement()
				p.fill(v.Message(), depth+1)
				l.Append(v)
				continue
			}
			l.Append(p.scalar(fd, i))
		}
	case fd.Message() != nil:
		if depth >= p.maxDepth {
			return
		}
		v := m.NewField(fd)
		p.fill(v.Message(), depth+1)
		m.Set(fd, v)
	default:
		m.Set(fd, p.scalar(fd, 0))
	}
}

func (p *populator) mapKey(fd protoreflect.FieldDescriptor, i int) protoreflect.MapKey {
	switch fd.Kind() {
	case protoreflect.StringKind:
		return protoreflect.ValueOfString(fmt.Sprintf("key-%d", i)).MapKey()
	case protoreflect.BoolKind:
		return protoreflect.ValueOfBool(i == 1).MapKey()
	case protoreflect.Int64Kind, protoreflect.Sint64Kind, protoreflect.Sfixed64Kind:
		return protoreflect.ValueOfInt64(int64(i + 1)).MapKey()
	case protoreflect.Uint64Kind, protoreflect.Fixed64Kind:
		return protoreflect.ValueOfUint64(uint64(i + 1)).MapKey()
	case protoreflect.Uint32Kind, protoreflect.Fixed32Kind:
		return protoreflect.ValueOfUint32(uint32(i + 1)).MapKey()
	default:
		return protoreflect.ValueOfInt32(int32(i + 1)).MapKey()
	}
}

// scalar is the value of a non-message field. A repeated TRANSLATE gets a uid then "" (so "" survives is checked).
func (p *populator) scalar(fd protoreflect.FieldDescriptor, i int) protoreflect.Value {
	switch fd.Kind() {
	case protoreflect.StringKind:
		if userref.Translate(fd) {
			if i == 1 {
				return protoreflect.ValueOfString("")
			}
			return protoreflect.ValueOfString(p.uid())
		}
		return protoreflect.ValueOfString(fmt.Sprintf("s-%s-%d", fd.Name(), i))
	case protoreflect.BytesKind:
		return protoreflect.ValueOfBytes([]byte{byte(i + 1)})
	case protoreflect.BoolKind:
		return protoreflect.ValueOfBool(true)
	case protoreflect.EnumKind:
		vals := fd.Enum().Values()
		return protoreflect.ValueOfEnum(vals.Get(min(1, vals.Len()-1)).Number())
	case protoreflect.FloatKind:
		return protoreflect.ValueOfFloat32(1.5)
	case protoreflect.DoubleKind:
		return protoreflect.ValueOfFloat64(2.5)
	case protoreflect.Int64Kind, protoreflect.Sint64Kind, protoreflect.Sfixed64Kind:
		return protoreflect.ValueOfInt64(int64(i + 7))
	case protoreflect.Uint64Kind, protoreflect.Fixed64Kind:
		return protoreflect.ValueOfUint64(uint64(i + 7))
	case protoreflect.Uint32Kind, protoreflect.Fixed32Kind:
		return protoreflect.ValueOfUint32(uint32(i + 7))
	default:
		return protoreflect.ValueOfInt32(int32(i + 7))
	}
}

// oracle is the independent reference translation: it reads user_ref on every set field (no plan) and replaces every
// TRANSLATE value by pubOf, and in every CONDITIONAL value the span its stand-in rule names (realRuleSet: the rules
// themselves are tested in apiserver and notifications; here the walker's mechanics are). PUBLIC_ID fields are left
// alone (the populator pre-fills them).
func oracle(m protoreflect.Message, pubOf func(string) string) {
	var set []protoreflect.FieldDescriptor
	m.Range(func(fd protoreflect.FieldDescriptor, _ protoreflect.Value) bool {
		set = append(set, fd)
		return true
	})
	for _, fd := range set {
		switch {
		case fd.IsMap():
			if fd.MapValue().Message() != nil {
				m.Get(fd).Map().Range(func(_ protoreflect.MapKey, v protoreflect.Value) bool {
					oracle(v.Message(), pubOf)
					return true
				})
			}
		case fd.Message() != nil && fd.IsList():
			l := m.Get(fd).List()
			for i := range l.Len() {
				oracle(l.Get(i).Message(), pubOf)
			}
		case fd.Message() != nil:
			oracle(m.Get(fd).Message(), pubOf)
		case userref.Translate(fd) && fd.IsList():
			l := m.Mutable(fd).List()
			for i := range l.Len() {
				l.Set(i, protoreflect.ValueOfString(pubOf(l.Get(i).String())))
			}
		case userref.Translate(fd):
			m.Set(fd, protoreflect.ValueOfString(pubOf(m.Get(fd).String())))
		case realRuleSet.rules[fd.FullName()] != nil:
			rule := realRuleSet.rules[fd.FullName()]
			swap := func(v string) string {
				if sp, ok := rule(m, v); ok && v != "" && sp.Start < sp.End {
					return v[:sp.Start] + pubOf(v[sp.Start:sp.End]) + v[sp.End:]
				}
				return v
			}
			if fd.IsList() {
				l := m.Mutable(fd).List()
				for i := range l.Len() {
					l.Set(i, protoreflect.ValueOfString(swap(l.Get(i).String())))
				}
				continue
			}
			m.Set(fd, protoreflect.ValueOfString(swap(m.Get(fd).String())))
		}
	}
}

func pubOfFunc(pairs map[string]string) func(string) string {
	return func(uid string) string {
		if uid == "" {
			return ""
		}
		if p, ok := pairs[uid]; ok {
			return p
		}
		return Tombstone
	}
}

func newReal(t testing.TB, md protoreflect.MessageDescriptor) protoreflect.Message {
	t.Helper()
	mt, err := protoregistry.GlobalTypes.FindMessageByName(md.FullName())
	if err != nil {
		t.Fatalf("%s: %v", md.FullName(), err)
	}
	return mt.New()
}

func maxArms(md protoreflect.MessageDescriptor, seen map[protoreflect.FullName]bool) int {
	if seen[md.FullName()] {
		return 1
	}
	seen[md.FullName()] = true
	n := 1
	for i := range md.Oneofs().Len() {
		if o := md.Oneofs().Get(i); !o.IsSynthetic() {
			n = max(n, o.Fields().Len())
		}
	}
	for i := range md.Fields().Len() {
		fd := md.Fields().Get(i)
		if fd.IsMap() {
			fd = fd.MapValue()
		}
		if fd.Message() != nil {
			n = max(n, maxArms(fd.Message(), seen))
		}
	}
	return n
}

var marshalDet = proto.MarshalOptions{Deterministic: true}

// checkProperties runs the walker over one populated message and checks every property against the oracle.
func checkProperties(t testing.TB, tr *Translator, md protoreflect.MessageDescriptor, pop *populator, roundTrip bool) {
	t.Helper()
	pairs := propertyPairs()
	pubOf := pubOfFunc(pairs)
	pop.pubOf = pubOf
	orig := newReal(t, md)
	pop.fill(orig, 0)
	origMsg := orig.Interface()

	want := proto.Clone(origMsg)
	oracle(want.ProtoReflect(), pubOf)
	got := proto.Clone(origMsg)
	if _, err := tr.TranslateResponse(context.Background(), nil, got); err != nil {
		t.Fatalf("%s: TranslateResponse: %v", md.FullName(), err)
	}
	if !proto.Equal(got, want) {
		t.Fatalf("%s: walker != oracle\n got: %v\nwant: %v", md.FullName(), got, want)
	}
	gotBin, err := marshalDet.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	wantBin, err := marshalDet.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotBin, wantBin) {
		t.Fatalf("%s: deterministic bytes differ from the oracle", md.FullName())
	}
	js, err := protojson.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	for _, u := range append(slices.Clone(mappedUIDs), unmapped) {
		if bytes.Contains(gotBin, []byte(u)) || bytes.Contains(js, []byte(u)) {
			t.Fatalf("%s: uid %s survived outbound translation", md.FullName(), u)
		}
	}
	back := proto.Clone(got)
	if _, err := tr.TranslateRequest(context.Background(), back); err != nil {
		t.Fatalf("%s: inbound of an outbound message: %v", md.FullName(), err)
	}
	if roundTrip && !proto.Equal(back, origMsg) {
		t.Fatalf("%s: inbound(outbound(m)) != m\n got: %v\nwant: %v", md.FullName(), back, origMsg)
	}
}

// TestProperties_RealAPI: every RPC input and output type, fully populated, once per oneof arm; with only mapped uids
// (round trip exact) and with an unmapped uid in the mix (tombstoned).
func TestProperties_RealAPI(t *testing.T) {
	tr, roots := realAPI(t)
	populated := map[protoreflect.FullName]bool{}
	for _, md := range roots {
		arms := maxArms(md, map[protoreflect.FullName]bool{})
		for v := range arms {
			t.Run(fmt.Sprintf("%s/arm%d", md.FullName(), v), func(t *testing.T) {
				checkProperties(t, tr, md, &populator{uids: mappedUIDs, variant: v, maxDepth: propertyDepth, populated: populated}, true)
				checkProperties(t, tr, md, &populator{uids: append(slices.Clone(mappedUIDs), unmapped), variant: v, maxDepth: propertyDepth}, false)
			})
		}
	}
	// The population must reach every field a plan translates; otherwise a deep chain could be skipped silently.
	// If this fails, raise propertyDepth rather than relaxing the check.
	for name, k := range realPlansShared.Covered() {
		if k != StepFillPublicID && !populated[name] {
			t.Errorf("%s (%v) was never populated by the property test", name, k)
		}
	}
}

// propertyDepth is how deep the property test populates nested messages.
const propertyDepth = 4

// FuzzTranslate picks an RPC message type and a random population from the inputs. The seed corpus runs as a normal
// test; `go test -fuzz FuzzTranslate ./pkg/platform/publicid/` explores further.
func FuzzTranslate(f *testing.F) {
	for i := range 8 {
		f.Add(uint16(i*37), uint64(i)*0x9e3779b97f4a7c15, i%2 == 0)
	}
	f.Fuzz(func(t *testing.T, idx uint16, seed uint64, withUnmapped bool) {
		tr, roots := realAPI(t)
		md := roots[int(idx)%len(roots)]
		uids := mappedUIDs
		if withUnmapped {
			uids = append(slices.Clone(mappedUIDs), unmapped)
		}
		pop := &populator{uids: uids, r: rand.New(rand.NewPCG(seed, uint64(idx))), maxDepth: 3, next: int(seed % 7)}
		checkProperties(t, tr, md, pop, !withUnmapped)
	})
}
