package messaging

import (
	"bytes"
	"context"
	"errors"
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

	// entries is users/{uid}/{folder} keyed "uid|folder"; lists and counts record the calls, queries the queries.
	entries  map[string][]EntryRow
	lists    int
	counts   int
	unreads  int // CountUnreadConversations calls
	queries  []ListQuery
	listErr  error
	countErr error // CountRequests fails with it

	// msgs is conversations/{id}/messages; msgQueries records the queries. marked records MarkRead calls as
	// "uid|convID"; markFound is what it answers (default found).
	msgs        map[string][]MessageRow
	msgQueries  []MessageQuery
	msgErr      error
	marked      []string
	receipts    []string // MarkRead calls that carried a read receipt (uid|conv)
	markMissing bool
	markErr     error

	// entryGets records GetEntry calls as "uid|folder|convID"; entryErr is what it answers when set.
	entryGets []string
	entryErr  error
	// entryErrFor fails GetEntry for these uids only (nil = none).
	entryErrFor map[string]error

	// accepts and deletes record the calls; lifeErr is returned by both when set; writes and deletedDocs count the
	// documents the fake wrote and deleted.
	accepts     []AcceptParams
	deletes     []DeleteParams
	lifeErr     error
	writes      int
	deletedDocs int

	// mls_init state (sendInit): commits keyed "convID/commitDocID", the stored welcomes, and dmNewUsed the new
	// conversations an mls_init opened per caller (the dm_new_daily counter of the init path).
	commits   map[string]CommitDoc
	welcomes  []fakeWelcome
	dmNewUsed map[string]int64
	// commitCalls counts Commit calls; commitErr fails them.
	commitCalls int
	commitErr   error

	// The sync reads (sync_fakes_test.go): welcomeRows is users/{uid}/dmWelcomes keyed by uid; syncCalls records each sync
	// repo call ("commits|conv", "epoch|conv|key|after", "welcomes|uid|device", "ack|uid|n"); syncErr fails them all.
	welcomeRows map[string][]WelcomeRow
	syncCalls   []string
	syncErr     error
	// orderErr is the raw Firestore error ListEpochMessagesByTime gets (passed through the repo's orderIndexErr, as the
	// Firestore repo does); tombOverride, when set, replaces ListTombstones' answer (rows the queries could never match).
	orderErr     error
	tombOverride func() ([]TombstoneRow, bool)
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

func (f *fakeRepo) MarkRead(_ context.Context, uid, convID string, _ time.Time, receipt bool) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.marked = append(f.marked, uid+"|"+convID)
	if receipt {
		f.receipts = append(f.receipts, uid+"|"+convID)
	}
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
	if err := f.entryErrFor[uid]; err != nil {
		return EntryDoc{}, false, err
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

// Send runs the refusals of sendTx in its order: the participant / gone check of an existing conversation (before the
// graph read), the recipient's block and DM policy, decideSend (the request cap answered through replayOrRefuse), the
// encryption rule of an existing conversation (encGate, through replayOrRefuse), then for a new conversation the
// recipient's users doc (and, for an mls_init, the dm_new_daily counter) before encGate(nil), and finally the
// commit-time AlreadyExists replay of a message already stored under this id (f.msgs). An mls_init is applied for real
// (sendInit: the conversation, commit, welcomes and message are stored); every other success still answers from the
// scripted sendRes, as before.
func (f *fakeRepo) Send(ctx context.Context, p SendParams) (SendResult, error) {
	f.mu.Lock()
	f.sends = append(f.sends, p)
	var conv *ConvDoc
	if c, ok := f.convs[p.ConvID]; ok {
		conv = &c
	}
	f.mu.Unlock()
	if f.sendErr != nil {
		return SendResult{}, f.sendErr
	}
	// Not a participant, or a participant of a conversation whose peer is gone: refused before the graph read.
	if conv != nil && (!conv.hasParticipant(p.UID) || len(conv.Gone) > 0) {
		_, derr := decideSend(conv, p.UID, false, p.MaxUnanswered)
		return SendResult{Conv: *conv}, derr
	}
	// The transaction's reads, in the real order: the recipient's graph (block, mute, mutual), then for a new
	// conversation the recipient's users doc.
	theirs, err := p.RecipientGraphInTx(ctx, nil)
	if err != nil {
		return SendResult{}, err
	}
	if theirs.Blocked[p.UID] {
		return SendResult{}, errBlocked
	}
	if dmPolicyRefuses(conv, p.UID, p.RecipientFollowingOnly, theirs.Following[p.UID]) {
		return SendResult{}, errDMPolicy
	}
	mutual := p.CallerFollowsPeer && theirs.Following[p.UID]
	dec, derr := decideSend(conv, p.UID, mutual, p.MaxUnanswered)
	if errors.Is(derr, ErrRequestLimit) {
		return f.replayOrRefuse(p, *conv, derr)
	}
	if derr != nil {
		return SendResult{}, derr
	}
	// The encryption rule of an existing conversation, after the same refusals as sendTx, with its replay lookup.
	if conv != nil {
		if gerr := encGate(conv, p.Enc); gerr != nil {
			return f.replayOrRefuse(p, *conv, gerr)
		}
	}
	if p.Enc != nil && p.Enc.Init != nil {
		return f.sendInit(ctx, p, conv, dec, theirs)
	}
	f.mu.Lock()
	res := f.sendRes
	f.mu.Unlock()
	res.Silent, res.Mutual = theirs.Muted[p.UID], mutual
	if res.Created {
		f.freshErr = checkRecipient(p.RecipientInTx(ctx, nil))
		if f.freshErr != nil {
			return SendResult{}, f.freshErr
		}
	}
	// A new conversation: gated after its recipient check, as sendTx gates it after the recipient and quota checks.
	if conv == nil {
		if gerr := encGate(nil, p.Enc); gerr != nil {
			return SendResult{}, gerr
		}
	}
	// The commit-time AlreadyExists of the message Create.
	if rr, replayed, rerr := f.commitReplay(p, res.Conv); replayed {
		return rr, rerr
	}
	if res.Msg.CreatedAt.IsZero() {
		res.Msg = newMsgDoc(p, wireTime(p.Now))
	}
	if res.Conv.State == "" {
		res.Conv = ConvDoc{Kind: kindDirect, Participants: sortedPair(p.UID, p.PeerUID), State: stateAccepted}
		if conv != nil {
			res.Conv = *conv
		}
	}
	f.mu.Lock()
	f.lastRes = res
	f.mu.Unlock()
	return res, nil
}

// commitReplay is the commit-time AlreadyExists of the message Create: a message already stored under this id is a
// replay (the same request hash, or a taken-down message) or ErrKeyReused; replayed is false when none is stored.
func (f *fakeRepo) commitReplay(p SendParams, conv ConvDoc) (SendResult, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, row := range f.msgs[p.ConvID] {
		if row.ID != p.MsgID {
			continue
		}
		if row.State != msgRemoved && row.RequestHash != p.RequestHash {
			return SendResult{}, true, ErrKeyReused
		}
		return SendResult{Replay: true, Msg: row.MsgDoc, Conv: conv}, true, nil
	}
	return SendResult{}, false, nil
}

// fakeWelcome is one stored welcome of the fake: users/{Owner}/dmWelcomes/{ID}.
type fakeWelcome struct {
	Owner, ID string
	WelcomeDoc
}

// sendInit applies an mls_init that passed every refusal before it, as sendTx does: a new conversation checks the
// recipient's users doc and the new-conversation quota (dmNewUsed against DMNewLimit), then the welcome-device verdict
// (encGate(nil)); then the conversation becomes MLS at (1, 1) (created, or updated with the request counter or the
// accepting reply merged), the commit (1, 0) is created (an existing one fails, like Create), each device's earlier welcome
// for the conversation is replaced, and the message is stored at (1, 1).
func (f *fakeRepo) sendInit(ctx context.Context, p SendParams, conv *ConvDoc, dec sendDecision, theirs graph.Snapshot) (SendResult, error) {
	res := SendResult{Silent: theirs.Muted[p.UID], Mutual: p.CallerFollowsPeer && theirs.Following[p.UID], RecipientInRequests: dec.RecipientInRequests}
	if dec.CreateConv {
		if err := checkRecipient(p.RecipientInTx(ctx, nil)); err != nil {
			return SendResult{}, err
		}
		f.mu.Lock()
		used := f.dmNewUsed[p.UID]
		f.mu.Unlock()
		if used+1 > p.DMNewLimit {
			return SendResult{}, ErrDMNewDaily
		}
		if gerr := encGate(nil, p.Enc); gerr != nil {
			return SendResult{}, gerr
		}
	}
	now := stampAfterClear(wireTime(p.Now), conv)
	f.mu.Lock()
	defer f.mu.Unlock()
	// putInit overwrites a (1, 0) record found here field by field under its LastUpdateTime (putCommitRecord), never with
	// Set (only a leftover of an earlier conversation can be one; defence in depth). The fake simply replaces it.
	commitKey := p.ConvID + "/" + commitDocID(initGen, initEpoch)
	var next ConvDoc
	if dec.CreateConv {
		next = ConvDoc{Kind: kindDirect, Participants: sortedPair(p.UID, p.PeerUID), State: dec.State, CreatedAt: now, UpdatedAt: now}
		if dec.State == stateRequest {
			next.RequestFrom, next.RequestTo, next.RequestCount = p.UID, p.PeerUID, 1
		}
		if f.dmNewUsed == nil {
			f.dmNewUsed = map[string]int64{}
		}
		f.dmNewUsed[p.UID]++
		res.Created = true
	} else {
		next = *conv
		switch {
		case dec.IncRequest:
			next.RequestCount++
			next.UpdatedAt = now
		case dec.AcceptNow:
			next.State, next.UpdatedAt, res.AcceptedByReply = stateAccepted, now, true
		}
		next.UpdatedAt = commitStamp(now, conv.UpdatedAt) // every arm of an upgrade, as the repo
	}
	startEncryption(&next)
	f.convs[p.ConvID] = next
	if f.commits == nil {
		f.commits = map[string]CommitDoc{}
	}
	f.commits[commitKey] = CommitDoc{Data: p.Enc.Init.Commit, SenderID: p.UID, Gen: initGen, Epoch: initEpoch, CreatedAt: now, ExpireAt: now.Add(CommitRetention)}
	for _, t := range p.Enc.Init.Targets {
		f.welcomes = slices.DeleteFunc(f.welcomes, func(w fakeWelcome) bool {
			return w.Owner == t.Owner && w.ConvID == p.ConvID && w.DeviceID == t.DeviceID
		})
		f.welcomes = append(f.welcomes, fakeWelcome{Owner: t.Owner, ID: welcomeDocID(p.ConvID, initGen, initEpoch, t.DeviceID), WelcomeDoc: WelcomeDoc{
			DeviceID: t.DeviceID, ConvID: p.ConvID, Gen: initGen, Epoch: initEpoch, Data: p.Enc.Init.Welcome, CreatedAt: now, ExpireAt: now.Add(WelcomeRetention),
		}})
	}
	msg := newMsgDoc(p, now)
	if f.msgs == nil {
		f.msgs = map[string][]MessageRow{}
	}
	f.msgs[p.ConvID] = append(f.msgs[p.ConvID], MessageRow{ID: p.MsgID, MsgDoc: msg})
	res.Msg, res.Conv = msg, next
	f.lastRes = res
	return res, nil
}

// Commit runs commitTx's order over the in-memory documents: the conversation refusals (commitConvRefusal), the peer's
// in-transaction graph then the caller's cached block, the record of the target pair and retry recognition, the field
// verdict, the welcome-device check (only with device ids), the pair; then the conversation moves, the record is stored
// (an existing one is replaced, as commitTx overwrites a leftover) and each device's earlier welcome is replaced. commitErr
// fails the call before anything when set; commitCalls counts the calls. NOT atomic and it always overwrites the record:
// first-wins (one record per pair, the loser STALE_EPOCH) is proven only by the emulator tests (commit_integration_test.go).
func (f *fakeRepo) Commit(ctx context.Context, p CommitParams) (CommitResult, error) {
	f.mu.Lock()
	f.commitCalls++
	var conv *ConvDoc
	if c, ok := f.convs[p.ConvID]; ok {
		conv = &c
	}
	f.mu.Unlock()
	if f.commitErr != nil {
		return CommitResult{}, f.commitErr
	}
	peer, err := commitConvRefusal(conv, p.UID)
	if err != nil {
		return CommitResult{}, err
	}
	res := CommitResult{Conv: *conv}
	theirs, err := p.RecipientGraphInTx(ctx, nil, peer)
	if err != nil {
		return res, err
	}
	if theirs.Blocked[p.UID] {
		return res, errBlocked
	}
	blocks, err := p.CallerBlocks(ctx, peer)
	if err != nil {
		return res, err
	}
	if blocks {
		return res, errBlocked
	}
	gen, epoch := commitRecordPair(p)
	key := p.ConvID + "/" + commitDocID(gen, epoch)
	f.mu.Lock()
	var rec *CommitDoc
	if c, ok := f.commits[key]; ok {
		rec = &c
	}
	f.mu.Unlock()
	if isCommitRetry(*conv, rec, p.UID, p.Commit, gen, epoch) {
		res.Retry = true
		return res, nil
	}
	if p.FieldErr != nil {
		return res, p.FieldErr
	}
	var targets []welcomeTarget
	if len(p.DeviceIDs) > 0 {
		if targets, err = p.WelcomeTargets(ctx, peer); err != nil {
			return res, err
		}
	}
	if err := commitPairStale(*conv, p); err != nil {
		return res, err
	}
	now := wireTime(p.Now)
	next := *conv
	next.MlsGen, next.MlsEpoch = commitNextPair(p)
	next.UpdatedAt = commitStamp(now, conv.UpdatedAt)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.convs[p.ConvID] = next
	if f.commits == nil {
		f.commits = map[string]CommitDoc{}
	}
	f.commits[key] = CommitDoc{Data: p.Commit, SenderID: p.UID, Gen: gen, Epoch: epoch, CreatedAt: now, ExpireAt: now.Add(CommitRetention)}
	for _, t := range targets {
		f.welcomes = slices.DeleteFunc(f.welcomes, func(w fakeWelcome) bool {
			return w.Owner == t.Owner && w.ConvID == p.ConvID && w.DeviceID == t.DeviceID
		})
		f.welcomes = append(f.welcomes, fakeWelcome{Owner: t.Owner, ID: welcomeDocID(p.ConvID, gen, epoch, t.DeviceID), WelcomeDoc: WelcomeDoc{
			DeviceID: t.DeviceID, ConvID: p.ConvID, Gen: gen, Epoch: epoch, Data: p.Welcome, CreatedAt: now, ExpireAt: now.Add(WelcomeRetention),
		}})
	}
	res.Conv = next
	return res, nil
}

// fakeDevices is the key directory seam: the ACTIVE device ids per user; calls records the lookups (uids). registered
// adds devices that are registered but inactive (DeviceIDs answers active + registered); allCalls records DeviceIDs lookups.
type fakeDevices struct {
	mu         sync.Mutex
	active     map[string][]string
	registered map[string][]string
	calls      []string
	allCalls   []string
	err        error
}

func (f *fakeDevices) DeviceIDs(_ context.Context, uid string) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.allCalls = append(f.allCalls, uid)
	if f.err != nil {
		return nil, f.err
	}
	return append(slices.Clone(f.active[uid]), f.registered[uid]...), nil
}

func (f *fakeDevices) ActiveDeviceIDs(_ context.Context, uid string) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, uid)
	if f.err != nil {
		return nil, f.err
	}
	return slices.Clone(f.active[uid]), nil
}

