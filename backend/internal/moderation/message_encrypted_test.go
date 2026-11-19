package moderation

import (
	"bytes"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// reportKey is a recognisable 32-byte report key: it must never reach the evidence or a log.
var reportKey = bytes.Repeat([]byte{0xA5}, 32)

func contentPayload(t *testing.T, text, shared string) []byte {
	t.Helper()
	b, err := proto.Marshal(&messagingv1.MessageContent{Text: text, SharedPostId: shared, ReportKey: reportKey})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func encInput(payload []byte) ReportInput {
	in := msgInput()
	in.MessagePayload = payload
	return in
}

func wantPayloadValidation(t *testing.T, err error) *apierr.Error {
	t.Helper()
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["field"] != "message_payload" {
		t.Fatalf("err = %v, want field message_payload", err)
	}
	return ae
}

// requestFields renders every request-log field set during a call, to check what a log line would carry.
func requestFields(info *logger.RequestInfo) string {
	var b strings.Builder
	for _, a := range info.Fields() {
		fmt.Fprintf(&b, "%s=%v ", a.Key, a.Value)
	}
	return b.String()
}

// Verified and unverified reports are both accepted with the same answer; the evidence holds the disclosed text and
// shared post id and the lookup's verdict, the lookup gets the payload's raw bytes, and the log carries only the verdict.
func TestReport_EncryptedMessageEvidence(t *testing.T) {
	t.Parallel()
	for _, verified := range []bool{true, false} {
		t.Run(fmt.Sprintf("verified=%v", verified), func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			payload := contentPayload(t, "you will regret this", "1234567890123456789")
			l := &fakeLookup{msg: ReportedMessage{SenderUID: sender, SenderHandle: "mallory", CreatedAt: f.now, Encrypted: true, Verified: verified}}
			ctx, info := logger.WithRequestInfo(gctx())
			res, err := f.msgSvc(l).Report(ctx, reporter, encInput(payload))
			if err != nil || res.AlreadyReported {
				t.Fatalf("res = %+v, err = %v", res, err)
			}
			if len(l.payloads) != 1 || !bytes.Equal(l.payloads[0], payload) {
				t.Errorf("the lookup got %x, want the raw payload", l.payloads)
			}
			want := &Evidence{Text: "you will regret this", AuthorHandle: "mallory", PostCreatedAt: f.now,
				MessageEncrypted: true, MessageVerified: verified, SharedPostID: "1234567890123456789"}
			if got := f.repo.calls[0].Report.Evidence; !reflect.DeepEqual(got, want) {
				t.Errorf("evidence = %+v, want %+v", got, want)
			}
			if v, ok := info.Get(fieldVerified); !ok || v != verified {
				t.Errorf("log field %s = %v (%v), want %v", fieldVerified, v, ok, verified)
			}
			logged := requestFields(info)
			for _, secret := range []string{"regret", "1234567890123456789", fmt.Sprintf("%x", reportKey), string(reportKey)} {
				if strings.Contains(logged, secret) {
					t.Errorf("request log carries %q: %s", secret, logged)
				}
			}
		})
	}
}

// The payload is parsed leniently (fields in any order, unknown fields) and handed to the lookup byte for byte, never
// re-serialised; the stored text is the parsed one.
func TestReport_EncryptedPayloadIsPassedRawAndParsedLeniently(t *testing.T) {
	t.Parallel()
	var raw []byte
	raw = protowire.AppendTag(raw, 3, protowire.BytesType)
	raw = protowire.AppendBytes(raw, reportKey)
	raw = protowire.AppendTag(raw, 99, protowire.VarintType) // unknown to MessageContent
	raw = protowire.AppendVarint(raw, 7)
	raw = protowire.AppendTag(raw, 1, protowire.BytesType)
	raw = protowire.AppendString(raw, "out of order")
	f := newFixture()
	l := &fakeLookup{msg: ReportedMessage{SenderUID: sender, Encrypted: true, Verified: true}}
	if _, err := f.msgSvc(l).Report(gctx(), reporter, encInput(raw)); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(l.payloads[0], raw) {
		t.Errorf("the lookup got %x, want the raw bytes %x", l.payloads[0], raw)
	}
	if ev := f.repo.calls[0].Report.Evidence; ev.Text != "out of order" || !ev.MessageVerified || ev.SharedPostID != "" {
		t.Errorf("evidence = %+v", ev)
	}
}

// The content's shape is the sending app's rule: an over-long text is kept and a shared post id that is not one is
// dropped, never a refusal (a sender must not be able to make its own message unreportable).
func TestReport_EncryptedContentShapeIsNotRefused(t *testing.T) {
	t.Parallel()
	f := newFixture()
	long := strings.Repeat("x", 4000)
	l := &fakeLookup{msg: ReportedMessage{SenderUID: sender, Encrypted: true}}
	if _, err := f.msgSvc(l).Report(gctx(), reporter, encInput(contentPayload(t, long, "../../etc"))); err != nil {
		t.Fatal(err)
	}
	if ev := f.repo.calls[0].Report.Evidence; ev.Text != long || ev.SharedPostID != "" || ev.MessageVerified {
		t.Errorf("evidence text %d chars, shared %q, verified %v", len(ev.Text), ev.SharedPostID, ev.MessageVerified)
	}
}

// The payload refusals that depend on the message come after the lookup; the format ones before any work.
func TestReport_EncryptedPayloadRefusals(t *testing.T) {
	t.Parallel()
	encrypted := ReportedMessage{SenderUID: sender, Encrypted: true}
	plaintext := ReportedMessage{SenderUID: sender, Text: "x"}
	tests := []struct {
		name       string
		lookup     *fakeLookup
		in         func(t *testing.T) ReportInput
		wantLookup bool
	}{
		{"missing payload on an encrypted message", &fakeLookup{msg: encrypted},
			func(*testing.T) ReportInput { return encInput(nil) }, true},
		{"payload on a plaintext message", &fakeLookup{msg: plaintext},
			func(t *testing.T) ReportInput { return encInput(contentPayload(t, "x", "")) }, true},
		{"malformed bytes that do not match the commitment", &fakeLookup{msg: encrypted},
			func(*testing.T) ReportInput { return encInput([]byte{0xff, 0xff, 0xff}) }, true},
		{"truncated text that does not match the commitment", &fakeLookup{msg: encrypted},
			func(*testing.T) ReportInput { return encInput([]byte{0x0a, 0x05, 'h', 'i'}) }, true},
		{"payload over 8192 bytes", &fakeLookup{msg: encrypted},
			func(*testing.T) ReportInput { return encInput(make([]byte, MaxMessagePayloadBytes+1)) }, false},
		{"payload on a POST report", &fakeLookup{msg: encrypted},
			func(t *testing.T) ReportInput {
				in := okInput()
				in.MessagePayload = contentPayload(t, "x", "")
				return in
			}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			_, err := f.msgSvc(tt.lookup).Report(gctx(), reporter, tt.in(t))
			ae := wantPayloadValidation(t, err)
			if strings.Contains(ae.Message, "\xff") || strings.Contains(ae.Message, "proto") {
				t.Errorf("message %q quotes the payload or the parser", ae.Message)
			}
			if got := len(tt.lookup.calls) > 0; got != tt.wantLookup {
				t.Errorf("lookup called = %v, want %v", got, tt.wantLookup)
			}
			if len(f.repo.calls) != 0 || f.posts.n != 0 {
				t.Error("a refused payload did a write or a post read")
			}
		})
	}
	// A payload at the bound is a format pass (it then fails to parse: all zero bytes are an invalid tag).
	f := newFixture()
	l := &fakeLookup{msg: encrypted}
	_, err := f.msgSvc(l).Report(gctx(), reporter, encInput(make([]byte, MaxMessagePayloadBytes)))
	_ = wantPayloadValidation(t, err)
	if len(l.calls) != 1 {
		t.Error("a payload of exactly 8192 bytes was refused before the lookup")
	}
}

