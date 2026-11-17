package publicid

import (
	"context"
	"errors"
	"slices"
	"testing"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// pairs maps uid1..uid4 to pub1..pub4; uid9 has no public id.
func pairs() map[string]string {
	return map[string]string{uidN(1): pubN(1), uidN(2): pubN(2), uidN(3): pubN(3), uidN(4): pubN(4)}
}

func author(api *testAPI, uid string) protoreflect.Message {
	a := api.msg("Author")
	if uid != "" {
		setStr(a, "user_id", uid)
	}
	setStr(a, "name", "name-"+uid)
	return a
}

func TestTranslateResponse_Semantics(t *testing.T) {
	api := newTestAPI(t)
	res := newFakeResolver(pairs())
	tr := newTranslatorT(t, api.plans, res, 500)

	post := api.msg("Post")
	setStr(post, "id", "post-1")
	setMsg(post, "author", author(api, uidN(1)))
	ments := list(post, "mentions")
	ments.Append(protoreflect.ValueOfMessage(author(api, uidN(2))))
	ments.Append(protoreflect.ValueOfMessage(author(api, uidN(9))))
	ments.Append(protoreflect.ValueOfMessage(author(api, "")))
	emb := api.msg("Post")
	setMsg(emb, "author", author(api, uidN(1)))
	setMsg(post, "embedded", emb)
	authors := post.Mutable(post.Descriptor().Fields().ByName("authors")).Map()
	authors.Set(protoreflect.ValueOfString("k").MapKey(), protoreflect.ValueOfMessage(author(api, uidN(3))))
	ids := list(post, "ids")
	for _, v := range []string{uidN(4), "", uidN(9)} {
		ids.Append(protoreflect.ValueOfString(v))
	}
	setStr(post, "owner_id", uidN(2))
	meta := post.Mutable(post.Descriptor().Fields().ByName("meta")).Map()
	meta.Set(protoreflect.ValueOfString(uidN(1)).MapKey(), protoreflect.ValueOfString(uidN(1)))

	if _, err := tr.TranslateResponse(context.Background(), nil, post); err != nil {
		t.Fatal(err)
	}
	check := func(what, got, want string) {
		t.Helper()
		if got != want {
			t.Errorf("%s = %q, want %q", what, got, want)
		}
	}
	a := getMsg(post, "author")
	check("author.user_id", getStr(a, "user_id"), pubN(1))
	check("author.public_id (filled)", getStr(a, "public_id"), pubN(1))
	check("author.name", getStr(a, "name"), "name-"+uidN(1))
	m := post.Get(post.Descriptor().Fields().ByName("mentions")).List()
	check("mentions[0]", getStr(m.Get(0).Message(), "user_id"), pubN(2))
	check("mentions[1] unmapped", getStr(m.Get(1).Message(), "user_id"), Tombstone)
	check("mentions[1] public_id", getStr(m.Get(1).Message(), "public_id"), Tombstone)
	check("mentions[2] empty", getStr(m.Get(2).Message(), "user_id"), "")
	if m.Get(2).Message().Has(m.Get(2).Message().Descriptor().Fields().ByName("public_id")) {
		t.Error("mentions[2]: public_id filled for an empty user_id")
	}
	check("embedded.author", getStr(getMsg(getMsg(post, "embedded"), "author"), "user_id"), pubN(1))
	check("authors[k]", getStr(authors.Get(protoreflect.ValueOfString("k").MapKey()).Message(), "user_id"), pubN(3))
	if got := strs(post.Get(post.Descriptor().Fields().ByName("ids")).List()); !slices.Equal(got, []string{pubN(4), "", Tombstone}) {
		t.Errorf("ids = %v", got)
	}
	check("owner_id", getStr(post, "owner_id"), pubN(2))
	if w := post.WhichOneof(post.Descriptor().Oneofs().ByName("target")); w == nil || w.Name() != "owner_id" {
		t.Errorf("oneof arm = %v, want owner_id", w)
	}
	check("meta (not annotated)", meta.Get(protoreflect.ValueOfString(uidN(1)).MapKey()).String(), uidN(1))
	check("id", getStr(post, "id"), "post-1")

	if len(res.calls) != 1 {
		t.Fatalf("resolver calls = %d, want 1", len(res.calls))
	}
	want := []string{uidN(1), uidN(2), uidN(9), uidN(3), uidN(4)}
	got := slices.Clone(res.calls[0])
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Errorf("resolver got %v, want the distinct uids %v", got, want)
	}
}

