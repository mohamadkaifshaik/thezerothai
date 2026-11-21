package messaging

// Unit tests of the MLS sync RPCs (service_sync.go), the reset cap and the encrypted fields of the read answers.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/reflect/protoreflect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// mlsConv stores the alice-bob conversation as MLS at (gen, epoch), created an hour before the rig's clock.
func (r *rig) mlsConv(gen, epoch int64) ConvDoc {
	c := ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted, Encryption: encMLS, MlsGen: gen, MlsEpoch: epoch,
		CreatedAt: r.now.Add(-time.Hour)}
	r.repo.convs[aliceBobConv] = c
	return c
}

// putCommit stores a commit record of the alice-bob conversation built on (gen, epoch), created at "at".
func (r *rig) putCommit(gen, epoch int64, sender string, at time.Time) {
	if r.repo.commits == nil {
		r.repo.commits = map[string]CommitDoc{}
	}
	r.repo.commits[aliceBobConv+"/"+commitDocID(gen, epoch)] = CommitDoc{
		Data: []byte(fmt.Sprintf("commit %d:%d", gen, epoch)), SenderID: sender, Gen: gen, Epoch: epoch, CreatedAt: at, ExpireAt: at.Add(CommitRetention),
	}
}

func pairsOf(resp *messagingv1.ListConversationCommitsResponse) []string {
	var out []string
	for _, c := range resp.GetCommits() {
		out = append(out, fmt.Sprintf("%d:%d", c.GetMlsGeneration(), c.GetMlsEpoch()))
	}
	return out
}

func wantValidation(t *testing.T, err error, field string) {
	t.Helper()
	code, reason, meta := reasonOf(t, err)
	if code != connect.CodeInvalidArgument || reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || meta["field"] != field {
		t.Fatalf("err = %v (%v %v %v), want VALIDATION %s", err, code, reason, meta, field)
	}
}

func TestListCommits_OrderAcrossAResetPagingAndFromSelf(t *testing.T) {
	r := newRig(t, nil)
	r.mlsConv(2, 2)
	at := r.now.Add(-30 * time.Minute)
	// Generation 1: init (1, 0) by alice, commits (1, 1) by bob, (1, 2) by alice; a reset (2, 0) by bob, then (2, 1) by alice.
	for _, p := range []struct {
		g, e   int64
		sender string
	}{{1, 0, alice}, {1, 1, bob}, {1, 2, alice}, {2, 0, bob}, {2, 1, alice}} {
		r.putCommit(p.g, p.e, p.sender, at)
		at = at.Add(time.Minute)
	}
	ctx := context.Background()
	all, err := r.svc.ListCommits(ctx, alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv})
	if err != nil {
		t.Fatal(err)
	}
	if got := pairsOf(all); !slices.Equal(got, []string{"1:0", "1:1", "1:2", "2:0", "2:1"}) {
		t.Fatalf("commits = %v", got)
	}
	if all.GetMore() || all.GetMlsGeneration() != 2 || all.GetMlsEpoch() != 2 {
		t.Errorf("more = %v pair = (%d, %d), want false (2, 2)", all.GetMore(), all.GetMlsGeneration(), all.GetMlsEpoch())
	}
	for _, c := range all.GetCommits() {
		wantSelf := map[string]bool{"1:0": true, "1:2": true, "2:1": true}[fmt.Sprintf("%d:%d", c.GetMlsGeneration(), c.GetMlsEpoch())]
		if c.GetFromSelf() != wantSelf || !bytes.Equal(c.GetCommit(), []byte(fmt.Sprintf("commit %d:%d", c.GetMlsGeneration(), c.GetMlsEpoch()))) {
			t.Errorf("commit (%d, %d): from_self %v bytes %q", c.GetMlsGeneration(), c.GetMlsEpoch(), c.GetFromSelf(), c.GetCommit())
		}
	}
	// from_self is per user: bob sees the opposite.
	other, _ := r.svc.ListCommits(ctx, bob, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv})
	for i, c := range other.GetCommits() {
		if c.GetFromSelf() == all.GetCommits()[i].GetFromSelf() {
			t.Errorf("commit %d: from_self is the same for both users", i)
		}
	}
	// Strictly after the after pair; across the generation change.
	after, _ := r.svc.ListCommits(ctx, alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv, AfterGeneration: 1, AfterEpoch: 1})
	if got := pairsOf(after); !slices.Equal(got, []string{"1:2", "2:0", "2:1"}) {
		t.Errorf("after (1, 1) = %v", got)
	}
	// Pages of 2: a full page is more = true; the next call starts after the last returned pair.
	var seen []string
	g, e := uint64(0), uint64(0)
	for range 5 {
		p, err := r.svc.ListCommits(ctx, alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv, AfterGeneration: g, AfterEpoch: e, PageSize: 2})
		if err != nil {
			t.Fatal(err)
		}
		seen = append(seen, pairsOf(p)...)
		if !p.GetMore() {
			break
		}
		last := p.GetCommits()[len(p.GetCommits())-1]
		g, e = last.GetMlsGeneration(), last.GetMlsEpoch()
	}
	if !slices.Equal(seen, pairsOf(all)) {
		t.Errorf("paged = %v, want %v", seen, pairsOf(all))
	}
	// After the last record: nothing, the current pair still answered.
	end, _ := r.svc.ListCommits(ctx, alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv, AfterGeneration: 2, AfterEpoch: 1})
	if len(end.GetCommits()) != 0 || end.GetMore() || end.GetMlsGeneration() != 2 || end.GetMlsEpoch() != 2 {
		t.Errorf("after the last = %v", end)
	}
}

func TestListCommits_PageSizeClamp(t *testing.T) {
	r := newRig(t, nil)
	r.mlsConv(1, 61)
	for e := range int64(61) {
		r.putCommit(1, e, alice, r.now.Add(-time.Minute))
	}
	for _, tt := range []struct {
		size int32
		want int
	}{{0, 20}, {-3, 20}, {7, 7}, {50, 50}, {51, 50}, {1000, 50}} {
		p, err := r.svc.ListCommits(context.Background(), alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv, PageSize: tt.size})
		if err != nil || len(p.GetCommits()) != tt.want || !p.GetMore() {
			t.Errorf("page_size %d: %d commits more %v err %v, want %d", tt.size, len(p.GetCommits()), p.GetMore(), err, tt.want)
		}
	}
}

// A record at or after the current pair is never returned (it cannot be this incarnation's: defence in depth). The
// creation time plays no part any more (the cross-instance clock rule went when the eraser started deleting commit records
// with the conversation tree): a record below the current pair is returned whenever it was created. A full page made only
// of dropped records answers more = false.
func TestListCommits_Leftovers(t *testing.T) {
	r := newRig(t, nil)
	conv := r.mlsConv(1, 3)
	live := conv.CreatedAt.Add(time.Minute)
	r.putCommit(1, 0, alice, conv.CreatedAt)                    // created with the conversation (an mls_init): live
	r.putCommit(1, 1, bob, conv.CreatedAt.Add(-48*time.Hour))   // below the current pair, stamped long before: returned
	r.putCommit(1, 2, alice, live)                              // live
	r.putCommit(1, 3, bob, conv.CreatedAt.Add(-48*time.Hour))   // at the current pair: a leftover
	r.putCommit(1, 7, bob, live)                                // after the current pair: a leftover whatever its time
	r.putCommit(2, 0, alice, conv.CreatedAt.Add(-48*time.Hour)) // after the current pair
	resp, err := r.svc.ListCommits(context.Background(), alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv})
	if err != nil {
		t.Fatal(err)
	}
	if got := pairsOf(resp); !slices.Equal(got, []string{"1:0", "1:1", "1:2"}) {
		t.Errorf("commits = %v, want the three records below the current pair", got)
	}

	// A full page of leftovers only.
	r3 := newRig(t, nil)
	conv3 := r3.mlsConv(1, 1)
	for e := int64(5); e < 8; e++ {
		r3.putCommit(1, e, bob, conv3.CreatedAt.Add(-48*time.Hour))
	}
	resp, _ = r3.svc.ListCommits(context.Background(), alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv, PageSize: 3})
	if len(resp.GetCommits()) != 0 || resp.GetMore() {
		t.Errorf("a page of leftovers = %v more %v, want none and more false", pairsOf(resp), resp.GetMore())
	}
}

// The after pair is unsigned on the wire: a value past 2^63 - 1 never turns negative (which would list everything), and an
// epoch past the id format is clamped to the end of its generation.
func TestListCommits_HugeAfterPair(t *testing.T) {
	r := newRig(t, nil)
	r.mlsConv(3, 1)
	for _, p := range [][2]int64{{1, 0}, {1, 1}, {2, 0}, {3, 0}} {
		r.putCommit(p[0], p[1], alice, r.now)
	}
	for _, tt := range []struct {
		g, e uint64
		want []string
	}{
		{1 << 63, 0, nil},
		{^uint64(0), ^uint64(0), nil},
		{maxDocPart + 1, 0, nil},
		{1, 1 << 63, []string{"2:0", "3:0"}},
		{2, ^uint64(0), []string{"3:0"}},
	} {
		resp, err := r.svc.ListCommits(context.Background(), alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv, AfterGeneration: tt.g, AfterEpoch: tt.e})
		if err != nil || !slices.Equal(pairsOf(resp), tt.want) || resp.GetMlsGeneration() != 3 {
			t.Errorf("after (%d, %d) = %v, %v; want %v", tt.g, tt.e, pairsOf(resp), err, tt.want)
		}
	}
}