// The existing refusals keep their answers when a payload is present: a non-participant (or any other unreportable cause)
// gets the one NOT_FOUND, byte-identical to a report without a payload, so the answer never says the conversation is
// encrypted; the caller's own message stays VALIDATION target_id.
func TestReport_PayloadKeepsTheExistingRefusals(t *testing.T) {
	t.Parallel()
	payload := contentPayload(t, "x", "")
	answer := func(in ReportInput, l *fakeLookup) *apierr.Error {
		f := newFixture()
		_, err := f.msgSvc(l).Report(gctx(), reporter, in)
		var ae *apierr.Error
		if !errors.As(err, &ae) {
			t.Fatalf("err = %v", err)
		}
		if len(f.repo.calls) != 0 {
			t.Error("a refusal wrote a report")
		}
		return ae
	}
	without := answer(msgInput(), &fakeLookup{err: ErrMessageNotFound})
	for name, in := range map[string]ReportInput{"with a payload": encInput(payload), "with garbage": encInput([]byte{0xff})} {
		if got := answer(in, &fakeLookup{err: ErrMessageNotFound}); !reflect.DeepEqual(got, without) {
			t.Errorf("%s: %+v differs from the answer without a payload %+v", name, got, without)
		}
	}
	own := answer(encInput(payload), &fakeLookup{err: ErrOwnMessage})
	if own.Code != connect.CodeInvalidArgument || own.Metadata["field"] != "target_id" {
		t.Errorf("own message with a payload = %+v, want VALIDATION target_id", own)
	}
}

