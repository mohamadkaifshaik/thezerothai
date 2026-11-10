package notifications

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// fakePrefsRepo is an in-memory PrefsRepo that counts reads and writes.
type fakePrefsRepo struct {
	docs   map[string]Prefs
	reads  int
	writes int
	getErr error
	setErr error
}

func newFakePrefsRepo() *fakePrefsRepo { return &fakePrefsRepo{docs: map[string]Prefs{}} }

func (f *fakePrefsRepo) GetPrefs(_ context.Context, uid string) (Prefs, error) {
	f.reads++
	if f.getErr != nil {
		return Prefs{}, f.getErr
	}
	if p, ok := f.docs[uid]; ok {
		return p, nil
	}
	return DefaultPrefs(), nil
}

func (f *fakePrefsRepo) SetPrefs(_ context.Context, uid string, p Prefs, _ time.Time) (bool, error) {
	if f.setErr != nil {
		return false, f.setErr
	}
	cur, _ := f.GetPrefs(context.Background(), uid)
	if cur == p {
		return false, nil
	}
	f.writes++
	f.docs[uid] = p
	return true, nil
}

// prefFlags is a FlagChecker over "uid|flag" keys with the two flags the preference path reads.
func prefFlags(on map[string][]string) flagSet {
	f := flagSet{}
	for uid, names := range on {
		for _, n := range names {
			f[uid+"|"+n] = true
		}
	}
	return f
}

func TestGroupOf_EveryTypeHasAGroup(t *testing.T) {
	want := map[Type]Group{
		TypeBeaconRequest: GroupPlans, TypeBeaconAccepted: GroupPlans, TypeBeaconCancelled: GroupPlans,
		TypeMention: GroupMentionsReplies, TypeReply: GroupMentionsReplies, TypeQuote: GroupMentionsReplies,
		TypeLike: GroupLikesReposts, TypeRepost: GroupLikesReposts,
		TypeFollow: GroupFollowers, TypeFollowRequest: GroupFollowers, TypeFollowAccepted: GroupFollowers,
		TypeMessage: GroupMessages,
	}
	for ty, g := range want {
		if GroupOf(ty) != g {
			t.Errorf("GroupOf(%s) = %q, want %q", ty, GroupOf(ty), g)
		}
	}
	// A type added later without a group would silently ignore the preferences: pin that every valid type is mapped.
	for _, ty := range []Type{TypeFollow, TypeMention, TypeReply, TypeLike, TypeRepost, TypeQuote, TypeFollowRequest, TypeFollowAccepted, TypeMessage, TypeBeaconRequest, TypeBeaconAccepted, TypeBeaconCancelled} {
		if !ty.Valid() || GroupOf(ty) == "" {
			t.Errorf("type %s is valid=%v group=%q", ty, ty.Valid(), GroupOf(ty))
		}
	}
	if len(want) != 12 {
		t.Fatal("update the table with the new type")
	}
}

func TestPrefs_OffRoundTrip(t *testing.T) {
	tests := []struct {
		name string
		p    Prefs
		off  []string
	}{
		{"defaults", DefaultPrefs(), nil},
		{"plans off", Prefs{false, true, true, true, true}, []string{"plans"}},
		{"all off", Prefs{}, []string{"plans", "mentions_replies", "likes_reposts", "followers", "messages"}},
		{"likes and messages off", Prefs{true, true, false, true, false}, []string{"likes_reposts", "messages"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			off := tt.p.Off()
			if strings.Join(off, ",") != strings.Join(tt.off, ",") {
				t.Errorf("Off() = %v, want %v", off, tt.off)
			}
			if got := PrefsFromOff(off); got != tt.p {
				t.Errorf("round trip = %+v, want %+v", got, tt.p)
			}
		})
	}
	if got := PrefsFromOff([]string{"some_future_group", "plans"}); got != (Prefs{false, true, true, true, true}) {
		t.Errorf("unknown stored group must be ignored: %+v", got)
	}
}

