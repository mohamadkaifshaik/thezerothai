package posts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// Reply audience (ADR-0021 D2, CMP-B2/B4): who may reply, set on a root post or quote, inherited by replies,
// enforced in service.Create after replyParent, hinted to viewers. FEATURE_REPLY_AUDIENCE gates SETTING only.

// rPolRepost is dave's REPOST of rRoot.
const rPolRepost = "0000000000000000110"

func replyAudienceRegistry(spec flags.Spec) *flags.Registry {
	spec.Name = ReplyAudienceFlagName
	return flags.NewRegistry(
		flags.Spec{Name: "posts", Mode: flags.On},
		flags.Spec{Name: RepliesFlagName, Mode: flags.On},
		flags.Spec{Name: EngagementFlagName, Mode: flags.On},
		flags.Spec{Name: QuotesFlagName, Mode: flags.On},
		spec,
	)
}

// restrictedEnv is newThreadEnv with every post of the conversation under rRoot carrying policy (replies inherit
// their conversation's policy), zed's root mentioning the listed users, and a REPOST of the root by dave.
func restrictedEnv(policy ReplyPolicy, mentioned ...string) *createEnv {
	e := newThreadEnv()
	for _, p := range e.repo.docs {
		p.ReplyPolicy = policy
	}
	for _, u := range mentioned {
		e.repo.docs[rRoot].Mentions = append(e.repo.docs[rRoot].Mentions, Mention{UserID: u, Handle: u})
	}
	rp := replyPost(rPolRepost, uDave, "dave", "", rPolRepost)
	rp.Kind, rp.RepostOfID = KindRepost, rRoot
	rp.Embedded = &Embedded{PostID: rRoot, Author: AuthorSnapshot{UserID: uZed, Handle: "zed"}, ReplyPolicy: policy}
	rp.EmbeddedAuthorID = uZed
	e.repo.docs[rPolRepost] = rp
	return e
}

func (e *createEnv) replyTo(parent string) (*Post, *budget.Counter, error) {
	// ReplyAudienceEnabled stays false: enforcement must not depend on the flag.
	return e.create(CreateInput{IdempotencyKey: key1, Text: "reply", ReplyToPostID: parent, RepliesEnabled: true})
}

func wantNotFound(t *testing.T, err error) {
	t.Helper()
	ae := wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if ae.Message != postNotFoundText {
		t.Fatalf("message = %q, want the one uniform NOT_FOUND answer", ae.Message)
	}
}

func wantReplyNotAllowed(t *testing.T, err error, policy string) {
	t.Helper()
	ae := wantAPIError(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_REPLY_NOT_ALLOWED)
	if ae.Metadata["policy"] != policy {
		t.Fatalf("metadata policy = %q, want %q", ae.Metadata["policy"], policy)
	}
}

// TestRequestHash_ReplyPolicyGoldens pins the exact bytes: `|policy=<NAME>` before `|pp=1` before `|ai=1`, each only
// when non-default; EVERYONE / absent and a reply's inherited policy leave the legacy bytes untouched.
func TestRequestHash_ReplyPolicyGoldens(t *testing.T) {
	t.Parallel()
	base := func(text, reply, quote string, media, alts []string) string {
		return fmt.Sprintf("v1|text=%q|media=%q|alts=%q|reply=%q|quote=%q",
			text, strings.Join(media, ","), strings.Join(alts, "\x1f"), reply, quote)
	}
	b := base("hello", "", "", []string{mid1}, []string{"alt"})
	tests := []struct {
		name   string
		policy ReplyPolicy
		pp, ai bool
		want   string
	}{
		{"default", ReplyPolicyEveryone, false, false, b},
		{"following", ReplyPolicyFollowing, false, false, b + "|policy=FOLLOWING"},
		{"mentioned only", ReplyPolicyMentionedOnly, false, false, b + "|policy=MENTIONED_ONLY"},
		{"following + pp", ReplyPolicyFollowing, true, false, b + "|policy=FOLLOWING|pp=1"},
		{"following + ai", ReplyPolicyFollowing, false, true, b + "|policy=FOLLOWING|ai=1"},
		{"mentioned + pp + ai", ReplyPolicyMentionedOnly, true, true, b + "|policy=MENTIONED_ONLY|pp=1|ai=1"},
		{"pp + ai only", ReplyPolicyEveryone, true, true, b + "|pp=1|ai=1"},
	}
	seen := map[string]string{}
	for _, tt := range tests {
		got := requestHash("hello", "", "", []string{mid1}, []string{"alt"}, tt.policy, tt.pp, tt.ai)
		if want := idempotency.HashRequest(tt.want); got != want {
			t.Errorf("%s: hash = %s, want HashRequest(%q) = %s", tt.name, got, tt.want, want)
		}
		if prev, dup := seen[got]; dup {
			t.Errorf("%s hashes like %s", tt.name, prev)
		}
		seen[got] = tt.name
	}
	// A reply's request carries no policy, so its hash is the legacy one.
	legacy := idempotency.HashRequest(base("hi", "0000000000000000007", "", nil, nil))
	if got := requestHash("hi", "0000000000000000007", "", nil, nil, ReplyPolicyEveryone, false, false); got != legacy {
		t.Errorf("reply hash changed: %s != %s", got, legacy)
	}
}

// TestValidateReplyPolicy covers every value of the proto enum plus out-of-range numbers, on a root and on a reply.
func TestValidateReplyPolicy(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		policy  int32
		reply   bool
		want    ReplyPolicy
		wantMsg string // non-empty: VALIDATION containing this text
	}{
		{"unspecified", 0, false, ReplyPolicyEveryone, ""},
		{"everyone stored as absent", 1, false, ReplyPolicyEveryone, ""},
		{"following", 2, false, ReplyPolicyFollowing, ""},
		{"mentioned only", 3, false, ReplyPolicyMentionedOnly, ""},
		{"following of following", 4, false, "", "not available yet"},
		{"verified", 5, false, "", "not available yet"},
		{"unknown number", 6, false, "", "not a valid value"},
		{"large unknown number", 99, false, "", "not a valid value"},
		{"negative", -1, false, "", "not a valid value"},
		{"unspecified on a reply", 0, true, ReplyPolicyEveryone, ""},
		{"everyone on a reply", 1, true, "", "first post of a conversation"},
		{"following on a reply", 2, true, "", "first post of a conversation"},
		{"mentioned only on a reply", 3, true, "", "first post of a conversation"},
		{"unavailable value on a reply", 4, true, "", "not available yet"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			in := CreateInput{ReplyPolicy: tt.policy}
			if tt.reply {
				in.ReplyToPostID = rRoot
			}
			got, err := validateReplyPolicy(in)
			if tt.wantMsg == "" {
				if err != nil || got != tt.want {
					t.Fatalf("got %q, %v; want %q", got, err, tt.want)
				}
				return
			}
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if !strings.Contains(ae.Message, tt.wantMsg) || ae.Metadata["field"] != "reply_policy" {
				t.Fatalf("message %q field %q, want %q on reply_policy", ae.Message, ae.Metadata["field"], tt.wantMsg)
			}
		})
	}
}

