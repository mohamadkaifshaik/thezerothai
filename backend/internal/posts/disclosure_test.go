package posts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// Content disclosure (ADR-0021 D3, CMP-C2/C4): two user-asserted labels, stored on the post doc, frozen into the
// Embedded snapshot, hashed only when set, gated by FEATURE_CONTENT_DISCLOSURE on SETTING only.

func disclosureRegistry(disclosure flags.Spec) *flags.Registry {
	disclosure.Name = ContentDisclosureFlagName
	return flags.NewRegistry(
		flags.Spec{Name: "posts", Mode: flags.On},
		flags.Spec{Name: RepliesFlagName, Mode: flags.On},
		flags.Spec{Name: EngagementFlagName, Mode: flags.On},
		flags.Spec{Name: QuotesFlagName, Mode: flags.On},
		disclosure,
	)
}

// TestRequestHash_DisclosureOnlyWhenSet: a request without labels hashes byte-for-byte as it did before ADR-0021
// (so a retry across the deploy replays), and each label changes the hash independently.
func TestRequestHash_DisclosureOnlyWhenSet(t *testing.T) {
	t.Parallel()
	base := func(text, reply, quote string, media, alts []string) string {
		return fmt.Sprintf("v1|text=%q|media=%q|alts=%q|reply=%q|quote=%q",
			text, strings.Join(media, ","), strings.Join(alts, ""), reply, quote)
	}
	tests := []struct {
		name         string
		text         string
		reply, quote string
		media, alts  []string
	}{
		{"text only", "hello", "", "", nil, nil},
		{"reply", "hello", "0000000000000000007", "", nil, nil},
		{"quote", "hello", "", "0000000000000000008", nil, nil},
		{"media with alts", "hello", "", "", []string{mid1, mid2}, []string{"a", "b"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := base(tt.text, tt.reply, tt.quote, tt.media, tt.alts)
			// Pinned goldens: the exact bytes hashed, suffixes only when set, |pp=1 before |ai=1.
			golden := []struct {
				name   string
				pp, ai bool
				want   string
			}{
				{"none", false, false, b},
				{"pp", true, false, b + "|pp=1"},
				{"ai", false, true, b + "|ai=1"},
				{"both", true, true, b + "|pp=1|ai=1"},
			}
			seen := map[string]string{}
			for _, g := range golden {
				got := requestHash(tt.text, tt.reply, tt.quote, tt.media, tt.alts, g.pp, g.ai)
				if want := idempotency.HashRequest(g.want); got != want {
					t.Fatalf("%s: request hash = %s, want HashRequest(%q) = %s", g.name, got, g.want, want)
				}
				if prev, dup := seen[got]; dup {
					t.Fatalf("%s hashes like %s", g.name, prev)
				}
				seen[got] = g.name
			}
		})
	}
}

// TestCreate_Disclosure covers the service: flag off with a label is FEATURE_DISABLED before any read, flag off
// without labels behaves as before, flag on persists and returns the labels, and the idempotency replay semantics
// follow the hash.
func TestCreate_Disclosure(t *testing.T) {
	tests := []struct {
		name       string
		enabled    bool
		pp, ai     bool
		wantReject bool
	}{
		{"off, no labels", false, false, false, false},
		{"off, paid partnership", false, true, false, true},
		{"off, made with AI", false, false, true, true},
		{"off, both", false, true, true, true},
		{"on, no labels", true, false, false, false},
		{"on, paid partnership", true, true, false, false},
		{"on, made with AI", true, false, true, false},
		{"on, both", true, true, true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			p, c, err := e.create(CreateInput{
				IdempotencyKey: key1, Text: "hello",
				PaidPartnership: tt.pp, MadeWithAI: tt.ai, DisclosureEnabled: tt.enabled,
			})
			if tt.wantReject {
				ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if ae.Metadata["feature"] != "content_disclosure" || c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
					t.Fatalf("feature=%q reads=%d writes=%d creates=%d", ae.Metadata["feature"], c.Reads(), c.Writes(), e.repo.createCalls)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if p.PaidPartnership != tt.pp || p.MadeWithAI != tt.ai {
				t.Fatalf("returned labels pp=%v ai=%v, want %v/%v", p.PaidPartnership, p.MadeWithAI, tt.pp, tt.ai)
			}
			stored := e.repo.docs[p.ID]
			if stored.PaidPartnership != tt.pp || stored.MadeWithAI != tt.ai {
				t.Fatalf("persisted labels pp=%v ai=%v, want %v/%v", stored.PaidPartnership, stored.MadeWithAI, tt.pp, tt.ai)
			}
			// No read/write assertion here: fakeRepo.Create adds fixed counts, so it could not fail. The "delta 0"
			// claim is asserted against a real emulator in TestCreate_Integration_Disclosure.
		})
	}
}