func TestPrefsStore_CacheAndUpdate(t *testing.T) {
	repo := newFakePrefsRepo()
	s := NewPrefsStore(repo, newDirectory("me"))
	ctx := context.Background()

	p, err := s.PrefsFor(ctx, "me")
	mustNoErr(t, err)
	if p != DefaultPrefs() {
		t.Fatalf("a user who never saved anything must have every group on, got %+v", p)
	}
	if _, err := s.PrefsFor(ctx, "me"); err != nil || repo.reads != 1 {
		t.Fatalf("second lookup must hit the cache: reads=%d err=%v", repo.reads, err)
	}

	off := Prefs{Plans: true, MentionsReplies: false, LikesReposts: true, Followers: true, Messages: true}
	got, err := s.UpdatePrefs(ctx, "me", goodKey, off)
	mustNoErr(t, err)
	if got != off || repo.writes != 1 {
		t.Fatalf("update = %+v writes=%d", got, repo.writes)
	}
	// This instance's fan-out sees the change at once, from the cache the update refreshed.
	if p, _ := s.PrefsFor(ctx, "me"); p != off || repo.reads != 2 {
		t.Errorf("after update PrefsFor = %+v reads=%d (want the new value without another read beyond the update's own)", p, repo.reads)
	}
	// Idempotent by state: the same update writes nothing.
	if _, err := s.UpdatePrefs(ctx, "me", goodKey, off); err != nil || repo.writes != 1 {
		t.Errorf("replay: err=%v writes=%d, want 1 write in total", err, repo.writes)
	}
	// GetPrefs reads storage (a settings screen read) and refreshes the cache.
	before := repo.reads
	if p, err := s.GetPrefs(ctx, "me"); err != nil || p != off || repo.reads != before+1 {
		t.Errorf("GetPrefs = %+v %v reads %d->%d", p, err, before, repo.reads)
	}
}

func TestPrefsStore_CacheExpires(t *testing.T) {
	// The LRU's own TTL is covered by pkg/platform/cache; here: a stored change made elsewhere is picked up on a miss.
	repo := newFakePrefsRepo()
	s := NewPrefsStore(repo, nil)
	if _, err := s.PrefsFor(context.Background(), "me"); err != nil {
		t.Fatal(err)
	}
	repo.docs["me"] = Prefs{}
	s.cache.Delete("me")
	if p, _ := s.PrefsFor(context.Background(), "me"); p != (Prefs{}) {
		t.Errorf("after the entry expired the stored value must be read, got %+v", p)
	}
}

func TestPrefsStore_Errors(t *testing.T) {
	ctx := context.Background()
	repo := newFakePrefsRepo()
	s := NewPrefsStore(repo, newDirectory("me"))

	_, err := s.UpdatePrefs(ctx, "me", "short", DefaultPrefs())
	if ae := wantAPI(t, err); ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != "idempotency_key" {
		t.Errorf("bad key: %v", err)
	}
	_, err = s.UpdatePrefs(ctx, "ghost", goodKey, DefaultPrefs()) // no profile in the directory
	if ae := wantAPI(t, err); ae.Reason != commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED {
		t.Errorf("no profile: %v", err)
	}
	if repo.writes != 0 {
		t.Error("a refused update wrote")
	}
	repo.setErr = errors.New("firestore down")
	if _, err := s.UpdatePrefs(ctx, "me", goodKey, Prefs{}); err == nil || strings.Contains(err.Error(), "me") && false {
		t.Errorf("a storage error must surface: %v", err)
	}
	repo.getErr = errors.New("firestore down")
	if _, err := s.PrefsFor(ctx, "me"); err == nil {
		t.Error("PrefsFor swallowed a read error (the fan-out decides to fail open, not the store)")
	}
	if _, err := s.GetPrefs(ctx, "me"); err == nil {
		t.Error("GetPrefs swallowed a read error")
	}
}

func wantAPI(t *testing.T, err error) *apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v (%T), want an *apierr.Error", err, err)
	}
	return ae
}

// ---- fan-out ----

func prefsRig(t *testing.T, fl FlagChecker, repo *fakePrefsRepo) *fanoutRig {
	t.Helper()
	r := newRig(t, fl)
	r.f.d.Prefs = NewPrefsStore(repo, r.dir)
	return r
}