func TestListCommits_RefusalsAndNone(t *testing.T) {
	r := newRig(t, nil)
	r.mlsConv(1, 2)
	r.putCommit(1, 0, alice, r.now)
	ctx := context.Background()
	_, err := r.svc.ListCommits(ctx, alice, &messagingv1.ListConversationCommitsRequest{ConversationId: "NOT-HEX"})
	wantValidation(t, err, "conversation_id")
	if len(r.repo.syncCalls) != 0 {
		t.Errorf("a validation refusal read %v", r.repo.syncCalls)
	}
	_, missing := r.svc.ListCommits(ctx, alice, &messagingv1.ListConversationCommitsRequest{ConversationId: ConversationID(alice, "uid-nobody")})
	_, stranger := r.svc.ListCommits(ctx, "uid-stranger", &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv})
	if code, _, _ := reasonOf(t, missing); code != connect.CodeNotFound || !bytes.Equal(wireBytes(t, missing), wireBytes(t, stranger)) {
		t.Errorf("missing %v / non-participant %v: want one byte-identical NOT_FOUND", missing, stranger)
	}
	// NONE: an empty list with (0, 0).
	r.repo.convs[aliceBobConv] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted, CreatedAt: r.now}
	resp, err := r.svc.ListCommits(ctx, alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv})
	if err != nil || len(resp.GetCommits()) != 0 || resp.GetMore() || resp.GetMlsGeneration() != 0 || resp.GetMlsEpoch() != 0 {
		t.Errorf("NONE = %v, %v", resp, err)
	}
	// A read failure is INTERNAL, never NOT_FOUND.
	r.repo.syncErr = errors.New("boom " + alice)
	_, err = r.svc.ListCommits(ctx, alice, &messagingv1.ListConversationCommitsRequest{ConversationId: aliceBobConv})
	wantInternal(t, err)
}

// wantInternal: err is not a wire answer (*apierr.Error), so the error middleware answers INTERNAL; and the raw uid is
// redacted from it.
func wantInternal(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v, want an internal (non-wire) error", err)
	}
	if strings.Contains(err.Error(), alice) {
		t.Errorf("the error carries the raw uid: %v", err)
	}
}

// putEpochMessages stores the alice-bob conversation's messages: per pair, n messages; returns the ids by pair.
func (r *rig) putEpochMessages(perPair map[[2]int64]int) map[[2]int64][]string {
	if r.repo.msgs == nil {
		r.repo.msgs = map[string][]MessageRow{}
	}
	out := map[[2]int64][]string{}
	i := 0
	for pair, n := range perPair {
		for range n {
			i++
			id := digest32(fmt.Sprintf("msg %d", i)) // ids are hashes: not creation order
			r.repo.msgs[aliceBobConv] = append(r.repo.msgs[aliceBobConv], MessageRow{ID: id, MsgDoc: MsgDoc{
				SenderID: []string{alice, bob}[i%2], State: msgVisible, CreatedAt: r.now.Add(-time.Duration(i) * time.Minute),
				Ciphertext: []byte("ct " + id), Commitment: bytes.Repeat([]byte{1}, CommitmentBytes),
				MlsGen: pair[0], MlsEpoch: pair[1], MlsKey: mlsKey(pair[0], pair[1]),
			}})
			out[pair] = append(out[pair], id)
		}
	}
	return out
}

// Every message of the epoch exactly once across pages, nothing of another epoch or generation (the same epoch number in
// another generation included), each page token bound to the caller, the conversation and the pair.
func TestListEpochMessages_PagesAreCompleteAndBound(t *testing.T) {
	r := newRig(t, nil)
	r.mlsConv(2, 3)
	ids := r.putEpochMessages(map[[2]int64]int{{1, 1}: 4, {1, 2}: 23, {2, 2}: 5, {2, 1}: 2})
	ctx := context.Background()
	var got []string
	tok := ""
	pages := 0
	for {
		resp, err := r.svc.ListEpochMessages(ctx, alice, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 2, PageSize: 10, PageToken: tok})
		if err != nil {
			t.Fatal(err)
		}
		pages++
		for _, m := range resp.GetMessages() {
			if m.GetMlsGeneration() != 1 || m.GetMlsEpoch() != 2 {
				t.Errorf("message %s of (%d, %d)", m.GetId(), m.GetMlsGeneration(), m.GetMlsEpoch())
			}
			got = append(got, m.GetId())
		}
		if tok = resp.GetNextPageToken(); tok == "" {
			break
		}
		if pages > 5 {
			t.Fatal("paging does not end")
		}
	}
	want := slices.Sorted(slices.Values(ids[[2]int64{1, 2}]))
	if !slices.Equal(got, want) || pages != 3 {
		t.Errorf("paged %d ids in %d pages, want the %d of (1, 2) once each in id order", len(got), pages, len(want))
	}

	first, _ := r.svc.ListEpochMessages(ctx, alice, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 2, PageSize: 10})
	tok = first.GetNextPageToken()
	for name, req := range map[string]struct {
		uid string
		req *messagingv1.ListEpochMessagesRequest
	}{
		"another pair":         {alice, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 3, PageToken: tok}},
		"another generation":   {alice, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 2, MlsEpoch: 2, PageToken: tok}},
		"another caller":       {bob, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 2, PageToken: tok}},
		"another conversation": {alice, &messagingv1.ListEpochMessagesRequest{ConversationId: ConversationID(alice, "uid-x"), MlsGeneration: 1, MlsEpoch: 2, PageToken: tok}},
		"tampered":             {alice, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 2, PageToken: tok + "x"}},
		"a ListMessages token": {alice, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 2, PageToken: cursor.EncodeAt(testCursorKey, messagesPageBinding(alice, aliceBobConv), cursor.Cursor{CreatedAt: r.now, DocID: want[0]}, r.now)}},
		"expired": {alice, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 2,
			PageToken: cursor.EncodeAt(testCursorKey, epochPageBinding(alice, aliceBobConv, "1:2"), cursor.Cursor{CreatedAt: r.now, DocID: want[0]}, r.now.Add(-31*24*time.Hour))}},
	} {
		calls := len(r.repo.syncCalls)
		_, err := r.svc.ListEpochMessages(ctx, req.uid, req.req)
		wantValidation(t, err, "page_token")
		if len(r.repo.syncCalls) != calls {
			t.Errorf("%s: a refused token read", name)
		}
	}
	// A pair with no messages and a NONE conversation: empty, no token.
	empty, err := r.svc.ListEpochMessages(ctx, alice, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 9, MlsEpoch: 9})
	if err != nil || len(empty.GetMessages()) != 0 || empty.GetNextPageToken() != "" {
		t.Errorf("empty pair = %v, %v", empty, err)
	}
}

func TestListEpochMessages_ValidationAndNotFound(t *testing.T) {
	r := newRig(t, nil)
	r.mlsConv(1, 2)
	ctx := context.Background()
	for _, tt := range []struct {
		req   *messagingv1.ListEpochMessagesRequest
		field string
	}{
		{&messagingv1.ListEpochMessagesRequest{ConversationId: "x", MlsGeneration: 0, MlsEpoch: 0}, "conversation_id"},
		{&messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 0, MlsEpoch: 0, PageToken: "junk"}, "mls_generation"},
		{&messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 0, PageToken: "junk"}, "mls_epoch"},
		{&messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 1, PageToken: "junk"}, "page_token"},
	} {
		_, err := r.svc.ListEpochMessages(ctx, alice, tt.req)
		wantValidation(t, err, tt.field)
	}
	if r.repo.gets != 0 || len(r.repo.syncCalls) != 0 {
		t.Errorf("validation read: gets %d sync %v", r.repo.gets, r.repo.syncCalls)
	}
	_, missing := r.svc.ListEpochMessages(ctx, alice, &messagingv1.ListEpochMessagesRequest{ConversationId: ConversationID(alice, "uid-nobody"), MlsGeneration: 1, MlsEpoch: 1})
	_, stranger := r.svc.ListEpochMessages(ctx, "uid-stranger", &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 1})
	_, viaMessages := r.svc.ListMessages(ctx, "uid-stranger", &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	if code, _, _ := reasonOf(t, missing); code != connect.CodeNotFound || !bytes.Equal(wireBytes(t, missing), wireBytes(t, stranger)) || !bytes.Equal(wireBytes(t, stranger), wireBytes(t, viaMessages)) {
		t.Errorf("missing / non-participant / ListMessages NOT_FOUND differ: %v / %v / %v", missing, stranger, viaMessages)
	}
	if len(r.repo.syncCalls) != 0 {
		t.Errorf("a refused caller ran the message query: %v", r.repo.syncCalls)
	}
}

