//go:build integration

package apiserver

// The whole encrypted-conversation feature as one narrative over the real Build chain on the emulators, through real
// Connect clients, with opaque bytes for every MLS record (the server never parses them): key devices, mls_init, the
// welcome inbox, a commit that adds a device, STALE_EPOCH and the catch-up list, commit retry recognition, a reset, a
// verified and an unverified report (raw evidence documents hold no secret), a takedown tombstone, ENCRYPTION_REQUIRED,
// e2ee_dm off for the recipient on a second instance over the same data, and a final scan of every log line both
// instances wrote for every marker the test used. Every expected answer is the contract's (messaging.proto,
// keys.proto, moderation.proto message_payload).

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/encoding/protowire"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// Device ids and byte markers: every one is unique to this test, so the final log scan is meaningful.
const (
	zqDevA      = "zqdev-chain-alice-0001"
	zqDevB1     = "zqdev-chain-bob-phone-01"
	zqDevB2     = "zqdev-chain-bob-tablet-2"
	zqDevFresh  = "zqdev-chain-fresh-bob-03"
	zqPushDevB  = "zqpush-chain-bob-000001"
	zqPushToken = "zqfcm-chain-bob-token-000001"
)

// zqReportKey is the report key inside every MessageContent of this test (32 bytes): never stored, never logged.
var zqReportKey = []byte("zqkey-chain-0123456789abcdef0123")

// encMsg is one encrypted message as a device would build it: the MessageContent bytes, the ciphertext and the
// commitment over the content.
type encMsg struct {
	text    string
	payload []byte
	ct      []byte
	sum     [32]byte
}

func newEncMsg(tag string) encMsg {
	text := "zqtxt-chain-" + tag
	var p []byte
	p = protowire.AppendTag(p, 3, protowire.BytesType)
	p = protowire.AppendBytes(p, zqReportKey)
	p = protowire.AppendTag(p, 1, protowire.BytesType)
	p = protowire.AppendString(p, text)
	return encMsg{text: text, payload: p, ct: []byte("zqct-chain-" + tag), sum: messaging.ReportCommitment(p)}
}

// req is an encrypted SendMessage of m at (gen, epoch) into conv (by conversation id).
func (m encMsg) req(key, conv string, gen, epoch uint64) *messagingv1.SendMessageRequest {
	return &messagingv1.SendMessageRequest{
		IdempotencyKey: key, Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: conv},
		Ciphertext: m.ct, ReportCommitment: m.sum[:], MlsGeneration: gen, MlsEpoch: epoch,
	}
}

// wantStale asserts STALE_EPOCH with the current pair in metadata (and conversation_id when conv is not empty).
func wantStale(t *testing.T, err error, gen, epoch uint64, conv string) {
	t.Helper()
	d := wireError(t, err, connect.CodeFailedPrecondition)
	md := d.GetMetadata()
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH || md["generation"] != strconv.FormatUint(gen, 10) || md["epoch"] != strconv.FormatUint(epoch, 10) {
		t.Errorf("STALE_EPOCH: reason %v metadata %v, want the pair (%d, %d)", d.GetReason(), md, gen, epoch)
	}
	if conv != "" && md["conversation_id"] != conv {
		t.Errorf("STALE_EPOCH metadata conversation_id = %q, want %q", md["conversation_id"], conv)
	}
}

func findMsg(ms []*messagingv1.Message, id string) (*messagingv1.Message, int) {
	var found *messagingv1.Message
	n := 0
	for _, m := range ms {
		if m.GetId() == id {
			found = m
			n++
		}
	}
	return found, n
}

func (e *dmChain) commitDocs(t *testing.T, conv string) []string {
	t.Helper()
	docs, err := e.fs.Collection("conversations").Doc(conv).Collection("commits").Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]string, 0, len(docs))
	for _, d := range docs {
		ids = append(ids, d.Ref.ID)
	}
	sort.Strings(ids)
	return ids
}

// logRecords parses every JSON line a chain logged.
func (e *dmChain) logRecords() []map[string]any {
	var out []map[string]any
	for _, line := range strings.Split(e.logText(), "\n") {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) == nil {
			out = append(out, rec)
		}
	}
	return out
}

