//go:build integration

package apiserver

// Report an end-to-end encrypted message over the real Build chain on the emulators: the reporter discloses the
// MessageContent bytes, the server checks them against the sender's commitment (verified, one byte changed, swept), the
// payload rules come after the existing refusals (a stranger gets the very same NOT_FOUND with or without a payload), the
// evidence child keeps only text, shared post id and the verdict (no report key, payload, ciphertext or commitment in any
// moderation document), a replay keeps the first evidence, and no log line carries the content. e2ee_dm is off for
// everyone on the reporting chain: reporting needs only reports and messaging.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/encoding/protowire"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// e2eeReportKey is a recognisable report key: it must appear in no stored moderation document and no log.
var e2eeReportKey = bytes.Repeat([]byte("K"), 32)

// rawContent is a MessageContent as a device could have encrypted it: report_key first, an unknown field, then the text
// and the shared post id (not the canonical field order, so a re-serialisation would not reproduce it).
func rawContent(text, shared string) []byte {
	var b []byte
	b = protowire.AppendTag(b, 3, protowire.BytesType)
	b = protowire.AppendBytes(b, e2eeReportKey)
	b = protowire.AppendTag(b, 15, protowire.VarintType)
	b = protowire.AppendVarint(b, 42)
	b = protowire.AppendTag(b, 1, protowire.BytesType)
	b = protowire.AppendString(b, text)
	if shared != "" {
		b = protowire.AppendTag(b, 2, protowire.BytesType)
		b = protowire.AppendString(b, shared)
	}
	return b
}

// sendEncrypted has alice send one encrypted message at (1, 1) committing to payload; it returns the message id.
func (w e2eeWorld) sendEncrypted(t *testing.T, e *dmChain, payload []byte, ciphertext string) string {
	t.Helper()
	sum := messaging.ReportCommitment(payload)
	res, err := e.msg.SendMessage(context.Background(), authed(w.alice.token, &messagingv1.SendMessageRequest{
		IdempotencyKey: contractKey("e2ee-send"), Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: w.conv},
		Ciphertext: []byte(ciphertext), ReportCommitment: sum[:], MlsGeneration: 1, MlsEpoch: 1,
	}))
	if err != nil {
		t.Fatalf("encrypted send: %v", err)
	}
	return res.Msg.GetMessage().GetId()
}

