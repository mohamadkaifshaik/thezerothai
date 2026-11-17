package publicid

import (
	"fmt"
	"slices"
	"strings"

	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/userref"
)

// StepKind is what a plan step does with its field.
type StepKind uint8

const (
	// StepTranslate translates a singular TRANSLATE string.
	StepTranslate StepKind = iota + 1
	// StepTranslateRepeated translates every element of a repeated TRANSLATE string.
	StepTranslateRepeated
	// StepDescend walks into a singular message field.
	StepDescend
	// StepDescendRepeated walks into every element of a repeated message field.
	StepDescendRepeated
	// StepDescendMapValue walks into every value of a message-valued map.
	StepDescendMapValue
	// StepFillPublicID sets the PUBLIC_ID field to the public id written into its sibling TRANSLATE field (outbound only).
	StepFillPublicID
	// StepConditional applies a registered Rule to a CONDITIONAL string (singular or repeated).
	StepConditional
)

var stepNames = [...]string{
	StepTranslate: "translate", StepTranslateRepeated: "translateRepeated", StepDescend: "descend",
	StepDescendRepeated: "descendRepeated", StepDescendMapValue: "descendMapValue", StepFillPublicID: "fillPublicID",
	StepConditional: "conditional",
}

func (k StepKind) String() string {
	if int(k) < len(stepNames) && stepNames[k] != "" {
		return stepNames[k]
	}
	return fmt.Sprintf("StepKind(%d)", k)
}

type step struct {
	kind StepKind
	fd   protoreflect.FieldDescriptor
	// src is the TRANSLATE field a StepFillPublicID copies from.
	src  protoreflect.FieldDescriptor
	sub  *plan
	rule Rule
}

type plan struct {
	steps []step
}

// Plans holds one plan per message type reachable from the API. Immutable after BuildPlans; safe for concurrent use.
type Plans struct {
	// byName has an entry for every reachable message type; the value is nil when the type has no user reference in
	// its transitive closure. A missing key means the type was never planned, which the walker treats as an error.
	byName  map[protoreflect.FullName]*plan
	methods int
	covered map[protoreflect.FullName]StepKind
}

// DzerothServices returns every service whose package starts with "dzeroth." in files, in a stable order. Production
// passes protoregistry.GlobalFiles.
func DzerothServices(files *protoregistry.Files) []protoreflect.ServiceDescriptor {
	var out []protoreflect.ServiceDescriptor
	files.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		if strings.HasPrefix(string(fd.Package()), "dzeroth.") {
			svcs := fd.Services()
			for i := range svcs.Len() {
				out = append(out, svcs.Get(i))
			}
		}
		return true
	})
	slices.SortFunc(out, func(a, b protoreflect.ServiceDescriptor) int {
		return strings.Compare(string(a.FullName()), string(b.FullName()))
	})
	return out
}

// BuildPlans builds the plans for the input and output message of every method of services. It fails (and the server
// must not serve) when:
//   - a method is client or server streaming (the walker is unary only);
//   - a user_ref annotation is UNSPECIFIED, or sits on a field that is not string or repeated string (a map field, a
//     map key or a map value counts as not string);
//   - a CONDITIONAL field reachable from an RPC has neither a rule nor a pass-through mark in rules;
//   - rules names a field that is not a reachable CONDITIONAL field (so a stale entry cannot linger).
//
// rules may be nil when the API has no CONDITIONAL field.
func BuildPlans(services []protoreflect.ServiceDescriptor, rules *Rules) (*Plans, error) {
	if rules == nil {
		rules = NewRules()
	}
	b := builder{rules: rules, children: map[protoreflect.FullName][]protoreflect.MessageDescriptor{}, direct: map[protoreflect.FullName]bool{}, seenRule: map[protoreflect.FullName]bool{}}
	var roots []protoreflect.MessageDescriptor
	methods := 0
	for _, sd := range services {
		ms := sd.Methods()
		for i := range ms.Len() {
			md := ms.Get(i)
			if md.IsStreamingClient() || md.IsStreamingServer() {
				return nil, fmt.Errorf("publicid: %s is streaming; only unary methods can be translated", md.FullName())
			}
			methods++
			roots = append(roots, md.Input(), md.Output())
		}
	}
	for _, md := range roots {
		if err := b.visit(md); err != nil {
			return nil, err
		}
	}
	for name := range rules.rules {
		if !b.seenRule[name] {
			return nil, fmt.Errorf("publicid: rule for %s, which is not a CONDITIONAL field reachable from an RPC", name)
		}
	}
	for name := range rules.pending {
		if !b.seenRule[name] {
			return nil, fmt.Errorf("publicid: pass-through mark for %s, which is not a CONDITIONAL field reachable from an RPC", name)
		}
	}
	return b.build(methods), nil
}