func TestMessagingE2EEChain_EndToEnd(t *testing.T) {
	skipIfNoEmulators(t)
	ctx := context.Background()
	mint := func() dmUser { tok, uid := mintToken(t, ""); return dmUser{tok, uid} }
	// Everyone is minted first: the allowlists are fixed when an instance is built. a and b hold the conversation, c is
	// an outsider, a2 and b2 are a fresh pair for the flag-off step, x blocks a2.
	a, b, c, a2, b2, x := mint(), mint(), mint(), mint(), mint(), mint()
	allowAll := map[string]struct{}{a.uid: {}, b.uid: {}, c.uid: {}, a2.uid: {}, b2.uid: {}, x.uid: {}}

	// Instance 1: messaging, reports, notifications on; e2ee_dm on for all six; inline notification delivery with the
	// emitter handed back so the push can be awaited, never polled.
	var inline *notifications.InlineEmitter
	env := newChainWith(t, func(cf *config.Config) {
		messagingOn(cf)
		reportsOn(cf)
		cf.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: allowAll}
		cf.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
		cf.NotificationsDelivery = "inline"
	}, nil, func(o *buildOpts) { o.inlineNotifications = func(em *notifications.InlineEmitter) { inline = em } })
	if inline == nil {
		t.Fatal("the chain did not wire the inline emitter")
	}
	e := &dmChain{
		chainEnv: env,
		msg:      messagingv1connect.NewMessagingServiceClient(http.DefaultClient, env.url),
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url),
	}
	keys := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)
	notifs := notificationsv1connect.NewNotificationServiceClient(http.DefaultClient, e.url)
	for _, u := range []dmUser{a, b, c, a2, b2, x} {
		e.createProfile(t, u.token)
	}
	e.mutual(t, a, b)
	e.mutual(t, a2, b2)
	conv := messaging.ConversationID(a.uid, b.uid)
	register := func(k keysv1connect.KeyServiceClient, u dmUser, dev string) {
		t.Helper()
		if _, err := k.RegisterKeyDevice(ctx, authed(u.token, &keysv1.RegisterKeyDeviceRequest{
			IdempotencyKey: contractKey("e2ee-chain-reg"), DeviceId: dev, SignaturePublicKey: bytes.Repeat([]byte{9}, 32),
		})); err != nil {
			t.Fatalf("RegisterKeyDevice %s: %v", dev, err)
		}
	}
	commit := func(who dmUser, gen, epoch uint64, commitB, welcome []byte, devs []string, reset bool) (*messagingv1.CommitConversationResponse, error) {
		r, err := e.msg.CommitConversation(ctx, authed(who.token, &messagingv1.CommitConversationRequest{
			IdempotencyKey: contractKey("e2ee-chain-commit"), ConversationId: conv, MlsGeneration: gen, MlsEpoch: epoch,
			Commit: commitB, Welcome: welcome, WelcomeDeviceIds: devs, Reset_: reset,
		}))
		if err != nil {
			return nil, err
		}
		return r.Msg, nil
	}
	listCommits := func(who dmUser, ag, ae uint64) *messagingv1.ListConversationCommitsResponse {
		t.Helper()
		r, err := e.msg.ListConversationCommits(ctx, authed(who.token, &messagingv1.ListConversationCommitsRequest{ConversationId: conv, AfterGeneration: ag, AfterEpoch: ae}))
		if err != nil {
			t.Fatalf("ListConversationCommits: %v", err)
		}
		return r.Msg
	}
	listWelcomes := func(who dmUser, dev string) ([]*messagingv1.Welcome, error) {
		r, err := e.msg.ListWelcomes(ctx, authed(who.token, &messagingv1.ListWelcomesRequest{DeviceId: dev}))
		if err != nil {
			return nil, err
		}
		return r.Msg.GetWelcomes(), nil
	}
	epochMsgs := func(ch *dmChain, who dmUser, gen, epoch uint64) []*messagingv1.Message {
		t.Helper()
		r, err := ch.msg.ListEpochMessages(ctx, authed(who.token, &messagingv1.ListEpochMessagesRequest{ConversationId: conv, MlsGeneration: gen, MlsEpoch: epoch}))
		if err != nil {
			t.Fatalf("ListEpochMessages (%d, %d): %v", gen, epoch, err)
		}
		return r.Msg.GetMessages()
	}
	thread := func(ch *dmChain, who dmUser) []*messagingv1.Message {
		t.Helper()
		r, err := ch.msg.ListMessages(ctx, authed(who.token, &messagingv1.ListMessagesRequest{ConversationId: conv, PageSize: 50}))
		if err != nil {
			t.Fatalf("ListMessages: %v", err)
		}
		return r.Msg.GetMessages()
	}
	send := func(ch *dmChain, who dmUser, r *messagingv1.SendMessageRequest) (*messagingv1.SendMessageResponse, error) {
		res, err := ch.msg.SendMessage(ctx, authed(who.token, r))
		if err != nil {
			return nil, err
		}
		return res.Msg, nil
	}

	// --- 1. Key devices: both users register and upload; a looks up b (peer timestamps and counts absent). ---------
	register(keys, a, zqDevA)
	register(keys, b, zqDevB1)
	for _, d := range []struct {
		u   dmUser
		dev string
	}{{a, zqDevA}, {b, zqDevB1}} {
		up, err := keys.UploadKeyPackages(ctx, authed(d.u.token, &keysv1.UploadKeyPackagesRequest{
			IdempotencyKey: contractKey("e2ee-chain-up"), DeviceId: d.dev, KeyPackages: [][]byte{[]byte("zqkp-chain-" + d.dev)}, LastResortKeyPackage: []byte("zqkplr-chain-" + d.dev),
		}))
		if err != nil || up.Msg.GetKeyPackageCount() != 1 || !up.Msg.GetHasLastResort() {
			t.Fatalf("UploadKeyPackages %s = %v, %v", d.dev, up, err)
		}
	}
	look, err := keys.GetKeyDevices(ctx, authed(a.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{b.uid}}))
	if err != nil || len(look.Msg.GetUsers()) != 1 || len(look.Msg.GetUsers()[0].GetDevices()) != 1 {
		t.Fatalf("a's lookup of b = %v, %v", look, err)
	}
	if d := look.Msg.GetUsers()[0].GetDevices()[0]; d.GetDeviceId() != zqDevB1 || d.GetCreatedAt() != nil || d.GetLastSeenAt() != nil || d.GetKeyPackageCount() != 0 || d.GetHasLastResort() {
		t.Errorf("b's device as a sees it = %v, want the id and key only", d)
	}

	// --- 2. mls_init: a starts encryption with b, welcoming b's device. ------------------------------------------
	if _, err := notifs.RegisterDevice(ctx, authed(b.token, &notificationsv1.RegisterDeviceRequest{
		IdempotencyKey: contractKey("e2ee-chain-push"), DeviceId: zqPushDevB, FcmToken: zqPushToken, Platform: notificationsv1.DevicePlatform_DEVICE_PLATFORM_ANDROID,
	})); err != nil {
		t.Fatalf("RegisterDevice (push): %v", err)
	}
	mInit := newEncMsg("init-11")
	initCommit, initWelcome := []byte("zqcommit-chain-init-10"), []byte("zqwelcome-chain-init-10")
	initReq := mInit.req(contractKey("e2ee-chain-init"), "", 1, 1)
	initReq.Target = &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: b.uid}
	initReq.MlsInit = &messagingv1.MlsInit{Commit: initCommit, Welcome: initWelcome, WelcomeDeviceIds: []string{zqDevB1}}
	initRes, err := send(e, a, initReq)
	if err != nil {
		t.Fatalf("mls_init: %v", err)
	}
	if cv := initRes.GetConversation(); cv.GetId() != conv || cv.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_MLS || cv.GetMlsGeneration() != 1 || cv.GetMlsEpoch() != 1 {
		t.Fatalf("conversation after mls_init = %v", cv)
	}
	idInit := initRes.GetMessage().GetId()
	if m := initRes.GetMessage(); !bytes.Equal(m.GetCiphertext(), mInit.ct) || !bytes.Equal(m.GetReportCommitment(), mInit.sum[:]) || m.GetMlsGeneration() != 1 || m.GetMlsEpoch() != 1 || m.GetText() != "" || m.GetCiphertextRemoved() || !m.GetFromSelf() {
		t.Errorf("returned message = %v", m)
	}
	for _, u := range []dmUser{a, b} {
		l, err := e.msg.ListConversations(ctx, authed(u.token, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX}))
		if err != nil || len(l.Msg.GetConversations()) != 1 {
			t.Fatalf("%s's inbox = %v, %v", u.uid, l, err)
		}
		if p := l.Msg.GetConversations()[0].GetLastMessage(); !p.GetEncrypted() || p.GetSnippet() != "" || p.GetSharedPost() {
			t.Errorf("preview = %v, want encrypted with an empty snippet", p)
		}
	}
	// The push: one generic `message` push to b's registered token (LogSender in this chain), its log line carrying
	// only the type and two hashes. Wait for every delivery the send started.
	inline.Wait()
	var pushes []map[string]any
	for _, rec := range e.logRecords() {
		if rec["msg"] == "notification_push_local" && rec["type"] == "message" {
			pushes = append(pushes, rec)
		}
	}
	if len(pushes) != 1 {
		t.Fatalf("message pushes after mls_init = %v, want one", pushes)
	}
	for k := range pushes[0] {
		switch k {
		case "time", "level", "msg", "type", "row_hash", "token_hash":
		default:
			t.Errorf("the push line carries %q = %v", k, pushes[0][k])
		}
	}

	// --- 3. b's welcome inbox: one welcome labelled (1, 0); a's device is not b's; ack; a second ack is a no-op. ---
	wl, err := listWelcomes(b, zqDevB1)
	if err != nil || len(wl) != 1 {
		t.Fatalf("b's welcomes = %v, %v", wl, err)
	}
	if w := wl[0]; w.GetConversationId() != conv || w.GetMlsGeneration() != 1 || w.GetMlsEpoch() != 0 || !bytes.Equal(w.GetWelcome(), initWelcome) {
		t.Errorf("welcome = %v, want conv (1, 0) with the init welcome", w)
	}
	_, err = listWelcomes(b, zqDevA)
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "device_id")
	for i := 0; i < 2; i++ {
		if _, err := e.msg.AckWelcomes(ctx, authed(b.token, &messagingv1.AckWelcomesRequest{IdempotencyKey: contractKey("e2ee-chain-ack"), DeviceId: zqDevB1, Ids: []string{wl[0].GetId()}})); err != nil {
			t.Fatalf("AckWelcomes #%d: %v", i+1, err)
		}
		if left, err := listWelcomes(b, zqDevB1); err != nil || len(left) != 0 {
			t.Fatalf("after ack #%d = %v, %v", i+1, left, err)
		}
	}

	// --- 4. b reads the ciphertext; epoch (1, 1) lists the message exactly once. ---------------------------------
	if m, n := findMsg(thread(e, b), idInit); n != 1 || !bytes.Equal(m.GetCiphertext(), mInit.ct) || !bytes.Equal(m.GetReportCommitment(), mInit.sum[:]) || m.GetFromSelf() {
		t.Errorf("b's ListMessages: %d copies, %v", n, m)
	}
	if ms := epochMsgs(e, b, 1, 1); len(ms) != 1 || ms[0].GetId() != idInit || !bytes.Equal(ms[0].GetCiphertext(), mInit.ct) {
		t.Errorf("epoch (1, 1) = %v", ms)
	}

	// --- 5. b adds a second device by a commit on (1, 1); a's send on (1, 1) is STALE_EPOCH; a catches up. -------
	register(keys, b, zqDevB2)
	bCommit, bWelcome := []byte("zqcommit-chain-b-add-11"), []byte("zqwelcome-chain-b-add-11")
	cr, err := commit(b, 1, 1, bCommit, bWelcome, []string{zqDevB2}, false)
	if err != nil || cr.GetMlsGeneration() != 1 || cr.GetMlsEpoch() != 2 {
		t.Fatalf("b's commit = %v, %v, want (1, 2)", cr, err)
	}
	if wl, err := listWelcomes(b, zqDevB2); err != nil || len(wl) != 1 || wl[0].GetMlsGeneration() != 1 || wl[0].GetMlsEpoch() != 1 || !bytes.Equal(wl[0].GetWelcome(), bWelcome) {
		t.Errorf("the tablet's welcome = %v, %v, want (1, 1)", wl, err)
	}
	before := e.messageCount(t, a, b)
	mStale := newEncMsg("stale-11")
	_, err = send(e, a, mStale.req(contractKey("e2ee-chain-stale"), conv, 1, 1))
	wantStale(t, err, 1, 2, "")
	// The same stale send addressed by recipient also names the conversation (SendMessage comment).
	byRecipient := mStale.req(contractKey("e2ee-chain-stale-r"), "", 1, 1)
	byRecipient.Target = &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: b.uid}
	_, err = send(e, a, byRecipient)
	wantStale(t, err, 1, 2, conv)
	if n := e.messageCount(t, a, b); n != before {
		t.Errorf("STALE_EPOCH stored a message: %d -> %d", before, n)
	}
	// a created the group by mls_init, so its after-pair is (1, 0) (exclusive): the one commit after it is b's.
	cs := listCommits(a, 1, 0)
	if len(cs.GetCommits()) != 1 || cs.GetMore() || cs.GetMlsGeneration() != 1 || cs.GetMlsEpoch() != 2 {
		t.Fatalf("a's catch-up from (1, 0) = %v", cs)
	}
	if cm := cs.GetCommits()[0]; cm.GetMlsGeneration() != 1 || cm.GetMlsEpoch() != 1 || cm.GetFromSelf() || !bytes.Equal(cm.GetCommit(), bCommit) {
		t.Errorf("commit = %v, want b's (1, 1), from_self false", cm)
	}
	if all := listCommits(a, 0, 0); len(all.GetCommits()) != 2 || !all.GetCommits()[0].GetFromSelf() || !bytes.Equal(all.GetCommits()[0].GetCommit(), initCommit) || all.GetCommits()[0].GetMlsEpoch() != 0 {
		t.Errorf("everything from (0, 0) = %v, want a's init (1, 0) then b's (1, 1)", all)
	}
	// Re-encrypted at (1, 2), sent under a NEW idempotency key.
	m12 := newEncMsg("msg-12")
	r12, err := send(e, a, m12.req(contractKey("e2ee-chain-12"), conv, 1, 2))
	if err != nil || r12.GetMessage().GetMlsGeneration() != 1 || r12.GetMessage().GetMlsEpoch() != 2 {
		t.Fatalf("send at (1, 2) = %v, %v", r12, err)
	}
	id12 := r12.GetMessage().GetId()
	if n := e.messageCount(t, a, b); n != before+1 {
		t.Errorf("messages after the send at (1, 2): %d, want %d", n, before+1)
	}

	// --- 6. b's commit retried with identical bytes: the current pair, no second record; other bytes: STALE. -----
	commitsBefore := e.commitDocs(t, conv)
	if len(commitsBefore) != 2 {
		t.Fatalf("commit records = %v, want (1, 0) and (1, 1)", commitsBefore)
	}
	if rr, err := commit(b, 1, 1, bCommit, bWelcome, []string{zqDevB2}, false); err != nil || rr.GetMlsGeneration() != 1 || rr.GetMlsEpoch() != 2 {
		t.Errorf("b's retry = %v, %v, want success (1, 2)", rr, err)
	}
	for _, who := range []dmUser{b, a} {
		_, err := commit(who, 1, 1, []byte("zqcommit-chain-other-11-"+who.uid[:4]), nil, nil, false)
		wantStale(t, err, 1, 2, "")
	}
	if got := e.commitDocs(t, conv); strings.Join(got, ",") != strings.Join(commitsBefore, ",") {
		t.Errorf("commit records after the retry and the refusals = %v, want %v", got, commitsBefore)
	}

	// --- 7. A reset by a (generation 1, one b device) -> (2, 1); old-generation send and a stale reset refused. ---
	resetCommit, resetWelcome := []byte("zqcommit-chain-a-reset-g1"), []byte("zqwelcome-chain-a-reset-g1")
	rs, err := commit(a, 1, 0, resetCommit, resetWelcome, []string{zqDevB1}, true)
	if err != nil || rs.GetMlsGeneration() != 2 || rs.GetMlsEpoch() != 1 {
		t.Fatalf("reset = %v, %v, want (2, 1)", rs, err)
	}
	mOld := newEncMsg("old-gen-12")
	_, err = send(e, a, mOld.req(contractKey("e2ee-chain-oldgen"), conv, 1, 2))
	wantStale(t, err, 2, 1, "")
	_, err = commit(a, 1, 0, []byte("zqcommit-chain-a-reset-g1-again"), resetWelcome, []string{zqDevB1}, true)
	wantStale(t, err, 2, 1, "")
	if rr, err := commit(a, 1, 0, resetCommit, resetWelcome, []string{zqDevB1}, true); err != nil || rr.GetMlsGeneration() != 2 || rr.GetMlsEpoch() != 1 {
		t.Errorf("reset retried with identical bytes = %v, %v, want success (2, 1)", rr, err)
	}
	cs = listCommits(a, 1, 0)
	if len(cs.GetCommits()) != 2 || cs.GetMlsGeneration() != 2 || cs.GetMlsEpoch() != 1 {
		t.Fatalf("a's catch-up across the reset = %v", cs)
	}
	for i, want := range []struct {
		gen, epoch uint64
		fromSelf   bool
		bytes      []byte
	}{{1, 1, false, bCommit}, {2, 0, true, resetCommit}} {
		if cm := cs.GetCommits()[i]; cm.GetMlsGeneration() != want.gen || cm.GetMlsEpoch() != want.epoch || cm.GetFromSelf() != want.fromSelf || !bytes.Equal(cm.GetCommit(), want.bytes) {
			t.Errorf("commit %d = %v, want (%d, %d) from_self %v", i, cm, want.gen, want.epoch, want.fromSelf)
		}
	}
	if wl, err := listWelcomes(b, zqDevB1); err != nil || len(wl) != 1 || wl[0].GetMlsGeneration() != 2 || wl[0].GetMlsEpoch() != 0 || !bytes.Equal(wl[0].GetWelcome(), resetWelcome) {
		t.Errorf("b's phone after the reset = %v, %v, want one welcome (2, 0)", wl, err)
	}
	// Epoch (1, 2) is closed by the reset: its list is complete.
	if ms := epochMsgs(e, b, 1, 2); len(ms) != 1 || ms[0].GetId() != id12 {
		t.Errorf("epoch (1, 2) = %v, want the one message", ms)
	}

	// --- 8. Reports: verified, one byte changed (unverified), raw evidence holds no secret, an outsider's refusal. -
	m21 := newEncMsg("msg-21")
	r21, err := send(e, a, m21.req(contractKey("e2ee-chain-21"), conv, 2, 1))
	if err != nil {
		t.Fatalf("send at (2, 1): %v", err)
	}
	id21 := r21.GetMessage().GetId()
	ver, err := e.reportWith(b, conv, idInit, mInit.payload)
	if err != nil || ver.GetAlreadyReported() {
		t.Fatalf("verified report = %v, %v", ver, err)
	}
	changed := append([]byte(nil), m12.payload...)
	changed[len(changed)-1] ^= 1
	unv, err := e.reportWith(b, conv, id12, changed)
	if err != nil || unv.GetAlreadyReported() {
		t.Fatalf("unverified report = %v, %v", unv, err)
	}
	changedText := m12.text[:len(m12.text)-1] + string(m12.text[len(m12.text)-1]^1)
	for _, rc := range []struct {
		id, text string
		verified any
	}{{ver.GetReportId(), mInit.text, true}, {unv.GetReportId(), changedText, nil}} {
		parent, child := e.storedReport(t, rc.id)
		if child["encrypted"] != true || child["verified"] != rc.verified || child["text"] != rc.text {
			t.Errorf("evidence of %s = %v, want encrypted, verified %v, text %q", rc.id, child, rc.verified, rc.text)
		}
		secrets := [][]byte{zqReportKey, mInit.payload, m12.payload, changed, mInit.ct, m12.ct, mInit.sum[:], m12.sum[:]}
		for _, v := range [][]byte{zqReportKey, mInit.payload, m12.payload, changed, mInit.sum[:], m12.sum[:]} {
			secrets = append(secrets, []byte(base64.StdEncoding.EncodeToString(v)), []byte(base64.RawURLEncoding.EncodeToString(v)), []byte(hex.EncodeToString(v)))
		}
		noSecretBytes(t, "reports/"+rc.id, parent, secrets...)
		noSecretBytes(t, "reports/"+rc.id+"/evidence/message", child, secrets...)
	}
	_, withPayload := e.reportWith(c, conv, id21, m21.payload)
	_, withoutPayload := e.reportWith(c, conv, id21, nil)
	wireError(t, withPayload, connect.CodeNotFound)
	if wireBytes(t, withPayload) != wireBytes(t, withoutPayload) {
		t.Errorf("an outsider with a payload %v / without %v differ", withPayload, withoutPayload)
	}

	// --- 9. Takedown of a's (2, 1) message: a tombstone with no bytes in ListMessages and in its epoch. ----------
	if tr, err := messaging.NewFirestoreRepo(e.fs, nil).TakedownMessage(ctx, conv, id21, false); err != nil || !tr.Wrote {
		t.Fatalf("takedown = %+v, %v", tr, err)
	}
	tombstone := func(where string, m *messagingv1.Message, n int) {
		t.Helper()
		if n != 1 || m.GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED || !m.GetCiphertextRemoved() || len(m.GetCiphertext()) != 0 || len(m.GetReportCommitment()) != 0 || m.GetText() != "" || m.GetMlsGeneration() != 2 || m.GetMlsEpoch() != 1 {
			t.Errorf("%s: %d copies, %v, want one REMOVED tombstone at (2, 1) without bytes", where, n, m)
		}
	}
	for _, u := range []dmUser{a, b} {
		ms := thread(e, u)
		m, n := findMsg(ms, id21)
		tombstone("ListMessages", m, n)
		if other, _ := findMsg(ms, id12); !bytes.Equal(other.GetCiphertext(), m12.ct) {
			t.Errorf("an untouched message lost its ciphertext: %v", other)
		}
	}
	m, n := findMsg(epochMsgs(e, b, 2, 1), id21)
	tombstone("ListEpochMessages (2, 1)", m, n)

	// --- 10. A plaintext send into the MLS conversation: ENCRYPTION_REQUIRED, nothing stored. --------------------
	before = e.messageCount(t, a, b)
	_, err = e.send(a, b, contractKey("e2ee-chain-plain"), "zqplain-chain-refused-by-recipient")
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, "conversation_id", conv)
	_, err = send(e, b, &messagingv1.SendMessageRequest{IdempotencyKey: contractKey("e2ee-chain-plain2"), Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: conv}, Text: "zqplain-chain-refused-by-conv"})
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, "", "")
	if n := e.messageCount(t, a, b); n != before {
		t.Errorf("a refused plaintext send stored a message: %d -> %d", before, n)
	}

	// --- 11. e2ee_dm off for b (and the fresh b2) on a second instance over the same data. -----------------------
	register(keys, b2, zqDevFresh) // while b2 still has the flag on instance 1
	off := newDMChain(t, func(cf *config.Config) {
		cf.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: map[string]struct{}{a.uid: {}, a2.uid: {}, x.uid: {}, c.uid: {}}}
	})
	offKeys := keysv1connect.NewKeyServiceClient(http.DefaultClient, off.url)
	off.block(t, x, a2)
	initTo := func(to dmUser) *messagingv1.SendMessageRequest {
		m := newEncMsg("fresh-init")
		r := m.req(contractKey("e2ee-chain-fresh"), "", 1, 1)
		r.Target = &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: to.uid}
		r.MlsInit = &messagingv1.MlsInit{Commit: []byte("zqcommit-chain-fresh"), Welcome: []byte("zqwelcome-chain-fresh"), WelcomeDeviceIds: []string{zqDevFresh}}
		return r
	}
	_, flagOff := send(off, a2, initTo(b2))
	wantReason(t, flagOff, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "", "")
	_, blockedInit := send(off, a2, initTo(x))
	_, blockedPlain := off.send(a2, x, contractKey("e2ee-chain-blocked"), "zqplain-chain-to-blocker")
	if wireBytes(t, flagOff) != wireBytes(t, blockedInit) || wireBytes(t, flagOff) != wireBytes(t, blockedPlain) {
		t.Errorf("flag off for the recipient %v differs from a block %v / %v", flagOff, blockedInit, blockedPlain)
	}
	if _, exists := off.convDoc(t, a2, b2); exists {
		t.Error("the refused mls_init created a conversation")
	}
	// The existing encrypted conversation keeps working for both, at the current pair (2, 1).
	var offIDs []string
	for _, s := range []struct {
		who dmUser
		tag string
	}{{a, "off-a-21"}, {b, "off-b-21"}} {
		om := newEncMsg(s.tag)
		r, err := send(off, s.who, om.req(contractKey("e2ee-chain-"+s.tag), conv, 2, 1))
		if err != nil {
			t.Fatalf("%s's encrypted send with b off e2ee_dm: %v", s.tag, err)
		}
		offIDs = append(offIDs, r.GetMessage().GetId())
	}
	for _, u := range []dmUser{a, b} {
		ms := thread(off, u)
		for _, id := range offIDs {
			if _, n := findMsg(ms, id); n != 1 {
				t.Errorf("%s's thread on the flag-off instance lacks %s", u.uid, id)
			}
		}
	}
	// keys.v1: b's devices vanish from a's lookup (an empty success); b cannot look anyone up.
	if look, err := offKeys.GetKeyDevices(ctx, authed(a.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{b.uid}})); err != nil || len(look.Msg.GetUsers()) != 1 || len(look.Msg.GetUsers()[0].GetDevices()) != 0 {
		t.Errorf("a's lookup of b with b off = %v, %v, want an empty success", look, err)
	}
	_, err = offKeys.GetKeyDevices(ctx, authed(b.token, &keysv1.GetKeyDevicesRequest{UserIds: []string{a.uid}}))
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "e2ee_dm")

	// --- 12. Privacy sweep: no instance logged a marker, a device id, a uid or any byte value in any encoding. ----
	inline.Wait()
	markers := []string{"zqtxt-chain", "zqct-chain", "zqcommit-chain", "zqwelcome-chain", "zqkp-chain", "zqkplr-chain", "zqplain-chain", "zqkey-chain", "zqdev-chain", "zqpush-chain", "zqfcm-chain",
		zqDevA, zqDevB1, zqDevB2, zqDevFresh, zqPushDevB, zqPushToken, a.uid, b.uid, c.uid, a2.uid, b2.uid, x.uid}
	byteValues := [][]byte{zqReportKey, mInit.payload, m12.payload, m21.payload, changed, mInit.sum[:], m12.sum[:], m21.sum[:], mInit.ct, m12.ct, m21.ct, initCommit, initWelcome, bCommit, bWelcome, resetCommit, resetWelcome}
	for _, v := range byteValues {
		markers = append(markers, base64.StdEncoding.EncodeToString(v), base64.RawURLEncoding.EncodeToString(v), hex.EncodeToString(v))
	}
	for name, ch := range map[string]*dmChain{"instance 1": e, "flag-off instance": off} {
		all := ch.logText()
		if all == "" {
			t.Fatalf("%s logged nothing: the scan would prove nothing", name)
		}
		for _, mk := range markers {
			if strings.Contains(all, mk) {
				t.Errorf("%s's log contains %q", name, mk)
			}
		}
	}
}