// TestCreate_ReplyPolicy_Setting: the flag gates SETTING; the order is replies, quotes, media, reply_audience,
// content_disclosure; a refused request reads and writes nothing.
func TestCreate_ReplyPolicy_Setting(t *testing.T) {
	const quoteTarget = pidOther
	tests := []struct {
		name       string
		in         CreateInput
		wantFeat   string // FEATURE_DISABLED feature
		wantValid  bool   // VALIDATION
		wantStored ReplyPolicy
	}{
		{"flag off, unspecified", CreateInput{Text: "a"}, "", false, ""},
		{"flag off, following", CreateInput{Text: "a", ReplyPolicy: 2}, "reply_audience", false, ""},
		{"flag off, everyone", CreateInput{Text: "a", ReplyPolicy: 1}, "reply_audience", false, ""},
		{"flag off, unavailable value", CreateInput{Text: "a", ReplyPolicy: 4}, "reply_audience", false, ""},
		{"flag off, unknown value", CreateInput{Text: "a", ReplyPolicy: 99}, "reply_audience", false, ""},
		{"flag off, reply with policy: replies first when off", CreateInput{Text: "a", ReplyToPostID: rRoot, ReplyPolicy: 2}, "replies", false, ""},
		{"flag off, reply allowed with policy: reply_audience", CreateInput{Text: "a", ReplyToPostID: rRoot, ReplyPolicy: 2, RepliesEnabled: true}, "reply_audience", false, ""},
		{"flag off, media beats reply_audience", CreateInput{Text: "a", ReplyPolicy: 2, MediaIDs: []string{mid1}}, "media", false, ""},
		{"flag off, quote beats reply_audience", CreateInput{Text: "a", ReplyPolicy: 2, QuoteOfPostID: quoteTarget}, "quotes", false, ""},
		{"flag off, reply_audience beats disclosure", CreateInput{Text: "a", ReplyPolicy: 2, PaidPartnership: true}, "reply_audience", false, ""},
		{"flag off, disclosure alone", CreateInput{Text: "a", PaidPartnership: true}, "content_disclosure", false, ""},
		{"flag on, unspecified", CreateInput{Text: "a", ReplyAudienceEnabled: true}, "", false, ""},
		{"flag on, everyone is stored absent", CreateInput{Text: "a", ReplyPolicy: 1, ReplyAudienceEnabled: true}, "", false, ""},
		{"flag on, following", CreateInput{Text: "a", ReplyPolicy: 2, ReplyAudienceEnabled: true}, "", false, ReplyPolicyFollowing},
		{"flag on, mentioned only", CreateInput{Text: "a", ReplyPolicy: 3, ReplyAudienceEnabled: true}, "", false, ReplyPolicyMentionedOnly},
		{"flag on, following of following", CreateInput{Text: "a", ReplyPolicy: 4, ReplyAudienceEnabled: true}, "", true, ""},
		{"flag on, verified", CreateInput{Text: "a", ReplyPolicy: 5, ReplyAudienceEnabled: true}, "", true, ""},
		{"flag on, unknown", CreateInput{Text: "a", ReplyPolicy: 42, ReplyAudienceEnabled: true}, "", true, ""},
		{"flag on, policy on a reply", CreateInput{Text: "a", ReplyToPostID: rRoot, RepliesEnabled: true, ReplyPolicy: 2, ReplyAudienceEnabled: true}, "", true, ""},
		{"flag on, quote with policy", CreateInput{Text: "a", QuoteOfPostID: quoteTarget, QuotesEnabled: true, ReplyPolicy: 3, ReplyAudienceEnabled: true}, "", false, ReplyPolicyMentionedOnly},
		{"flag on, with disclosure", CreateInput{Text: "a", ReplyPolicy: 2, ReplyAudienceEnabled: true, PaidPartnership: true, DisclosureEnabled: true}, "", false, ReplyPolicyFollowing},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newThreadEnv()
			e.repo.docs[pidOther] = post(pidOther, uZed)
			e.repo.docs[pidOther].Author = AuthorSnapshot{UserID: uZed, Handle: "zed"}
			in := tt.in
			in.IdempotencyKey = key1
			p, c, err := e.create(in)
			switch {
			case tt.wantFeat != "":
				ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if ae.Metadata["feature"] != tt.wantFeat || c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
					t.Fatalf("feature=%q reads=%d writes=%d creates=%d", ae.Metadata["feature"], c.Reads(), c.Writes(), e.repo.createCalls)
				}
			case tt.wantValid:
				_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
				if c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
					t.Fatalf("reads=%d writes=%d creates=%d, want a refusal before any read", c.Reads(), c.Writes(), e.repo.createCalls)
				}
			default:
				if err != nil {
					t.Fatal(err)
				}
				if p.ReplyPolicy != tt.wantStored || e.repo.docs[p.ID].ReplyPolicy != tt.wantStored {
					t.Fatalf("returned %q stored %q, want %q", p.ReplyPolicy, e.repo.docs[p.ID].ReplyPolicy, tt.wantStored)
				}
				if got := ToProto(p).GetReplyPolicy(); got != policyToProto(tt.wantStored) {
					t.Fatalf("wire policy = %v", got)
				}
			}
		})
	}
}

