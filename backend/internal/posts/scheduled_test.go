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

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

var (
	schedKey  = []byte("0123456789abcdef0123456789abcdef")
	schedNow  = time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	schedBase = time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC)
)

// schedKeyFor builds a valid idempotency key (16..64 of [A-Za-z0-9_-]).
func schedKeyFor(n int) string { return fmt.Sprintf("sched-key-%016d", n) }

// newSched returns a stored-shaped scheduled post of uid whose publishAt is base + n minutes.
func newSched(t *testing.T, uid string, n int, status ScheduledStatus) *ScheduledPost {
	t.Helper()
	id, err := ScheduledID(uid, schedKeyFor(n))
	if err != nil {
		t.Fatal(err)
	}
	p := &ScheduledPost{
		ID: id, UID: uid, SchemaVersion: ScheduledSchemaVersion, PublishAt: schedBase.Add(time.Duration(n) * time.Minute),
		Status: status, RequestHash: "h", CreatedAt: schedNow, UpdatedAt: schedNow,
	}
	if status == ScheduledPending || status == ScheduledFailed {
		p.Draft = &ScheduledDraft{Text: fmt.Sprintf("draft %d", n), Media: []MediaRef{{ID: "m1", AltText: "alt"}}, ReplyPolicy: ReplyPolicyFollowing, PaidPartnership: true}
	}
	return p
}

func TestScheduledID(t *testing.T) {
	a, err := ScheduledID("alice", schedKeyFor(1))
	if err != nil {
		t.Fatal(err)
	}
	if len(a) != 32 || !ValidScheduledID(a) {
		t.Fatalf("id = %q, want 32 lower-case hex characters", a)
	}
	if again, _ := ScheduledID("alice", schedKeyFor(1)); again != a {
		t.Errorf("not deterministic: %q != %q", again, a)
	}
	// It is the first 32 hex characters of SHA-256(uid|"SchedulePost"|key), and scoped by the RPC name.
	if want := idempotency.Key("alice", "SchedulePost", schedKeyFor(1))[:32]; a != want {
		t.Errorf("id = %q, want %q", a, want)
	}
	if other := idempotency.Key("alice", "CreatePost", schedKeyFor(1))[:32]; a == other {
		t.Error("the id must differ from the CreatePost idempotency key for the same uid and key")
	}

	// Distinct (uid, key) pairs never share an id, including pairs whose concatenations only differ at the separator.
	pairs := [][2]string{
		{"a", "bbbbbbbbbbbbbbbb"}, {"ab", "bbbbbbbbbbbbbbbb"}, {"a", "abbbbbbbbbbbbbbbb"}, {"b", "abbbbbbbbbbbbbbbb"},
		{"a-b", "cccccccccccccccc"}, {"a", "b-cccccccccccccccc"}, {"a", "b_cccccccccccccccc"}, {"A", "bbbbbbbbbbbbbbbb"},
	}
	seen := map[string][2]string{}
	for _, p := range pairs {
		id, err := ScheduledID(p[0], p[1])
		if err != nil {
			t.Fatalf("ScheduledID(%q, %q): %v", p[0], p[1], err)
		}
		if prev, dup := seen[id]; dup {
			t.Errorf("collision: %v and %v both map to %s", prev, p, id)
		}
		seen[id] = p
	}

	// The "|" separator can never appear in either part, because anything that could contain it is refused.
	for _, tt := range []struct{ name, uid, key string }{
		{"empty uid", "", schedKeyFor(1)},
		{"uid with the separator", "a|SchedulePost|b", schedKeyFor(1)},
		{"uid with a slash", "a/b", schedKeyFor(1)},
		{"uid with an underscore", "a_b", schedKeyFor(1)},
		{"key with the separator", "alice", "aaaaaaaa|bbbbbbbbbbbb"},
		{"key too short", "alice", "short"},
		{"key too long", "alice", strings.Repeat("k", 65)},
		{"key with a space", "alice", "aaaaaaaa bbbbbbbbbbbb"},
	} {
		if id, err := ScheduledID(tt.uid, tt.key); !errors.Is(err, ErrInvalidScheduledID) || id != "" {
			t.Errorf("%s: ScheduledID = %q, %v, want ErrInvalidScheduledID", tt.name, id, err)
		}
	}
}

