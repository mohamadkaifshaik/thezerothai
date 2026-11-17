package publicid

import (
	"context"
	"errors"
	"fmt"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// ErrNoPlan is returned when a message's type was not planned (not the input or output of any planned method, nor
// reachable from one). The walker fails closed rather than pass an unknown message through.
var ErrNoPlan = errors.New("publicid: message type has no plan")

// Translator walks messages along their plans. Safe for concurrent use; all per-request data lives in State.
type Translator struct {
	plans    *Plans
	resolver Resolver
	valid    func(string) bool
	maxBatch int
}

// NewTranslator wires the walker. valid is the canonical public id validator (identity.ValidPublicID) and maxBatch the
// most ids one resolver call may carry (identity.MaxPublicIDLookups); the walker chunks at it, so a large page is
// never an error for size.
func NewTranslator(plans *Plans, resolver Resolver, valid func(string) bool, maxBatch int) (*Translator, error) {
	switch {
	case plans == nil:
		return nil, errors.New("publicid: nil plans")
	case resolver == nil:
		return nil, errors.New("publicid: nil resolver")
	case valid == nil:
		return nil, errors.New("publicid: nil validator")
	case maxBatch <= 0:
		return nil, fmt.Errorf("publicid: batch size %d must be positive", maxBatch)
	}
	if valid(Tombstone) {
		return nil, errors.New("publicid: the validator accepts the tombstone id; it must never be a valid public id")
	}
	return &Translator{plans: plans, resolver: resolver, valid: valid, maxBatch: maxBatch}, nil
}

// Stats are the per-request counters the interceptor logs. Ids are counted distinct within one direction.
type Stats struct {
	// InboundIDs is the distinct public ids looked up in the request.
	InboundIDs int
	// InboundUnknown is how many of them resolved to nobody (passed through to the handler unchanged).
	InboundUnknown int
	// OutboundIDs is the distinct uids translated in the response (seeded pairs included).
	OutboundIDs int
	// OutboundUnmapped is how many of them have no public id and went out as Tombstone.
	OutboundUnmapped int
	// ResolverCalls is the number of resolver calls in both directions.
	ResolverCalls int
}

// State carries what one request learned inbound into its response: the pairs already resolved (no second lookup)
// and the pass-through set (ids echoed unchanged outbound rather than tombstoned). A nil *State is valid and empty.
type State struct {
	uidToPub    map[string]string
	passThrough map[string]struct{}
	stats       Stats
}

// Stats returns the counters so far (zero for a nil state).
func (s *State) Stats() Stats {
	if s == nil {
		return Stats{}
	}
	return s.stats
}

// slot is one string to rewrite: m.fd (element idx when repeated, -1 when singular) whose value was orig at collect
// time; the id is orig[span.Start:span.End]. Writes are computed from orig, so a message reachable twice is written
// twice with the same result and never translated twice.
type slot struct {
	m    protoreflect.Message
	fd   protoreflect.FieldDescriptor
	idx  int
	orig string
	span Span
	// fill marks a StepFillPublicID slot: orig is the uid of the sibling TRANSLATE field and the whole value is set.
	fill bool
}

func (s *slot) id() string { return s.orig[s.span.Start:s.span.End] }

func (s *slot) write(rep string) {
	v := rep
	if !s.fill {
		v = s.orig[:s.span.Start] + rep + s.orig[s.span.End:]
	}
	if s.idx < 0 {
		s.m.Set(s.fd, protoreflect.ValueOfString(v))
		return
	}
	s.m.Mutable(s.fd).List().Set(s.idx, protoreflect.ValueOfString(v))
}

func (t *Translator) planFor(m protoreflect.Message) (*plan, error) {
	pl, ok := t.plans.byName[m.Descriptor().FullName()]
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrNoPlan, m.Descriptor().FullName())
	}
	return pl, nil
}