type builder struct {
	rules *Rules
	order []protoreflect.MessageDescriptor
	// children are the message types directly reachable from a type (fields, list elements, map values).
	children map[protoreflect.FullName][]protoreflect.MessageDescriptor
	// direct marks a type that holds a translated field itself (TRANSLATE, or CONDITIONAL with a rule).
	direct   map[protoreflect.FullName]bool
	seenRule map[protoreflect.FullName]bool
}

// visit records md and everything reachable from it, validating every field once per type.
func (b *builder) visit(md protoreflect.MessageDescriptor) error {
	if _, ok := b.children[md.FullName()]; ok {
		return nil
	}
	b.children[md.FullName()] = nil // placeholder: breaks recursion
	b.order = append(b.order, md)
	var kids []protoreflect.MessageDescriptor
	fields := md.Fields()
	for i := range fields.Len() {
		fd := fields.Get(i)
		if err := b.checkField(fd); err != nil {
			return err
		}
		switch {
		case fd.IsMap():
			if v := fd.MapValue(); v.Message() != nil {
				kids = append(kids, v.Message())
			}
		case fd.Message() != nil:
			kids = append(kids, fd.Message())
		}
	}
	b.children[md.FullName()] = kids
	for _, k := range kids {
		if err := b.visit(k); err != nil {
			return err
		}
	}
	return nil
}

func (b *builder) checkField(fd protoreflect.FieldDescriptor) error {
	if fd.IsMap() {
		for _, f := range []protoreflect.FieldDescriptor{fd, fd.MapKey(), fd.MapValue()} {
			if _, ok := userref.Kind(f); ok {
				return fmt.Errorf("publicid: %s: user_ref on a map, map key or map value is not supported", fd.FullName())
			}
		}
		return nil
	}
	kind, ok := userref.Kind(fd)
	if !ok {
		return nil
	}
	if kind == commonv1.UserRefKind_USER_REF_KIND_UNSPECIFIED {
		return fmt.Errorf("publicid: %s: user_ref = UNSPECIFIED", fd.FullName())
	}
	if fd.Kind() != protoreflect.StringKind {
		return fmt.Errorf("publicid: %s: user_ref on a %v field; only string and repeated string are supported", fd.FullName(), fd.Kind())
	}
	switch kind {
	case commonv1.UserRefKind_USER_REF_KIND_TRANSLATE:
		b.direct[fd.ContainingMessage().FullName()] = true
	case commonv1.UserRefKind_USER_REF_KIND_CONDITIONAL:
		b.seenRule[fd.FullName()] = true
		_, hasRule := b.rules.rules[fd.FullName()]
		_, pending := b.rules.pending[fd.FullName()]
		if !hasRule && !pending {
			return fmt.Errorf("publicid: %s is CONDITIONAL and has no registered rule", fd.FullName())
		}
		if hasRule {
			b.direct[fd.ContainingMessage().FullName()] = true
		}
	}
	return nil
}

