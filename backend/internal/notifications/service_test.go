package notifications

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

var testKey = []byte("0123456789abcdef0123456789abcdef")

const goodKey = "0123456789abcdef"

func newService(repo *fakeRepo, dir *fakeDirectory, seen *fakeSeen, now func() time.Time) Service {
	return newServiceWithSocial(repo, dir, seen, now, &fakeSocial{})
}

func newServiceWithSocial(repo *fakeRepo, dir *fakeDirectory, seen *fakeSeen, now func() time.Time, social Social) Service {
	return NewService(Deps{Repo: repo, Directory: dir, Social: social, Seen: seen, CursorKey: testKey, Now: now})
}

func seedRows(repo *fakeRepo, uid string, n int, start time.Time) {
	repo.rows[uid] = map[string]Notification{}
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("follow_u%03d", i)
		repo.rows[uid][id] = Notification{ID: id, Type: TypeFollow, CreatedAt: start.Add(time.Duration(i) * time.Minute), ActorIDs: []string{"u"}}
	}
}

func idsOf(ns []Notification) []string {
	out := make([]string, len(ns))
	for i, n := range ns {
		out[i] = n.ID
	}
	return out
}

func connectCode(err error) connect.Code {
	if err == nil {
		return 0
	}
	return apierr.ToConnect(err).Code()
}

func TestList_ColdOpenPagesAndRefresh(t *testing.T) {
	repo := newFakeRepo()
	dir := newDirectory("me")
	dir.seenAt = t0.Add(-time.Hour)
	seedRows(repo, "me", 7, t0.Add(-time.Hour))
	clock := t0
	svc := newService(repo, dir, &fakeSeen{}, func() time.Time { return clock })
	ctx := context.Background()

	// Cold open: newest first, a next page token because the page is full, and a since token.
	p1, err := svc.List(ctx, "me", ListInput{PageSize: 3})
	mustNoErr(t, err)
	if got, want := idsOf(p1.Notifications), []string{"follow_u006", "follow_u005", "follow_u004"}; strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("page 1 = %v, want %v", got, want)
	}
	if p1.NextPageToken == "" || p1.SinceToken == "" || p1.GapPageToken != "" {
		t.Fatalf("tokens = %+v", p1)
	}
	if !p1.SeenAt.Equal(dir.seenAt) {
		t.Errorf("seen_at = %v", p1.SeenAt)
	}
	if repo.lastList.Limit != 3 {
		t.Errorf("query limit = %d", repo.lastList.Limit)
	}

	// Scroll: strictly older rows, no overlap, and the last page has no token.
	p2, err := svc.List(ctx, "me", ListInput{PageSize: 3, PageToken: p1.NextPageToken})
	mustNoErr(t, err)
	if got := idsOf(p2.Notifications); strings.Join(got, ",") != "follow_u003,follow_u002,follow_u001" {
		t.Fatalf("page 2 = %v", got)
	}
	p3, err := svc.List(ctx, "me", ListInput{PageSize: 3, PageToken: p2.NextPageToken})
	mustNoErr(t, err)
	if got := idsOf(p3.Notifications); strings.Join(got, ",") != "follow_u000" || p3.NextPageToken != "" {
		t.Fatalf("page 3 = %v next=%q", got, p3.NextPageToken)
	}

	// Refresh with nothing new: 0 rows, the since token stays usable.
	clock = clock.Add(time.Minute)
	r0, err := svc.List(ctx, "me", ListInput{PageSize: 3, SinceToken: p1.SinceToken})
	mustNoErr(t, err)
	// The since token trails the newest row by the settle window, so the newest row itself is re-delivered
	// (the client dedupes by id) but nothing older is.
	if got := idsOf(r0.Notifications); len(got) != 1 || got[0] != "follow_u006" {
		t.Fatalf("refresh with nothing new = %v", got)
	}
	if r0.SinceToken == "" {
		t.Error("refresh must return a since token")
	}

	// Refresh after 5 new rows with a page of 3: newest 3, a gap token for the older ones.
	for i := 10; i < 15; i++ {
		id := fmt.Sprintf("follow_u%03d", i)
		repo.rows["me"][id] = Notification{ID: id, Type: TypeFollow, CreatedAt: t0.Add(time.Duration(i) * time.Second), ActorIDs: []string{"u"}}
	}
	r1, err := svc.List(ctx, "me", ListInput{PageSize: 3, SinceToken: p1.SinceToken})
	mustNoErr(t, err)
	if got := idsOf(r1.Notifications); strings.Join(got, ",") != "follow_u014,follow_u013,follow_u012" {
		t.Fatalf("refresh = %v", got)
	}
	if r1.GapPageToken == "" || r1.NextPageToken != "" {
		t.Fatalf("refresh tokens = %+v", r1)
	}
	gap, err := svc.List(ctx, "me", ListInput{PageSize: 3, PageToken: r1.GapPageToken})
	mustNoErr(t, err)
	if got := idsOf(gap.Notifications); strings.Join(got, ",") != "follow_u011,follow_u010,follow_u006" {
		t.Fatalf("gap fill = %v", got)
	}
}