func (e *dmChain) reportWith(who dmUser, convID, msgID string, payload []byte) (*moderationv1.ReportContentResponse, error) {
	r, err := e.moderation.ReportContent(context.Background(), authed(who.token, &moderationv1.ReportContentRequest{
		IdempotencyKey: contractKey("e2ee-report"), TargetType: moderationv1.ReportTargetType_REPORT_TARGET_TYPE_MESSAGE,
		TargetId: convID + ":" + msgID, Reason: moderationv1.ReportReason_REPORT_REASON_HARASSMENT, MessagePayload: payload,
	}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

// storedReport is the report document and its evidence child, raw.
func (e *dmChain) storedReport(t *testing.T, id string) (parent, child map[string]any) {
	t.Helper()
	ctx := context.Background()
	ps, err := e.fs.Collection("reports").Doc(id).Get(ctx)
	if err != nil {
		t.Fatalf("report %s: %v", id, err)
	}
	cs, err := e.fs.Collection("reports").Doc(id).Collection("evidence").Doc("message").Get(ctx)
	if err != nil {
		t.Fatalf("report %s evidence: %v", id, err)
	}
	return ps.Data(), cs.Data()
}

// noSecretBytes fails when a stored value is a byte string (moderation stores none) or a string holds any of secrets.
func noSecretBytes(t *testing.T, where string, v any, secrets ...[]byte) {
	t.Helper()
	switch x := v.(type) {
	case []byte:
		t.Errorf("%s holds bytes %x", where, x)
	case string:
		for _, s := range secrets {
			if len(s) > 0 && strings.Contains(x, string(s)) {
				t.Errorf("%s holds a secret: %q", where, x)
			}
		}
	case map[string]any:
		for k, vv := range x {
			noSecretBytes(t, where+"."+k, vv, secrets...)
		}
	case []any:
		for i, vv := range x {
			noSecretBytes(t, fmt.Sprintf("%s[%d]", where, i), vv, secrets...)
		}
	}
}

func TestMessageReport_EncryptedVerification(t *testing.T) {
	w := newE2EEWorld(t)
	e := newReportChain(t, nil) // e2ee_dm off for everyone here
	ctx := context.Background()
	payload := rawContent("you will regret this", "1234567890123456789")
	m1 := w.sendEncrypted(t, e, payload, "ciphertext-one")
	m2 := w.sendEncrypted(t, e, rawContent("zqsecond", ""), "ciphertext-two")
	m3 := w.sendEncrypted(t, e, rawContent("zqthird", ""), "ciphertext-three")

	// Verified: the exact raw bytes (non-canonical order, an unknown field) hash to the commitment.
	res, err := e.reportWith(w.bob, w.conv, m1, payload)
	if err != nil || res.GetAlreadyReported() || res.GetReportId() != moderation.ReportID(w.bob.uid, moderation.TargetMessage, w.conv+":"+m1) {
		t.Fatalf("verified report = %v, %v", res, err)
	}
	parent, child := e.storedReport(t, res.GetReportId())
	if child["text"] != "you will regret this" || child["encrypted"] != true || child["verified"] != true || child["sharedPostId"] != "1234567890123456789" || len(child) != 5 {
		t.Errorf("child = %v, want text, expireAt, encrypted, verified, sharedPostId", child)
	}
	if parent["targetOwnerId"] != w.alice.uid || parent["status"] != "OPEN" {
		t.Errorf("report = %v", parent)
	}
	got, err := moderation.NewFirestoreRepo(e.fs, nil).Get(ctx, res.GetReportId())
	if err != nil || !got.Evidence.MessageEncrypted || !got.Evidence.MessageVerified || got.Evidence.Text != "you will regret this" {
		t.Fatalf("Ops.Get = %+v, %v", got.Evidence, err)
	}

	// A replay with other bytes is already_reported and keeps the first evidence (the report id is the idempotency).
	again, err := e.reportWith(w.bob, w.conv, m1, rawContent("something else", ""))
	if err != nil || !again.GetAlreadyReported() {
		t.Fatalf("replay = %v, %v", again, err)
	}
	if _, c := e.storedReport(t, res.GetReportId()); c["text"] != "you will regret this" || c["verified"] != true {
		t.Errorf("replay changed the evidence: %v", c)
	}

	// Unverified: one byte changed is still accepted, with the same answer shape.
	changed := rawContent("zqsecond", "")
	changed[len(changed)-1] ^= 1
	r2, err := e.reportWith(w.bob, w.conv, m2, changed)
	if err != nil || r2.GetAlreadyReported() {
		t.Fatalf("unverified report = %v, %v", r2, err)
	}
	if _, c := e.storedReport(t, r2.GetReportId()); c["encrypted"] != true || c["verified"] != nil || c["text"] != "zqsecone" { // the changed last byte is the text's: "zqsecond" -> "zqsecone"
		t.Errorf("unverified child = %v", c)
	}

	// Swept (the 30-day sweep set ctRemoved; bytes left behind on purpose): still VISIBLE, reportable, never verified.
	msgRef := e.fs.Collection("conversations").Doc(w.conv).Collection("messages")
	if _, err := msgRef.Doc(m3).Update(ctx, []firestore.Update{{Path: "ctRemoved", Value: true}}); err != nil {
		t.Fatal(err)
	}
	r3, err := e.reportWith(w.bob, w.conv, m3, rawContent("zqthird", ""))
	if err != nil {
		t.Fatalf("swept report: %v", err)
	}
	if _, c := e.storedReport(t, r3.GetReportId()); c["encrypted"] != true || c["verified"] != nil || c["text"] != "zqthird" {
		t.Errorf("swept child = %v", c)
	}

	// No stored moderation document holds the report key, the raw payload, a ciphertext or a commitment.
	for _, id := range []string{res.GetReportId(), r2.GetReportId(), r3.GetReportId()} {
		p, c := e.storedReport(t, id)
		sum := messaging.ReportCommitment(payload)
		secrets := [][]byte{e2eeReportKey, payload, sum[:], []byte("ciphertext-")}
		noSecretBytes(t, "reports/"+id, p, secrets...)
		noSecretBytes(t, "reports/"+id+"/evidence/message", c, secrets...)
	}

	// The payload rules that depend on the message: required for an encrypted one; must parse.
	m4 := w.sendEncrypted(t, e, rawContent("fourth", ""), "ciphertext-four")
	_, err = e.reportWith(w.bob, w.conv, m4, nil)
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "message_payload")
	_, err = e.reportWith(w.bob, w.conv, m4, []byte{0xff, 0xff})
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "message_payload")
	_, err = e.reportWith(w.bob, w.conv, m4, make([]byte, moderation.MaxMessagePayloadBytes+1))
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "message_payload")

	// The existing refusals keep their order and bytes: the caller's own message is VALIDATION target_id; a stranger gets
	// the same NOT_FOUND with or without a payload, and the same as for an unknown message, so nothing says "encrypted".
	_, err = e.reportWith(w.alice, w.conv, m4, rawContent("fourth", ""))
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "target_id")
	carol := e.user(t)
	_, withPayload := e.reportWith(carol, w.conv, m4, rawContent("fourth", ""))
	_, withoutPayload := e.reportWith(carol, w.conv, m4, nil)
	_, unknown := e.reportWith(w.bob, w.conv, strings.Repeat("f", 32), nil)
	if wireBytes(t, withPayload) != wireBytes(t, withoutPayload) || wireBytes(t, withPayload) != wireBytes(t, unknown) {
		t.Errorf("stranger with payload %v / without %v / unknown message %v differ", withPayload, withoutPayload, unknown)
	}
	// A taken-down encrypted message (bytes still stored) is the same NOT_FOUND.
	if _, err := msgRef.Doc(m4).Update(ctx, []firestore.Update{{Path: "state", Value: messaging.MessageStateRemoved}}); err != nil {
		t.Fatal(err)
	}
	_, removed := e.reportWith(w.bob, w.conv, m4, rawContent("fourth", ""))
	if wireBytes(t, removed) != wireBytes(t, unknown) {
		t.Errorf("taken-down message = %v, want the one NOT_FOUND", removed)
	}

	// The log: the verdict as a boolean, never the content, the payload, the report key or an id.
	lines := e.logs.requestLines(rpcReportContent)
	var verdicts []any
	for _, l := range lines {
		if v, ok := l["message_verified"]; ok {
			verdicts = append(verdicts, v)
		}
	}
	// verified, one byte changed, swept; the replay stored nothing and logs no verdict.
	if fmt.Sprint(verdicts) != "[true false false]" {
		t.Errorf("message_verified fields = %v, want [true false false]", verdicts)
	}
	all := e.logText()
	sum := messaging.ReportCommitment(payload)
	secrets := []string{"regret", "1234567890123456789", "zqsec", "zqthird", "something else", "ciphertext-", w.conv, m1, w.alice.uid, w.bob.uid}
	// Byte values would reach a JSON log as base64 or hex: scan for every form of the key, the payload and the commitment.
	for _, b := range [][]byte{e2eeReportKey, payload, sum[:]} {
		secrets = append(secrets, string(b), base64.StdEncoding.EncodeToString(b), base64.RawURLEncoding.EncodeToString(b), hex.EncodeToString(b))
	}
	for _, secret := range secrets {
		if strings.Contains(all, secret) {
			t.Errorf("the API log contains %q", secret)
		}
	}
}

// A plaintext message must be reported without a payload.
func TestMessageReport_PlaintextRefusesAPayload(t *testing.T) {
	e := newReportChain(t, nil)
	th := e.reportThread(t)
	_, err := e.reportWith(th.b, th.convID, th.m1, rawContent("secret text one from a", ""))
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "message_payload")
	res, err := e.reportWith(th.b, th.convID, th.m1, nil)
	if err != nil || res.GetAlreadyReported() {
		t.Fatalf("plaintext report = %v, %v", res, err)
	}
	if _, c := e.storedReport(t, res.GetReportId()); len(c) != 2 || c["text"] != "secret text one from a" {
		t.Errorf("plaintext child = %v, want only text and expireAt", c)
	}
}