// The wire mapping of an epoch's messages: a cleared message (at or before the caller's DeleteConversation time) is still
// returned, with its ciphertext; a tombstone and a swept message carry no ciphertext or commitment and ciphertext_removed;
// text and shared_post are never set; the pair is always kept.
func TestListEpochMessages_Mapping(t *testing.T) {
	r := newRig(t, nil)
	r.mlsConv(1, 2)
	r.repo.convs[aliceBobConv] = func(c ConvDoc) ConvDoc { c.ClearedAt = map[string]time.Time{alice: r.now}; return c }(r.repo.convs[aliceBobConv])
	commitment := bytes.Repeat([]byte{9}, CommitmentBytes)
	base := MsgDoc{SenderID: bob, State: msgVisible, CreatedAt: r.now.Add(-time.Hour), Ciphertext: []byte("ct"), Commitment: commitment, MlsGen: 1, MlsEpoch: 1, MlsKey: "1:1", Text: "never", SharedPostID: "1234567890123456789"}
	mk := func(id string, mut func(*MsgDoc)) MessageRow {
		d := base
		mut(&d)
		return MessageRow{ID: id, MsgDoc: d}
	}
	r.repo.msgs = map[string][]MessageRow{aliceBobConv: {
		mk("00000000000000000000000000000001", func(*MsgDoc) {}),                                                             // cleared for alice, visible
		mk("00000000000000000000000000000002", func(d *MsgDoc) { d.CtRemoved, d.Ciphertext, d.Commitment = true, nil, nil }), // swept
		mk("00000000000000000000000000000003", func(d *MsgDoc) { d.CtRemoved = true }),                                       // swept flag, bytes still there
		mk("00000000000000000000000000000004", func(d *MsgDoc) { d.State = msgRemoved }),                                     // takedown (bytes not trusted)
		mk("00000000000000000000000000000005", func(d *MsgDoc) { d.State = msgDeletedAccount; d.SenderID = DeletedUID }),
		mk("00000000000000000000000000000006", func(d *MsgDoc) { d.SenderID = alice; d.CreatedAt = r.now.Add(time.Minute) }),
	}}
	resp, err := r.svc.ListEpochMessages(context.Background(), alice, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 1})
	if err != nil || len(resp.GetMessages()) != 6 {
		t.Fatalf("resp = %v, %v; want all six (the cleared one included)", resp, err)
	}
	// cleared_at: the caller's own clear time; unset for bob, who never deleted the conversation.
	if c := resp.GetClearedAt(); c == nil || !c.AsTime().Equal(r.now) {
		t.Errorf("cleared_at = %v, want %v", c, r.now)
	}
	if b, err := r.svc.ListEpochMessages(context.Background(), bob, &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 1}); err != nil || b.GetClearedAt() != nil {
		t.Errorf("bob's cleared_at = %v, %v; want unset", b.GetClearedAt(), err)
	}
	for i, m := range resp.GetMessages() {
		present := i == 0 || i == 5
		if m.GetText() != "" || m.GetSharedPost() != nil || m.GetMlsGeneration() != 1 || m.GetMlsEpoch() != 1 {
			t.Errorf("message %d: text %q shared %v pair (%d, %d)", i, m.GetText(), m.GetSharedPost(), m.GetMlsGeneration(), m.GetMlsEpoch())
		}
		if present != (len(m.GetCiphertext()) > 0 && bytes.Equal(m.GetReportCommitment(), commitment)) || present == m.GetCiphertextRemoved() {
			t.Errorf("message %d: ciphertext %q commitment %d bytes removed %v", i, m.GetCiphertext(), len(m.GetReportCommitment()), m.GetCiphertextRemoved())
		}
		if !present && (len(m.GetCiphertext()) > 0 || len(m.GetReportCommitment()) > 0) {
			t.Errorf("message %d carries bytes after removal", i)
		}
	}
	if !resp.GetMessages()[5].GetFromSelf() || resp.GetMessages()[4].GetFromSelf() {
		t.Error("from_self")
	}
	if resp.GetMessages()[3].GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED || resp.GetMessages()[4].GetState() != messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT {
		t.Error("tombstone states")
	}

	// ListMessages maps the same way (and still hides the cleared message).
	lm := r.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	if len(lm.GetMessages()) != 1 || !bytes.Equal(lm.GetMessages()[0].GetCiphertext(), []byte("ct")) || lm.GetMessages()[0].GetSharedPost() != nil || lm.GetMessages()[0].GetText() != "" {
		t.Errorf("ListMessages = %v", lm.GetMessages())
	}
	if c := lm.GetConversation(); c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_MLS || c.GetMlsGeneration() != 1 || c.GetMlsEpoch() != 2 {
		t.Errorf("ListMessages conversation = %v", c)
	}
}

// Conversation.encryption on ListMessages: NONE for a plaintext conversation, MLS with the pair also for an erased peer
// (an early return of threadConversation), unset on a since refresh.
func TestListMessages_ConversationEncryption(t *testing.T) {
	r := newRig(t, nil)
	r.putThread(1, nil)
	lm := r.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	if c := lm.GetConversation(); c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_NONE || c.GetMlsGeneration() != 0 {
		t.Errorf("plaintext = %v", c)
	}
	if m := lm.GetMessages()[0]; m.GetText() == "" || m.GetCiphertextRemoved() || m.GetMlsGeneration() != 0 {
		t.Errorf("plaintext message = %v", m)
	}
	since := r.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: lm.GetSinceToken()})
	if since.GetConversation() != nil {
		t.Error("a since response carries the conversation")
	}
	r2 := newRig(t, nil)
	r2.putThread(1, func(c *ConvDoc) {
		c.Participants = sortedPair(alice, DeletedUID)
		c.Encryption, c.MlsGen, c.MlsEpoch = encMLS, 3, 4
	})
	r2.repo.convs[ConversationID(alice, bob)] = r2.repo.convs[aliceBobConv]
	lm = r2.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	if c := lm.GetConversation(); c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_MLS || c.GetMlsGeneration() != 3 || c.GetMlsEpoch() != 4 {
		t.Errorf("erased peer, MLS = %v", c)
	}
}

// ListConversations rows: encryption UNSPECIFIED; an encrypted last message is encrypted = true with an empty snippet and
// shared_post false, whatever the entry holds.
func TestListConversations_EncryptedPreview(t *testing.T) {
	r := newRig(t, nil)
	r.repo.entries = map[string][]EntryRow{alice + "|" + dmInboxCollection: {
		{ID: aliceBobConv, EntryDoc: EntryDoc{PeerID: bob, LastMessageAt: r.now, Last: LastDoc{Snippet: "leaked?", State: msgVisible, SharedPost: true, Encrypted: true}}},
		{ID: ConversationID(alice, "uid-c"), EntryDoc: EntryDoc{PeerID: "uid-c", LastMessageAt: r.now.Add(-time.Minute), Last: LastDoc{Snippet: "plain", State: msgVisible}}},
	}}
	resp, err := r.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX})
	if err != nil || len(resp.GetConversations()) != 2 {
		t.Fatalf("resp = %v, %v", resp, err)
	}
	enc, plain := resp.GetConversations()[0], resp.GetConversations()[1]
	if p := enc.GetLastMessage(); !p.GetEncrypted() || p.GetSnippet() != "" || p.GetSharedPost() {
		t.Errorf("encrypted preview = %v", p)
	}
	if p := plain.GetLastMessage(); p.GetEncrypted() || p.GetSnippet() != "plain" {
		t.Errorf("plaintext preview = %v", p)
	}
	for _, c := range resp.GetConversations() {
		if c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_UNSPECIFIED || c.GetMlsGeneration() != 0 {
			t.Errorf("row %s: encryption %v", c.GetId(), c.GetEncryption())
		}
	}
}

// welcome rows of alice: two devices, plus bob's (never visible to alice).
func (r *rig) putWelcomes() {
	r.devices.active[alice] = []string{devAlice1}
	r.devices.registered = map[string][]string{alice: {devAlice2}} // registered, inactive
	r.devices.active[bob] = []string{devBob1}
	w := func(id, dev, conv string, gen int64) WelcomeRow {
		return WelcomeRow{ID: id, WelcomeDoc: WelcomeDoc{DeviceID: dev, ConvID: conv, Gen: gen, Epoch: 0, Data: []byte("w " + id), CreatedAt: r.now}}
	}
	r.repo.welcomeRows = map[string][]WelcomeRow{
		alice: {
			w("cccccccccccccccccccccccccccccccc", devAlice1, aliceBobConv, 1),
			w("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", devAlice1, ConversationID(alice, "uid-c"), 2),
			w("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", devAlice2, aliceBobConv, 1),
		},
		bob: {w("dddddddddddddddddddddddddddddddd", devBob1, aliceBobConv, 1)},
	}
}

// ListWelcomes pages at most 10 welcomes (each up to 64 KiB): 0 or negative => 10, above 10 => 10; a smaller size is kept.
// The other sync lists keep 20 / 50.
func TestListWelcomes_PageSizeClamp(t *testing.T) {
	r := newRig(t, nil)
	r.devices.active[alice] = []string{devAlice1}
	var rows []WelcomeRow
	for i := range 25 {
		rows = append(rows, WelcomeRow{ID: fmt.Sprintf("%032x", i), WelcomeDoc: WelcomeDoc{DeviceID: devAlice1, ConvID: aliceBobConv, Gen: 1, Data: []byte("w"), CreatedAt: r.now}})
	}
	r.repo.welcomeRows = map[string][]WelcomeRow{alice: rows}
	for _, tt := range []struct {
		size int32
		want int
	}{{0, 10}, {-3, 10}, {11, 10}, {50, 10}, {1 << 30, 10}, {7, 7}, {10, 10}} {
		resp, err := r.svc.ListWelcomes(context.Background(), alice, &messagingv1.ListWelcomesRequest{DeviceId: devAlice1, PageSize: tt.size})
		if err != nil {
			t.Fatal(err)
		}
		if len(resp.GetWelcomes()) != tt.want || !resp.GetMore() {
			t.Errorf("page_size %d: %d welcomes (more %v), want %d and more", tt.size, len(resp.GetWelcomes()), resp.GetMore(), tt.want)
		}
	}
}