// TestCreate_ReplyPolicy_Idempotency: a request that sets no policy (or EVERYONE) is stored under the legacy hash,
// so a retry across the deploy replays; a different policy under the same key is a reuse.
func TestCreate_ReplyPolicy_Idempotency(t *testing.T) {
	e := newCreateEnv()
	in := CreateInput{IdempotencyKey: key1, Text: "hello", ReplyPolicy: 2, ReplyAudienceEnabled: true}
	first, _, err := e.create(in)
	if err != nil {
		t.Fatal(err)
	}
	replay, c, err := e.create(in)
	if err != nil || replay.ID != first.ID || c.Writes() != 0 {
		t.Fatalf("replay id=%v err=%v writes=%d", replay, err, c.Writes())
	}
	changed := in
	changed.ReplyPolicy = 3
	_, _, err = e.create(changed)
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	plain := in
	plain.ReplyPolicy = 0
	_, _, err = e.create(plain)
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)

	// EVERYONE and UNSPECIFIED hash alike, and like a pre-ADR request: the legacy record replays under EVERYONE.
	e2 := newCreateEnv()
	legacyKey := idempotency.Key(testUID, createRPC, key2)
	e2.repo.idem = map[string]fakeIdem{legacyKey: {
		hash:   idempotency.HashRequest(fmt.Sprintf("v1|text=%q|media=%q|alts=%q|reply=%q|quote=%q", "hello", "", "", "", "")),
		postID: pidMine,
	}}
	e2.repo.docs[pidMine] = post(pidMine, testUID)
	got, _, err := e2.create(CreateInput{IdempotencyKey: key2, Text: "hello", ReplyPolicy: 1, ReplyAudienceEnabled: true})
	if err != nil || got.ID != pidMine {
		t.Fatalf("EVERYONE retry of a legacy record: post=%v err=%v, want a replay of %s", got, err, pidMine)
	}
}

// TestCreateReply_InheritsPolicy: a reply stores the parent's effective policy (0 extra reads, no uid), and its
// request hash stays the legacy one.
func TestCreateReply_InheritsPolicy(t *testing.T) {
	for _, policy := range []ReplyPolicy{ReplyPolicyFollowing, ReplyPolicyMentionedOnly} {
		t.Run(string(policy), func(t *testing.T) {
			e := restrictedEnv(policy, testUID)
			e.graph.snaps = map[string]graph.Snapshot{uZed: {Following: map[string]bool{testUID: true}}}
			// Deeper reply: the parent is a reply carrying the policy. The text mentions bob; the root mentions the caller.
			p, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "reply to @bob", ReplyToPostID: rReply1, RepliesEnabled: true})
			if err != nil {
				t.Fatal(err)
			}
			if p.ReplyPolicy != policy || e.repo.docs[p.ID].ReplyPolicy != policy {
				t.Fatalf("reply policy %q stored %q, want %q", p.ReplyPolicy, e.repo.docs[p.ID].ReplyPolicy, policy)
			}
			if got, want := e.repo.lastCreate.RequestHash, requestHash("reply to @bob", rReply1, "", nil, nil, ReplyPolicyEveryone, false, false); got != want {
				t.Fatalf("a reply's hash must not include the inherited policy")
			}
			d := toDoc(p)
			if d.ReplyPolicy != string(policy) {
				t.Fatalf("doc = %+v: the policy name must be inherited", d)
			}
			// Only the reply's own mentions are stored, never the root's (the policy carries no user id).
			if !reflect.DeepEqual(p.Mentions, []Mention{{UserID: "uid-bob", Handle: "bob"}}) || len(d.Mentions) != 1 || d.Mentions[0].UserID != "uid-bob" {
				t.Fatalf("mentions = %+v / doc %+v, want only the reply's own @bob", p.Mentions, d.Mentions)
			}
		})
	}
	// EVERYONE conversation: nothing stored.
	e := newThreadEnv()
	p, _, err := e.replyTo(rReply1)
	if err != nil || p.ReplyPolicy != ReplyPolicyEveryone {
		t.Fatalf("EVERYONE reply: %+v %v", p, err)
	}
}

// TestCreateReply_EveryoneNeverLoadsTheRoot: an EVERYONE / absent conversation keeps today's rules exactly: the
// root is not read (it may even be gone) and only the caller's graph is touched.
func TestCreateReply_EveryoneNeverLoadsTheRoot(t *testing.T) {
	e := newThreadEnv()
	delete(e.repo.docs, rRoot) // deep reply, root deleted: unrestricted conversations do not care
	delete(e.dir.profiles, uZed)
	_, _, err := e.replyTo(rReply1)
	if err != nil {
		t.Fatal(err)
	}
	if got := distinct(e.graph.asked); !reflect.DeepEqual(got, []string{testUID}) || len(e.graph.asked) != 1 {
		t.Fatalf("graph snapshots asked = %v, want only the caller's, once (viewable)", e.graph.asked)
	}
}

type policyCase struct {
	name   string
	policy ReplyPolicy
	setup  func(e *createEnv)
	parent string
	// want: "ok", "notfound", "denied"
	want string
	// graphAsked, when non-nil, pins the distinct graph.Snapshot uids asked, in order (the cold read pattern of the
	// ADR cost table; the real reader caches a repeated uid for 60 s, the fake charges every call).
	graphAsked []string
}

func runPolicyCases(t *testing.T, tests []policyCase) {
	t.Helper()
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := restrictedEnv(tt.policy)
			if tt.setup != nil {
				tt.setup(e)
			}
			_, c, err := e.replyTo(tt.parent)
			switch tt.want {
			case "ok":
				if err != nil {
					t.Fatal(err)
				}
			case "notfound":
				wantNotFound(t, err)
			case "denied":
				wantReplyNotAllowed(t, err, strings.ToLower(string(tt.policy)))
			}
			if tt.want != "ok" {
				if c.Writes() != 0 || e.repo.createCalls != 0 || len(e.repo.idem) != 0 {
					t.Fatalf("a refusal must write nothing: writes=%d creates=%d idem=%d", c.Writes(), e.repo.createCalls, len(e.repo.idem))
				}
				if e.repo.docs[rRoot] != nil && e.repo.docs[rRoot].ReplyCount != 0 {
					t.Fatal("a refusal must not touch the parent counter")
				}
			}
			if got := distinct(e.graph.asked); tt.graphAsked != nil && !reflect.DeepEqual(got, tt.graphAsked) {
				t.Fatalf("graph snapshots asked = %v, want %v", got, tt.graphAsked)
			}
		})
	}
}

// distinct returns the uids in first-seen order (never nil).
func distinct(in []string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, u := range in {
		if !seen[u] {
			seen[u] = true
			out = append(out, u)
		}
	}
	return out
}

func mention(uids ...string) func(e *createEnv) {
	return func(e *createEnv) {
		for _, u := range uids {
			e.repo.docs[rRoot].Mentions = append(e.repo.docs[rRoot].Mentions, Mention{UserID: u, Handle: u})
		}
	}
}

func follows(author string, uids ...string) func(e *createEnv) {
	return func(e *createEnv) {
		if e.graph.snaps == nil {
			e.graph.snaps = map[string]graph.Snapshot{}
		}
		f := map[string]bool{}
		for _, u := range uids {
			f[u] = true
		}
		e.graph.snaps[author] = graph.Snapshot{Following: f}
	}
}