func TestTranslateRequest_Semantics(t *testing.T) {
	api := newTestAPI(t)
	res := newFakeResolver(pairs())
	tr := newTranslatorT(t, api.plans, res, 500)
	unknown := pubN(77)

	req := api.msg("Req")
	setStr(req, "user_id", pubN(1))
	post := api.msg("Post")
	ids := list(post, "ids")
	for _, v := range []string{pubN(2), unknown, "", Tombstone, pubN(1)} {
		ids.Append(protoreflect.ValueOfString(v))
	}
	pa := author(api, "")
	setStr(pa, "public_id", "untouched-public-id")
	setMsg(post, "author", pa)
	setMsg(req, "post", post)

	st, err := tr.TranslateRequest(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if got := getStr(req, "user_id"); got != uidN(1) {
		t.Errorf("user_id = %q, want uid1", got)
	}
	if got := strs(post.Get(post.Descriptor().Fields().ByName("ids")).List()); !slices.Equal(got, []string{uidN(2), unknown, "", Tombstone, uidN(1)}) {
		t.Errorf("ids = %v", got)
	}
	if got := getStr(pa, "public_id"); got != "untouched-public-id" {
		t.Errorf("inbound touched a PUBLIC_ID field: %q", got)
	}
	if len(res.calls) != 1 || len(res.calls[0]) != 3 {
		t.Fatalf("resolver calls = %v, want one call with the 3 distinct valid ids (tombstone never sent)", res.calls)
	}
	if s := st.Stats(); s.InboundIDs != 3 || s.InboundUnknown != 1 || s.ResolverCalls != 1 {
		t.Errorf("stats = %+v", s)
	}

	// The response echoes the request's ids: seeded pairs need no lookup, pass-through ids come back unchanged.
	out := api.msg("Post")
	oids := list(out, "ids")
	for _, v := range []string{uidN(1), uidN(2), unknown, Tombstone} {
		oids.Append(protoreflect.ValueOfString(v))
	}
	if _, err := tr.TranslateResponse(context.Background(), st, out); err != nil {
		t.Fatal(err)
	}
	if got := strs(oids); !slices.Equal(got, []string{pubN(1), pubN(2), unknown, Tombstone}) {
		t.Errorf("response ids = %v", got)
	}
	if len(res.calls) != 1 {
		t.Errorf("response made %d more resolver calls, want 0 (all seeded)", len(res.calls)-1)
	}
	if s := st.Stats(); s.OutboundIDs != 2 || s.OutboundUnmapped != 0 || s.ResolverCalls != 1 {
		t.Errorf("stats = %+v", s)
	}
}

// TestTranslateRequest_Rejects: anything that is not a public id is VALIDATION naming the proto field, and the message
// is left exactly as it was.
func TestTranslateRequest_Rejects(t *testing.T) {
	api := newTestAPI(t)
	for _, tc := range []struct {
		name, field, value string
	}{
		{"raw uid", "user_id", uidN(1)},
		{"malformed", "user_id", "u0abc"},
		{"upper case", "user_id", "U0000000000000000000000000001"},
		{"first body char above 7", "user_id", "u8" + pubN(1)[2:]},
		{"repeated field", "ids", "not-an-id"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := newFakeResolver(pairs())
			tr := newTranslatorT(t, api.plans, res, 500)
			req := api.msg("Req")
			setStr(req, "user_id", pubN(1))
			post := api.msg("Post")
			list(post, "ids").Append(protoreflect.ValueOfString(pubN(2)))
			setMsg(req, "post", post)
			if tc.field == "user_id" {
				setStr(req, "user_id", tc.value)
			} else {
				list(post, "ids").Append(protoreflect.ValueOfString(tc.value))
			}
			before := proto.Clone(req.Interface())
			_, err := tr.TranslateRequest(context.Background(), req)
			var ae *apierr.Error
			if !errors.As(err, &ae) {
				t.Fatalf("err = %v, want *apierr.Error", err)
			}
			if ae.Code != connect.CodeInvalidArgument || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != tc.field {
				t.Errorf("err = %+v, want VALIDATION field=%s", ae, tc.field)
			}
			if !proto.Equal(before, req.Interface()) {
				t.Error("message changed on a validation error")
			}
			if len(res.calls) != 0 {
				t.Error("resolver called before validation finished")
			}
		})
	}
}