// build decides which types need a plan by a fixed point over the reachable graph (a type needs one when it holds a
// translated field or reaches a type that does), then fills the steps. Deciding first keeps recursive types right.
func (b *builder) build(methods int) *Plans {
	need := map[protoreflect.FullName]bool{}
	for name, d := range b.direct {
		need[name] = d
	}
	for changed := true; changed; {
		changed = false
		for _, md := range b.order {
			if need[md.FullName()] {
				continue
			}
			for _, k := range b.children[md.FullName()] {
				if need[k.FullName()] {
					need[md.FullName()] = true
					changed = true
					break
				}
			}
		}
	}
	p := &Plans{byName: make(map[protoreflect.FullName]*plan, len(b.order)), methods: methods, covered: map[protoreflect.FullName]StepKind{}}
	for _, md := range b.order {
		if need[md.FullName()] {
			p.byName[md.FullName()] = &plan{}
		} else {
			p.byName[md.FullName()] = nil
		}
	}
	for _, md := range b.order {
		if pl := p.byName[md.FullName()]; pl != nil {
			pl.steps = b.steps(md, p)
			for _, s := range pl.steps {
				if s.kind != StepDescend && s.kind != StepDescendRepeated && s.kind != StepDescendMapValue {
					p.covered[s.fd.FullName()] = s.kind
				}
			}
		}
	}
	return p
}

func (b *builder) steps(md protoreflect.MessageDescriptor, p *Plans) []step {
	var out []step
	var translate, pub []protoreflect.FieldDescriptor
	fields := md.Fields()
	for i := range fields.Len() {
		fd := fields.Get(i)
		if fd.IsMap() {
			if v := fd.MapValue().Message(); v != nil && p.byName[v.FullName()] != nil {
				out = append(out, step{kind: StepDescendMapValue, fd: fd, sub: p.byName[v.FullName()]})
			}
			continue
		}
		if m := fd.Message(); m != nil {
			if sub := p.byName[m.FullName()]; sub != nil {
				k := StepDescend
				if fd.IsList() {
					k = StepDescendRepeated
				}
				out = append(out, step{kind: k, fd: fd, sub: sub})
			}
			continue
		}
		kind, _ := userref.Kind(fd)
		switch kind {
		case commonv1.UserRefKind_USER_REF_KIND_TRANSLATE:
			translate = append(translate, fd)
			k := StepTranslate
			if fd.IsList() {
				k = StepTranslateRepeated
			}
			out = append(out, step{kind: k, fd: fd})
		case commonv1.UserRefKind_USER_REF_KIND_CONDITIONAL:
			if rule, ok := b.rules.rules[fd.FullName()]; ok {
				out = append(out, step{kind: StepConditional, fd: fd, rule: rule})
			}
		case commonv1.UserRefKind_USER_REF_KIND_PUBLIC_ID:
			pub = append(pub, fd)
		}
	}
	if len(translate) == 1 && len(pub) == 1 && fillable(translate[0]) && fillable(pub[0]) {
		out = append(out, step{kind: StepFillPublicID, fd: pub[0], src: translate[0]})
	}
	return out
}

// fillable: a singular field outside any real oneof, so writing it never selects or switches an arm
// (GetProfileRequest keeps user_id and public_id in one oneof and is therefore never filled).
func fillable(fd protoreflect.FieldDescriptor) bool {
	if fd.IsList() {
		return false
	}
	o := fd.ContainingOneof()
	return o == nil || o.IsSynthetic()
}

// Methods is the number of methods planned.
func (p *Plans) Methods() int { return p.methods }

// Lookup reports whether the message type was planned (reachable from some method) and whether its plan does any work.
func (p *Plans) Lookup(name protoreflect.FullName) (planned, hasSteps bool) {
	pl, ok := p.byName[name]
	return ok, pl != nil
}

// Messages lists every planned message type, sorted.
func (p *Plans) Messages() []protoreflect.FullName {
	out := make([]protoreflect.FullName, 0, len(p.byName))
	for name := range p.byName {
		out = append(out, name)
	}
	slices.Sort(out)
	return out
}

// Covered maps every field a plan step reads or writes (not the descend steps) to its step kind: the guard uses it to
// prove every reachable TRANSLATE field is translated.
func (p *Plans) Covered() map[protoreflect.FullName]StepKind {
	out := make(map[protoreflect.FullName]StepKind, len(p.covered))
	for k, v := range p.covered {
		out[k] = v
	}
	return out
}