func both(fs ...func(e *createEnv)) func(e *createEnv) {
	return func(e *createEnv) {
		for _, f := range fs {
			f(e)
		}
	}
}

// callerOwnsRoot makes the caller the conversation author: the root, its REPOST target and its profile.
func callerOwnsRoot(e *createEnv) {
	root := e.repo.docs[rRoot]
	root.AuthorID = testUID
	root.Author = AuthorSnapshot{UserID: testUID, Handle: "Alice"}
	e.repo.docs[rPolRepost].Embedded.Author.UserID = testUID
	e.repo.docs[rPolRepost].EmbeddedAuthorID = testUID
}

func TestEnforceReplyPolicy_MentionedOnly(t *testing.T) {
	runPolicyCases(t, []policyCase{
		{"direct, mentioned caller", ReplyPolicyMentionedOnly, mention(testUID), rRoot, "ok", []string{testUID}},
		{"direct, not mentioned", ReplyPolicyMentionedOnly, mention("uid-other"), rRoot, "denied", []string{testUID}},
		{"direct, nobody mentioned", ReplyPolicyMentionedOnly, nil, rRoot, "denied", nil},
		{"direct, caller is the root author", ReplyPolicyMentionedOnly, callerOwnsRoot, rRoot, "ok", nil},
		{"direct, mentioned but the root author blocks the caller", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }), rRoot, "notfound", nil},
		{"direct, not mentioned and blocked: NOT_FOUND, never REPLY_NOT_ALLOWED", ReplyPolicyMentionedOnly,
			func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }, rRoot, "notfound", nil},
		{"direct, the caller blocked the root author", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.graph.snap.Blocked = map[string]bool{uZed: true} }), rRoot, "notfound", nil},
		{"direct, the caller's blockedBy overflowed", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.graph.snap.BlockedByOverflow = true }), rRoot, "notfound", nil},
		{"direct, root author muted by the caller is irrelevant", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.graph.snap.Muted = map[string]bool{uZed: true} }), rRoot, "ok", nil},
		{"direct, root hidden", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.repo.docs[rRoot].Moderation = ModerationTakenDown }), rRoot, "notfound", nil},
		{"direct, root author suspended", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { delete(e.dir.profiles, uZed) }), rRoot, "notfound", nil},
		{"direct, root author protected", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.protect(uZed) }), rRoot, "notfound", nil},
		{"deep, mentioned caller", ReplyPolicyMentionedOnly, mention(testUID), rReply1, "ok", nil},
		{"deep, not mentioned", ReplyPolicyMentionedOnly, mention("uid-other"), rReply1, "denied", nil},
		{"deep, only the root's mentions count", ReplyPolicyMentionedOnly,
			func(e *createEnv) { e.repo.docs[rReply1].Mentions = []Mention{{UserID: testUID, Handle: "alice"}} }, rReply1, "denied", nil},
		{"deep, caller wrote the parent: its graph is read once more", ReplyPolicyMentionedOnly, mention(testUID), rReply4, "ok", []string{testUID}},
		{"deep, mentioned but blocked by the root author", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }), rReply1, "notfound", nil},
		{"deep, not mentioned and blocked by the root author", ReplyPolicyMentionedOnly,
			func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }, rReply1, "notfound", nil},
		{"deep, the caller blocked the root author", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.graph.snap.Blocked = map[string]bool{uZed: true} }), rReply1, "notfound", nil},
		{"deep, caller blockedBy overflow", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.graph.snap.BlockedByOverflow = true }), rReply1, "notfound", nil},
		{"deep, root hidden", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.repo.docs[rRoot].Moderation = ModerationSuspendedAuthor }), rReply1, "notfound", nil},
		{"deep, root deleted", ReplyPolicyMentionedOnly,
			func(e *createEnv) { delete(e.repo.docs, rRoot) }, rReply1, "notfound", nil},
		{"deep, root author suspended or deleting", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { delete(e.dir.profiles, uZed) }), rReply1, "notfound", nil},
		{"deep, root not public", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.repo.docs[rRoot].Visibility = VisibilityFollowers }), rReply1, "notfound", nil},
		{"deep, the root author replies to a deep reply", ReplyPolicyMentionedOnly, callerOwnsRoot, rReply1, "ok", nil},
		{"deep, root is a quote whose embedded author blocks the caller", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) {
				e.repo.docs[rRoot].Kind = KindQuote
				e.repo.docs[rRoot].EmbeddedAuthorID = "uid-quoted"
				e.graph.snap.BlockedBy = map[string]bool{"uid-quoted": true}
			}), rReply1, "notfound", nil},
		{"reply to a repost resolves to the original: mentioned", ReplyPolicyMentionedOnly, mention(testUID), rPolRepost, "ok", nil},
		{"reply to a repost resolves to the original: not mentioned", ReplyPolicyMentionedOnly, nil, rPolRepost, "denied", nil},
	})
}

func TestEnforceReplyPolicy_Following(t *testing.T) {
	runPolicyCases(t, []policyCase{
		{"direct, follower", ReplyPolicyFollowing, follows(uZed, testUID), rRoot, "ok", []string{testUID, uZed}},
		{"direct, non-follower", ReplyPolicyFollowing, follows(uZed, "uid-other"), rRoot, "denied", []string{testUID, uZed}},
		{"direct, the caller follows the author but the author does not follow back", ReplyPolicyFollowing,
			func(e *createEnv) { e.graph.snap.Following = map[string]bool{uZed: true} }, rRoot, "denied", nil},
		{"direct, caller is the root author: no follow read", ReplyPolicyFollowing, callerOwnsRoot, rRoot, "ok", []string{}},
		{"direct, follower but blocked by the root author", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }), rRoot, "notfound", nil},
		{"direct, non-follower and blocked: NOT_FOUND", ReplyPolicyFollowing,
			func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }, rRoot, "notfound", nil},
		{"direct, the caller blocked the root author", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.graph.snap.Blocked = map[string]bool{uZed: true} }), rRoot, "notfound", nil},
		{"direct, blockedBy overflow", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.graph.snap.BlockedByOverflow = true }), rRoot, "notfound", nil},
		{"direct, root hidden", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.repo.docs[rRoot].Moderation = ModerationTakenDown }), rRoot, "notfound", nil},
		{"direct, root author deleting", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { delete(e.dir.profiles, uZed) }), rRoot, "notfound", nil},
		{"deep, follower", ReplyPolicyFollowing, follows(uZed, testUID), rReply1, "ok", []string{testUID, uZed}},
		{"deep, non-follower", ReplyPolicyFollowing, nil, rReply1, "denied", []string{testUID, uZed}},
		{"deep, caller wrote the parent: caller graph read once more, then the root author's", ReplyPolicyFollowing,
			follows(uZed, testUID), rReply4, "ok", []string{testUID, uZed}},
		{"deep, follower but blocked by the root author", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }), rReply1, "notfound", nil},
		{"deep, follower but the caller blocked the root author", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.graph.snap.Blocked = map[string]bool{uZed: true} }), rReply1, "notfound", nil},
		{"deep, follower but the caller's blockedBy overflowed", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.graph.snap.BlockedByOverflow = true }), rReply1, "notfound", nil},
		{"deep, root deleted", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { delete(e.repo.docs, rRoot) }), rReply1, "notfound", nil},
		{"deep, root author suspended", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { delete(e.dir.profiles, uZed) }), rReply1, "notfound", nil},
		{"deep, root hidden", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.repo.docs[rRoot].Moderation = ModerationTakenDown }), rReply1, "notfound", nil},
		{"deep, the root author's own deep reply", ReplyPolicyFollowing, callerOwnsRoot, rReply1, "ok", nil},
		{"reply to a repost resolves to the original: follower", ReplyPolicyFollowing, follows(uZed, testUID), rPolRepost, "ok", nil},
		{"reply to a repost resolves to the original: non-follower", ReplyPolicyFollowing, nil, rPolRepost, "denied", nil},
	})
}