func TestListWelcomes_OnlyThatDeviceOfTheCaller(t *testing.T) {
	r := newRig(t, nil)
	r.putWelcomes()
	ctx := context.Background()
	resp, err := r.svc.ListWelcomes(ctx, alice, &messagingv1.ListWelcomesRequest{DeviceId: devAlice1})
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, w := range resp.GetWelcomes() {
		ids = append(ids, w.GetId())
	}
	if !slices.Equal(ids, []string{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "cccccccccccccccccccccccccccccccc"}) || resp.GetMore() {
		t.Errorf("welcomes = %v more %v, want the two of devAlice1 in id order", ids, resp.GetMore())
	}
	if w := resp.GetWelcomes()[1]; w.GetConversationId() != aliceBobConv || w.GetMlsGeneration() != 1 || w.GetMlsEpoch() != 0 || string(w.GetWelcome()) != "w cccccccccccccccccccccccccccccccc" || w.GetCreatedAt() == nil {
		t.Errorf("welcome = %v", w)
	}
	// An inactive registered device is accepted.
	resp, err = r.svc.ListWelcomes(ctx, alice, &messagingv1.ListWelcomesRequest{DeviceId: devAlice2})
	if err != nil || len(resp.GetWelcomes()) != 1 || resp.GetWelcomes()[0].GetId() != "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" {
		t.Errorf("inactive device = %v, %v", resp, err)
	}
	// Page size 1: more.
	resp, _ = r.svc.ListWelcomes(ctx, alice, &messagingv1.ListWelcomesRequest{DeviceId: devAlice1, PageSize: 1})
	if len(resp.GetWelcomes()) != 1 || !resp.GetMore() {
		t.Errorf("page of 1 = %v", resp)
	}
	// Another user's device, an unknown device and a malformed id: one VALIDATION device_id, byte-identical; the malformed
	// one reads nothing, and no refusal runs the welcome query.
	calls := len(r.repo.syncCalls)
	_, foreign := r.svc.ListWelcomes(ctx, alice, &messagingv1.ListWelcomesRequest{DeviceId: devBob1})
	_, unknown := r.svc.ListWelcomes(ctx, alice, &messagingv1.ListWelcomesRequest{DeviceId: "unknown-device-000001"})
	lookups := len(r.devices.allCalls)
	_, malformed := r.svc.ListWelcomes(ctx, alice, &messagingv1.ListWelcomesRequest{DeviceId: "short"})
	wantValidation(t, foreign, "device_id")
	if !bytes.Equal(wireBytes(t, foreign), wireBytes(t, unknown)) || !bytes.Equal(wireBytes(t, foreign), wireBytes(t, malformed)) {
		t.Error("the device_id refusals differ")
	}
	if len(r.devices.allCalls) != lookups || len(r.repo.syncCalls) != calls {
		t.Errorf("refusals read: devices %v sync %v", r.devices.allCalls, r.repo.syncCalls[calls:])
	}
	// A failed device lookup is an error, never VALIDATION.
	r.devices.err = errors.New("directory down")
	_, err = r.svc.ListWelcomes(ctx, alice, &messagingv1.ListWelcomesRequest{DeviceId: devAlice1})
	wantInternal(t, err)
}