// TranslateRequest rewrites msg from wire to internal form in place. Per value of a translated field: "" stays "";
// Tombstone and a well-formed public id that resolves to nobody are passed through unchanged (and remembered, so the
// response echoes them); a resolved public id becomes its uid; anything else is an *apierr.Error VALIDATION naming the
// proto field. On any error msg is unchanged. A message whose type has a nil plan returns (nil, nil) without
// allocating.
func (t *Translator) TranslateRequest(ctx context.Context, msg proto.Message) (*State, error) {
	m := msg.ProtoReflect()
	pl, err := t.planFor(m)
	if err != nil || pl == nil {
		return nil, err
	}
	slots, err := collect(m, pl, false, nil)
	if err != nil {
		return nil, err
	}
	st := &State{}
	if len(slots) == 0 {
		return st, nil
	}
	var lookup []string
	seen := map[string]struct{}{}
	for i := range slots {
		id := slots[i].id()
		if id == Tombstone {
			st.pass(id)
			continue
		}
		if !t.valid(id) {
			name := string(slots[i].fd.Name())
			return nil, apierr.Validation(name, name+" must be a public id")
		}
		if _, dup := seen[id]; !dup {
			seen[id] = struct{}{}
			lookup = append(lookup, id)
		}
	}
	st.stats.InboundIDs = len(lookup)
	pubToUID, err := t.resolve(ctx, st, lookup, t.resolver.UIDsForPublicIDs)
	if err != nil {
		return nil, fmt.Errorf("publicid: resolve request ids: %w", err)
	}
	for _, id := range lookup {
		uid, ok := pubToUID[id]
		if !ok {
			st.pass(id)
			st.stats.InboundUnknown++
			continue
		}
		if st.uidToPub == nil {
			st.uidToPub = make(map[string]string, len(lookup))
		}
		st.uidToPub[uid] = id
	}
	for i := range slots {
		if uid, ok := pubToUID[slots[i].id()]; ok {
			slots[i].write(uid)
		}
	}
	return st, nil
}

// TranslateResponse rewrites msg from internal to wire form in place: every uid becomes its public id, or Tombstone
// when it has none; a value in st's pass-through set is echoed unchanged; a PUBLIC_ID field next to a filled TRANSLATE
// field gets the same id. Pairs learned by TranslateRequest are not looked up again. A resolver error fails the walk
// and msg is unchanged (never a fallback to the raw uid). st may be nil (TranslateRequest returns nil for a request
// type with a nil plan). The returned Stats cover the whole request, inbound counters from st included, so the caller
// logs them whether or not st was nil; they are returned on error too.
func (t *Translator) TranslateResponse(ctx context.Context, st *State, msg proto.Message) (Stats, error) {
	m := msg.ProtoReflect()
	pl, err := t.planFor(m)
	if err != nil || pl == nil {
		return st.Stats(), err
	}
	slots, err := collect(m, pl, true, make([]slot, 0, 32))
	if err != nil || len(slots) == 0 {
		return st.Stats(), err
	}
	if st == nil {
		st = &State{}
	}
	var lookup []string
	seen := map[string]struct{}{}
	for i := range slots {
		id := slots[i].id()
		if _, ok := st.passThrough[id]; ok {
			continue
		}
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		st.stats.OutboundIDs++
		if _, known := st.uidToPub[id]; !known {
			lookup = append(lookup, id)
		}
	}
	found, err := t.resolve(ctx, st, lookup, t.resolver.PublicIDsForUIDs)
	if err != nil {
		return st.Stats(), fmt.Errorf("publicid: resolve response ids: %w", err)
	}
	if len(lookup) > 0 && st.uidToPub == nil {
		st.uidToPub = make(map[string]string, len(lookup))
	}
	for _, uid := range lookup {
		pub, ok := found[uid]
		if !ok {
			pub = Tombstone
			st.stats.OutboundUnmapped++
		}
		st.uidToPub[uid] = pub
	}
	for i := range slots {
		id := slots[i].id()
		if _, ok := st.passThrough[id]; ok {
			if slots[i].fill {
				slots[i].write(id)
			}
			continue
		}
		slots[i].write(st.uidToPub[id])
	}
	return st.Stats(), nil
}

func (s *State) pass(id string) {
	if s.passThrough == nil {
		s.passThrough = map[string]struct{}{}
	}
	s.passThrough[id] = struct{}{}
}

