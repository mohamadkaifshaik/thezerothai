package publicid

import (
	"errors"
	"fmt"

	"google.golang.org/protobuf/reflect/protoreflect"
)

// Span locates the user id inside a CONDITIONAL field's value: value[Start:End].
type Span struct {
	Start, End int
}

// Rule decides, for one value of a CONDITIONAL field, whether it holds a user id and where. parent is the message that
// holds the field, so a rule can read a sibling (e.g. target_type). It answers ok=false when the value holds no user
// id; the walker then leaves it untouched. Both directions use the same rule: inbound the span holds a public id and is
// replaced by the uid with the usual semantics, outbound it holds a uid and is replaced by the public id. A rule must
// be pure and must not modify parent.
type Rule func(parent protoreflect.Message, value string) (span Span, ok bool)

// WholeValue is the span of the entire value, for rules that translate the field as a whole when a sibling says so.
func WholeValue(value string) Span { return Span{Start: 0, End: len(value)} }

// Rules is the registry of CONDITIONAL field rules, keyed by the field's full name. Every CONDITIONAL field reachable
// from an RPC must have exactly one entry, either a rule or a pass-through mark, or BuildPlans fails. Not safe for
// concurrent registration; build it once before BuildPlans.
type Rules struct {
	rules   map[protoreflect.FullName]Rule
	pending map[protoreflect.FullName]string
}

// NewRules returns an empty registry.
func NewRules() *Rules {
	return &Rules{rules: map[protoreflect.FullName]Rule{}, pending: map[protoreflect.FullName]string{}}
}

// Register sets the rule for a CONDITIONAL field. A nil rule, a second registration or a field already marked
// pass-through is an error.
func (r *Rules) Register(field protoreflect.FullName, rule Rule) error {
	if rule == nil {
		return fmt.Errorf("publicid: nil rule for %s", field)
	}
	if err := r.free(field); err != nil {
		return err
	}
	r.rules[field] = rule
	return nil
}

// PassThroughUntilRuleLands marks a CONDITIONAL field as deliberately untranslated: the walker leaves it untouched in
// both directions, so it keeps carrying raw uids on the wire. It exists only so plans can be built for an API whose
// rule has not been written yet; reason must say which change adds the rule. Never use it for a field that is live
// with FEATURE_PUBLIC_IDS on.
func (r *Rules) PassThroughUntilRuleLands(field protoreflect.FullName, reason string) error {
	if reason == "" {
		return fmt.Errorf("publicid: pass-through for %s needs a reason", field)
	}
	if err := r.free(field); err != nil {
		return err
	}
	r.pending[field] = reason
	return nil
}

// PassThrough lists the fields marked by PassThroughUntilRuleLands with their reasons (a copy).
func (r *Rules) PassThrough() map[protoreflect.FullName]string {
	out := make(map[protoreflect.FullName]string, len(r.pending))
	for k, v := range r.pending {
		out[k] = v
	}
	return out
}

func (r *Rules) free(field protoreflect.FullName) error {
	if !field.IsValid() {
		return fmt.Errorf("publicid: %q is not a full field name", field)
	}
	if _, ok := r.rules[field]; ok {
		return fmt.Errorf("publicid: %s already has a rule", field)
	}
	if _, ok := r.pending[field]; ok {
		return fmt.Errorf("publicid: %s is already marked pass-through", field)
	}
	return nil
}

// errBadSpan is returned (wrapped) when a rule answers a span outside its value: a bug in the rule, so the walk fails.
var errBadSpan = errors.New("publicid: rule returned a span outside the value")