func TestAckWelcomes(t *testing.T) {
	r := newRig(t, nil)
	r.putWelcomes()
	ctx := context.Background()
	key := "ack-key-0000000001"
	for _, tt := range []struct {
		req   *messagingv1.AckWelcomesRequest
		field string
	}{
		{&messagingv1.AckWelcomesRequest{IdempotencyKey: "bad", DeviceId: devAlice1, Ids: []string{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}, "idempotency_key"},
		{&messagingv1.AckWelcomesRequest{IdempotencyKey: key, DeviceId: "bad", Ids: []string{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}, "device_id"},
		{&messagingv1.AckWelcomesRequest{IdempotencyKey: key, DeviceId: devAlice1}, "ids"},
		{&messagingv1.AckWelcomesRequest{IdempotencyKey: key, DeviceId: devAlice1, Ids: []string{"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}, "ids"},
		{&messagingv1.AckWelcomesRequest{IdempotencyKey: key, DeviceId: devAlice1, Ids: slices.Repeat([]string{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, 51)}, "ids"},
		{&messagingv1.AckWelcomesRequest{IdempotencyKey: key, DeviceId: devBob1, Ids: []string{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}, "device_id"},
	} {
		_, err := r.svc.AckWelcomes(ctx, alice, tt.req)
		wantValidation(t, err, tt.field)
	}
	if len(r.repo.syncCalls) != 0 {
		t.Fatalf("a refusal deleted: %v", r.repo.syncCalls)
	}
	// Acknowledged through devAlice2, ids of devAlice1's welcome and of bob's (foreign: not under alice's path), duplicated:
	// alice's is deleted (device_id does not scope the delete), bob's untouched; a replay is a success.
	req := &messagingv1.AckWelcomesRequest{IdempotencyKey: key, DeviceId: devAlice2, Ids: []string{
		"cccccccccccccccccccccccccccccccc", "dddddddddddddddddddddddddddddddd", "cccccccccccccccccccccccccccccccc",
	}}
	for range 2 {
		if _, err := r.svc.AckWelcomes(ctx, alice, req); err != nil {
			t.Fatal(err)
		}
	}
	if !slices.Equal(r.repo.syncCalls, []string{"ack|" + alice + "|2", "ack|" + alice + "|2"}) {
		t.Errorf("deletes = %v, want 2 distinct ids twice, always under alice", r.repo.syncCalls)
	}
	if len(r.repo.welcomeRows[alice]) != 2 || len(r.repo.welcomeRows[bob]) != 1 {
		t.Errorf("welcomes left: alice %d bob %d", len(r.repo.welcomeRows[alice]), len(r.repo.welcomeRows[bob]))
	}
	// 50 ids is the maximum.
	if _, err := r.svc.AckWelcomes(ctx, alice, &messagingv1.AckWelcomesRequest{IdempotencyKey: key, DeviceId: devAlice1, Ids: slices.Repeat([]string{"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}, 50)}); err != nil {
		t.Errorf("50 ids: %v", err)
	}
}

// wantCapLimit asserts a RATE_LIMITED refusal naming limit.
func wantCapLimit(t *testing.T, err error, limit string) {
	t.Helper()
	if err == nil {
		t.Fatalf("no error, want RATE_LIMITED %s", limit)
	}
	code, reason, meta := reasonOf(t, err)
	if code != connect.CodeResourceExhausted || reason != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED || meta["limit"] != limit {
		t.Fatalf("got %v (%v %v %v), want RATE_LIMITED %s", err, code, reason, meta, limit)
	}
}

// The reset cap (messages_resets_daily): drawn on only by reset = true calls, after the flag, the verified email and the
// step-1 form (a malformed reset does not burn it) and before any lookup (a refused well-formed reset counts); ordinary
// commits never draw on it; another user is untouched; a caller with the flag off never reaches it.
func TestCommit_ResetCap(t *testing.T) {
	r := newRig(t, func(r *rig) { r.limits.ResetsPerDay = 2 })
	ctx := verifiedCtx()
	malformed := &messagingv1.CommitConversationRequest{IdempotencyKey: ckey(1), ConversationId: "not-hex", MlsGeneration: 1, Reset_: true}
	for range 3 {
		_, err := r.svc.Commit(ctx, alice, malformed)
		wantValidation(t, err, "conversation_id") // not counted
	}
	// Well-formed resets of a conversation that does not exist: counted, then NOT_FOUND; the third is capped.
	unknown := ConversationID(alice, "uid-nobody")
	reset := resetReq(ckey(2), unknown, 1, "r", devBob1)
	for range 2 {
		_, err := r.svc.Commit(ctx, alice, reset)
		if !bytes.Equal(wireBytes(t, err), wireBytes(t, notFound())) {
			t.Fatalf("reset of an unknown conversation = %v, want NOT_FOUND", err)
		}
	}
	_, err := r.svc.Commit(ctx, alice, reset)
	wantCapLimit(t, err, "messages_resets_daily")
	if r.repo.commitCalls != 2 {
		t.Errorf("repo calls = %d, want 2 (the capped reset never reached it)", r.repo.commitCalls)
	}
	// An ordinary commit is not on the reset cap; another user has their own.
	_, err = r.svc.Commit(ctx, alice, commitReq(ckey(3), unknown, 1, 1, "c"))
	if !bytes.Equal(wireBytes(t, err), wireBytes(t, notFound())) {
		t.Errorf("ordinary commit = %v, want NOT_FOUND", err)
	}
	_, err = r.svc.Commit(ctx, bob, reset)
	if !bytes.Equal(wireBytes(t, err), wireBytes(t, notFound())) {
		t.Errorf("bob's reset = %v, want NOT_FOUND", err)
	}
	// The flag answers first: a caller with messaging off is FEATURE_DISABLED every time and never draws on the cap.
	off := newRig(t, func(r *rig) {
		r.limits.ResetsPerDay = 1
		r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Off})
	})
	for range 3 {
		_, err = off.svc.Commit(ctx, alice, reset)
		if _, reason, _ := reasonOf(t, err); reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
			t.Fatalf("flag off reset = %v, want FEATURE_DISABLED", err)
		}
	}
	if !off.svc.resets.Allow(alice) {
		t.Error("a flag-off caller drew on the reset cap")
	}
}

// The per-(caller, conversation) commit cap (messages_commits_per_conversation_daily, default 20): drawn on by every
// well-formed CommitConversation (a reset included), after the step-1 form and before any lookup, keyed by caller and
// conversation id. The 21st commit on one conversation is RATE_LIMITED while another conversation still commits; a
// malformed call does not count; a non-participant's calls draw only on their own counter (NOT_FOUND until the cap, then
// RATE_LIMITED with the same bytes for an existing and an unknown conversation id) and leave the participants' alone.
func TestCommit_PerConversationCap(t *testing.T) {
	const perConv = 20
	other := ConversationID(alice, carolUID)
	r, convID := commitRig(t, 1, 1, func(r *rig) {
		r.limits.CommitsPerConversationPerDay = perConv
		r.profs.profiles[carolUID] = activeProfile(carolUID, "carol", r.now.Add(-30*24*time.Hour))
		r.devices.active[carolUID] = []string{devCarol1}
		c := commitConvAt(1, 1, r.now)
		c.Participants = sortedPair(alice, carolUID)
		r.repo.convs[other] = c
	})
	ctx := verifiedCtx()
	// Malformed calls on the conversation: not counted.
	for i := range 5 {
		_, err := r.svc.Commit(ctx, alice, commitReq(ckey(900+i), convID, 0, 1, "bad"))
		wantValidation(t, err, "mls_generation")
	}
	for i := range perConv {
		wantPair(t, r.mustCommit(t, alice, commitReq(ckey(i+1), convID, 1, uint64(i+1), fmt.Sprint(i))), 1, uint64(i+2))
	}
	calls := r.repo.commitCalls
	_, err := r.svc.Commit(ctx, alice, commitReq(ckey(100), convID, 1, perConv+1, "over"))
	wantCapLimit(t, err, limitCommitsPerConvDaily)
	// A reset on the same conversation is refused by the same cap (and does not reach the repo).
	_, err = r.svc.Commit(ctx, alice, resetReq(ckey(101), convID, 1, "reset", devBob1))
	wantCapLimit(t, err, limitCommitsPerConvDaily)
	if r.repo.commitCalls != calls {
		t.Errorf("a capped commit reached the repo")
	}
	// Another conversation of the same caller, and the peer on the same conversation, still commit.
	wantPair(t, r.mustCommit(t, alice, commitReq(ckey(200), other, 1, 1, "other")), 1, 2)
	wantPair(t, r.mustCommit(t, bob, commitReq(ckey(201), convID, 1, perConv+1, "bob")), 1, perConv+2)

	// A non-participant: NOT_FOUND until their own counter runs out, then RATE_LIMITED, byte-identical for an existing and an
	// unknown conversation id.
	unknown := ConversationID(carolUID, "uid-nobody")
	var capped [][]byte
	for _, id := range []string{convID, unknown} {
		for i := range perConv {
			_, err := r.svc.Commit(ctx, carolUID, commitReq(ckey(300+i), id, 1, 1, "x"))
			if !bytes.Equal(wireBytes(t, err), wireBytes(t, notFound())) {
				t.Fatalf("carol's commit %d on %s = %v, want NOT_FOUND", i+1, id[:8], err)
			}
		}
		_, err := r.svc.Commit(ctx, carolUID, commitReq(ckey(400), id, 1, 1, "x"))
		wantCapLimit(t, err, limitCommitsPerConvDaily)
		capped = append(capped, wireBytes(t, err))
	}
	if !bytes.Equal(capped[0], capped[1]) {
		t.Errorf("capped answer depends on the conversation: %q vs %q", capped[0], capped[1])
	}
	// Carol's calls drew nothing from bob's counter on the conversation.
	wantPair(t, r.mustCommit(t, bob, commitReq(ckey(500), convID, 1, perConv+2, "bob2")), 1, perConv+3)
}

// The two service caps' order: the per-conversation cap is drawn first, so a reset it refuses leaves the reset cap
// untouched.
func TestCommit_CapOrder(t *testing.T) {
	r, convID := commitRig(t, 1, 1, func(r *rig) {
		r.limits.CommitsPerConversationPerDay = 1
		r.limits.ResetsPerDay = 1
	})
	ctx := verifiedCtx()
	wantPair(t, r.mustCommit(t, alice, commitReq(ckey(1), convID, 1, 1, "c")), 1, 2)
	_, err := r.svc.Commit(ctx, alice, resetReq(ckey(2), convID, 1, "r", devBob1))
	wantCapLimit(t, err, limitCommitsPerConvDaily)
	if !r.svc.resets.Allow(alice) {
		t.Error("a reset refused by the per-conversation cap drew on the reset cap")
	}
}

// --- ListEpochMessages order = CREATED_AT and ListMessageTombstones (receive walks, Part B) ---

const (
	orderUnspecified = messagingv1.EpochMessageOrder_EPOCH_MESSAGE_ORDER_UNSPECIFIED
	orderCreatedAt   = messagingv1.EpochMessageOrder_EPOCH_MESSAGE_ORDER_CREATED_AT
)

// e2eeSpec is the e2ee_dm flag in a mode, with the given uids allowlisted.
func e2eeSpec(mode flags.Mode, allow ...string) flags.Spec {
	m := map[string]struct{}{}
	for _, u := range allow {
		m[u] = struct{}{}
	}
	return flags.Spec{Name: keys.FlagName, Mode: mode, Allowlist: m}
}

// orderRig is the alice-bob MLS conversation at (1, 2) under the given flags (default: messaging and e2ee_dm on).
func orderRig(t *testing.T, specs ...flags.Spec) *rig {
	t.Helper()
	if len(specs) == 0 {
		specs = []flags.Spec{{Name: FlagName, Mode: flags.On}, e2eeSpec(flags.On)}
	}
	r := newRig(t, func(r *rig) { r.reg = flags.NewRegistry(specs...) })
	r.mlsConv(1, 2)
	return r
}

// timedMsg is one stored message of the alice-bob conversation at the pair (1, 1), created age before the rig's clock.
type timedMsg struct {
	id    string
	age   time.Duration
	state string
}

func (r *rig) putTimed(msgs ...timedMsg) {
	if r.repo.msgs == nil {
		r.repo.msgs = map[string][]MessageRow{}
	}
	for _, m := range msgs {
		st := m.state
		if st == "" {
			st = msgVisible
		}
		r.repo.msgs[aliceBobConv] = append(r.repo.msgs[aliceBobConv], MessageRow{ID: m.id, MsgDoc: MsgDoc{
			SenderID: bob, State: st, CreatedAt: r.now.Add(-m.age), Ciphertext: []byte("ct"), Commitment: bytes.Repeat([]byte{1}, CommitmentBytes),
			MlsGen: 1, MlsEpoch: 1, MlsKey: "1:1",
		}})
	}
}

// hexID is a message id (32 lower-case hex) that sorts by n.
func hexID(n int) string { return fmt.Sprintf("%032x", n) }

func epochReq(order messagingv1.EpochMessageOrder, tok string, size int32) *messagingv1.ListEpochMessagesRequest {
	return &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 1, PageSize: size, PageToken: tok, Order: order}
}

// timeTok seals an order = CREATED_AT position of alice at (1, 1); id "" is a time-only position.
func (r *rig) timeTok(at time.Time, id string) string {
	if id == "" {
		id = trailDocID
	}
	return cursor.EncodeAt(testCursorKey, epochTimePageBinding(alice, aliceBobConv, "1:1"), cursor.Cursor{CreatedAt: at, DocID: id}, r.now)
}

// openTime opens an order = CREATED_AT token of alice at (1, 1) into its position (DocID "" for a time-only one).
func (r *rig) openTime(t *testing.T, tok string) cursor.Cursor {
	t.Helper()
	c, err := cursor.DecodeAtTTL(testCursorKey, epochTimePageBinding(alice, aliceBobConv, "1:1"), tok, r.now, 30*24*time.Hour)
	if err != nil {
		t.Fatalf("open token %q: %v", tok, err)
	}
	if c.DocID == trailDocID {
		c.DocID = ""
	}
	return c
}

func epochIDs(resp *messagingv1.ListEpochMessagesResponse) []string {
	out := []string{}
	for _, m := range resp.GetMessages() {
		out = append(out, m.GetId())
	}
	return out
}

func wantFeatureDisabled(t *testing.T, err error, feature string) {
	t.Helper()
	code, reason, meta := reasonOf(t, err)
	if code != connect.CodeFailedPrecondition || reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || meta["feature"] != feature {
		t.Fatalf("err = %v (%v %v %v), want FEATURE_DISABLED feature=%s", err, code, reason, meta, feature)
	}
}

func TestListEpochMessagesOrderEcho(t *testing.T) {
	r := orderRig(t)
	r.putTimed(timedMsg{id: hexID(3), age: 3 * time.Hour}, timedMsg{id: hexID(1), age: time.Hour}, timedMsg{id: hexID(4), age: 2 * time.Hour}, timedMsg{id: hexID(2), age: 2 * time.Hour})
	for _, tt := range []struct {
		name  string
		order messagingv1.EpochMessageOrder
		want  []string
	}{
		{"unspecified: id order, no echo, no resume", orderUnspecified, []string{hexID(1), hexID(2), hexID(3), hexID(4)}},
		{"created_at: oldest first, ties by id, echoed", orderCreatedAt, []string{hexID(3), hexID(2), hexID(4), hexID(1)}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := r.svc.ListEpochMessages(context.Background(), alice, epochReq(tt.order, "", 10))
			if err != nil {
				t.Fatal(err)
			}
			if got := epochIDs(resp); !slices.Equal(got, tt.want) {
				t.Errorf("ids = %v, want %v", got, tt.want)
			}
			if resp.GetOrder() != tt.order {
				t.Errorf("order echo = %v, want %v", resp.GetOrder(), tt.order)
			}
			if tt.order == orderUnspecified && (resp.GetResumePageToken() != "" || resp.GetResumeSettled()) {
				t.Errorf("id order carries resume %q settled %v", resp.GetResumePageToken(), resp.GetResumeSettled())
			}
		})
	}
}

func TestListEpochMessagesUnknownOrderIsValidation(t *testing.T) {
	for _, tt := range []struct {
		name  string
		specs []flags.Spec
	}{
		{"e2ee_dm on", nil},
		{"e2ee_dm off: the value is checked first", []flags.Spec{{Name: FlagName, Mode: flags.On}, e2eeSpec(flags.Off)}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := orderRig(t, tt.specs...)
			_, err := r.svc.ListEpochMessages(context.Background(), alice, epochReq(messagingv1.EpochMessageOrder(7), "", 10))
			wantValidation(t, err, "order")
			if r.repo.gets != 0 || len(r.repo.syncCalls) != 0 {
				t.Errorf("an unknown order read: gets %d sync %v", r.repo.gets, r.repo.syncCalls)
			}
		})
	}
}

func TestListEpochMessagesCreatedAtFlag(t *testing.T) {
	msgOn := flags.Spec{Name: FlagName, Mode: flags.On}
	for _, tt := range []struct {
		name    string
		specs   []flags.Spec
		order   messagingv1.EpochMessageOrder
		feature string // "" = served
	}{
		{"e2ee_dm globally off", []flags.Spec{msgOn, e2eeSpec(flags.Off)}, orderCreatedAt, keys.FlagName},
		{"e2ee_dm not registered", []flags.Spec{msgOn}, orderCreatedAt, keys.FlagName},
		{"e2ee_dm allowlist without the caller: served", []flags.Spec{msgOn, e2eeSpec(flags.Allowlist, bob)}, orderCreatedAt, ""},
		{"e2ee_dm percent 0: served", []flags.Spec{msgOn, {Name: keys.FlagName, Mode: flags.Percent}}, orderCreatedAt, ""},
		{"messaging globally off", []flags.Spec{{Name: FlagName, Mode: flags.Off}, e2eeSpec(flags.On)}, orderCreatedAt, FlagName},
		{"messaging allowlist without the caller: served", []flags.Spec{{Name: FlagName, Mode: flags.Allowlist}, e2eeSpec(flags.On)}, orderCreatedAt, ""},
		{"id order with e2ee_dm off: unaffected", []flags.Spec{msgOn, e2eeSpec(flags.Off)}, orderUnspecified, ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := orderRig(t, tt.specs...)
			r.putTimed(timedMsg{id: hexID(1), age: time.Hour})
			resp, err := r.svc.ListEpochMessages(context.Background(), alice, epochReq(tt.order, "", 10))
			if tt.feature != "" {
				wantFeatureDisabled(t, err, tt.feature)
				if r.repo.gets != 0 || len(r.repo.syncCalls) != 0 {
					t.Errorf("a disabled call read: gets %d sync %v", r.repo.gets, r.repo.syncCalls)
				}
				return
			}
			if err != nil || len(resp.GetMessages()) != 1 || resp.GetOrder() != tt.order {
				t.Fatalf("resp = %v, %v; want one message, order %v", resp, err, tt.order)
			}
		})
	}
}

func TestListEpochMessagesTokenBoundToOrder(t *testing.T) {
	r := orderRig(t)
	r.putTimed(timedMsg{id: hexID(1), age: 3 * time.Hour}, timedMsg{id: hexID(2), age: 2 * time.Hour}, timedMsg{id: hexID(3), age: time.Hour})
	ctx := context.Background()
	idPage, err := r.svc.ListEpochMessages(ctx, alice, epochReq(orderUnspecified, "", 2))
	if err != nil || idPage.GetNextPageToken() == "" {
		t.Fatalf("id page = %v, %v", idPage, err)
	}
	timePage, err := r.svc.ListEpochMessages(ctx, alice, epochReq(orderCreatedAt, "", 2))
	if err != nil || timePage.GetNextPageToken() == "" || timePage.GetResumePageToken() == "" {
		t.Fatalf("created_at page = %v, %v", timePage, err)
	}
	for _, tt := range []struct {
		name string
		req  *messagingv1.ListEpochMessagesRequest
	}{
		{"an id-order token in created_at order", epochReq(orderCreatedAt, idPage.GetNextPageToken(), 2)},
		{"a created_at next token in id order", epochReq(orderUnspecified, timePage.GetNextPageToken(), 2)},
		{"a created_at resume token in id order", epochReq(orderUnspecified, timePage.GetResumePageToken(), 2)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			calls := len(r.repo.syncCalls)
			_, err := r.svc.ListEpochMessages(ctx, alice, tt.req)
			wantValidation(t, err, "page_token")
			if len(r.repo.syncCalls) != calls {
				t.Errorf("a refused token read: %v", r.repo.syncCalls[calls:])
			}
		})
	}
	// Each order's own token still works.
	if _, err := r.svc.ListEpochMessages(ctx, alice, epochReq(orderCreatedAt, timePage.GetNextPageToken(), 2)); err != nil {
		t.Errorf("created_at next token in created_at order: %v", err)
	}
	if _, err := r.svc.ListEpochMessages(ctx, alice, epochReq(orderUnspecified, idPage.GetNextPageToken(), 2)); err != nil {
		t.Errorf("id-order token in id order: %v", err)
	}
}

func TestListEpochMessagesTimeOnlyTokenOnlyInTimeMode(t *testing.T) {
	r := orderRig(t)
	at := r.now.Add(-time.Hour)
	idBinding, timeBinding := epochPageBinding(alice, aliceBobConv, "1:1"), epochTimePageBinding(alice, aliceBobConv, "1:1")
	seal := func(binding string, c cursor.Cursor) string { return cursor.EncodeAt(testCursorKey, binding, c, r.now) }
	for _, tt := range []struct {
		name string
		req  *messagingv1.ListEpochMessagesRequest
		call string // the recorded query; "" = refused (VALIDATION page_token)
	}{
		{"a time-only position in id order", epochReq(orderUnspecified, seal(idBinding, cursor.Cursor{CreatedAt: at, DocID: trailDocID}), 10), ""},
		{"a time-only position without a time", epochReq(orderCreatedAt, seal(timeBinding, cursor.Cursor{DocID: trailDocID}), 10), ""},
		{"a position whose id is not a message id", epochReq(orderCreatedAt, seal(timeBinding, cursor.Cursor{CreatedAt: at, DocID: "zz"}), 10), ""},
		{"a time-only position in created_at order", epochReq(orderCreatedAt, r.timeTok(at, ""), 10),
			"epochtime|" + aliceBobConv + "|1:1|" + strconv.FormatInt(at.UnixMicro(), 10) + "||10"},
		{"a full position in created_at order", epochReq(orderCreatedAt, r.timeTok(at, hexID(5)), 10),
			"epochtime|" + aliceBobConv + "|1:1|" + strconv.FormatInt(at.UnixMicro(), 10) + "|" + hexID(5) + "|10"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			calls := len(r.repo.syncCalls)
			_, err := r.svc.ListEpochMessages(context.Background(), alice, tt.req)
			if tt.call == "" {
				wantValidation(t, err, "page_token")
				if len(r.repo.syncCalls) != calls {
					t.Errorf("a refused token read: %v", r.repo.syncCalls[calls:])
				}
				return
			}
			if err != nil || len(r.repo.syncCalls) != calls+1 || r.repo.syncCalls[calls] != tt.call {
				t.Fatalf("err %v, calls %v; want the query %q", err, r.repo.syncCalls[calls:], tt.call)
			}
		})
	}
}

func TestListEpochMessagesResumeToken(t *testing.T) {
	type pos struct {
		age time.Duration
		id  string
	}
	for _, tt := range []struct {
		name    string
		msgs    []timedMsg
		from    *pos // the request's position; nil = from the start; id "" = time-only
		size    int32
		rows    int
		resume  *pos // nil = ""
		settled bool
	}{
		{"full page settled: after its last row", []timedMsg{{hexID(1), 3 * time.Hour, ""}, {hexID(2), 2 * time.Hour, ""}, {hexID(3), time.Hour, ""}}, nil, 2, 2,
			&pos{2 * time.Hour, hexID(2)}, true},
		{"last page settled: after its last row", []timedMsg{{hexID(1), 3 * time.Hour, ""}, {hexID(2), 2 * time.Hour, ""}, {hexID(3), time.Hour, ""}}, nil, 10, 3,
			&pos{time.Hour, hexID(3)}, true},
		{"a last row inside the trail: the cut, not settled", []timedMsg{{hexID(1), 5 * time.Minute, ""}, {hexID(2), 10 * time.Second, ""}}, nil, 10, 2,
			&pos{EpochResumeTrail, ""}, false},
		{"an empty page with a position: the position", []timedMsg{{hexID(1), time.Hour, ""}}, &pos{30 * time.Minute, hexID(9)}, 10, 0,
			&pos{30 * time.Minute, hexID(9)}, true},
		{"an empty first page: no token", nil, nil, 10, 0, nil, true},
		{"a cut below the request position: the request position", []timedMsg{{hexID(1), 10 * time.Second, ""}}, &pos{30 * time.Second, hexID(5)}, 10, 1,
			&pos{30 * time.Second, hexID(5)}, false},
		{"a time-only request position above the cut: kept", []timedMsg{{hexID(1), 10 * time.Second, ""}}, &pos{30 * time.Second, ""}, 10, 1,
			&pos{30 * time.Second, ""}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := orderRig(t)
			r.putTimed(tt.msgs...)
			tok := ""
			if tt.from != nil {
				tok = r.timeTok(r.now.Add(-tt.from.age), tt.from.id)
			}
			resp, err := r.svc.ListEpochMessages(context.Background(), alice, epochReq(orderCreatedAt, tok, tt.size))
			if err != nil {
				t.Fatal(err)
			}
			if len(resp.GetMessages()) != tt.rows || resp.GetResumeSettled() != tt.settled {
				t.Fatalf("rows %d settled %v, want %d %v", len(resp.GetMessages()), resp.GetResumeSettled(), tt.rows, tt.settled)
			}
			if tt.resume == nil {
				if resp.GetResumePageToken() != "" {
					t.Fatalf("resume = %q, want none", resp.GetResumePageToken())
				}
				return
			}
			got := r.openTime(t, resp.GetResumePageToken())
			if want := r.now.Add(-tt.resume.age); !got.CreatedAt.Equal(want) || got.DocID != tt.resume.id {
				t.Errorf("resume at (%v, %q), want (%v, %q)", got.CreatedAt, got.DocID, want, tt.resume.id)
			}
		})
	}
}