func TestDeliver_PrefsSuppressThePushNotTheRow(t *testing.T) {
	tests := []struct {
		name     string
		ev       Event
		prefs    Prefs
		wantPush int
		wantRow  bool
	}{
		{"like push off", Event{Type: TypeLike, ActorID: "alice", RecipientIDs: []string{"bob"}, PostID: "1000000000000000001", At: t0}, Prefs{true, true, false, true, true}, 0, true},
		{"like push on", Event{Type: TypeLike, ActorID: "alice", RecipientIDs: []string{"bob"}, PostID: "1000000000000000001", At: t0}, DefaultPrefs(), 1, true},
		{"reply push off", Event{Type: TypeReply, ActorID: "alice", RecipientIDs: []string{"bob"}, PostID: "1000000000000000001", At: t0}, Prefs{true, false, true, true, true}, 0, true},
		{"mention push off", Event{Type: TypeMention, ActorID: "alice", RecipientIDs: []string{"bob"}, PostID: "1000000000000000001", At: t0}, Prefs{true, false, true, true, true}, 0, true},
		{"unrelated group off", Event{Type: TypeReply, ActorID: "alice", RecipientIDs: []string{"bob"}, PostID: "1000000000000000001", At: t0}, Prefs{false, true, false, false, false}, 1, true},
		{"follow push off", Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0}, Prefs{true, true, true, false, true}, 0, true},
		{"plans push off", Event{Type: TypeBeaconRequest, ActorID: "alice", RecipientIDs: []string{"bob"}, BeaconID: "1000000000000000002", At: t0}, Prefs{false, true, true, true, true}, 0, true},
		{"message push off (no row either way)", Event{Type: TypeMessage, ActorID: "alice", RecipientIDs: []string{"bob"}, ConversationID: convA, At: t0}, Prefs{true, true, true, true, false}, 0, false},
		{"message push on", Event{Type: TypeMessage, ActorID: "alice", RecipientIDs: []string{"bob"}, ConversationID: convA, At: t0}, DefaultPrefs(), 1, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakePrefsRepo()
			repo.docs["bob"] = tt.prefs
			r := prefsRig(t, prefsFlagsOn("alice", "bob"), repo)
			r.addDevice("bob", "d1", "tok-1")
			out, err := r.f.Deliver(context.Background(), tt.ev)
			mustNoErr(t, err)
			if out.Pushed != tt.wantPush {
				t.Errorf("pushed = %d, want %d (outcome %+v)", out.Pushed, tt.wantPush, out)
			}
			if (out.Created == 1) != tt.wantRow {
				t.Errorf("created = %d, want row=%v: in-app rows are never affected by push preferences", out.Created, tt.wantRow)
			}
			if tt.wantPush == 0 && out.PrefSuppressed != 1 {
				t.Errorf("PrefSuppressed = %d, want 1", out.PrefSuppressed)
			}
		})
	}
}

// prefsFlagsOn turns notifications, messaging and notification_prefs on for the uids.
func prefsFlagsOn(uids ...string) flagSet {
	f := flagSet{}
	for _, u := range uids {
		f[u+"|"+FlagName] = true
		f[u+"|"+MessagingFlagName] = true
		f[u+"|"+PrefsFlagName] = true
	}
	return f
}

// TestDeliver_PrefsFlagModes: the preference check only applies to a recipient with FEATURE_NOTIFICATION_PREFS on.
func TestDeliver_PrefsFlagModes(t *testing.T) {
	ev := Event{Type: TypeLike, ActorID: "alice", RecipientIDs: []string{"bob"}, PostID: "1000000000000000001", At: t0}
	allOff := Prefs{}
	tests := []struct {
		name      string
		flags     flagSet
		wantPush  int
		wantReads int
	}{
		{"flag on for the recipient: suppressed", prefsFlagsOn("alice", "bob"), 0, 1},
		{"flag off: prefs ignored, no read", flagSet{"alice|" + FlagName: true, "bob|" + FlagName: true}, 1, 0},
		{"flag on only for the actor: recipient is not in the rollout", flagSet{"alice|" + FlagName: true, "bob|" + FlagName: true, "alice|" + PrefsFlagName: true}, 1, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakePrefsRepo()
			repo.docs["bob"] = allOff
			r := prefsRig(t, tt.flags, repo)
			r.addDevice("bob", "d1", "tok-1")
			out, err := r.f.Deliver(context.Background(), ev)
			mustNoErr(t, err)
			if out.Pushed != tt.wantPush || repo.reads != tt.wantReads {
				t.Errorf("pushed=%d reads=%d, want %d and %d", out.Pushed, repo.reads, tt.wantPush, tt.wantReads)
			}
		})
	}
	// No Prefs wired at all: unchanged behaviour.
	r := newRig(t, prefsFlagsOn("alice", "bob"))
	r.addDevice("bob", "d1", "tok-1")
	if out, err := r.f.Deliver(context.Background(), ev); err != nil || out.Pushed != 1 {
		t.Errorf("without Prefs: %+v %v", out, err)
	}
}