func TestValidScheduledID(t *testing.T) {
	tests := []struct {
		id   string
		want bool
	}{
		{strings.Repeat("a", 32), true},
		{"0123456789abcdef0123456789abcdef", true},
		{"", false},
		{strings.Repeat("a", 31), false},
		{strings.Repeat("a", 33), false},
		{strings.Repeat("A", 32), false},
		{strings.Repeat("g", 32), false},
		{strings.Repeat("a", 31) + "/", false},
		{strings.Repeat("a", 31) + "_", false},
	}
	for _, tt := range tests {
		if got := ValidScheduledID(tt.id); got != tt.want {
			t.Errorf("ValidScheduledID(%q) = %v, want %v", tt.id, got, tt.want)
		}
	}
}

func TestScheduledPageToken(t *testing.T) {
	p := newSched(t, "alice", 1, ScheduledPending)
	tok := EncodeScheduledPageToken(schedKey, "alice", p, schedNow)
	if tok == "" {
		t.Fatal("empty token")
	}
	pos, err := DecodeScheduledPageToken(schedKey, "alice", tok, schedNow.Add(time.Hour))
	if err != nil || pos == nil || pos.ID != p.ID || !pos.CreatedAt.Equal(p.PublishAt) {
		t.Fatalf("round trip = %+v, %v, want %s at %v", pos, err, p.ID, p.PublishAt)
	}

	t.Run("empty token is the first page", func(t *testing.T) {
		pos, err := DecodeScheduledPageToken(schedKey, "alice", "", schedNow)
		if pos != nil || err != nil {
			t.Errorf("= %+v, %v, want nil, nil", pos, err)
		}
	})
	// A token issued to another uid opens nothing, even for a uid that differs only in case or by a prefix.
	for _, other := range []string{"bob", "Alice", "alic", "alice2", "alice|x"} {
		if _, err := DecodeScheduledPageToken(schedKey, other, tok, schedNow); !errors.Is(err, ErrInvalidScheduledToken) {
			t.Errorf("a token for alice opened for %q: err = %v", other, err)
		}
	}
	t.Run("a thread-bound token is not a scheduled token", func(t *testing.T) {
		foreign := cursor.EncodeAt(schedKey, threadBinding("alice", "0000000000000000001"), cursor.Cursor{CreatedAt: p.PublishAt, DocID: p.ID}, schedNow)
		if _, err := DecodeScheduledPageToken(schedKey, "alice", foreign, schedNow); !errors.Is(err, ErrInvalidScheduledToken) {
			t.Errorf("err = %v, want ErrInvalidScheduledToken", err)
		}
	})
	t.Run("wrong key, tampered, expired, garbage", func(t *testing.T) {
		if _, err := DecodeScheduledPageToken([]byte("another-key-another-key-another!"), "alice", tok, schedNow); !errors.Is(err, ErrInvalidScheduledToken) {
			t.Errorf("wrong key: %v", err)
		}
		if _, err := DecodeScheduledPageToken(schedKey, "alice", tok[:len(tok)-2]+"AA", schedNow); !errors.Is(err, ErrInvalidScheduledToken) {
			t.Errorf("tampered: %v", err)
		}
		if _, err := DecodeScheduledPageToken(schedKey, "alice", tok, schedNow.Add(25*time.Hour)); !errors.Is(err, ErrInvalidScheduledToken) {
			t.Errorf("expired: %v", err)
		}
		if _, err := DecodeScheduledPageToken(schedKey, "alice", "not-a-token", schedNow); !errors.Is(err, ErrInvalidScheduledToken) {
			t.Errorf("garbage: %v", err)
		}
	})
	t.Run("a sealed token whose id is not a scheduled id", func(t *testing.T) {
		bad := &ScheduledPost{ID: "../../users/bob", PublishAt: schedBase}
		if _, err := DecodeScheduledPageToken(schedKey, "alice", EncodeScheduledPageToken(schedKey, "alice", bad, schedNow), schedNow); !errors.Is(err, ErrInvalidScheduledToken) {
			t.Errorf("err = %v, want ErrInvalidScheduledToken", err)
		}
	})
}

