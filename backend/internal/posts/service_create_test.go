package posts

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

const (
	testUID = "uid-alice"
	key1    = "0123456789abcdef"
	key2    = "fedcba9876543210"
)

type createEnv struct {
	svc    *service
	repo   *fakeRepo
	dir    *fakeDirectory
	graph  *fakeGraph
	events *recordingEvents
	cache  *Cache
}

func newCreateEnv(opts ...Option) *createEnv {
	now := time.Unix(1_700_000_000, 0)
	e := &createEnv{
		repo: newFakeRepo(),
		dir: &fakeDirectory{
			profiles: map[string]identity.Profile{
				testUID: {UserID: testUID, Handle: "Alice", HandleLower: "alice", DisplayName: "Alice A", AvatarThumbURL: "https://x/a.webp", Verified: true,
					Status: identity.AccountStatusActive, CreatedAt: now.Add(-72 * time.Hour), SnapshotVersion: 3},
			},
			handles: map[string]string{"bob": "uid-bob", "carol": "uid-carol"},
		},
		graph:  &fakeGraph{},
		events: &recordingEvents{},
		cache:  NewCache(time.Minute, 0, 0),
	}
	e.svc = New(Deps{
		Repo: e.repo, Cache: e.cache, Events: e.events, Directory: e.dir, Graph: e.graph,
		PostsPerDay: 100, NewAccountPostsPerDay: 20, NewAccountWindow: 24 * time.Hour,
		Now: func() time.Time { return now },
	}, opts...).(*service)
	return e
}

func (e *createEnv) create(in CreateInput) (*Post, *budget.Counter, error) {
	ctx, c := budget.WithCounter(googleCtx(context.Background(), testUID))
	p, err := e.svc.Create(ctx, testUID, in)
	return p, c, err
}

func wantAPIError(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason) *apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error %v (%T) is not an *apierr.Error", err, err)
	}
	if ae.Code != code || ae.Reason != reason {
		t.Fatalf("got code=%v reason=%v (%q), want %v / %v", ae.Code, ae.Reason, ae.Message, code, reason)
	}
	return ae
}

func TestCreate_StoresADR0003Shape(t *testing.T) {
	e := newCreateEnv()
	p, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "Hello @Bob and @ghost #Go #go"})
	if err != nil {
		t.Fatal(err)
	}
	if p.Kind != KindPost || p.IsReply || p.ConversationID != p.ID || p.Visibility != VisibilityPublic || p.AuthorID != testUID {
		t.Fatalf("shape: %+v", p)
	}
	if !reflect.DeepEqual(p.Mentions, []Mention{{UserID: "uid-bob", Handle: "bob"}}) || !reflect.DeepEqual(p.Hashtags, []string{"go"}) {
		t.Fatalf("mentions=%v hashtags=%v", p.Mentions, p.Hashtags)
	}
	if p.Author != (AuthorSnapshot{UserID: testUID, Handle: "Alice", DisplayName: "Alice A", AvatarURL: "https://x/a.webp", Verified: true}) || p.SnapshotVersion != 3 {
		t.Fatalf("author snapshot: %+v v%d", p.Author, p.SnapshotVersion)
	}
	if p.LikeCount+p.RepostCount+p.ReplyCount+p.QuoteCount != 0 {
		t.Fatal("counters must start at 0")
	}
	if got, ok := e.cache.GetPost(p.ID); !ok || got != p {
		t.Fatal("post must be in the posts cache after commit")
	}
	if len(e.events.created) != 1 || !reflect.DeepEqual(e.dir.forgotten, []string{testUID}) {
		t.Fatalf("events=%d forgotten=%v", len(e.events.created), e.dir.forgotten)
	}
	if e.repo.postsCount != 1 || c.Writes() != 4 {
		t.Fatalf("postsCount=%d writes=%d, want 1 and 4", e.repo.postsCount, c.Writes())
	}
}