// A sender cannot make its own message unreportable with what it puts in the content: invalid UTF-8 is kept as U+FFFD
// (what the app's lenient decoder shows), duplicate and mistyped fields decode as protobuf would, and bytes that are not
// even protobuf are accepted as "undecodable" when they are exactly what the sender committed to. Malformed bytes that do
// not match the commitment are the reporter's own and stay VALIDATION (TestReport_EncryptedPayloadRefusals).
func TestReport_EncryptedSenderContentStaysReportable(t *testing.T) {
	t.Parallel()
	field := func(b []byte, num protowire.Number, s string) []byte {
		return protowire.AppendString(protowire.AppendTag(b, num, protowire.BytesType), s)
	}
	invalidUTF8 := field(field(nil, 3, string(reportKey)), 1, "abuse\xff")
	duplicate := field(field(nil, 1, "first"), 1, "last")
	varintText := protowire.AppendVarint(protowire.AppendTag(field(nil, 3, string(reportKey)), 1, protowire.VarintType), 5)
	malformed := []byte{0x0a, 0x7f, 'x'} // a length past the end
	tests := []struct {
		name      string
		payload   []byte
		verified  bool
		want      *Evidence
		wantField bool // the request log carries the verdict
	}{
		{"invalid UTF-8, verified", invalidUTF8, true, &Evidence{Text: "abuse�", MessageEncrypted: true, MessageVerified: true}, true},
		{"invalid UTF-8, unverified", invalidUTF8, false, &Evidence{Text: "abuse�", MessageEncrypted: true}, true},
		{"duplicate text, last wins", duplicate, true, &Evidence{Text: "last", MessageEncrypted: true, MessageVerified: true}, true},
		{"text as a varint is skipped", varintText, true, &Evidence{MessageEncrypted: true, MessageVerified: true}, true},
		{"malformed but committed to", malformed, true, &Evidence{MessageEncrypted: true, MessageVerified: true, MessageUndecodable: true}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			l := &fakeLookup{msg: ReportedMessage{SenderUID: sender, SenderHandle: "mallory", CreatedAt: f.now, Encrypted: true, Verified: tt.verified}}
			ctx, info := logger.WithRequestInfo(gctx())
			if _, err := f.msgSvc(l).Report(ctx, reporter, encInput(tt.payload)); err != nil {
				t.Fatal(err)
			}
			want := *tt.want
			want.AuthorHandle, want.PostCreatedAt = "mallory", f.now
			if got := f.repo.calls[0].Report.Evidence; !reflect.DeepEqual(got, &want) {
				t.Errorf("evidence = %+v, want %+v", got, &want)
			}
			if v, ok := info.Get(fieldVerified); ok != tt.wantField || (ok && v != tt.verified) {
				t.Errorf("log verdict = %v (%v)", v, ok)
			}
			if logged := requestFields(info); strings.Contains(logged, "abuse") || strings.Contains(logged, string(reportKey)) {
				t.Errorf("request log carries content: %s", logged)
			}
		})
	}
}