func TestScheduledPageSize(t *testing.T) {
	for in, want := range map[int]int{-5: 20, 0: 20, 1: 1, 20: 20, 50: 50, 51: 50, 5000: 50} {
		if got := ScheduledPageSize(in); got != want {
			t.Errorf("ScheduledPageSize(%d) = %d, want %d", in, got, want)
		}
	}
}

// TestListScheduledPage: PENDING and FAILED items page in publishAt order, other statuses never appear, the cursor is
// bound to the caller, a short page has no next token, and every page costs one read per item.
func TestListScheduledPage(t *testing.T) {
	var all []*ScheduledPost
	for n := 0; n < 5; n++ {
		st := ScheduledPending
		if n%2 == 1 {
			st = ScheduledFailed
		}
		all = append(all, newSched(t, "alice", n, st))
	}
	all = append(all, newSched(t, "alice", 9, ScheduledPublished), newSched(t, "alice", 10, ScheduledCancelled), newSched(t, "bob", 0, ScheduledPending))
	repo := newFakeScheduledStore(all...)

	ctx, c := budget.WithCounter(context.Background())
	var got []string
	token := ""
	pages := 0
	for {
		page, err := ListScheduledPage(ctx, repo, schedKey, "alice", 2, token, schedNow)
		if err != nil {
			t.Fatal(err)
		}
		pages++
		for _, p := range page.Items {
			got = append(got, p.ID)
			if p.UID != "alice" {
				t.Errorf("another user's item %s leaked into the list", p.ID)
			}
		}
		if page.NextPageToken == "" {
			break
		}
		token = page.NextPageToken
	}
	if len(got) != 5 || pages != 3 {
		t.Fatalf("got %d items over %d pages, want 5 over 3", len(got), pages)
	}
	for i, id := range got {
		if id != all[i].ID {
			t.Errorf("item %d = %s, want %s (publishAt order)", i, id, all[i].ID)
		}
	}
	if c.Reads() != 5 { // 2 + 2 + 1 documents: the last page was short, so no empty page follows
		t.Errorf("reads = %d, want 5 (one per returned item)", c.Reads())
	}

	t.Run("an exactly full last page yields a token whose page is empty and costs 1 read", func(t *testing.T) {
		ctx, c := budget.WithCounter(context.Background())
		first, err := ListScheduledPage(ctx, repo, schedKey, "alice", 5, "", schedNow)
		if err != nil || len(first.Items) != 5 || first.NextPageToken == "" {
			t.Fatalf("first = %d items token=%q err=%v", len(first.Items), first.NextPageToken, err)
		}
		second, err := ListScheduledPage(ctx, repo, schedKey, "alice", 5, first.NextPageToken, schedNow)
		if err != nil || len(second.Items) != 0 || second.NextPageToken != "" {
			t.Fatalf("second = %d items token=%q err=%v", len(second.Items), second.NextPageToken, err)
		}
		if c.Reads() != 5+1 {
			t.Errorf("reads = %d, want 6", c.Reads())
		}
	})

	t.Run("a cursor from another uid is rejected before any read", func(t *testing.T) {
		bobPage, err := ListScheduledPage(context.Background(), repo, schedKey, "bob", 1, "", schedNow)
		if err != nil || len(bobPage.Items) != 1 {
			t.Fatal(err)
		}
		alicePage, err := ListScheduledPage(context.Background(), repo, schedKey, "alice", 1, "", schedNow)
		if err != nil || alicePage.NextPageToken == "" {
			t.Fatal(err)
		}
		before := repo.calls
		if _, err := ListScheduledPage(context.Background(), repo, schedKey, "bob", 1, alicePage.NextPageToken, schedNow); !errors.Is(err, ErrInvalidScheduledToken) {
			t.Errorf("err = %v, want ErrInvalidScheduledToken", err)
		}
		if repo.calls != before {
			t.Error("a foreign token reached the repository")
		}
	})

	t.Run("page size clamps to 50 and defaults to 20", func(t *testing.T) {
		var many []*ScheduledPost
		for n := 0; n < 60; n++ {
			many = append(many, newSched(t, "carol", n, ScheduledPending))
		}
		r := newFakeScheduledStore(many...)
		def, _ := ListScheduledPage(context.Background(), r, schedKey, "carol", 0, "", schedNow)
		big, _ := ListScheduledPage(context.Background(), r, schedKey, "carol", 500, "", schedNow)
		if len(def.Items) != 20 || len(big.Items) != 50 {
			t.Errorf("default page %d, clamped page %d, want 20 and 50", len(def.Items), len(big.Items))
		}
	})

	t.Run("repository errors are wrapped", func(t *testing.T) {
		boom := errors.New("boom")
		r := newFakeScheduledStore()
		r.err = boom
		if _, err := ListScheduledPage(context.Background(), r, schedKey, "alice", 1, "", schedNow); !errors.Is(err, boom) {
			t.Errorf("err = %v, want it to wrap boom", err)
		}
	})
}