func TestCreate_AuthorRecentUpdatedFromWrittenData(t *testing.T) {
	e := newCreateEnv()
	e.cache.StoreAuthorRecent(testUID, nil, false, time.Now())
	p, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "first"})
	if err != nil {
		t.Fatal(err)
	}
	r, ok := e.svc.AuthorRecent(testUID)
	if !ok || len(r.Posts) != 1 || r.Posts[0].ID != p.ID {
		t.Fatalf("author-recent = %+v, %v", r, ok)
	}
}

func TestCreate_Mentions(t *testing.T) {
	tests := []struct {
		name         string
		text         string
		snap         graph.Snapshot
		wantMentions []string
		wantGraph    int
		wantResolve  int
	}{
		{"no candidate: no graph read", "just text #tag", graph.Snapshot{}, nil, 0, 0},
		{"unknown handle stays text", "@ghost hi", graph.Snapshot{}, nil, 1, 1},
		{"blocked-by author is dropped", "@bob @carol", graph.Snapshot{BlockedBy: map[string]bool{"uid-bob": true}}, []string{"carol"}, 1, 1},
		{"blockedBy overflow drops all, no handle read", "@bob @carol", graph.Snapshot{BlockedByOverflow: true}, nil, 1, 0},
		{"author blocked bob: still mentioned", "@bob", graph.Snapshot{Blocked: map[string]bool{"uid-bob": true}}, []string{"bob"}, 1, 1},
		{"mention inside URL: no graph, no handle read", "https://ex.com/?ref=@bob", graph.Snapshot{}, nil, 0, 0},
		{"URL candidate does not cost a read but a real one does", "https://ex.com/?ref=@bob @carol", graph.Snapshot{}, []string{"carol"}, 1, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			e.graph.snap = tt.snap
			p, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: tt.text})
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, m := range p.Mentions {
				got = append(got, m.Handle)
			}
			if !reflect.DeepEqual(got, tt.wantMentions) {
				t.Fatalf("mentions = %v, want %v", got, tt.wantMentions)
			}
			if e.graph.calls != tt.wantGraph || len(e.dir.resolved) != tt.wantResolve {
				t.Fatalf("graph reads=%d resolves=%d, want %d and %d", e.graph.calls, len(e.dir.resolved), tt.wantGraph, tt.wantResolve)
			}
		})
	}
}

func TestCreate_ElevenMentionsStoreTen(t *testing.T) {
	e := newCreateEnv()
	var parts []string
	for i := 0; i < 11; i++ {
		h := "user" + string(rune('a'+i))
		e.dir.handles[h] = "uid-" + h
		parts = append(parts, "@"+h)
	}
	p, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: strings.Join(parts, " ")})
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Mentions) != 10 || len(e.dir.resolved[0]) != 10 {
		t.Fatalf("stored %d mentions, resolved %d handles; want 10 and 10", len(p.Mentions), len(e.dir.resolved[0]))
	}
}

func TestCreate_FeatureDisabledBeforeAnythingElse(t *testing.T) {
	tests := []struct {
		name string
		in   CreateInput
		want string
	}{
		{"reply", CreateInput{ReplyToPostID: "x"}, "replies"},
		{"quote", CreateInput{QuoteOfPostID: "x"}, "quotes"},
		{"media", CreateInput{MediaIDs: []string{"m"}}, "media"},
		{"alt texts only", CreateInput{MediaAltTexts: []string{"a"}}, "media"},
		{"reply and media: replies first", CreateInput{ReplyToPostID: "x", MediaIDs: []string{"m"}, QuoteOfPostID: "y"}, "replies"},
		{"quote and media: quotes first", CreateInput{QuoteOfPostID: "y", MediaIDs: []string{"m"}}, "quotes"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			in := tt.in
			in.Text, in.IdempotencyKey = "", "bad" // invalid on purpose: the feature check must win
			_, c, err := e.create(in)
			ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if ae.Metadata["feature"] != tt.want || c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
				t.Fatalf("feature=%q reads=%d writes=%d", ae.Metadata["feature"], c.Reads(), c.Writes())
			}
		})
	}
}

