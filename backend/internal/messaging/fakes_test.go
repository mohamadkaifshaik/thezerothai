package messaging

import (
	"bytes"
	"context"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// fakeRepo is a Repo that records its calls and answers from a script.
type fakeRepo struct {
	mu       sync.Mutex
	convs    map[string]ConvDoc
	gets     int
	sends    []SendParams
	sendRes  SendResult
	lastRes  SendResult // what the fake transaction decided (Silent and Mutual from the recipient.s graph)
	sendErr  error
	freshErr error // what FreshRecipient returned when the fake ran it

	// entries is users/{uid}/{folder} keyed "uid|folder" (W7-7); lists and counts record the calls, queries the queries.
	entries  map[string][]EntryRow
	lists    int
	counts   int
	unreads  int // CountUnreadConversations calls
	queries  []ListQuery
	listErr  error
	countErr error // CountRequests fails with it (W7-37)

	// msgs is conversations/{id}/messages (W7-8); msgQueries records the queries. marked records MarkRead calls as
	// "uid|convID"; markFound is what it answers (default found).
	msgs        map[string][]MessageRow
	msgQueries  []MessageQuery
	msgErr      error
	marked      []string
	markMissing bool
	markErr     error

	// entryGets records GetEntry calls as "uid|folder|convID" (W7-27); entryErr is what it answers when set.
	entryGets []string
	entryErr  error

	// accepts and deletes record the W7-9 calls; lifeErr is returned by both when set; writes and deletedDocs count the
	// documents the fake wrote and deleted (the budget the real repo reports).
	accepts     []AcceptParams
	deletes     []DeleteParams
	lifeErr     error
	writes      int
	deletedDocs int
}

func (f *fakeRepo) findEntry(uid, folder, convID string) (int, bool) {
	for i, r := range f.entries[entryKey(uid, folder)] {
		if r.ID == convID {
			return i, true
		}
	}
	return 0, false
}

// Accept applies the same pure rules as the Firestore transaction (decideAccept) to the in-memory documents: the
// request entry moves to dmInbox, the conversation becomes ACCEPTED.
func (f *fakeRepo) Accept(_ context.Context, p AcceptParams) (AcceptResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.accepts = append(f.accepts, p)
	if f.lifeErr != nil {
		return AcceptResult{}, f.lifeErr
	}
	var conv *ConvDoc
	if c, ok := f.convs[p.ConvID]; ok {
		conv = &c
	}
	dec, err := decideAccept(conv, p.UID)
	if err != nil {
		return AcceptResult{}, err
	}
	if dec.Already {
		return AcceptResult{Already: true, Conv: *conv}, nil
	}
	if p.PeerAllowed != nil && !p.PeerAllowed(peerOf(conv.Participants, p.UID)) {
		return AcceptResult{}, errPeerFlagOff
	}
	i, ok := f.findEntry(p.UID, dmRequestsCollection, p.ConvID)
	if !ok {
		return AcceptResult{}, ErrNotFound
	}
	row := f.entries[entryKey(p.UID, dmRequestsCollection)][i]
	f.entries[entryKey(p.UID, dmRequestsCollection)] = slices.Delete(slices.Clone(f.entries[entryKey(p.UID, dmRequestsCollection)]), i, i+1)
	f.entries[entryKey(p.UID, dmInboxCollection)] = append(slices.Clone(f.entries[entryKey(p.UID, dmInboxCollection)]), row)
	conv.State, conv.UpdatedAt = stateAccepted, notBefore(wireTime(p.Now), conv.UpdatedAt)
	f.convs[p.ConvID] = *conv
	f.writes += 2
	f.deletedDocs++
	return AcceptResult{Conv: *conv}, nil
}

// Delete applies decideDelete and deleteIsReplay to the in-memory documents: clearedAt[caller] is set, the caller's
// entry removed, nothing else touched.
func (f *fakeRepo) Delete(_ context.Context, p DeleteParams) (DeleteResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deletes = append(f.deletes, p)
	if f.lifeErr != nil {
		return DeleteResult{}, f.lifeErr
	}
	var conv *ConvDoc
	if c, ok := f.convs[p.ConvID]; ok {
		conv = &c
	}
	folder, err := decideDelete(conv, p.UID)
	if err != nil {
		return DeleteResult{}, err
	}
	if deleteIsKeyReplay(*conv, p.UID, p.KeyDigest) {
		return DeleteResult{Replay: true, Folder: folder, Conv: *conv}, nil
	}
	collection := dmInboxCollection // the entry folder label is not the collection name
	if folder == entryRequests {
		collection = dmRequestsCollection
	}
	i, exists := f.findEntry(p.UID, collection, p.ConvID)
	if deleteIsReplay(*conv, p.UID, exists) {
		return DeleteResult{Replay: true, Folder: folder, Conv: *conv}, nil
	}
	var lastMessageAt time.Time
	if exists {
		lastMessageAt = f.entries[entryKey(p.UID, collection)][i].LastMessageAt
	}
	now := notBefore(wireTime(p.Now), conv.UpdatedAt, lastMessageAt)
	cleared := map[string]time.Time{}
	for k, v := range conv.ClearedAt {
		cleared[k] = v
	}
	cleared[p.UID] = now
	conv.ClearedAt, conv.UpdatedAt = cleared, now
	if p.KeyDigest != "" {
		keys := map[string]string{}
		for k, v := range conv.ClearedKey {
			keys[k] = v
		}
		keys[p.UID] = p.KeyDigest
		conv.ClearedKey = keys
	}
	f.convs[p.ConvID] = *conv
	f.writes++
	if exists {
		f.entries[entryKey(p.UID, collection)] = slices.Delete(slices.Clone(f.entries[entryKey(p.UID, collection)]), i, i+1)
		f.deletedDocs++
	}
	return DeleteResult{Folder: folder, EntryDeleted: exists, Conv: *conv}, nil
}

// ListMessages answers like the Firestore query: `createdAt DESC, __name__ DESC`, createdAt > ClearedAt, StartAfter /
// EndBefore, Limit.
func (f *fakeRepo) ListMessages(_ context.Context, convID string, q MessageQuery) ([]MessageRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.msgQueries = append(f.msgQueries, q)
	if f.msgErr != nil {
		return nil, f.msgErr
	}
	older := func(t time.Time, id string, c *cursor.Cursor) bool {
		return t.Before(c.CreatedAt) || (t.Equal(c.CreatedAt) && id < c.DocID)
	}
	var out []MessageRow
	for _, r := range f.msgs[convID] {
		if !q.ClearedAt.IsZero() && !r.CreatedAt.After(q.ClearedAt) {
			continue
		}
		if q.Before != nil && !older(r.CreatedAt, r.ID, q.Before) {
			continue
		}
		if q.After != nil && (older(r.CreatedAt, r.ID, q.After) || (r.CreatedAt.Equal(q.After.CreatedAt) && r.ID == q.After.DocID)) {
			continue
		}
		out = append(out, r)
	}
	slices.SortFunc(out, func(a, b MessageRow) int {
		if c := b.CreatedAt.Compare(a.CreatedAt); c != 0 {
			return c
		}
		return strings.Compare(b.ID, a.ID)
	})
	if len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out, nil
}

func (f *fakeRepo) MarkRead(_ context.Context, uid, convID string, _ time.Time) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.marked = append(f.marked, uid+"|"+convID)
	return !f.markMissing, f.markErr
}