// TestRejectReason_ReplyNotAllowed: the request log line names the refusal (runbook query outcome=rejected:...).
func TestRejectReason_ReplyNotAllowed(t *testing.T) {
	t.Parallel()
	if got := rejectReason(replyNotAllowed(ReplyPolicyFollowing)); got != "reply_not_allowed" {
		t.Fatalf("rejectReason = %q, want reply_not_allowed", got)
	}
}

// TestEnforceReplyPolicy_NotFlagGated: a stored restrictive policy is enforced whether FEATURE_REPLY_AUDIENCE is
// off or on; only SETTING consults the flag (switching it off must never reopen a conversation).
func TestEnforceReplyPolicy_NotFlagGated(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		t.Run(fmt.Sprintf("flag=%v", enabled), func(t *testing.T) {
			e := restrictedEnv(ReplyPolicyMentionedOnly, "uid-other")
			_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "r", ReplyToPostID: rRoot, RepliesEnabled: true, ReplyAudienceEnabled: enabled})
			wantReplyNotAllowed(t, err, "mentioned_only")
		})
	}
	// Through the real handler with the flag registry off for the caller.
	e := restrictedEnv(ReplyPolicyFollowing)
	srv := NewServer(e.svc, replyAudienceRegistry(flags.Spec{Mode: flags.Off}))
	_, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key1, Text: "r", ReplyToPostId: rRoot}))
	wantReplyNotAllowed(t, err, "following")
	var ce *connect.Error
	if !errors.As(apierr.ToConnect(err), &ce) || ce.Code() != connect.CodePermissionDenied {
		t.Fatalf("connect error = %v, want PermissionDenied", err)
	}
}

// TestServer_CreatePost_ReplyAudienceFlagMatrix drives the real handler and registry: the flag gates setting only.
func TestServer_CreatePost_ReplyAudienceFlagMatrix(t *testing.T) {
	on, off := flags.Spec{Mode: flags.On}, flags.Spec{Mode: flags.Off}
	tests := []struct {
		name string
		spec flags.Spec
		want bool
	}{
		{"on", on, true},
		{"off (default)", off, false},
		{"allowlisted caller", allowOnly(testUID), true},
		{"allowlisted someone else", allowOnly("someone-else"), false},
		{"percent 0", flags.Spec{Mode: flags.Percent, Percent: 0}, false},
		{"percent 100", flags.Spec{Mode: flags.Percent, Percent: 100}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newDeleteEnv()
			srv := NewServer(e.svc, replyAudienceRegistry(tt.spec))
			resp, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{
				IdempotencyKey: key1, Text: "audience", ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY}))
			if tt.want {
				if err != nil {
					t.Fatal(err)
				}
				if got := resp.Msg.GetPost().GetPost().GetReplyPolicy(); got != postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY {
					t.Fatalf("echoed policy = %v", got)
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != "reply_audience" {
				t.Fatalf("err = %v, want FEATURE_DISABLED feature=reply_audience", err)
			}
			if e.repo.createCalls != 0 {
				t.Fatal("a refused request reached the repo")
			}
			if _, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key2, Text: "plain"})); err != nil {
				t.Fatalf("plain post with the flag off: %v", err)
			}
		})
	}
}