func TestCreate_Validation(t *testing.T) {
	tests := []struct {
		name  string
		in    CreateInput
		field string
	}{
		{"short key", CreateInput{IdempotencyKey: "short", Text: "hi"}, "idempotency_key"},
		{"empty text", CreateInput{IdempotencyKey: key1, Text: "  "}, "text"},
		{"too long", CreateInput{IdempotencyKey: key1, Text: strings.Repeat("a", 281)}, "text"},
		{"bidi control", CreateInput{IdempotencyKey: key1, Text: "hi ‮"}, "text"},
		{"invisible only", CreateInput{IdempotencyKey: key1, Text: "​⁠"}, "text"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			_, c, err := e.create(tt.in)
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != tt.field || c.Reads() != 0 || e.repo.createCalls != 0 {
				t.Fatalf("field=%q reads=%d", ae.Metadata["field"], c.Reads())
			}
		})
	}
}

func TestCreate_EmailNotVerified(t *testing.T) {
	tests := []struct {
		name   string
		claims authn.Claims
		opts   []Option
		wantOK bool
	}{
		{"unverified password", authn.Claims{UID: testUID, SignInProvider: authn.SignInProviderPassword}, nil, false},
		{"verified password", authn.Claims{UID: testUID, SignInProvider: authn.SignInProviderPassword, EmailVerified: true}, nil, true},
		{"google", authn.Claims{UID: testUID, SignInProvider: authn.SignInProviderGoogle}, nil, true},
		{"anonymous by default", authn.Claims{UID: testUID, SignInProvider: authn.SignInProviderAnonymous}, nil, false},
		{"anonymous with the emulator option", authn.Claims{UID: testUID, SignInProvider: authn.SignInProviderAnonymous}, []Option{WithAllowAnonymous(true)}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv(tt.opts...)
			ctx, c := budget.WithCounter(authn.WithClaims(context.Background(), tt.claims))
			_, err := e.svc.Create(ctx, testUID, CreateInput{IdempotencyKey: key1, Text: "hi"})
			if tt.wantOK {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED)
			if c.Reads() != 0 {
				t.Fatalf("reads = %d, want 0", c.Reads())
			}
		})
	}
}

func TestCreate_NoProfile(t *testing.T) {
	e := newCreateEnv()
	delete(e.dir.profiles, testUID)
	_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi"})
	wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED)
}

func TestCreate_ReplayAndKeyReuse(t *testing.T) {
	e := newCreateEnv()
	first, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	// Replay with a warm posts cache: 1 read (the idempotency doc), 0 writes, no second event.
	again, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hello"})
	if err != nil || again.ID != first.ID || c.Reads() != 1 || c.Writes() != 0 {
		t.Fatalf("replay: id=%v err=%v reads=%d writes=%d", again, err, c.Reads(), c.Writes())
	}
	if len(e.events.created) != 1 || e.repo.postsCount != 1 {
		t.Fatalf("replay must not re-run effects: events=%d postsCount=%d", len(e.events.created), e.repo.postsCount)
	}
	// Normalisation first: the same text typed with CRLF/extra space hashes equal.
	if p, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "  hello  "}); err != nil || p.ID != first.ID {
		t.Fatalf("normalised replay: %v %v", p, err)
	}
	// Cold cache replay: 1 extra read for the post.
	e.cache = NewCache(time.Minute, 0, 0)
	e.svc.cache = e.cache
	_, c, err = e.create(CreateInput{IdempotencyKey: key1, Text: "hello"})
	if err != nil || c.Reads() != 2 {
		t.Fatalf("cold replay: err=%v reads=%d, want 2", err, c.Reads())
	}
	// A different body with the same key.
	_, c, err = e.create(CreateInput{IdempotencyKey: key1, Text: "different"})
	wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	if c.Writes() != 0 {
		t.Fatalf("reused key wrote %d docs", c.Writes())
	}
	// Another key is a new post.
	if p, _, err := e.create(CreateInput{IdempotencyKey: key2, Text: "hello"}); err != nil || p.ID == first.ID {
		t.Fatalf("new key: %v %v", p, err)
	}
}