// TestCreate_DisclosureIdempotency: the same key with the same labels replays; the same key with different labels
// is IDEMPOTENCY_KEY_REUSED; a plain retry of a pre-deploy request (no labels) still replays.
func TestCreate_DisclosureIdempotency(t *testing.T) {
	e := newCreateEnv()
	in := CreateInput{IdempotencyKey: key1, Text: "hello", MadeWithAI: true, DisclosureEnabled: true}
	first, _, err := e.create(in)
	if err != nil {
		t.Fatal(err)
	}
	replay, c, err := e.create(in)
	if err != nil || replay.ID != first.ID || c.Writes() != 0 {
		t.Fatalf("replay id=%v err=%v writes=%d", replay, err, c.Writes())
	}
	changed := in
	changed.PaidPartnership = true
	_, _, err = e.create(changed)
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)

	// Pre-deploy record: stored under the legacy hash, retried by the new code without labels.
	e2 := newCreateEnv()
	legacyKey := idempotency.Key(testUID, createRPC, key2)
	e2.repo.idem = map[string]fakeIdem{legacyKey: {
		hash:   idempotency.HashRequest(fmt.Sprintf("v1|text=%q|media=%q|alts=%q|reply=%q|quote=%q", "hello", "", "", "", "")),
		postID: pidMine,
	}}
	e2.repo.docs[pidMine] = post(pidMine, testUID)
	got, _, err := e2.create(CreateInput{IdempotencyKey: key2, Text: "hello"})
	if err != nil || got.ID != pidMine {
		t.Fatalf("legacy retry: post=%v err=%v, want a replay of %s", got, err, pidMine)
	}
}