// TestReplyPermissionFor is the 0-read timeline hint (review I-6 included).
func TestReplyPermissionFor(t *testing.T) {
	t.Parallel()
	const viewer, author, other = "uid-viewer", "uid-author", "uid-other"
	allowed, notAllowed, unknown := postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED, postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED, postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
	root := func(p ReplyPolicy, mentioned ...string) *Post {
		x := &Post{ID: "1", AuthorID: author, Kind: KindPost, ReplyPolicy: p}
		for _, m := range mentioned {
			x.Mentions = append(x.Mentions, Mention{UserID: m})
		}
		return x
	}
	tests := []struct {
		name   string
		p      *Post
		viewer string
		want   postsv1.ReplyPermission
	}{
		{"legacy root (absent policy)", root(""), viewer, allowed},
		{"EVERYONE root", root(ReplyPolicyEveryone), viewer, allowed},
		{"FOLLOWING root, viewer is the author", root(ReplyPolicyFollowing), author, allowed},
		{"FOLLOWING root, other viewer needs a read", root(ReplyPolicyFollowing), viewer, unknown},
		{"MENTIONED_ONLY root, author", root(ReplyPolicyMentionedOnly), author, allowed},
		{"MENTIONED_ONLY root, mentioned viewer", root(ReplyPolicyMentionedOnly, viewer), viewer, allowed},
		{"MENTIONED_ONLY root, other viewer", root(ReplyPolicyMentionedOnly, other), viewer, notAllowed},
		{"QUOTE root uses its own policy", &Post{Kind: KindQuote, AuthorID: author, ReplyPolicy: ReplyPolicyMentionedOnly}, viewer, notAllowed},
		{"reply in an EVERYONE conversation", &Post{Kind: KindReply, IsReply: true, AuthorID: other}, viewer, allowed},
		{"reply in a FOLLOWING conversation", &Post{Kind: KindReply, IsReply: true, AuthorID: other, ReplyPolicy: ReplyPolicyFollowing}, viewer, unknown},
		{"reply in a MENTIONED_ONLY conversation, mentioned viewer: no oracle", &Post{Kind: KindReply, IsReply: true, AuthorID: other, ReplyPolicy: ReplyPolicyMentionedOnly, Mentions: []Mention{{UserID: viewer}}}, viewer, unknown},
		{"own reply in a restricted conversation", &Post{Kind: KindReply, IsReply: true, AuthorID: viewer, ReplyPolicy: ReplyPolicyMentionedOnly}, viewer, unknown},
		{"REPOST of an EVERYONE post", &Post{Kind: KindRepost, Embedded: &Embedded{PostID: "9"}}, viewer, allowed},
		{"REPOST of a FOLLOWING post", &Post{Kind: KindRepost, Embedded: &Embedded{PostID: "9", ReplyPolicy: ReplyPolicyFollowing}}, viewer, unknown},
		{"REPOST of a MENTIONED_ONLY post (no mentions in the embed)", &Post{Kind: KindRepost, Embedded: &Embedded{PostID: "9", ReplyPolicy: ReplyPolicyMentionedOnly}}, viewer, unknown},
		{"REPOST of a MENTIONED_ONLY post by the viewer's own repost", &Post{Kind: KindRepost, AuthorID: viewer, Embedded: &Embedded{PostID: "9", ReplyPolicy: ReplyPolicyMentionedOnly}}, viewer, unknown},
		{"REPOST tombstone", &Post{Kind: KindRepost, Embedded: &Embedded{PostID: "9", Unavailable: true}}, viewer, unknown},
		{"REPOST without an embed", &Post{Kind: KindRepost}, viewer, unknown},
		{"the REPOST row's own policy field is ignored", &Post{Kind: KindRepost, ReplyPolicy: ReplyPolicyFollowing, Embedded: &Embedded{PostID: "9"}}, viewer, allowed},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := replyPermissionFor(tt.p, tt.viewer); got != tt.want {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
			if got := ToView(tt.p, ViewerSet{}, tt.viewer).GetViewerReplyPermission(); got != tt.want {
				t.Fatalf("ToView hint = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestServer_GetPost_ReplyHint: GetPost decides a root with at most the one cached graph read; a reply in a
// restricted conversation is UNKNOWN whatever the viewer's relation to the root (no M-1 oracle).
func TestServer_GetPost_ReplyHint(t *testing.T) {
	allowed, notAllowed, unknown := postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED, postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED, postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
	tests := []struct {
		name   string
		policy ReplyPolicy
		setup  func(e *createEnv)
		get    string
		want   postsv1.ReplyPermission
	}{
		{"EVERYONE root", "", nil, rRoot, allowed},
		{"FOLLOWING root, author follows the viewer", ReplyPolicyFollowing, follows(uZed, testUID), rRoot, allowed},
		{"FOLLOWING root, author does not", ReplyPolicyFollowing, follows(uZed, "uid-other"), rRoot, notAllowed},
		{"FOLLOWING root, the viewer blocked the author: UNKNOWN", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.graph.snap.Blocked = map[string]bool{uZed: true} }), rRoot, unknown},
		{"FOLLOWING root, blockedBy overflow: UNKNOWN", ReplyPolicyFollowing,
			both(follows(uZed, testUID), func(e *createEnv) { e.graph.snap.BlockedByOverflow = true }), rRoot, unknown},
		{"MENTIONED_ONLY root, mentioned", ReplyPolicyMentionedOnly, mention(testUID), rRoot, allowed},
		{"MENTIONED_ONLY root, not mentioned", ReplyPolicyMentionedOnly, nil, rRoot, notAllowed},
		{"MENTIONED_ONLY root, the viewer blocked the author: UNKNOWN", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.graph.snap.Blocked = map[string]bool{uZed: true} }), rRoot, unknown},
		{"deep reply in MENTIONED_ONLY, mentioned viewer: UNKNOWN", ReplyPolicyMentionedOnly, mention(testUID), rReply1, unknown},
		{"deep reply in MENTIONED_ONLY, unmentioned viewer: UNKNOWN", ReplyPolicyMentionedOnly, nil, rReply1, unknown},
		{"deep reply in FOLLOWING: UNKNOWN", ReplyPolicyFollowing, follows(uZed, testUID), rReply1, unknown},
		{"reply in EVERYONE", "", nil, rReply1, allowed},
		{"REPOST row uses the embedded policy: EVERYONE", "", nil, rPolRepost, allowed},
		{"REPOST row uses the embedded policy: restricted", ReplyPolicyMentionedOnly, mention(testUID), rPolRepost, unknown},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := restrictedEnv(tt.policy)
			if tt.setup != nil {
				tt.setup(e)
			}
			srv := NewServer(e.svc, replyAudienceRegistry(flags.Spec{Mode: flags.Off})) // the hint is not flag-gated
			got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: tt.get}))
			if err != nil {
				t.Fatal(err)
			}
			if h := got.Msg.GetPost().GetViewerReplyPermission(); h != tt.want {
				t.Fatalf("hint = %v, want %v", h, tt.want)
			}
		})
	}
}

// TestServer_GetThread_ReplyHint: one hint for every row, computed from the root GetThread loaded; an unavailable
// root is UNKNOWN.
func TestServer_GetThread_ReplyHint(t *testing.T) {
	allowed, notAllowed, unknown := postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED, postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED, postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN
	tests := []struct {
		name   string
		policy ReplyPolicy
		setup  func(e *createEnv)
		focal  string
		want   postsv1.ReplyPermission
	}{
		{"EVERYONE thread", "", nil, rReply1, allowed},
		{"root focal, FOLLOWING, follower", ReplyPolicyFollowing, follows(uZed, testUID), rRoot, allowed},
		{"root focal, FOLLOWING, non-follower", ReplyPolicyFollowing, nil, rRoot, notAllowed},
		{"deep focal, FOLLOWING, follower", ReplyPolicyFollowing, follows(uZed, testUID), rReply1, allowed},
		{"deep focal, FOLLOWING, non-follower", ReplyPolicyFollowing, nil, rReply1, notAllowed},
		{"deep focal, MENTIONED_ONLY, mentioned", ReplyPolicyMentionedOnly, mention(testUID), rReply1, allowed},
		{"deep focal, MENTIONED_ONLY, not mentioned", ReplyPolicyMentionedOnly, nil, rReply1, notAllowed},
		{"the root author's own thread", ReplyPolicyFollowing, callerOwnsRoot, rReply1, allowed},
		{"root unavailable (author blocks the caller): UNKNOWN", ReplyPolicyMentionedOnly,
			both(mention(testUID), func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }), rReply1, unknown},
		{"root unavailable (deleted): UNKNOWN", ReplyPolicyFollowing,
			func(e *createEnv) { delete(e.repo.docs, rRoot) }, rReply1, unknown},
		{"root unavailable (hidden): UNKNOWN", ReplyPolicyFollowing,
			func(e *createEnv) { e.repo.docs[rRoot].Moderation = ModerationTakenDown }, rReply1, unknown},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := restrictedEnv(tt.policy)
			if tt.setup != nil {
				tt.setup(e)
			}
			srv := NewServer(e.svc, replyAudienceRegistry(flags.Spec{Mode: flags.Off}))
			resp, err := srv.GetThread(callerCtx(testUID), connect.NewRequest(&postsv1.GetThreadRequest{PostId: tt.focal}))
			if err != nil {
				t.Fatal(err)
			}
			views := []*postsv1.PostView{resp.Msg.GetFocal(), resp.Msg.GetParent(), resp.Msg.GetRoot()}
			views = append(views, resp.Msg.GetReplies()...)
			n := 0
			for _, v := range views {
				if v == nil {
					continue
				}
				n++
				if got := v.GetViewerReplyPermission(); got != tt.want {
					t.Fatalf("row %s hint = %v, want %v", v.GetPost().GetPostId(), got, tt.want)
				}
			}
			if n == 0 {
				t.Fatal("no rows")
			}
		})
	}
}