func TestListEpochMessagesNextTokenOnlyOnFullPage(t *testing.T) {
	for _, tt := range []struct {
		name string
		n    int
		next bool
	}{
		{"no messages", 0, false},
		{"a short page", 1, false},
		{"a full page", 2, true},
		{"a full page with more", 3, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := orderRig(t)
			for i := range tt.n {
				r.putTimed(timedMsg{id: hexID(i + 1), age: time.Duration(10-i) * time.Hour})
			}
			resp, err := r.svc.ListEpochMessages(context.Background(), alice, epochReq(orderCreatedAt, "", 2))
			if err != nil {
				t.Fatal(err)
			}
			if (resp.GetNextPageToken() != "") != tt.next {
				t.Fatalf("next token %q, want set = %v", resp.GetNextPageToken(), tt.next)
			}
			if !tt.next {
				return
			}
			last := resp.GetMessages()[len(resp.GetMessages())-1]
			if got := r.openTime(t, resp.GetNextPageToken()); got.DocID != last.GetId() || !got.CreatedAt.Equal(last.GetCreatedAt().AsTime()) {
				t.Errorf("next token at %+v, want the last row %s", got, last.GetId())
			}
			rest, err := r.svc.ListEpochMessages(context.Background(), alice, epochReq(orderCreatedAt, resp.GetNextPageToken(), 2))
			if err != nil || len(rest.GetMessages()) != tt.n-2 || rest.GetNextPageToken() != "" {
				t.Errorf("the next page = %v, %v; want the other %d, no token", rest, err, tt.n-2)
			}
		})
	}
}