// replayOrRefuse is FirestoreRepo.replayOrRefuse over f.msgs: the stored message of this key with the same request hash
// (or a taken-down one) is a replay, with another hash ErrKeyReused, and no stored message keeps the refusal.
func (f *fakeRepo) replayOrRefuse(p SendParams, conv ConvDoc, refusal error) (SendResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, row := range f.msgs[p.ConvID] {
		if row.ID != p.MsgID {
			continue
		}
		if row.State != msgRemoved && row.RequestHash != p.RequestHash {
			return SendResult{}, ErrKeyReused
		}
		return SendResult{Replay: true, Msg: row.MsgDoc, Conv: conv}, nil
	}
	return SendResult{}, refusal
}

// fakeSocial serves graph snapshots.
type fakeSocial struct {
	mu    sync.Mutex
	snaps map[string]graph.Snapshot
	calls int
	err   error
	// errFor fails the read of one uid only.
	errFor map[string]error
}

func (f *fakeSocial) Snapshot(_ context.Context, uid string) (graph.Snapshot, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if err := f.errFor[uid]; err != nil {
		return graph.Snapshot{}, err
	}
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
	devices  *fakeDevices
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
		events: &recEvents{}, badge: &recBadge{}, devices: &fakeDevices{active: map[string][]string{}}, now: time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC),
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
		Repo: r.repo, Social: r.social, TxSocial: r.txSocial, TxProfiles: r.txProfs, AllowAnonymous: r.allowAnon, Profiles: r.profs, Events: r.events, Badge: r.badge, Devices: r.devices, Limits: r.limits, CursorKey: testCursorKey, Now: func() time.Time { return r.now },
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
// themselves (L-8). A context without claims is refused with EMAIL_NOT_VERIFIED.
func verifiedCtx() context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{SignInProvider: authn.SignInProviderGoogle})
}