func TestCreate_ReplayOfDeletedPost(t *testing.T) {
	e := newCreateEnv()
	p, _, _ := e.create(CreateInput{IdempotencyKey: key1, Text: "hello"})
	delete(e.repo.docs, p.ID)
	e.cache.DeletePost(p.ID)
	_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hello"})
	wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
}

func TestCreate_QuotaTiers(t *testing.T) {
	tests := []struct {
		name      string
		createdAt time.Duration // age of the account
		wantLimit int64
	}{
		{"established account", 72 * time.Hour, 100},
		{"under 24 h", 2 * time.Hour, 20},
		{"exactly at the window", 24 * time.Hour, 100},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			pr := e.dir.profiles[testUID]
			pr.CreatedAt = time.Unix(1_700_000_000, 0).Add(-tt.createdAt)
			e.dir.profiles[testUID] = pr
			if _, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi"}); err != nil {
				t.Fatal(err)
			}
			if e.repo.lastCreate.QuotaLimit != tt.wantLimit {
				t.Fatalf("limit = %d, want %d", e.repo.lastCreate.QuotaLimit, tt.wantLimit)
			}
		})
	}
}

func TestCreate_QuotaExceeded(t *testing.T) {
	e := newCreateEnv()
	e.repo.quotaUsed = 100
	_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi"})
	ae := wantAPIError(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
	if ae.Metadata["quota"] != "posts" || c.Writes() != 0 || len(e.events.created) != 0 || len(e.dir.forgotten) != 0 {
		t.Fatalf("meta=%v writes=%d events=%d forgotten=%v", ae.Metadata, c.Writes(), len(e.events.created), e.dir.forgotten)
	}
	e = newCreateEnv()
	pr := e.dir.profiles[testUID]
	pr.CreatedAt = time.Unix(1_700_000_000, 0).Add(-time.Hour)
	e.dir.profiles[testUID] = pr
	e.repo.quotaUsed = 20
	_, _, err = e.create(CreateInput{IdempotencyKey: key1, Text: "hi"})
	wantAPIError(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
}

func TestCreate_UnexpectedErrorIsNotAnAPIError(t *testing.T) {
	e := newCreateEnv()
	e.repo.createErr = errBoom
	_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "hi"})
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) || !errors.Is(err, errBoom) {
		t.Fatalf("err = %v, want a wrapped non-API error", err)
	}
	if len(e.events.created) != 0 {
		t.Fatal("no event on failure")
	}
}

func TestCreate_Budget(t *testing.T) {
	// Warm: author profile and handles cached -> 2 reads (idempotency + quotas), 4 writes.
	e := newCreateEnv()
	_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "no mentions"})
	if err != nil || c.Reads() > 2 || c.Writes() > 4 {
		t.Fatalf("warm: err=%v reads=%d writes=%d", err, c.Reads(), c.Writes())
	}
	// Cold ceiling: graph 1 + 10 handles + idempotency 1 + quotas 1 = 13 here (+1 interceptor = 14 documented).
	e = newCreateEnv()
	var parts []string
	for i := 0; i < 10; i++ {
		h := "user" + string(rune('a'+i))
		e.dir.handles[h] = "uid-" + h
		parts = append(parts, "@"+h)
	}
	_, c, err = e.create(CreateInput{IdempotencyKey: key1, Text: strings.Join(parts, " ")})
	if err != nil || c.Reads() > 13 || c.Writes() > 4 {
		t.Fatalf("cold: err=%v reads=%d writes=%d", err, c.Reads(), c.Writes())
	}
}

func TestWithAllowAnonymous_DefaultIsFalse(t *testing.T) {
	if New(Deps{}).(*service).allowAnonymous {
		t.Fatal("allowAnonymous must default to false")
	}
	if !New(Deps{}, WithAllowAnonymous(true)).(*service).allowAnonymous {
		t.Fatal("WithAllowAnonymous(true) must enable it")
	}
}