// TestDeliver_PrefsLookupFailsOpen: a failing settings read must not drop pushes.
func TestDeliver_PrefsLookupFailsOpen(t *testing.T) {
	repo := newFakePrefsRepo()
	repo.getErr = errors.New("firestore unavailable")
	r := prefsRig(t, prefsFlagsOn("alice", "bob"), repo)
	r.addDevice("bob", "d1", "tok-1")
	out, err := r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0})
	mustNoErr(t, err)
	if out.Pushed != 1 {
		t.Errorf("pushed = %d, want 1 (fail open)", out.Pushed)
	}
	if !strings.Contains(r.logs.String(), "notification_prefs_failed") || strings.Contains(r.logs.String(), "firestore unavailable") && strings.Contains(r.logs.String(), `"bob"`) {
		t.Errorf("log = %s", r.logs.String())
	}
}

// TestDeliver_SuppressedPushIsNotResentOnRedelivery: the row is the delivery record, so a redelivery after the user turns
// the group back on finds the row and sends nothing (the push that was suppressed stays suppressed).
func TestDeliver_SuppressedPushIsNotResentOnRedelivery(t *testing.T) {
	repo := newFakePrefsRepo()
	repo.docs["bob"] = Prefs{true, true, true, false, true}
	r := prefsRig(t, prefsFlagsOn("alice", "bob"), repo)
	r.addDevice("bob", "d1", "tok-1")
	ev := Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0}
	out, err := r.f.Deliver(context.Background(), ev)
	mustNoErr(t, err)
	if out.Created != 1 || out.Pushed != 0 || out.PrefSuppressed != 1 {
		t.Fatalf("first delivery = %+v", out)
	}
	// The user turns followers back on (this instance's cache refreshed), then Pub/Sub redelivers the same event.
	if _, err := r.f.d.Prefs.(*PrefsStore).UpdatePrefs(context.Background(), "bob", goodKey, DefaultPrefs()); err != nil {
		t.Fatal(err)
	}
	out, err = r.f.Deliver(context.Background(), ev)
	mustNoErr(t, err)
	if out.Duplicate != 1 || out.Pushed != 0 || len(r.sender.sent) != 0 {
		t.Errorf("redelivery = %+v sent=%d, want a duplicate row and no push", out, len(r.sender.sent))
	}
}

// TestDeliver_SuppressedPushDoesNotSpendTheLimiter: a push the user muted must not consume the hourly push budget.
func TestDeliver_SuppressedPushDoesNotSpendTheLimiter(t *testing.T) {
	repo := newFakePrefsRepo()
	repo.docs["bob"] = Prefs{true, true, false, true, true}
	r := prefsRig(t, prefsFlagsOn("alice", "bob"), repo)
	r.f.d.PushLimit = NewPushLimiter(1)
	r.addDevice("bob", "d1", "tok-1")
	for i := 0; i < 3; i++ {
		ev := Event{Type: TypeLike, ActorID: "alice", RecipientIDs: []string{"bob"}, PostID: "100000000000000000" + string(rune('1'+i)), At: t0}
		if out, err := r.f.Deliver(context.Background(), ev); err != nil || out.Throttled != 0 || out.PrefSuppressed != 1 {
			t.Fatalf("like %d: %+v %v", i, out, err)
		}
	}
	follow := Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob"}, At: t0}
	if out, err := r.f.Deliver(context.Background(), follow); err != nil || out.Pushed != 1 {
		t.Errorf("the one allowed push was spent by muted ones: %+v %v", out, err)
	}
}

// ---- server ----

func prefsServer(fl FlagChecker, repo *fakePrefsRepo) *Server {
	svc := NewService(Deps{Repo: newFakeRepo(), Directory: newDirectory("me"), Social: &fakeSocial{}, Seen: &fakeSeen{}, CursorKey: testKey, Now: func() time.Time { return t0 }})
	return NewServer(svc, fl, WithPrefs(NewPrefsStore(repo, newDirectory("me"))))
}