// resolve calls fn over ids in chunks of maxBatch and merges the answers.
func (t *Translator) resolve(ctx context.Context, st *State, ids []string, fn func(context.Context, []string) (map[string]string, error)) (map[string]string, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	var out map[string]string
	for start := 0; start < len(ids); start += t.maxBatch {
		chunk := ids[start:min(start+t.maxBatch, len(ids))]
		st.stats.ResolverCalls++
		got, err := fn(ctx, chunk)
		if err != nil {
			return nil, err
		}
		if out == nil {
			out = got
			if len(ids) > t.maxBatch {
				out = make(map[string]string, len(ids))
				for k, v := range got {
					out[k] = v
				}
			}
			continue
		}
		for k, v := range got {
			out[k] = v
		}
	}
	return out, nil
}

// collect appends a slot for every non-empty id the plan reaches in m. It only reads: an unset message field is never
// materialised (Has before Get), so collecting changes nothing.
func collect(m protoreflect.Message, pl *plan, outbound bool, slots []slot) ([]slot, error) {
	var err error
	for i := range pl.steps {
		s := &pl.steps[i]
		if s.kind == StepFillPublicID {
			// Outbound only; keyed on the source field, whether or not the PUBLIC_ID field is set yet.
			// An explicitly present but empty uid (optional string) fills nothing, like an absent one.
			if outbound && m.Has(s.src) && m.Get(s.src).String() != "" {
				slots = append(slots, fillSlot(m, s))
			}
			continue
		}
		if !m.Has(s.fd) {
			continue
		}
		switch s.kind {
		case StepTranslate:
			slots = appendWhole(slots, m, s.fd, -1, m.Get(s.fd).String())
		case StepTranslateRepeated:
			l := m.Get(s.fd).List()
			for j := range l.Len() {
				slots = appendWhole(slots, m, s.fd, j, l.Get(j).String())
			}
		case StepConditional:
			if slots, err = appendConditional(slots, m, s); err != nil {
				return nil, err
			}
		case StepDescend:
			if slots, err = collect(m.Get(s.fd).Message(), s.sub, outbound, slots); err != nil {
				return nil, err
			}
		case StepDescendRepeated:
			l := m.Get(s.fd).List()
			for j := range l.Len() {
				if slots, err = collect(l.Get(j).Message(), s.sub, outbound, slots); err != nil {
					return nil, err
				}
			}
		case StepDescendMapValue:
			if slots, err = collectMap(m.Get(s.fd).Map(), s.sub, outbound, slots); err != nil {
				return nil, err
			}
		}
	}
	return slots, nil
}

// collectMap is separate from collect so that the Range closure's captures do not move collect's locals to the heap
// on every call.
func collectMap(mp protoreflect.Map, sub *plan, outbound bool, slots []slot) ([]slot, error) {
	var err error
	mp.Range(func(_ protoreflect.MapKey, v protoreflect.Value) bool {
		slots, err = collect(v.Message(), sub, outbound, slots)
		return err == nil
	})
	return slots, err
}

func appendWhole(slots []slot, m protoreflect.Message, fd protoreflect.FieldDescriptor, idx int, v string) []slot {
	if v == "" {
		return slots
	}
	return append(slots, slot{m: m, fd: fd, idx: idx, orig: v, span: WholeValue(v)})
}

func fillSlot(m protoreflect.Message, s *step) slot {
	uid := m.Get(s.src).String()
	return slot{m: m, fd: s.fd, idx: -1, orig: uid, span: WholeValue(uid), fill: true}
}

func appendConditional(slots []slot, m protoreflect.Message, s *step) ([]slot, error) {
	one := func(idx int, v string) error {
		if v == "" {
			return nil
		}
		sp, ok := s.rule(m, v)
		if !ok {
			return nil
		}
		if sp.Start < 0 || sp.End > len(v) || sp.Start > sp.End {
			return fmt.Errorf("%w: %s", errBadSpan, s.fd.FullName())
		}
		if sp.Start == sp.End {
			return nil
		}
		slots = append(slots, slot{m: m, fd: s.fd, idx: idx, orig: v, span: sp})
		return nil
	}
	if s.fd.IsList() {
		l := m.Get(s.fd).List()
		for j := range l.Len() {
			if err := one(j, l.Get(j).String()); err != nil {
				return nil, err
			}
		}
		return slots, nil
	}
	if err := one(-1, m.Get(s.fd).String()); err != nil {
		return nil, err
	}
	return slots, nil
}