func TestResolverError_FailsAndLeavesMessage(t *testing.T) {
	api := newTestAPI(t)
	res := newFakeResolver(pairs())
	res.err = errResolver
	tr := newTranslatorT(t, api.plans, res, 500)

	req := api.msg("Req")
	setStr(req, "user_id", pubN(1))
	before := proto.Clone(req.Interface())
	if _, err := tr.TranslateRequest(context.Background(), req); !errors.Is(err, errResolver) {
		t.Errorf("request err = %v, want the resolver error", err)
	}
	if !proto.Equal(before, req.Interface()) {
		t.Error("request changed on a resolver error")
	}

	out := api.msg("Post")
	setMsg(out, "author", author(api, uidN(1)))
	before = proto.Clone(out.Interface())
	if _, err := tr.TranslateResponse(context.Background(), nil, out); !errors.Is(err, errResolver) {
		t.Errorf("response err = %v, want the resolver error", err)
	}
	if !proto.Equal(before, out.Interface()) {
		t.Error("response changed on a resolver error (no fallback to raw uid, no partial write)")
	}
}

func TestTranslate_ChunksAtBatchSize(t *testing.T) {
	api := newTestAPI(t)
	p := map[string]string{}
	for i := range 5 {
		p[uidN(i)] = pubN(i)
	}
	res := newFakeResolver(p)
	tr := newTranslatorT(t, api.plans, res, 2)
	out := api.msg("Post")
	ids := list(out, "ids")
	for i := range 5 {
		ids.Append(protoreflect.ValueOfString(uidN(i)))
	}
	st := &State{}
	if _, err := tr.TranslateResponse(context.Background(), st, out); err != nil {
		t.Fatal(err)
	}
	if len(res.calls) != 3 {
		t.Errorf("resolver calls = %d, want 3 chunks of at most 2", len(res.calls))
	}
	for i := range 5 {
		if got := ids.Get(i).String(); got != pubN(i) {
			t.Errorf("ids[%d] = %q, want %q", i, got, pubN(i))
		}
	}
	if s := st.Stats(); s.ResolverCalls != 3 || s.OutboundIDs != 5 {
		t.Errorf("stats = %+v", s)
	}

	// Inbound chunks too.
	res.calls = nil
	in := api.msg("Post")
	iids := list(in, "ids")
	for i := range 5 {
		iids.Append(protoreflect.ValueOfString(pubN(i)))
	}
	if _, err := tr.TranslateRequest(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if len(res.calls) != 3 || iids.Get(4).String() != uidN(4) {
		t.Errorf("inbound calls = %d, ids[4] = %q", len(res.calls), iids.Get(4).String())
	}
}

// TestTranslateResponse_AliasedMessageTranslatedOnce: the same Author reachable three times is looked up once and
// written with the public id, never translated a second time (which would tombstone it).
func TestTranslateResponse_AliasedMessageTranslatedOnce(t *testing.T) {
	api := newTestAPI(t)
	res := newFakeResolver(pairs())
	tr := newTranslatorT(t, api.plans, res, 500)
	shared := author(api, uidN(1))
	post := api.msg("Post")
	setMsg(post, "author", shared)
	l := list(post, "mentions")
	l.Append(protoreflect.ValueOfMessage(shared))
	l.Append(protoreflect.ValueOfMessage(shared))
	if _, err := tr.TranslateResponse(context.Background(), nil, post); err != nil {
		t.Fatal(err)
	}
	if got := getStr(shared, "user_id"); got != pubN(1) {
		t.Errorf("shared user_id = %q, want pub1", got)
	}
	if got := getStr(shared, "public_id"); got != pubN(1) {
		t.Errorf("shared public_id = %q, want pub1", got)
	}
	if len(res.calls) != 1 || len(res.calls[0]) != 1 {
		t.Errorf("resolver calls = %v, want one call with one uid", res.calls)
	}
}

func TestConditional(t *testing.T) {
	api := newTestAPI(t)
	tr := newTranslatorT(t, api.plans, newFakeResolver(pairs()), 500)
	for _, tc := range []struct {
		name       string
		targetType int32
		in, want   string
		tagged     []string
		wantTagged []string
	}{
		{"account target translated", 2, pubN(1), uidN(1), nil, nil},
		{"post target untouched", 1, "1234567890", "1234567890", nil, nil},
		{"post target that looks like a uid untouched", 1, uidN(1), uidN(1), nil, nil},
		{"tagged suffix translated", 1, "", "", []string{"follow_" + pubN(2), "plain", "a_b_" + pubN(3), "x_"}, []string{"follow_" + uidN(2), "plain", "a_b_" + uidN(3), "x_"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := api.msg("Report")
			r.Set(r.Descriptor().Fields().ByName("target_type"), protoreflect.ValueOfInt32(tc.targetType))
			if tc.in != "" {
				setStr(r, "target_id", tc.in)
			}
			for _, v := range tc.tagged {
				list(r, "tagged").Append(protoreflect.ValueOfString(v))
			}
			st, err := tr.TranslateRequest(context.Background(), r)
			if err != nil {
				t.Fatal(err)
			}
			if got := getStr(r, "target_id"); got != tc.want {
				t.Errorf("target_id = %q, want %q", got, tc.want)
			}
			if tc.tagged != nil {
				if got := strs(r.Get(r.Descriptor().Fields().ByName("tagged")).List()); !slices.Equal(got, tc.wantTagged) {
					t.Errorf("tagged = %v, want %v", got, tc.wantTagged)
				}
				// And back: outbound rewrites only the span.
				if _, err := tr.TranslateResponse(context.Background(), st, r); err != nil {
					t.Fatal(err)
				}
				if got := strs(r.Get(r.Descriptor().Fields().ByName("tagged")).List()); !slices.Equal(got, tc.tagged) {
					t.Errorf("tagged round trip = %v, want %v", got, tc.tagged)
				}
			}
		})
	}

	t.Run("account target malformed is validation", func(t *testing.T) {
		r := api.msg("Report")
		r.Set(r.Descriptor().Fields().ByName("target_type"), protoreflect.ValueOfInt32(2))
		setStr(r, "target_id", uidN(1))
		_, err := tr.TranslateRequest(context.Background(), r)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Metadata["field"] != "target_id" {
			t.Fatalf("err = %v, want VALIDATION field=target_id", err)
		}
	})
}

func TestConditional_BadSpanFailsWalk(t *testing.T) {
	for _, sp := range []Span{{Start: -1, End: 2}, {Start: 0, End: 999}, {Start: 3, End: 1}} {
		fd := compile(t, testFile())
		r := NewRules()
		if err := r.Register(testPkg+".Report.target_id", func(protoreflect.Message, string) (Span, bool) { return sp, true }); err != nil {
			t.Fatal(err)
		}
		if err := r.Register(testPkg+".Report.tagged", func(protoreflect.Message, string) (Span, bool) { return Span{}, true }); err != nil {
			t.Fatal(err)
		}
		plans, err := BuildPlans([]protoreflect.ServiceDescriptor{fd.Services().Get(0)}, r)
		if err != nil {
			t.Fatal(err)
		}
		tr := newTranslatorT(t, plans, newFakeResolver(nil), 500)
		msg := (&testAPI{file: fd}).msg("Report")
		setStr(msg, "target_id", "abc")
		list(msg, "tagged").Append(protoreflect.ValueOfString("empty-span-is-no-id"))
		if _, err := tr.TranslateRequest(context.Background(), msg); !errors.Is(err, errBadSpan) {
			t.Errorf("span %+v: err = %v, want errBadSpan", sp, err)
		}
		if _, err := tr.TranslateResponse(context.Background(), nil, msg); !errors.Is(err, errBadSpan) {
			t.Errorf("span %+v outbound: err = %v, want errBadSpan", sp, err)
		}
	}
}

func TestOneofArmKept(t *testing.T) {
	api := newTestAPI(t)
	tr := newTranslatorT(t, api.plans, newFakeResolver(pairs()), 500)
	c := api.msg("Choice")
	setStr(c, "user_id", uidN(1))
	if _, err := tr.TranslateResponse(context.Background(), nil, c); err != nil {
		t.Fatal(err)
	}
	if w := c.WhichOneof(c.Descriptor().Oneofs().ByName("who")); w == nil || w.Name() != "user_id" || getStr(c, "user_id") != pubN(1) {
		t.Errorf("arm = %v, user_id = %q; want user_id arm with pub1", w, getStr(c, "user_id"))
	}
	c2 := api.msg("Choice")
	setStr(c2, "public_id", pubN(2))
	if _, err := tr.TranslateRequest(context.Background(), c2); err != nil {
		t.Fatal(err)
	}
	if w := c2.WhichOneof(c2.Descriptor().Oneofs().ByName("who")); w == nil || w.Name() != "public_id" || getStr(c2, "public_id") != pubN(2) {
		t.Errorf("inbound changed the public_id arm: %v %q", w, getStr(c2, "public_id"))
	}
}

func TestNilPlanAndNoPlan(t *testing.T) {
	api := newTestAPI(t)
	res := newFakeResolver(pairs())
	tr := newTranslatorT(t, api.plans, res, 500)
	plain := api.msg("Plain")
	setStr(plain, "x", uidN(1))
	setStr(plain, "not_user", uidN(1))
	st, err := tr.TranslateRequest(context.Background(), plain)
	if err != nil || st != nil {
		t.Fatalf("nil plan request = (%v, %v), want (nil, nil)", st, err)
	}
	if _, err := tr.TranslateResponse(context.Background(), nil, plain); err != nil {
		t.Fatal(err)
	}
	if getStr(plain, "x") != uidN(1) || getStr(plain, "not_user") != uidN(1) || len(res.calls) != 0 {
		t.Error("a nil-plan message was touched")
	}
	allocs := testing.AllocsPerRun(100, func() {
		if _, err := tr.TranslateRequest(context.Background(), plain); err != nil {
			t.Fatal(err)
		}
		if _, err := tr.TranslateResponse(context.Background(), nil, plain); err != nil {
			t.Fatal(err)
		}
	})
	if allocs != 0 {
		t.Errorf("nil plan allocates %v per request, want 0", allocs)
	}

	// A planned type with nothing set: an empty state, no resolver call.
	st, err = tr.TranslateRequest(context.Background(), api.msg("Req"))
	if err != nil || st == nil || len(res.calls) != 0 {
		t.Errorf("empty Req = (%v, %v), calls %d", st, err, len(res.calls))
	}

	if _, err := tr.TranslateRequest(context.Background(), &commonv1.AuthorSnapshot{}); !errors.Is(err, ErrNoPlan) {
		t.Errorf("unplanned type request err = %v, want ErrNoPlan", err)
	}
	if _, err := tr.TranslateResponse(context.Background(), nil, &commonv1.AuthorSnapshot{}); !errors.Is(err, ErrNoPlan) {
		t.Errorf("unplanned type response err = %v, want ErrNoPlan", err)
	}
	if (*State)(nil).Stats() != (Stats{}) {
		t.Error("nil state stats not zero")
	}
}

func TestNewTranslator_Validates(t *testing.T) {
	api := newTestAPI(t)
	res := newFakeResolver(nil)
	for _, tc := range []struct {
		name  string
		plans *Plans
		res   Resolver
		valid func(string) bool
		batch int
	}{
		{"nil plans", nil, res, canonicalValid, 1},
		{"nil resolver", api.plans, nil, canonicalValid, 1},
		{"nil validator", api.plans, res, nil, 1},
		{"zero batch", api.plans, res, canonicalValid, 0},
		{"validator accepts tombstone", api.plans, res, func(string) bool { return true }, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := NewTranslator(tc.plans, tc.res, tc.valid, tc.batch); err == nil {
				t.Fatal("want an error")
			}
		})
	}
}