func TestServer_PrefsFlagModes(t *testing.T) {
	calls := map[string]func(*Server) error{
		"GetNotificationPrefs": func(s *Server) error {
			_, err := s.GetNotificationPrefs(authedCtx("me"), connect.NewRequest(&notificationsv1.GetNotificationPrefsRequest{}))
			return err
		},
		"UpdateNotificationPrefs": func(s *Server) error {
			_, err := s.UpdateNotificationPrefs(authedCtx("me"), connect.NewRequest(&notificationsv1.UpdateNotificationPrefsRequest{IdempotencyKey: goodKey, Prefs: &notificationsv1.NotificationPrefs{}}))
			return err
		},
	}
	modes := []struct {
		name        string
		on          map[string][]string
		wantFeature string // "" = the whole-service FEATURE_DISABLED (no metadata); "-" = reaches the service
	}{
		{"notifications off, prefs on", map[string][]string{"me": {PrefsFlagName}}, ""},
		{"notifications on, prefs off", map[string][]string{"me": {FlagName}}, PrefsFlagName},
		{"both off", nil, ""},
		{"both on", map[string][]string{"me": {FlagName, PrefsFlagName}}, "-"},
	}
	for name, call := range calls {
		for _, m := range modes {
			t.Run(name+"/"+m.name, func(t *testing.T) {
				repo := newFakePrefsRepo()
				err := call(prefsServer(prefFlags(m.on), repo))
				if m.wantFeature == "-" {
					if err != nil {
						t.Fatalf("err = %v", err)
					}
					return
				}
				ae := wantAPI(t, err)
				if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
					t.Fatalf("err = %v, want FAILED_PRECONDITION + FEATURE_DISABLED", err)
				}
				if ae.Metadata["feature"] != m.wantFeature {
					t.Errorf("feature = %q, want %q", ae.Metadata["feature"], m.wantFeature)
				}
				if repo.reads != 0 || repo.writes != 0 {
					t.Error("a flag-off call reached storage")
				}
			})
		}
	}
	// No service wired: Unimplemented once the flags pass.
	s := NewServer(nil, prefFlags(map[string][]string{"me": {FlagName, PrefsFlagName}}))
	for name, call := range calls {
		if err := call(s); connect.CodeOf(err) != connect.CodeUnimplemented {
			t.Errorf("%s without a service: %v", name, err)
		}
	}
}

func TestServer_PrefsGetAndUpdate(t *testing.T) {
	repo := newFakePrefsRepo()
	s := prefsServer(prefFlags(map[string][]string{"me": {FlagName, PrefsFlagName}}), repo)
	got, err := s.GetNotificationPrefs(authedCtx("me"), connect.NewRequest(&notificationsv1.GetNotificationPrefsRequest{}))
	mustNoErr(t, err)
	if p := got.Msg.GetPrefs(); !p.GetPlansPush() || !p.GetMentionsRepliesPush() || !p.GetLikesRepostsPush() || !p.GetFollowersPush() || !p.GetMessagesPush() {
		t.Fatalf("default prefs = %v, want everything on", p)
	}
	upd, err := s.UpdateNotificationPrefs(authedCtx("me"), connect.NewRequest(&notificationsv1.UpdateNotificationPrefsRequest{
		IdempotencyKey: goodKey, Prefs: &notificationsv1.NotificationPrefs{PlansPush: true, FollowersPush: true},
	}))
	mustNoErr(t, err)
	want := Prefs{Plans: true, Followers: true}
	if PrefsFromProto(upd.Msg.GetPrefs()) != want || repo.docs["me"] != want {
		t.Errorf("update = %v stored %+v", upd.Msg.GetPrefs(), repo.docs["me"])
	}
	got, err = s.GetNotificationPrefs(authedCtx("me"), connect.NewRequest(&notificationsv1.GetNotificationPrefsRequest{}))
	mustNoErr(t, err)
	if PrefsFromProto(got.Msg.GetPrefs()) != want {
		t.Errorf("get after update = %v", got.Msg.GetPrefs())
	}
	// A missing prefs message is a validation error, before any write; so is a malformed key.
	_, err = s.UpdateNotificationPrefs(authedCtx("me"), connect.NewRequest(&notificationsv1.UpdateNotificationPrefsRequest{IdempotencyKey: goodKey}))
	if ae := wantAPI(t, err); ae.Metadata["field"] != "prefs" {
		t.Errorf("missing prefs: %v", err)
	}
	_, err = s.UpdateNotificationPrefs(authedCtx("me"), connect.NewRequest(&notificationsv1.UpdateNotificationPrefsRequest{IdempotencyKey: "x", Prefs: &notificationsv1.NotificationPrefs{}}))
	if ae := wantAPI(t, err); ae.Metadata["field"] != "idempotency_key" {
		t.Errorf("bad key: %v", err)
	}
	// Another caller's preferences are separate.
	if p, _ := repo.GetPrefs(context.Background(), "other"); p != DefaultPrefs() {
		t.Errorf("other = %+v", p)
	}
}