func TestListEpochMessagesIndexMissingFailsClosed(t *testing.T) {
	for _, tt := range []struct {
		name     string
		repoErr  error
		fallback bool
	}{
		{"FAILED_PRECONDITION: an empty unordered page", status.Error(codes.FailedPrecondition, "The query requires an index: conversations/"+aliceBobConv), true},
		{"another error: INTERNAL, no fallback", status.Error(codes.Unavailable, "down"), false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := orderRig(t)
			r.repo.convs[aliceBobConv] = func(c ConvDoc) ConvDoc { c.ClearedAt = map[string]time.Time{alice: r.now.Add(-time.Hour)}; return c }(r.repo.convs[aliceBobConv])
			r.putTimed(timedMsg{id: hexID(1), age: 2 * time.Hour})
			var logs bytes.Buffer
			r.svc.d.Log = slog.New(slog.NewJSONHandler(&logs, nil))
			r.repo.orderErr = tt.repoErr
			resp, err := r.svc.ListEpochMessages(context.Background(), alice, epochReq(orderCreatedAt, r.timeTok(r.now.Add(-3*time.Hour), hexID(7)), 10))
			if !tt.fallback {
				if code, _, _ := reasonOf(t, err); code != connect.CodeInternal {
					t.Fatalf("err = %v, want INTERNAL", err)
				}
				if strings.Contains(logs.String(), fieldOrderFallback) {
					t.Errorf("a non-index error logged the fallback: %s", logs.String())
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if len(resp.GetMessages()) != 0 || resp.GetOrder() != orderUnspecified || resp.GetNextPageToken() != "" || resp.GetResumePageToken() != "" || resp.GetResumeSettled() {
				t.Errorf("fallback page = %v; want empty, order unset, no tokens, not settled", resp)
			}
			if c := resp.GetClearedAt(); c == nil || !c.AsTime().Equal(r.now.Add(-time.Hour)) {
				t.Errorf("cleared_at = %v, want as usual", c)
			}
			var errorLines []map[string]any
			for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
				var rec map[string]any
				if json.Unmarshal([]byte(line), &rec) == nil && rec["level"] == "ERROR" {
					errorLines = append(errorLines, rec)
				}
			}
			if len(errorLines) != 1 {
				t.Fatalf("ERROR lines = %d (%s), want exactly one", len(errorLines), logs.String())
			}
			rec := errorLines[0]
			if rec[fieldOrderFallback] != true || rec[fieldConvHash] != logger.HashConversation(aliceBobConv) || rec[fieldKind] != kindEpochMessages {
				t.Errorf("ERROR line = %v; want %s=true, the conversation hash and the kind", rec, fieldOrderFallback)
			}
			for _, secret := range []string{alice, bob, aliceBobConv, hexID(1), hexID(7)} {
				if strings.Contains(logs.String(), secret) {
					t.Errorf("the fallback log names %q: %s", secret, logs.String())
				}
			}
		})
	}
}

func tombReq(conv, tok string, size int32) *messagingv1.ListMessageTombstonesRequest {
	return &messagingv1.ListMessageTombstonesRequest{ConversationId: conv, PageSize: size, PageToken: tok}
}

func tombIDs(resp *messagingv1.ListMessageTombstonesResponse) []string {
	out := []string{}
	for _, ts := range resp.GetTombstones() {
		out = append(out, ts.GetId())
	}
	return out
}