// TestContextUsable pins the shared predicate that GetThread and reply enforcement both use (review M-1).
func TestContextUsable(t *testing.T) {
	t.Parallel()
	const caller, author = "uid-caller", "uid-author"
	pub := func() *Post { return &Post{ID: "1", AuthorID: author, Visibility: VisibilityPublic} }
	tests := []struct {
		name   string
		p      *Post
		active bool
		caller string
		snap   graph.Snapshot
		want   bool
	}{
		{"usable", pub(), true, caller, graph.Snapshot{}, true},
		{"nil", nil, true, caller, graph.Snapshot{}, false},
		{"not public", &Post{AuthorID: author, Visibility: VisibilityFollowers}, true, caller, graph.Snapshot{}, false},
		{"hidden", &Post{AuthorID: author, Visibility: VisibilityPublic, Moderation: ModerationTakenDown}, true, caller, graph.Snapshot{}, false},
		{"author not active", pub(), false, caller, graph.Snapshot{}, false},
		{"author blocks the caller", pub(), true, caller, graph.Snapshot{BlockedBy: map[string]bool{author: true}}, false},
		{"caller blocks the author", pub(), true, caller, graph.Snapshot{Blocked: map[string]bool{author: true}}, false},
		{"overflow fails closed", pub(), true, caller, graph.Snapshot{BlockedByOverflow: true}, false},
		{"embedded author blocks the caller", &Post{AuthorID: author, Visibility: VisibilityPublic, EmbeddedAuthorID: "uid-emb"}, true, caller, graph.Snapshot{BlockedBy: map[string]bool{"uid-emb": true}}, false},
		{"own post is exempt from the graph", &Post{AuthorID: caller, Visibility: VisibilityPublic}, true, caller, graph.Snapshot{BlockedByOverflow: true, Blocked: map[string]bool{caller: true}}, true},
		{"own post still needs to be visible", &Post{AuthorID: caller, Visibility: VisibilityPublic, Moderation: ModerationTakenDown}, true, caller, graph.Snapshot{}, false},
	}
	for _, tt := range tests {
		if got := contextUsable(tt.p, tt.active, tt.caller, tt.snap); got != tt.want {
			t.Errorf("%s: got %v, want %v", tt.name, got, tt.want)
		}
	}
}

// TestSnapshotOf_CopiesReplyPolicy: a quote or repost freezes the original's effective policy in its embed; the
// REPOST row has none of its own.
func TestSnapshotOf_CopiesReplyPolicy(t *testing.T) {
	t.Parallel()
	for _, pol := range []ReplyPolicy{ReplyPolicyEveryone, ReplyPolicyFollowing, ReplyPolicyMentionedOnly} {
		orig := &Post{ID: pidOther, Author: AuthorSnapshot{UserID: otherUID}, ReplyPolicy: pol, CreatedAt: time.UnixMilli(5)}
		if s := snapshotOf(orig); s.ReplyPolicy != pol {
			t.Errorf("snapshotOf %q -> %q", pol, s.ReplyPolicy)
		}
		rp := NewRepostPost("0000000000000000099", time.UnixMilli(9), AuthorSnapshot{UserID: testUID}, 1, orig)
		if rp.ReplyPolicy != ReplyPolicyEveryone || rp.Embedded.ReplyPolicy != pol {
			t.Errorf("repost: own %q embed %q, want none / %q", rp.ReplyPolicy, rp.Embedded.ReplyPolicy, pol)
		}
		if got := ToProto(rp).GetEmbedded().GetReplyPolicy(); got != policyToProto(pol) {
			t.Errorf("wire embed policy = %v", got)
		}
	}
}

// TestDoc_ReplyPolicyRoundTripAndLegacy: the field name on disk is `replyPolicy`, absent for EVERYONE, and a legacy
// doc reads as EVERYONE; a tombstone embed carries none.
func TestDoc_ReplyPolicyRoundTripAndLegacy(t *testing.T) {
	t.Parallel()
	p := &Post{ID: "1", AuthorID: testUID, Kind: KindQuote, ReplyPolicy: ReplyPolicyMentionedOnly,
		Embedded:  &Embedded{PostID: "2", Author: AuthorSnapshot{UserID: otherUID}, ReplyPolicy: ReplyPolicyFollowing, CreatedAt: time.UnixMilli(3)},
		CreatedAt: time.UnixMilli(4)}
	got := toDoc(p).toPost("1")
	if got.ReplyPolicy != ReplyPolicyMentionedOnly || got.Embedded.ReplyPolicy != ReplyPolicyFollowing {
		t.Fatalf("round trip: %q / %q", got.ReplyPolicy, got.Embedded.ReplyPolicy)
	}
	legacy := postDoc{AuthorID: testUID, Kind: "POST", Embedded: &embeddedDoc{PostID: "2", Text: "t"}}.toPost("9")
	if legacy.ReplyPolicy != ReplyPolicyEveryone || legacy.Embedded.ReplyPolicy != ReplyPolicyEveryone {
		t.Fatalf("legacy doc must read as EVERYONE: %+v", legacy)
	}
	if pb := ToProto(legacy); pb.GetReplyPolicy() != postsv1.ReplyPolicy_REPLY_POLICY_UNSPECIFIED || pb.GetEmbedded().GetReplyPolicy() != postsv1.ReplyPolicy_REPLY_POLICY_UNSPECIFIED {
		t.Fatalf("legacy wire policy must be UNSPECIFIED: %v", pb)
	}
	if toDoc(&Post{ID: "3", AuthorID: testUID}).ReplyPolicy != "" {
		t.Fatal("EVERYONE must not write the field (omitempty)")
	}
	tomb := toDoc(&Post{ID: "3", Kind: KindQuote, Embedded: &Embedded{PostID: "2", Unavailable: true, ReplyPolicy: ReplyPolicyFollowing}})
	if tomb.Embedded.ReplyPolicy != "" {
		t.Fatalf("a tombstone embed must carry no policy: %+v", tomb.Embedded)
	}
}