// TestCreate_DisclosureQuoteCopiesTargetLabels: a quote keeps its own labels on itself and the quoted post's
// labels on the embed; a quote of a labelled post made without labels carries only the embed's.
func TestCreate_DisclosureQuoteCopiesTargetLabels(t *testing.T) {
	e := newDeleteEnv()
	e.repo.docs[pidOther].PaidPartnership = true
	e.repo.docs[pidOther].MadeWithAI = true
	p, _, err := e.create(CreateInput{
		IdempotencyKey: key1, Text: "my take", QuoteOfPostID: pidOther, QuotesEnabled: true,
		MadeWithAI: false, PaidPartnership: true, DisclosureEnabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !p.PaidPartnership || p.MadeWithAI {
		t.Fatalf("quote's own labels pp=%v ai=%v, want true/false", p.PaidPartnership, p.MadeWithAI)
	}
	if p.Embedded == nil || !p.Embedded.PaidPartnership || !p.Embedded.MadeWithAI {
		t.Fatalf("embedded = %+v, want both labels copied from the quoted post", p.Embedded)
	}
	pb := ToProto(p)
	if !pb.GetPaidPartnership() || pb.GetMadeWithAi() || !pb.GetEmbedded().GetPaidPartnership() || !pb.GetEmbedded().GetMadeWithAi() {
		t.Fatalf("wire labels wrong: %v", pb)
	}

	// Quoting with the flag off for the caller still copies the target's labels (display never consults the flag).
	e2 := newDeleteEnv()
	e2.repo.docs[pidOther].MadeWithAI = true
	q, _, err := e2.create(CreateInput{IdempotencyKey: key1, Text: "t", QuoteOfPostID: pidOther, QuotesEnabled: true})
	if err != nil || q.PaidPartnership || q.MadeWithAI || q.Embedded == nil || !q.Embedded.MadeWithAI {
		t.Fatalf("flag-off quote: %+v err=%v", q, err)
	}
}

// TestSnapshotOfAndRepost: snapshotOf copies both labels, and a REPOST carries none of its own while its
// embedded snapshot keeps the original's.
func TestSnapshotOfAndRepost(t *testing.T) {
	t.Parallel()
	tests := []struct{ pp, ai bool }{{false, false}, {true, false}, {false, true}, {true, true}}
	for _, tt := range tests {
		orig := &Post{ID: pidOther, Author: AuthorSnapshot{UserID: otherUID}, Text: "x", PaidPartnership: tt.pp, MadeWithAI: tt.ai,
			CreatedAt: time.UnixMilli(5)}
		s := snapshotOf(orig)
		if s.PaidPartnership != tt.pp || s.MadeWithAI != tt.ai {
			t.Errorf("snapshotOf %+v -> %+v", tt, s)
		}
		rp := NewRepostPost("0000000000000000099", time.UnixMilli(9), AuthorSnapshot{UserID: testUID}, 1, orig)
		if rp.PaidPartnership || rp.MadeWithAI {
			t.Errorf("a REPOST must not carry labels of its own: %+v", rp)
		}
		if rp.Embedded.PaidPartnership != tt.pp || rp.Embedded.MadeWithAI != tt.ai {
			t.Errorf("repost embed %+v -> %+v", tt, rp.Embedded)
		}
	}
}

// TestDoc_DisclosureRoundTripAndLegacy: toDoc/toPost keep both labels on the post and the embed; a legacy doc
// without the fields reads as false; the tombstone embed carries none.
func TestDoc_DisclosureRoundTripAndLegacy(t *testing.T) {
	t.Parallel()
	p := &Post{ID: "1", AuthorID: testUID, Kind: KindQuote, PaidPartnership: true, MadeWithAI: true,
		Embedded:  &Embedded{PostID: "2", Author: AuthorSnapshot{UserID: otherUID}, MadeWithAI: true, CreatedAt: time.UnixMilli(3)},
		CreatedAt: time.UnixMilli(4)}
	got := toDoc(p).toPost("1")
	if !got.PaidPartnership || !got.MadeWithAI || got.Embedded.PaidPartnership || !got.Embedded.MadeWithAI {
		t.Fatalf("round trip lost labels: %+v embedded %+v", got, got.Embedded)
	}
	legacy := postDoc{AuthorID: testUID, Kind: "POST", Embedded: &embeddedDoc{PostID: "2", Text: "t"}}.toPost("9")
	if legacy.PaidPartnership || legacy.MadeWithAI || legacy.Embedded.PaidPartnership || legacy.Embedded.MadeWithAI {
		t.Fatalf("legacy doc must read as false: %+v", legacy)
	}
	pb := ToProto(legacy)
	if pb.GetPaidPartnership() || pb.GetMadeWithAi() || pb.GetEmbedded().GetPaidPartnership() || pb.GetEmbedded().GetMadeWithAi() {
		t.Fatalf("legacy wire labels must be false: %v", pb)
	}
	// ToProto-level only: the stored tombstone (tombstoneUpdates replaces the whole embedded map) is asserted
	// against the emulator in TestCreate_Integration_Disclosure.
	tomb := ToProto(&Post{ID: "3", Kind: KindQuote, Embedded: &Embedded{PostID: "2", Unavailable: true, PaidPartnership: true}})
	if tomb.GetEmbedded().GetPaidPartnership() || !tomb.GetEmbedded().GetUnavailable() {
		t.Fatalf("a tombstone embed must carry no labels: %v", tomb.GetEmbedded())
	}
}

// TestToView_CarriesDisclosure: ToView (used by GetPost, GetThread and the timeline module) returns the labels.
func TestToView_CarriesDisclosure(t *testing.T) {
	t.Parallel()
	v := ToView(&Post{ID: "1", PaidPartnership: true, MadeWithAI: true, CreatedAt: time.UnixMilli(1)}, ViewerSet{})
	if !v.GetPost().GetPaidPartnership() || !v.GetPost().GetMadeWithAi() {
		t.Fatalf("view = %v", v)
	}
}

// TestServer_CreatePost_DisclosureFlagMatrix drives the real handler and registry: the flag gates setting only.
func TestServer_CreatePost_DisclosureFlagMatrix(t *testing.T) {
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
			srv := NewServer(e.svc, disclosureRegistry(tt.spec))
			resp, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{
				IdempotencyKey: key1, Text: "ad", PaidPartnership: true, MadeWithAi: true}))
			if tt.want {
				if err != nil {
					t.Fatal(err)
				}
				p := resp.Msg.GetPost().GetPost()
				if !p.GetPaidPartnership() || !p.GetMadeWithAi() {
					t.Fatalf("echoed labels = %v/%v, want true/true", p.GetPaidPartnership(), p.GetMadeWithAi())
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != "content_disclosure" {
				t.Fatalf("err = %v, want FEATURE_DISABLED feature=content_disclosure", err)
			}
			if e.repo.createCalls != 0 {
				t.Fatalf("a refused request reached the repo")
			}
			// Flag off with no labels is the old behaviour.
			if _, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key2, Text: "plain"})); err != nil {
				t.Fatalf("plain post with disclosure off: %v", err)
			}
		})
	}
}