func TestListMessageTombstonesBothStatesByID(t *testing.T) {
	r := orderRig(t)
	r.repo.convs[aliceBobConv] = func(c ConvDoc) ConvDoc { c.ClearedAt = map[string]time.Time{alice: r.now}; return c }(r.repo.convs[aliceBobConv])
	r.putTimed(
		timedMsg{hexID(5), time.Hour, msgRemoved}, timedMsg{hexID(2), time.Hour, msgDeletedAccount}, timedMsg{hexID(3), time.Hour, msgVisible},
		timedMsg{hexID(1), 40 * 24 * time.Hour, msgRemoved}, timedMsg{hexID(4), time.Minute, msgDeletedAccount},
	)
	other := ConversationID(alice, "uid-x")
	r.repo.msgs[other] = []MessageRow{{ID: hexID(6), MsgDoc: MsgDoc{State: msgRemoved}}}
	resp, err := r.svc.ListMessageTombstones(context.Background(), alice, tombReq(aliceBobConv, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{hexID(1), hexID(2), hexID(4), hexID(5)}
	wantStates := []messagingv1.MessageState{messagingv1.MessageState_MESSAGE_STATE_REMOVED, messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT,
		messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT, messagingv1.MessageState_MESSAGE_STATE_REMOVED}
	if got := tombIDs(resp); !slices.Equal(got, want) || resp.GetNextPageToken() != "" {
		t.Fatalf("tombstones %v next %q, want %v (the cleared one included) and no token", got, resp.GetNextPageToken(), want)
	}
	for i, ts := range resp.GetTombstones() {
		if ts.GetState() != wantStates[i] {
			t.Errorf("%s: state %v, want %v", ts.GetId(), ts.GetState(), wantStates[i])
		}
	}
}

func TestListMessageTombstonesMergePaging(t *testing.T) {
	for _, tt := range []struct {
		name              string
		removed, deleted  int
		size              int32
		firstLen          int
		firstHasNextToken bool
	}{
		{"one state full", 5, 0, 5, 5, true},
		{"neither full but the merge cut (60 + 70 at 100)", 60, 70, 100, 100, true},
		{"both short: one page", 3, 4, 10, 7, false},
		{"interleaved across many pages", 7, 8, 4, 4, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := orderRig(t)
			var all []string
			removed, deleted := tt.removed, tt.deleted
			for i := 0; removed+deleted > 0; i++ {
				st := msgRemoved
				if removed == 0 || (deleted > 0 && i%2 == 1) {
					st, deleted = msgDeletedAccount, deleted-1
				} else {
					removed--
				}
				r.putTimed(timedMsg{hexID(i + 1), time.Hour, st})
				all = append(all, hexID(i+1))
			}
			r.putTimed(timedMsg{hexID(10_000), time.Hour, msgVisible})
			var got []string
			tok := ""
			for page := 0; ; page++ {
				if page > 50 {
					t.Fatal("paging does not end")
				}
				resp, err := r.svc.ListMessageTombstones(context.Background(), alice, tombReq(aliceBobConv, tok, tt.size))
				if err != nil {
					t.Fatal(err)
				}
				if page == 0 && (len(resp.GetTombstones()) != tt.firstLen || (resp.GetNextPageToken() != "") != tt.firstHasNextToken) {
					t.Errorf("first page: %d rows, token %q; want %d, token %v", len(resp.GetTombstones()), resp.GetNextPageToken(), tt.firstLen, tt.firstHasNextToken)
				}
				got = append(got, tombIDs(resp)...)
				if tok = resp.GetNextPageToken(); tok == "" {
					break
				}
			}
			if !slices.Equal(got, all) {
				t.Errorf("paged %d ids, want the %d tombstones once each in id order (no duplicate, no skip)", len(got), len(all))
			}
		})
	}
}

func TestListMessageTombstonesParticipantOnly(t *testing.T) {
	r := orderRig(t)
	r.putTimed(timedMsg{hexID(1), time.Hour, msgRemoved})
	ctx := context.Background()
	_, stranger := r.svc.ListMessageTombstones(ctx, "uid-stranger", tombReq(aliceBobConv, "", 0))
	_, missing := r.svc.ListMessageTombstones(ctx, alice, tombReq(ConversationID(alice, "uid-nobody"), "", 0))
	_, viaEpoch := r.svc.ListEpochMessages(ctx, "uid-stranger", &messagingv1.ListEpochMessagesRequest{ConversationId: aliceBobConv, MlsGeneration: 1, MlsEpoch: 1})
	if code, _, _ := reasonOf(t, stranger); code != connect.CodeNotFound || !bytes.Equal(wireBytes(t, stranger), wireBytes(t, missing)) || !bytes.Equal(wireBytes(t, stranger), wireBytes(t, viaEpoch)) {
		t.Errorf("non-participant / missing / ListEpochMessages NOT_FOUND differ: %v / %v / %v", stranger, missing, viaEpoch)
	}
	for _, c := range r.repo.syncCalls {
		if strings.HasPrefix(c, "tombstones|") {
			t.Errorf("a refused caller ran the tombstone query: %s", c)
		}
	}
	if resp, err := r.svc.ListMessageTombstones(ctx, bob, tombReq(aliceBobConv, "", 0)); err != nil || len(resp.GetTombstones()) != 1 {
		t.Errorf("the other participant: %v, %v", resp, err)
	}
}

func TestListMessageTombstonesValidation(t *testing.T) {
	r := orderRig(t)
	ctx := context.Background()
	seal := func(binding, id string, issued time.Time) string {
		return cursor.EncodeAt(testCursorKey, binding, cursor.Cursor{CreatedAt: r.now, DocID: id}, issued)
	}
	good := seal(tombstonePageBinding(alice, aliceBobConv), hexID(1), r.now)
	for _, tt := range []struct {
		name  string
		req   *messagingv1.ListMessageTombstonesRequest
		field string
	}{
		{"conversation id", tombReq("x", "", 0), "conversation_id"},
		{"upper-case conversation id", tombReq(strings.ToUpper(aliceBobConv), "", 0), "conversation_id"},
		{"a foreign token (another caller)", tombReq(aliceBobConv, seal(tombstonePageBinding(bob, aliceBobConv), hexID(1), r.now), 0), "page_token"},
		{"another conversation's token", tombReq(aliceBobConv, seal(tombstonePageBinding(alice, ConversationID(alice, "uid-x")), hexID(1), r.now), 0), "page_token"},
		{"a tampered token", tombReq(aliceBobConv, good+"x", 0), "page_token"},
		{"an expired token", tombReq(aliceBobConv, seal(tombstonePageBinding(alice, aliceBobConv), hexID(1), r.now.Add(-31*24*time.Hour)), 0), "page_token"},
		{"a ListEpochMessages token", tombReq(aliceBobConv, seal(epochPageBinding(alice, aliceBobConv, "1:1"), hexID(1), r.now), 0), "page_token"},
		{"a token whose id is not a message id", tombReq(aliceBobConv, seal(tombstonePageBinding(alice, aliceBobConv), "zz", r.now), 0), "page_token"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			gets, calls := r.repo.gets, len(r.repo.syncCalls)
			_, err := r.svc.ListMessageTombstones(ctx, alice, tt.req)
			wantValidation(t, err, tt.field)
			if r.repo.gets != gets || len(r.repo.syncCalls) != calls {
				t.Errorf("a refused request read")
			}
		})
	}
	if _, err := r.svc.ListMessageTombstones(ctx, alice, tombReq(aliceBobConv, good, 0)); err != nil {
		t.Errorf("a good token: %v", err)
	}
	for _, tt := range []struct {
		in   int32
		want int
	}{{0, 50}, {-3, 50}, {7, 7}, {100, 100}, {101, 100}, {5000, 100}} {
		if _, err := r.svc.ListMessageTombstones(ctx, alice, tombReq(aliceBobConv, "", tt.in)); err != nil {
			t.Fatal(err)
		}
		if last := r.repo.syncCalls[len(r.repo.syncCalls)-1]; !strings.HasSuffix(last, "|"+strconv.Itoa(tt.want)) {
			t.Errorf("page_size %d: query %q, want limit %d", tt.in, last, tt.want)
		}
	}
}

func TestListMessageTombstonesFlag(t *testing.T) {
	msgOn := flags.Spec{Name: FlagName, Mode: flags.On}
	for _, tt := range []struct {
		name    string
		specs   []flags.Spec
		feature string // "" = served
	}{
		{"messaging globally off", []flags.Spec{{Name: FlagName, Mode: flags.Off}, e2eeSpec(flags.On)}, FlagName},
		{"both off: messaging first", []flags.Spec{{Name: FlagName, Mode: flags.Off}, e2eeSpec(flags.Off)}, FlagName},
		{"e2ee_dm globally off", []flags.Spec{msgOn, e2eeSpec(flags.Off)}, keys.FlagName},
		{"e2ee_dm not registered", []flags.Spec{msgOn}, keys.FlagName},
		{"e2ee_dm allowlist without the caller: served", []flags.Spec{msgOn, e2eeSpec(flags.Allowlist, bob)}, ""},
		{"messaging allowlist without the caller: served", []flags.Spec{{Name: FlagName, Mode: flags.Allowlist}, e2eeSpec(flags.On)}, ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := orderRig(t, tt.specs...)
			r.putTimed(timedMsg{hexID(1), time.Hour, msgRemoved})
			resp, err := r.svc.ListMessageTombstones(context.Background(), alice, tombReq(aliceBobConv, "", 0))
			if tt.feature != "" {
				wantFeatureDisabled(t, err, tt.feature)
				if r.repo.gets != 0 || len(r.repo.syncCalls) != 0 {
					t.Errorf("a disabled call read: gets %d sync %v", r.repo.gets, r.repo.syncCalls)
				}
				return
			}
			if err != nil || len(resp.GetTombstones()) != 1 {
				t.Fatalf("resp = %v, %v; want the one tombstone", resp, err)
			}
		})
	}
}

func TestListMessageTombstonesIDsAndStatesOnly(t *testing.T) {
	// The wire shape: a tombstone carries an id and a state, nothing else (never a time, an actor or a sender).
	if fields := (&messagingv1.MessageTombstone{}).ProtoReflect().Descriptor().Fields(); fields.Len() != 2 || fields.ByName("id") == nil || fields.ByName("state") == nil {
		t.Fatalf("MessageTombstone has %d fields, want exactly id and state", fields.Len())
	}
	for _, tt := range []struct {
		name    string
		rows    []TombstoneRow
		more    bool
		want    []string
		dropped int
		next    string // the id the next token is at; "" = none
	}{
		{"a stored state other than the two and a malformed id are skipped",
			[]TombstoneRow{{hexID(1), msgRemoved}, {"NOT-AN-ID", msgRemoved}, {hexID(2), msgVisible}, {hexID(3), msgDeletedAccount}}, false,
			[]string{hexID(1), hexID(3)}, 2, ""},
		{"a skipped last row still advances the token",
			[]TombstoneRow{{hexID(1), msgRemoved}, {hexID(4), "SOMETHING"}}, true,
			[]string{hexID(1)}, 1, hexID(4)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := orderRig(t)
			r.repo.tombOverride = func() ([]TombstoneRow, bool) { return tt.rows, tt.more }
			ctx, info := logger.WithRequestInfo(context.Background())
			resp, err := r.svc.ListMessageTombstones(ctx, alice, tombReq(aliceBobConv, "", 0))
			if err != nil {
				t.Fatal(err)
			}
			if got := tombIDs(resp); !slices.Equal(got, tt.want) {
				t.Errorf("ids = %v, want %v", got, tt.want)
			}
			for _, ts := range resp.GetTombstones() {
				n := 0
				ts.ProtoReflect().Range(func(protoreflect.FieldDescriptor, protoreflect.Value) bool { n++; return true })
				if n != 2 {
					t.Errorf("%s carries %d fields, want id and state", ts.GetId(), n)
				}
			}
			if v, _ := info.Get(fieldTombDropped); v != int64(tt.dropped) { // slog stores an int as int64
				t.Errorf("dropped = %v, want %d", v, tt.dropped)
			}
			if tt.next == "" {
				if resp.GetNextPageToken() != "" {
					t.Errorf("next token %q, want none", resp.GetNextPageToken())
				}
				return
			}
			c, err := cursor.DecodeAtTTL(testCursorKey, tombstonePageBinding(alice, aliceBobConv), resp.GetNextPageToken(), r.now, 30*24*time.Hour)
			if err != nil || c.DocID != tt.next {
				t.Errorf("next token at %q (%v), want %q", c.DocID, err, tt.next)
			}
		})
	}
}