// TestExport_ReplyPolicyShape: the export names the policy only when set, and holds no user id.
func TestExport_ReplyPolicyShape(t *testing.T) {
	t.Parallel()
	plain, _ := json.Marshal(exportedPost{ID: "1"})
	if bytes.Contains(plain, []byte("replyPolicy")) {
		t.Fatalf("EVERYONE export changed: %s", plain)
	}
	set, _ := json.Marshal(exportedPost{ID: "1", ReplyPolicy: "FOLLOWING"})
	if !bytes.Contains(set, []byte(`"replyPolicy":"FOLLOWING"`)) {
		t.Fatalf("export = %s", set)
	}
}

// TestGetThread_ContextUnchangedByRefactor: the shared predicate keeps threadContext's behaviour (parent/root
// unavailable by cause, never distinguishable).
func TestGetThread_ContextUnchangedByRefactor(t *testing.T) {
	e := newThreadEnv()
	e.graph.snap.BlockedBy = map[string]bool{uZed: true}
	th, _, err := e.thread(ThreadInput{PostID: rReply4})
	if err != nil {
		t.Fatal(err)
	}
	// EVERYONE: the answer does not depend on the root, so an unavailable root is no oracle and the hint is ALLOWED.
	if !th.RootUnavailable || th.ReplyPermission != postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED {
		t.Fatalf("root unavailable=%v hint=%v", th.RootUnavailable, th.ReplyPermission)
	}
	// RESTRICTED with the same unavailable root: the hint needs the root, so it stays UNKNOWN.
	er := restrictedEnv(ReplyPolicyFollowing)
	er.graph.snap.BlockedBy = map[string]bool{uZed: true}
	thr, _, err := er.thread(ThreadInput{PostID: rReply4})
	if err != nil {
		t.Fatal(err)
	}
	if !thr.RootUnavailable || thr.ReplyPermission != postsv1.ReplyPermission_REPLY_PERMISSION_UNKNOWN {
		t.Fatalf("restricted: root unavailable=%v hint=%v, want UNKNOWN", thr.RootUnavailable, thr.ReplyPermission)
	}
	// Reads stay bounded: GetThread adds nothing for an EVERYONE thread (no FOLLOWING graph read).
	e2 := newThreadEnv()
	_, _, err = e2.thread(ThreadInput{PostID: rReply4})
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range e2.graph.asked {
		if a != testUID {
			t.Fatalf("an EVERYONE thread read the graph of %q", a)
		}
	}
}

// TestEnforceReplyPolicy_DependencyFailuresAreInternal: a failing root read or follow read is an internal error,
// never a REPLY_NOT_ALLOWED (which would wrongly tell the caller the conversation is closed) and never stored.
func TestEnforceReplyPolicy_DependencyFailuresAreInternal(t *testing.T) {
	notAPIError := func(t *testing.T, err error) {
		t.Helper()
		var ae *apierr.Error
		if err == nil || errors.As(err, &ae) {
			t.Fatalf("err = %v, want a plain internal error", err)
		}
	}
	t.Run("root author graph read fails", func(t *testing.T) {
		e := restrictedEnv(ReplyPolicyFollowing)
		e.graph.errs = map[string]error{uZed: errBoom}
		_, _, err := e.replyTo(rRoot)
		notAPIError(t, err)
		if e.repo.createCalls != 0 {
			t.Fatal("nothing may be written")
		}
	})
	t.Run("root read fails on a deep reply", func(t *testing.T) {
		e := restrictedEnv(ReplyPolicyMentionedOnly, testUID)
		if _, err := e.svc.Get(context.Background(), rReply1); err != nil { // warm the parent so only the root read fails
			t.Fatal(err)
		}
		e.repo.getAllErr = errBoom
		_, _, err := e.replyTo(rReply1)
		notAPIError(t, err)
		if e.repo.createCalls != 0 {
			t.Fatal("nothing may be written")
		}
	})
}

// TestCreate_ReplyReplayAfterPermissionLost pins the founder-accepted behaviour (CMP-B2 review, MINOR 2): enforcement
// runs before the idempotency lookup, so a replay of a reply that was created while allowed answers REPLY_NOT_ALLOWED
// (or NOT_FOUND once the root is unusable) after the permission is gone. It fails closed and never grants access;
// the reply itself still exists.
func TestCreate_ReplyReplayAfterPermissionLost(t *testing.T) {
	tests := []struct {
		name   string
		revoke func(e *createEnv)
		want   string
	}{
		{"mention removed from the root", func(e *createEnv) { e.repo.docs[rRoot].Mentions = nil }, "denied"},
		{"root hidden", func(e *createEnv) { e.repo.docs[rRoot].Moderation = ModerationTakenDown }, "notfound"},
		{"root author blocks the caller", func(e *createEnv) { e.graph.snap.BlockedBy = map[string]bool{uZed: true} }, "notfound"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := restrictedEnv(ReplyPolicyMentionedOnly, testUID)
			first, _, err := e.replyTo(rRoot)
			if err != nil {
				t.Fatalf("first reply: %v", err)
			}
			tt.revoke(e)
			e.repo.createCalls = 0
			got, c, err := e.replyTo(rRoot) // same idempotency key and request
			switch tt.want {
			case "denied":
				wantReplyNotAllowed(t, err, "mentioned_only")
			case "notfound":
				wantNotFound(t, err)
			}
			if got != nil || c.Writes() != 0 || e.repo.createCalls != 0 {
				t.Fatalf("a refused replay returns nothing and writes nothing: post=%v writes=%d creates=%d", got, c.Writes(), e.repo.createCalls)
			}
			if e.repo.docs[first.ID] == nil {
				t.Fatal("the original reply must still exist")
			}
		})
	}
}