// TestServer_GetPost_DisclosureDisplaysWithFlagOff: turning the flag off leaves existing labels rendered.
func TestServer_GetPost_DisclosureDisplaysWithFlagOff(t *testing.T) {
	e := newDeleteEnv()
	e.repo.docs[pidOther].PaidPartnership = true
	srv := NewServer(e.svc, disclosureRegistry(flags.Spec{Mode: flags.Off}))
	got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: pidOther}))
	if err != nil {
		t.Fatal(err)
	}
	if !got.Msg.GetPost().GetPost().GetPaidPartnership() || got.Msg.GetPost().GetPost().GetMadeWithAi() {
		t.Fatalf("GetPost labels = %v", got.Msg.GetPost().GetPost())
	}
}

// TestExport_DisclosureShape: the manual export names the labels only when set, so older exports are unchanged.
func TestExport_DisclosureShape(t *testing.T) {
	t.Parallel()
	plain, _ := json.Marshal(exportedPost{ID: "1"})
	if bytes.Contains(plain, []byte("paidPartnership")) || bytes.Contains(plain, []byte("madeWithAi")) {
		t.Fatalf("unlabelled post export changed: %s", plain)
	}
	set, _ := json.Marshal(exportedPost{ID: "1", PaidPartnership: true, MadeWithAI: true})
	if !bytes.Contains(set, []byte(`"paidPartnership":true`)) || !bytes.Contains(set, []byte(`"madeWithAi":true`)) {
		t.Fatalf("labelled post export = %s", set)
	}
}

// TestGet_WarmCacheKeepsDisclosure: CreatePost seeds the instance cache with SetPost, and a counter adjustment
// copies the cached post; a warm Get (0 reads) must still carry both labels on the post and on its embed.
func TestGet_WarmCacheKeepsDisclosure(t *testing.T) {
	e := newDeleteEnv()
	e.repo.docs[pidOther].MadeWithAI = true
	p, _, err := e.create(CreateInput{
		IdempotencyKey: key1, Text: "my take", QuoteOfPostID: pidOther, QuotesEnabled: true,
		PaidPartnership: true, DisclosureEnabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, step := range []string{"after create", "after AdjustCounts"} {
		if step == "after AdjustCounts" {
			e.cache.AdjustCounts(p.ID, 1, 0, 0)
		}
		ctx, c := budget.WithCounter(context.Background())
		got, err := e.svc.Get(ctx, p.ID)
		if err != nil {
			t.Fatal(err)
		}
		if c.Reads() != 0 {
			t.Fatalf("%s: warm Get read %d docs, want 0", step, c.Reads())
		}
		if !got.PaidPartnership || got.MadeWithAI || got.Embedded == nil || got.Embedded.PaidPartnership || !got.Embedded.MadeWithAI {
			t.Fatalf("%s: labels lost on the cache path: %+v embedded %+v", step, got, got.Embedded)
		}
	}
}