func TestList_Validation(t *testing.T) {
	repo := newFakeRepo()
	seedRows(repo, "me", 2, t0)
	clock := t0
	svc := newService(repo, newDirectory("me", "you"), &fakeSeen{}, func() time.Time { return clock })
	ctx := context.Background()
	first, err := svc.List(ctx, "me", ListInput{PageSize: 1})
	mustNoErr(t, err)

	tests := []struct {
		name string
		uid  string
		in   ListInput
	}{
		{"both tokens", "me", ListInput{PageToken: first.NextPageToken, SinceToken: first.SinceToken}},
		{"garbage page token", "me", ListInput{PageToken: "nope"}},
		{"garbage since token", "me", ListInput{SinceToken: "nope"}},
		{"a since token is not a page token", "me", ListInput{PageToken: first.SinceToken}},
		{"a page token is not a since token", "me", ListInput{SinceToken: first.NextPageToken}},
		{"another user's page token", "you", ListInput{PageToken: first.NextPageToken}},
		{"another user's since token", "you", ListInput{SinceToken: first.SinceToken}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo.lastList = ListQuery{}
			_, err := svc.List(ctx, tt.uid, tt.in)
			if connectCode(err) != connect.CodeInvalidArgument {
				t.Fatalf("err = %v, want INVALID_ARGUMENT", err)
			}
			if repo.lastList.Limit != 0 {
				t.Error("a rejected token must cost 0 reads")
			}
		})
	}

	t.Run("an expired token", func(t *testing.T) {
		clock = t0.Add(RefreshTokenTTL + time.Hour)
		defer func() { clock = t0 }()
		_, err := svc.List(ctx, "me", ListInput{SinceToken: first.SinceToken})
		if connectCode(err) != connect.CodeInvalidArgument {
			t.Fatalf("err = %v", err)
		}
	})
}

func TestList_PageSizeClamp(t *testing.T) {
	tests := []struct {
		in   int32
		want int
	}{{0, 20}, {-5, 20}, {1, 1}, {20, 20}, {50, 50}, {51, 50}, {1000, 50}}
	for _, tt := range tests {
		if got := clampPageSize(tt.in); got != tt.want {
			t.Errorf("clampPageSize(%d) = %d, want %d", tt.in, got, tt.want)
		}
	}
}

func TestList_RepoErrorIsRedacted(t *testing.T) {
	repo := newFakeRepo()
	repo.listErr = fmt.Errorf("query for uid-secret-123 failed: %w", errBoom)
	svc := newService(repo, newDirectory("uid-secret-123"), &fakeSeen{}, nil)
	_, err := svc.List(context.Background(), "uid-secret-123", ListInput{})
	if err == nil || strings.Contains(err.Error(), "uid-secret-123") {
		t.Fatalf("err = %v (must not carry the raw uid)", err)
	}
}