func entryKey(uid, folder string) string { return uid + "|" + folder }

// GetEntry answers from the in-memory folders (entryRequests reads dmRequests, anything else dmInbox) and records the call
// as "uid|folder|convID" in entryGets.
func (f *fakeRepo) GetEntry(_ context.Context, uid, convID, folder string) (EntryDoc, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.entryGets = append(f.entryGets, uid+"|"+folder+"|"+convID)
	if f.entryErr != nil {
		return EntryDoc{}, false, f.entryErr
	}
	collection := dmInboxCollection
	if folder == entryRequests {
		collection = dmRequestsCollection
	}
	if i, ok := f.findEntry(uid, collection, convID); ok {
		return f.entries[entryKey(uid, collection)][i].EntryDoc, true, nil
	}
	return EntryDoc{}, false, nil
}

// ListEntries answers like the Firestore query: `lastMessageAt DESC, __name__ DESC`, StartAfter / EndBefore, Limit.
func (f *fakeRepo) ListEntries(_ context.Context, uid, folder string, q ListQuery) ([]EntryRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lists++
	f.queries = append(f.queries, q)
	if f.listErr != nil {
		return nil, f.listErr
	}
	rows := slices.Clone(f.entries[entryKey(uid, folder)])
	// after reports whether (t, id) sorts strictly after (ct, cid) in the DESC order, i.e. is older.
	older := func(t time.Time, id string, c *cursor.Cursor) bool {
		return t.Before(c.CreatedAt) || (t.Equal(c.CreatedAt) && id < c.DocID)
	}
	// A since query (After set) orders and positions by changedAt and skips entries without one; the others by lastMessageAt.
	at := func(r EntryRow) time.Time {
		if q.After != nil {
			return r.ChangedAt
		}
		return r.LastMessageAt
	}
	var out []EntryRow
	for _, r := range rows {
		if q.After != nil && r.ChangedAt.IsZero() {
			continue
		}
		if q.Before != nil && !older(at(r), r.ID, q.Before) {
			continue
		}
		if q.After != nil && (older(at(r), r.ID, q.After) || (at(r).Equal(q.After.CreatedAt) && r.ID == q.After.DocID)) {
			continue
		}
		out = append(out, r)
	}
	slices.SortFunc(out, func(a, b EntryRow) int {
		if c := at(b).Compare(at(a)); c != 0 {
			return c
		}
		return strings.Compare(b.ID, a.ID)
	})
	if len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out, nil
}