// TestTombstone_ConsistentWithCanonicalRule: the tombstone has the public id shape (prefix, length, alphabet) but the
// canonical rule rejects it because its first body character is above 7, so it can never be minted; inbound it is
// passed to the handler unchanged, like an unknown id, and never sent to the resolver.
func TestTombstone_ConsistentWithCanonicalRule(t *testing.T) {
	if len(Tombstone) != 27 || Tombstone[0] != 'u' {
		t.Fatalf("Tombstone %q does not have the public id shape", Tombstone)
	}
	if canonicalValid(Tombstone) {
		t.Fatal("the canonical rule accepts the tombstone; it could be minted")
	}
	if !canonicalValid("u7" + Tombstone[2:]) {
		t.Fatal("test rule broken: the same id with first body char 7 should be valid")
	}
	api := newTestAPI(t)
	res := newFakeResolver(pairs())
	tr := newTranslatorT(t, api.plans, res, 500)
	req := api.msg("Req")
	setStr(req, "user_id", Tombstone)
	st, err := tr.TranslateRequest(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if getStr(req, "user_id") != Tombstone || len(res.calls) != 0 {
		t.Errorf("tombstone inbound: user_id = %q, calls = %d", getStr(req, "user_id"), len(res.calls))
	}
	out := api.msg("Author")
	setStr(out, "user_id", Tombstone)
	if _, err := tr.TranslateResponse(context.Background(), st, out); err != nil {
		t.Fatal(err)
	}
	if getStr(out, "user_id") != Tombstone || getStr(out, "public_id") != Tombstone || len(res.calls) != 0 {
		t.Errorf("tombstone echo: %q / %q, calls %d", getStr(out, "user_id"), getStr(out, "public_id"), len(res.calls))
	}
}