func TestMarkSeen(t *testing.T) {
	t.Run("writes seenAt and evicts the profile cache", func(t *testing.T) {
		seen, dir := &fakeSeen{}, newDirectory("me")
		svc := newService(newFakeRepo(), dir, seen, func() time.Time { return t0 })
		at, err := svc.MarkSeen(context.Background(), "me", goodKey)
		mustNoErr(t, err)
		if seen.uid != "me" || !seen.at.Equal(t0) || !at.Equal(t0) {
			t.Errorf("seen = %+v, at = %v", seen, at)
		}
		if len(dir.forgotten) != 1 || dir.forgotten[0] != "me" {
			t.Errorf("forgotten = %v", dir.forgotten)
		}
	})
	t.Run("bad key", func(t *testing.T) {
		svc := newService(newFakeRepo(), newDirectory(), &fakeSeen{}, nil)
		if _, err := svc.MarkSeen(context.Background(), "me", "short"); connectCode(err) != connect.CodeInvalidArgument {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("no profile", func(t *testing.T) {
		svc := newService(newFakeRepo(), newDirectory(), &fakeSeen{err: identity.ErrNotFound}, nil)
		if _, err := svc.MarkSeen(context.Background(), "me", goodKey); connectCode(err) != connect.CodeFailedPrecondition {
			t.Errorf("err = %v", err)
		}
	})
	t.Run("storage error", func(t *testing.T) {
		dir := newDirectory()
		svc := newService(newFakeRepo(), dir, &fakeSeen{err: errBoom}, nil)
		if _, err := svc.MarkSeen(context.Background(), "me", goodKey); connectCode(err) != connect.CodeInternal {
			t.Errorf("err = %v, want INTERNAL", err)
		}
		if len(dir.forgotten) != 0 {
			t.Error("a failed write must not evict the cache")
		}
	})
}

func TestRegisterDevice(t *testing.T) {
	good := DeviceInput{IdempotencyKey: goodKey, DeviceID: "device-0123456789", Token: "fcm:APA91bH-token", Platform: PlatformAndroid}
	tests := []struct {
		name    string
		mut     func(*DeviceInput)
		wantBad string
	}{
		{"ok", func(*DeviceInput) {}, ""},
		{"bad key", func(d *DeviceInput) { d.IdempotencyKey = "x" }, "idempotency_key"},
		{"short device id", func(d *DeviceInput) { d.DeviceID = "short" }, "device_id"},
		{"device id with a slash", func(d *DeviceInput) { d.DeviceID = "device/0123456789a" }, "device_id"},
		{"empty token", func(d *DeviceInput) { d.Token = "" }, "fcm_token"},
		{"huge token", func(d *DeviceInput) { d.Token = strings.Repeat("a", MaxFCMTokenBytes+1) }, "fcm_token"},
		{"token with whitespace", func(d *DeviceInput) { d.Token = "a b" }, "fcm_token"},
		{"token with a control char", func(d *DeviceInput) { d.Token = "a\x00b" }, "fcm_token"},
		{"web platform is out of scope", func(d *DeviceInput) { d.Platform = "web" }, "platform"},
		{"unspecified platform", func(d *DeviceInput) { d.Platform = "" }, "platform"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			svc := newService(repo, newDirectory(), &fakeSeen{}, nil)
			in := good
			tt.mut(&in)
			err := svc.RegisterDevice(context.Background(), "me", in)
			if tt.wantBad == "" {
				mustNoErr(t, err)
				if len(repo.devices["me"]) != 1 || repo.devices["me"][0].Token != good.Token {
					t.Errorf("devices = %+v", repo.devices)
				}
				return
			}
			if connectCode(err) != connect.CodeInvalidArgument {
				t.Fatalf("err = %v", err)
			}
			if strings.Contains(err.Error(), good.Token) || len(repo.devices["me"]) != 0 {
				t.Errorf("err leaks the token or a device was written: %v", err)
			}
		})
	}
}

func TestUnregisterDevice(t *testing.T) {
	repo := newFakeRepo()
	repo.devices["me"] = []Device{{ID: "device-0123456789", Token: "t"}}
	svc := newService(repo, newDirectory(), &fakeSeen{}, nil)
	ctx := context.Background()
	if err := svc.UnregisterDevice(ctx, "me", "x", "device-0123456789"); connectCode(err) != connect.CodeInvalidArgument {
		t.Errorf("bad key: %v", err)
	}
	if err := svc.UnregisterDevice(ctx, "me", goodKey, "no"); connectCode(err) != connect.CodeInvalidArgument {
		t.Errorf("bad id: %v", err)
	}
	mustNoErr(t, svc.UnregisterDevice(ctx, "me", goodKey, "device-0123456789"))
	if len(repo.devices["me"]) != 0 || repo.removed[0] != "me/device-0123456789/" {
		t.Errorf("devices = %+v removed = %v", repo.devices, repo.removed)
	}
}

func TestList_HidesSuppressedActorsAtReadTime(t *testing.T) {
	t.Parallel()
	row := func(id, actor string, at time.Time, ids ...string) Notification {
		return Notification{ID: id, Type: TypeLike, Actor: Actor{UserID: actor}, ActorIDs: ids, ActorCount: len(ids), CreatedAt: at}
	}
	repo := newFakeRepo()
	repo.rows["me"] = map[string]Notification{
		"a": row("a", "blocked", t0.Add(5*time.Minute), "blocked"),
		"b": row("b", "muted", t0.Add(4*time.Minute), "muted"),
		"c": row("c", "blockedby", t0.Add(3*time.Minute), "blockedby"),
		"d": row("d", "friend", t0.Add(2*time.Minute), "friend"),
		// a collapsed row: the displayed actor is fine, one other actor is blocked: count drops by one
		"e": row("e", "friend", t0.Add(time.Minute), "blocked", "x", "friend"),
	}
	social := &fakeSocial{snaps: map[string]graphSnap{"me": {
		Blocked: map[string]bool{"blocked": true}, Muted: map[string]bool{"muted": true}, BlockedBy: map[string]bool{"blockedby": true},
	}}}
	svc := newServiceWithSocial(repo, newDirectory("me"), &fakeSeen{}, func() time.Time { return t0.Add(time.Hour) }, social)
	res, err := svc.List(context.Background(), "me", ListInput{PageSize: 5})
	mustNoErr(t, err)
	if got := strings.Join(idsOf(res.Notifications), ","); got != "d,e" {
		t.Fatalf("rows = %s, want d,e", got)
	}
	if res.Notifications[1].ActorCount != 2 {
		t.Errorf("collapsed count = %d, want 2", res.Notifications[1].ActorCount)
	}
	// The page was full (5 raw rows scanned, 2 shown): paging must continue from the raw oldest row, and the
	// since token must come from the raw newest row, not from the filtered slice.
	if res.NextPageToken == "" {
		t.Error("a full raw page must keep next_page_token even when most rows were filtered")
	}
	if res.SinceToken == "" {
		t.Error("since token missing")
	}
	// A refresh from that token starts at the raw newest row ("a", hidden), so it is not re-read forever.
	again, err := svc.List(context.Background(), "me", ListInput{PageSize: 5, SinceToken: res.SinceToken})
	mustNoErr(t, err)
	// The since token trails the raw newest row ("a", hidden) by the settle window; "a" is the only row at or
	// after it, and it is filtered, so the refresh shows nothing.
	if len(again.Notifications) != 0 {
		t.Errorf("refresh = %v, want no visible rows", idsOf(again.Notifications))
	}
}

func TestList_AllFilteredStillPages(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.rows["me"] = map[string]Notification{}
	for i := 0; i < 3; i++ {
		id := fmt.Sprintf("r%d", i)
		repo.rows["me"][id] = Notification{ID: id, Type: TypeFollow, Actor: Actor{UserID: "blocked"}, ActorIDs: []string{"blocked"}, CreatedAt: t0.Add(time.Duration(i) * time.Minute)}
	}
	repo.rows["me"]["old"] = Notification{ID: "old", Type: TypeFollow, Actor: Actor{UserID: "friend"}, ActorIDs: []string{"friend"}, CreatedAt: t0.Add(-time.Hour)}
	social := &fakeSocial{snaps: map[string]graphSnap{"me": {Blocked: map[string]bool{"blocked": true}}}}
	svc := newServiceWithSocial(repo, newDirectory("me"), &fakeSeen{}, func() time.Time { return t0.Add(time.Hour) }, social)
	p1, err := svc.List(context.Background(), "me", ListInput{PageSize: 3})
	mustNoErr(t, err)
	if len(p1.Notifications) != 0 || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %v next=%q: an all-filtered full page is empty but must still point at the next one", idsOf(p1.Notifications), p1.NextPageToken)
	}
	p2, err := svc.List(context.Background(), "me", ListInput{PageSize: 3, PageToken: p1.NextPageToken})
	mustNoErr(t, err)
	if got := idsOf(p2.Notifications); len(got) != 1 || got[0] != "old" {
		t.Fatalf("page 2 = %v", got)
	}
}

func TestList_GraphErrorFailsClosed(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	seedRows(repo, "me", 2, t0)
	svc := newServiceWithSocial(repo, newDirectory("me"), &fakeSeen{}, nil, &fakeSocial{err: errBoom})
	if _, err := svc.List(context.Background(), "me", ListInput{}); err == nil {
		t.Fatal("a failed graph read must not show unfiltered rows")
	}
	// An empty inbox needs no graph read at all.
	empty := newServiceWithSocial(newFakeRepo(), newDirectory("me"), &fakeSeen{}, nil, &fakeSocial{err: errBoom})
	if _, err := empty.List(context.Background(), "me", ListInput{}); err != nil {
		t.Fatalf("empty inbox: %v", err)
	}
}

func TestList_ProfileErrorIsLoggedNotFatal(t *testing.T) {
	repo := newFakeRepo()
	seedRows(repo, "me", 1, t0)
	dir := newDirectory("me")
	dir.err = errBoom
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	defer slog.SetDefault(old)
	svc := newService(repo, dir, &fakeSeen{}, nil)
	res, err := svc.List(context.Background(), "me", ListInput{})
	mustNoErr(t, err)
	if len(res.Notifications) != 1 || !res.SeenAt.IsZero() {
		t.Errorf("res = %+v", res)
	}
	if !strings.Contains(buf.String(), "notifications_list_seen_at_unavailable") {
		t.Errorf("the GetProfiles error was not logged: %q", buf.String())
	}
}

func TestMarkSeen_SkipsWhenRecentlyMarked(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		seenAgo   time.Duration // negative = in the future
		zero      bool
		wantWrite bool
	}{
		{"never marked", 0, true, true},
		{"marked 1 s ago", time.Second, false, false},
		{"marked 9 s ago", 9 * time.Second, false, false},
		{"marked 10 s ago", MarkSeenMinInterval, false, true},
		{"marked an hour ago", time.Hour, false, true},
		{"another instance's clock is ahead", -3 * time.Second, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			seen, dir := &fakeSeen{}, newDirectory("me")
			if !tt.zero {
				dir.seenAt = t0.Add(-tt.seenAgo)
			}
			svc := newService(newFakeRepo(), dir, seen, func() time.Time { return t0 })
			at, err := svc.MarkSeen(context.Background(), "me", goodKey)
			mustNoErr(t, err)
			wrote := seen.uid != ""
			if wrote != tt.wantWrite {
				t.Fatalf("wrote = %v, want %v", wrote, tt.wantWrite)
			}
			if !tt.wantWrite {
				if !at.Equal(dir.seenAt) || len(dir.forgotten) != 0 {
					t.Errorf("skip must return the cached seen_at and evict nothing: at=%v forgotten=%v", at, dir.forgotten)
				}
			} else if !at.Equal(t0) || len(dir.forgotten) != 1 {
				t.Errorf("at = %v forgotten = %v", at, dir.forgotten)
			}
		})
	}
}