func (f *fakeRepo) CountRequests(_ context.Context, uid string) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.counts++
	if f.countErr != nil {
		return 0, f.countErr
	}
	return int64(len(f.entries[entryKey(uid, dmRequestsCollection)])), nil
}

func (f *fakeRepo) CountUnreadConversations(_ context.Context, uid string) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.unreads++
	var n int64
	for _, r := range f.entries[entryKey(uid, dmInboxCollection)] {
		if r.UnreadCount > 0 {
			n++
		}
	}
	return min(n, unreadConversationsCap), nil
}

func (f *fakeRepo) GetConversation(_ context.Context, id string) (ConvDoc, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gets++
	c, ok := f.convs[id]
	return c, ok, nil
}

func (f *fakeRepo) Send(ctx context.Context, p SendParams) (SendResult, error) {
	f.mu.Lock()
	f.sends = append(f.sends, p)
	f.mu.Unlock()
	if f.sendErr != nil {
		return SendResult{}, f.sendErr
	}
	// The transaction's reads, in the real order (W7-33): the recipient's graph (block, mute, mutual), then for a new
	// conversation the recipient's users doc.
	theirs, err := p.RecipientGraphInTx(ctx, nil)
	if err != nil {
		return SendResult{}, err
	}
	if theirs.Blocked[p.UID] {
		return SendResult{}, errBlocked
	}
	f.mu.Lock()
	res := f.sendRes
	f.mu.Unlock()
	res.Silent, res.Mutual = theirs.Muted[p.UID], p.CallerFollowsPeer && theirs.Following[p.UID]
	if res.Created {
		f.freshErr = checkRecipient(p.RecipientInTx(ctx, nil))
		if f.freshErr != nil {
			return SendResult{}, f.freshErr
		}
	}
	if res.Msg.CreatedAt.IsZero() {
		res.Msg = MsgDoc{SenderID: p.UID, Text: p.Text, State: msgVisible, RequestHash: p.RequestHash, CreatedAt: wireTime(p.Now)}
	}
	if res.Conv.State == "" {
		res.Conv = ConvDoc{Kind: kindDirect, Participants: sortedPair(p.UID, p.PeerUID), State: stateAccepted}
	}
	f.mu.Lock()
	f.lastRes = res
	f.mu.Unlock()
	return res, nil
}

// fakeSocial serves graph snapshots.
type fakeSocial struct {
	mu    sync.Mutex
	snaps map[string]graph.Snapshot
	calls int
	err   error
}

func (f *fakeSocial) Snapshot(_ context.Context, uid string) (graph.Snapshot, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	return f.snaps[uid], f.err
}

// fakeProfiles is identity's directory: only ACTIVE profiles are returned, and Forget makes the next call "fresh".
type fakeProfiles struct {
	mu       sync.Mutex
	profiles map[string]identity.Profile
	calls    int
	forgot   []string
	err      error
}

func (f *fakeProfiles) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if p, ok := f.profiles[u]; ok && p.Status == identity.AccountStatusActive {
			out[u] = p
		}
	}
	return out, nil
}

func (f *fakeProfiles) Forget(uids ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.forgot = append(f.forgot, uids...)
}

type recEvents struct {
	mu  sync.Mutex
	got []MessageEvent
}

func (r *recEvents) MessageSent(_ context.Context, e MessageEvent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.got = append(r.got, e)
}

type recBadge struct {
	mu  sync.Mutex
	got [][]string
}

func (r *recBadge) Forget(uids ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.got = append(r.got, uids)
}

// testCursorKey seals the list tokens of the unit tests.
var testCursorKey = []byte("0123456789abcdef0123456789abcdef")

const (
	alice = "uid-alice"
	bob   = "uid-bob"
)

func activeProfile(uid, handle string, createdAt time.Time) identity.Profile {
	return identity.Profile{UserID: uid, Handle: handle, DisplayName: "Name " + handle, AvatarThumbURL: "https://img/" + handle, Status: identity.AccountStatusActive, CreatedAt: createdAt}
}

// rig is one service over fakes. Both users have the flag on and are established accounts unless a test says otherwise.
type rig struct {
	svc      *service
	repo     *fakeRepo
	social   *fakeSocial
	txSocial *fakeTxSocial
	txProfs  *fakeTxProfiles
	profs    *fakeProfiles
	events   *recEvents
	badge    *recBadge
	reg      *flags.Registry
	now      time.Time
	limits   Limits
	// allowAnon is Deps.AllowAnonymous (the emulator allowance); a context without claims still fails the verified-email gate.
	allowAnon bool
}