func TestScheduledTransition(t *testing.T) {
	const ttl = 168 * time.Hour
	now := schedNow
	wantExpire := now.Add(ttl)
	tests := []struct {
		name      string
		tr        ScheduledTransition
		from      ScheduledStatus
		wantErr   bool
		wantDraft bool // the draft survives the transition
		wantPost  string
		wantFail  ScheduledFailure
	}{
		{"published clears the draft", ScheduledTransition{To: ScheduledPublished, PostID: "1234567890123456789"}, ScheduledPending, false, false, "1234567890123456789", ""},
		{"cancelled clears the draft", ScheduledTransition{To: ScheduledCancelled}, ScheduledPending, false, false, "", ""},
		{"dismissing a failed item clears the draft", ScheduledTransition{To: ScheduledCancelled}, ScheduledFailed, false, false, "", ""},
		{"failed keeps the draft for reschedule", ScheduledTransition{To: ScheduledFailed, Failure: FailureMediaUnavailable}, ScheduledPending, false, true, "", FailureMediaUnavailable},
		{"published needs a post id", ScheduledTransition{To: ScheduledPublished}, ScheduledPending, true, false, "", ""},
		{"failed needs a reason", ScheduledTransition{To: ScheduledFailed}, ScheduledPending, true, false, "", ""},
		{"failed needs a known reason", ScheduledTransition{To: ScheduledFailed, Failure: "WEIRD"}, ScheduledPending, true, false, "", ""},
		{"pending is not a target", ScheduledTransition{To: ScheduledPending}, ScheduledFailed, true, false, "", ""},
		{"unknown target", ScheduledTransition{To: "ARCHIVED"}, ScheduledPending, true, false, "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ups, err := tt.tr.updates(now, ttl)
			if tt.wantErr {
				if err == nil || !errors.Is(err, errScheduledTransition) {
					t.Fatalf("err = %v, want errScheduledTransition", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			byPath := map[string]any{}
			for _, u := range ups {
				byPath[u.Path] = u.Value
			}
			if byPath["status"] != string(tt.tr.To) || byPath["expireAt"] != wantExpire || byPath["updatedAt"] != now {
				t.Errorf("updates = %v, want status %s, expireAt %v, updatedAt %v", byPath, tt.tr.To, wantExpire, now)
			}
			// Never a whole-document write: every path is a plain field, and the draft is deleted, not blanked.
			for path := range byPath {
				if path == "" || strings.Contains(path, ".") {
					t.Errorf("unexpected update path %q", path)
				}
			}
			v, has := byPath["draft"]
			if has == tt.wantDraft || (has && v != firestore.Delete) {
				t.Errorf("draft update = %v (present %v), want the draft cleared with firestore.Delete exactly when it must go", v, has)
			}
			for _, forbidden := range []string{"requestHash", "publishAt", "createdAt", "schemaVersion", "attempts"} {
				if _, has := byPath[forbidden]; has {
					t.Errorf("a transition must not touch %s", forbidden)
				}
			}

			// apply mirrors the updates on the in-memory copy.
			p := newSched(t, "alice", 1, tt.from)
			p.UpdatedAt = now.Add(-time.Hour)
			tt.tr.apply(p, now, ttl)
			if p.Status != tt.tr.To || p.PostID != tt.wantPost || p.Failure != tt.wantFail || (p.Draft != nil) != tt.wantDraft ||
				p.ExpireAt == nil || !p.ExpireAt.Equal(wantExpire) || !p.UpdatedAt.Equal(now) {
				t.Errorf("applied = %+v, want status %s post %q failure %q draft kept %v", p, tt.tr.To, tt.wantPost, tt.wantFail, tt.wantDraft)
			}
		})
	}
	if _, err := (ScheduledTransition{To: ScheduledCancelled}).updates(now, 0); !errors.Is(err, errScheduledTransition) {
		t.Errorf("a zero TTL must be refused, got %v", err)
	}
}

func TestScheduledPathShape(t *testing.T) {
	c := &firestore.Client{}
	hex := strings.Repeat("ab", 16)
	tests := []struct {
		name    string
		ref     *firestore.DocumentRef
		wantUID string
		wantOK  bool
	}{
		{"the real shape", c.Doc("users/alice/scheduled/" + hex), "alice", true},
		{"uid with a dash", c.Doc("users/a-b/scheduled/" + hex), "a-b", true},
		{"another top-level collection", c.Doc("other/alice/scheduled/" + hex), "", false},
		{"nested one level deeper", c.Doc("users/alice/x/y/scheduled/" + hex), "", false},
		{"under a scheduled doc", c.Doc("users/alice/scheduled/" + hex + "/scheduled/" + hex), "", false},
		{"another subcollection name", c.Doc("users/alice/notifications/" + hex), "", false},
		{"the top-level scheduled collection", c.Doc("scheduled/" + hex), "", false},
		{"id not hex", c.Doc("users/alice/scheduled/not-a-scheduled-id"), "", false},
		{"id upper-case", c.Doc("users/alice/scheduled/" + strings.ToUpper(hex)), "", false},
		{"uid with an underscore", c.Doc("users/a_b/scheduled/" + hex), "", false},
		{"nil", nil, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			uid, id, ok := scheduledPathShape(tt.ref)
			if ok != tt.wantOK || uid != tt.wantUID || (ok && id != hex) {
				t.Errorf("scheduledPathShape = %q, %q, %v, want uid %q ok %v", uid, id, ok, tt.wantUID, tt.wantOK)
			}
		})
	}
}

// TestScheduledDocRoundTrip: the stored shape keeps a draft only when there is one and an expireAt only when set.
func TestScheduledDocRoundTrip(t *testing.T) {
	p := newSched(t, "alice", 3, ScheduledPending)
	d := toScheduledDoc(p)
	if d.Draft == nil || d.Draft.Text != "draft 3" || d.ExpireAt != nil || d.Status != "PENDING" || d.SchemaVersion != 1 {
		t.Fatalf("doc = %+v", d)
	}
	back := d.toScheduledPost("alice", p.ID, schedNow)
	if back.Draft == nil || back.Draft.Text != "draft 3" || back.Draft.ReplyPolicy != ReplyPolicyFollowing || !back.Draft.PaidPartnership ||
		len(back.Draft.Media) != 1 || back.Draft.Media[0].AltText != "alt" || back.ExpireAt != nil || !back.PublishAt.Equal(p.PublishAt) {
		t.Errorf("round trip = %+v / draft %+v", back, back.Draft)
	}
	done := newSched(t, "alice", 4, ScheduledCancelled)
	exp := schedNow.Add(time.Hour)
	done.ExpireAt = &exp
	dd := toScheduledDoc(done)
	if dd.Draft != nil || dd.ExpireAt == nil {
		t.Errorf("terminal doc = %+v, want no draft and an expireAt", dd)
	}
	if got := dd.toScheduledPost("alice", done.ID, schedNow); got.Draft != nil || got.ExpireAt == nil || !got.ExpireAt.Equal(exp) {
		t.Errorf("terminal round trip = %+v", got)
	}
}

func TestScheduledEraser(t *testing.T) {
	ctx, c := budget.WithCounter(context.Background())
	var docs []*ScheduledPost
	for n := 0; n < opsPage+3; n++ {
		docs = append(docs, newSched(t, "alice", n, ScheduledPending))
	}
	docs = append(docs, newSched(t, "bob", 0, ScheduledPending))
	repo := newFakeScheduledStore(docs...)
	e := NewScheduledEraser(repo)

	cp, done, err := e.PurgeUser(ctx, "alice", ScheduledCheckpoint{})
	if err != nil || done || cp.Deleted != opsPage {
		t.Fatalf("first page = %+v done=%v err=%v, want 500 deleted and not done", cp, done, err)
	}
	cp, done, err = e.PurgeUser(ctx, "alice", cp)
	if err != nil || !done || cp.Deleted != opsPage+3 {
		t.Fatalf("second page = %+v done=%v err=%v, want %d deleted and done", cp, done, err, opsPage+3)
	}
	if len(repo.docs["alice"]) != 0 || len(repo.docs["bob"]) != 1 {
		t.Errorf("alice has %d docs left, bob %d: only the owner's documents may go", len(repo.docs["alice"]), len(repo.docs["bob"]))
	}
	if c.Deletes() != opsPage+3 {
		t.Errorf("deletes = %d, want %d", c.Deletes(), opsPage+3)
	}

	t.Run("an account that never scheduled is done after one call", func(t *testing.T) {
		cp, done, err := e.PurgeUser(context.Background(), "carol", ScheduledCheckpoint{})
		if err != nil || !done || cp.Deleted != 0 {
			t.Errorf("= %+v %v %v", cp, done, err)
		}
	})
	t.Run("an error keeps the checkpoint and is not done", func(t *testing.T) {
		boom := errors.New("boom")
		repo.err = boom
		in := ScheduledCheckpoint{Deleted: 7}
		cp, done, err := e.PurgeUser(context.Background(), "alice", in)
		if !errors.Is(err, boom) || done || cp != in {
			t.Errorf("= %+v %v %v", cp, done, err)
		}
	})
}

func TestScheduledExporter(t *testing.T) {
	pending := newSched(t, "alice", 1, ScheduledPending)
	failed := newSched(t, "alice", 2, ScheduledFailed)
	failed.Failure = FailureExpired
	published := newSched(t, "alice", 3, ScheduledPublished)
	published.PostID = "1234567890123456789"
	cancelled := newSched(t, "alice", 4, ScheduledCancelled)
	other := newSched(t, "bob", 1, ScheduledPending)

	export := func(t *testing.T, repo *fakeScheduledStore, uid string) (map[string]any, string) {
		t.Helper()
		var buf bytes.Buffer
		if err := NewScheduledExporter(repo).ExportUser(context.Background(), uid, &buf); err != nil {
			t.Fatal(err)
		}
		var v map[string]any
		if err := json.Unmarshal(buf.Bytes(), &v); err != nil {
			t.Fatalf("not JSON: %v\n%s", err, buf.String())
		}
		return v, buf.String()
	}

	v, raw := export(t, newFakeScheduledStore(pending, failed, published, cancelled, other), "alice")
	items, _ := v["scheduled"].([]any)
	if v["userId"] != "alice" || len(items) != 4 {
		t.Fatalf("export = %s", raw)
	}
	byID := map[string]map[string]any{}
	for _, it := range items {
		m := it.(map[string]any)
		byID[m["id"].(string)] = m
	}
	for _, p := range []*ScheduledPost{pending, failed} {
		d, _ := byID[p.ID]["draft"].(map[string]any)
		if d == nil || !strings.HasPrefix(d["text"].(string), "draft ") || d["replyPolicy"] != "FOLLOWING" || d["paidPartnership"] != true {
			t.Errorf("%s export has no draft: %v", p.Status, byID[p.ID])
			continue
		}
		media, _ := d["media"].([]any)
		if len(media) != 1 || media[0].(map[string]any)["altText"] != "alt" {
			t.Errorf("draft media = %v", d["media"])
		}
	}
	if byID[failed.ID]["failure"] != "EXPIRED" {
		t.Errorf("failed item = %v", byID[failed.ID])
	}
	for _, p := range []*ScheduledPost{published, cancelled} {
		if _, has := byID[p.ID]["draft"]; has {
			t.Errorf("%s export carries a draft that the document no longer holds: %v", p.Status, byID[p.ID])
		}
	}
	if byID[published.ID]["postId"] != published.PostID {
		t.Errorf("published item = %v", byID[published.ID])
	}
	for _, secret := range []string{"requestHash", "attempts", "bob"} {
		if strings.Contains(raw, secret) {
			t.Errorf("the export leaks %q: %s", secret, raw)
		}
	}
	// Every listed item keeps the stored order: publishAt ascending.
	for i := 1; i < len(items); i++ {
		if items[i-1].(map[string]any)["publishAt"].(string) > items[i].(map[string]any)["publishAt"].(string) {
			t.Errorf("items out of order: %s", raw)
		}
	}

	t.Run("an empty account still exports a valid empty section", func(t *testing.T) {
		v, raw := export(t, newFakeScheduledStore(), "carol")
		if items, ok := v["scheduled"].([]any); !ok || len(items) != 0 || v["userId"] != "carol" {
			t.Errorf("export = %s", raw)
		}
	})
	t.Run("more than one page", func(t *testing.T) {
		var docs []*ScheduledPost
		for n := 0; n < opsPage+2; n++ {
			docs = append(docs, newSched(t, "dave", n, ScheduledPending))
		}
		ctx, c := budget.WithCounter(context.Background())
		var buf bytes.Buffer
		if err := NewScheduledExporter(newFakeScheduledStore(docs...)).ExportUser(ctx, "dave", &buf); err != nil {
			t.Fatal(err)
		}
		var v struct {
			Scheduled []map[string]any `json:"scheduled"`
		}
		if err := json.Unmarshal(buf.Bytes(), &v); err != nil || len(v.Scheduled) != opsPage+2 {
			t.Fatalf("exported %d items, err %v, want %d", len(v.Scheduled), err, opsPage+2)
		}
		if c.Reads() != opsPage+2 {
			t.Errorf("reads = %d, want one per document (%d)", c.Reads(), opsPage+2)
		}
	})
	t.Run("a repository error aborts the export", func(t *testing.T) {
		boom := errors.New("boom")
		r := newFakeScheduledStore()
		r.err = boom
		if err := NewScheduledExporter(r).ExportUser(context.Background(), "alice", &bytes.Buffer{}); !errors.Is(err, boom) {
			t.Errorf("err = %v", err)
		}
	})
}

func TestScheduledStatusAndFailureValid(t *testing.T) {
	for _, s := range []ScheduledStatus{ScheduledPending, ScheduledPublished, ScheduledCancelled, ScheduledFailed} {
		if !s.Valid() {
			t.Errorf("%s should be valid", s)
		}
	}
	if ScheduledStatus("").Valid() || ScheduledStatus("pending").Valid() {
		t.Error("an empty or lower-case status must not be valid")
	}
	for _, f := range []ScheduledFailure{FailureMediaUnavailable, FailureQuotaExceeded, FailureAccountRestricted, FailureInvalidContent, FailureExpired, FailureInternal, FailureUnsupported} {
		if !f.Valid() {
			t.Errorf("%s should be valid", f)
		}
	}
	if ScheduledFailure("").Valid() || ScheduledFailure("OTHER").Valid() {
		t.Error("an empty or unknown failure must not be valid")
	}
}