func newRig(t *testing.T, mut func(*rig)) *rig {
	t.Helper()
	r := &rig{
		repo: &fakeRepo{convs: map[string]ConvDoc{}}, social: &fakeSocial{snaps: map[string]graph.Snapshot{}},
		events: &recEvents{}, badge: &recBadge{}, now: time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC),
		limits: Limits{RequestMaxUnanswered: 3, DMNewPerDay: 20, NewAccountDMNewPerDay: 5, NewAccountSendsPerDay: 50, NewAccountWindow: 72 * time.Hour, ConversationCacheEntries: 100},
		reg:    flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}),
	}
	r.allowAnon = true
	old := r.now.Add(-30 * 24 * time.Hour)
	r.profs = &fakeProfiles{profiles: map[string]identity.Profile{alice: activeProfile(alice, "alice", old), bob: activeProfile(bob, "bob", old)}}
	r.txSocial, r.txProfs = &fakeTxSocial{social: r.social}, &fakeTxProfiles{profs: r.profs}
	if mut != nil {
		mut(r)
	}
	r.svc = New(r.reg, Deps{
		Repo: r.repo, Social: r.social, TxSocial: r.txSocial, TxProfiles: r.txProfs, AllowAnonymous: r.allowAnon, Profiles: r.profs, Events: r.events, Badge: r.badge, Limits: r.limits, CursorKey: testCursorKey, Now: func() time.Time { return r.now },
	}).(*service)
	return r
}

// wireBytes is an error as the client receives it: code, message and every attached detail, serialised.
func wireBytes(t *testing.T, err error) []byte {
	t.Helper()
	ce := apierr.ToConnect(err)
	if ce == nil {
		t.Fatal("no error")
	}
	var buf bytes.Buffer
	buf.WriteString(ce.Code().String() + "|" + ce.Message() + "|")
	for _, d := range ce.Details() {
		v, verr := d.Value()
		if verr != nil {
			t.Fatalf("detail: %v", verr)
		}
		raw, merr := proto.MarshalOptions{Deterministic: true}.Marshal(v)
		if merr != nil {
			t.Fatalf("marshal detail: %v", merr)
		}
		buf.Write(raw)
	}
	return buf.Bytes()
}

// reasonOf is the ErrorDetail reason and metadata of err.
func reasonOf(t *testing.T, err error) (connect.Code, commonv1.ErrorReason, map[string]string) {
	t.Helper()
	ce := apierr.ToConnect(err)
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok {
				return ce.Code(), ed.GetReason(), ed.GetMetadata()
			}
		}
	}
	return ce.Code(), commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil
}

// fakeTxSocial serves the recipient's graph inside the "transaction" from the same snapshots as fakeSocial, so a test sets
// r.social.snaps[bob] once; txCalls counts the in-transaction reads (the cache is never involved).
type fakeTxSocial struct {
	social *fakeSocial
	// override answers the in-transaction read for a uid when set, while the cached fakeSocial keeps its (stale) value.
	override map[string]graph.Snapshot
	txCalls  int
	err      error
}

func (f *fakeTxSocial) SnapshotInTx(_ context.Context, _ *firestore.Transaction, uid string) (graph.Snapshot, error) {
	f.txCalls++
	if s, ok := f.override[uid]; ok {
		return s, f.err
	}
	f.social.mu.Lock()
	defer f.social.mu.Unlock()
	return f.social.snaps[uid], f.err
}

// fakeTxProfiles is identity.TxProfiles over the fakeProfiles map (any status comes back, a missing user is ErrNotFound).
type fakeTxProfiles struct {
	profs   *fakeProfiles
	txCalls int
	// missing answers ErrNotFound; status, when set, replaces the stored status (a deletion or suspension that committed
	// after the directory.s cached read).
	missing bool
	status  identity.AccountStatus
}

func (f *fakeTxProfiles) ProfileInTx(_ context.Context, _ *firestore.Transaction, uid string) (identity.Profile, error) {
	f.txCalls++
	f.profs.mu.Lock()
	defer f.profs.mu.Unlock()
	p, ok := f.profs.profiles[uid]
	if f.status != identity.AccountStatusUnspecified {
		p.Status = f.status
	}
	if !ok || f.missing {
		return identity.Profile{}, identity.ErrNotFound
	}
	return p, nil
}

// verifiedCtx is a context whose caller passed the verified-identity gate (a Google sign-in), which Send and Accept re-check
// themselves (W7-33, L-8). A context without claims is refused with EMAIL_NOT_VERIFIED.
func verifiedCtx() context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{SignInProvider: authn.SignInProviderGoogle})
}
