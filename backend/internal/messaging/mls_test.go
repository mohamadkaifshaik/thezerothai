package messaging

import (
	"bytes"
	"errors"
	"math"
	"sort"
	"strings"
	"testing"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

const (
	devA = "device-aaaaaaaaaaaa"
	devB = "device-bbbbbbbbbbbb"
)

func encReq(mut func(r *messagingv1.SendMessageRequest)) *messagingv1.SendMessageRequest {
	r := &messagingv1.SendMessageRequest{
		Ciphertext:       []byte("ct"),
		ReportCommitment: bytes.Repeat([]byte{1}, CommitmentBytes),
		MlsGeneration:    1,
		MlsEpoch:         3,
	}
	if mut != nil {
		mut(r)
	}
	return r
}

func initReq(mut func(r *messagingv1.SendMessageRequest)) *messagingv1.SendMessageRequest {
	return encReq(func(r *messagingv1.SendMessageRequest) {
		r.MlsEpoch = 1
		r.MlsInit = &messagingv1.MlsInit{Commit: []byte("c"), Welcome: []byte("w"), WelcomeDeviceIds: []string{devA}}
		if mut != nil {
			mut(r)
		}
	})
}

func fieldOf(t *testing.T, err error) string {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want *apierr.Error", err)
	}
	if ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION {
		t.Fatalf("err = %v, want VALIDATION", err)
	}
	return ae.Metadata["field"]
}

func TestValidateEncrypted_PlaintextPassesThrough(t *testing.T) {
	for _, r := range []*messagingv1.SendMessageRequest{
		{},
		{Text: "hello"},
		{Text: "hello", SharedPostId: "1234567890123456789"},
	} {
		got, err := validateEncrypted(r)
		if got != nil || err != nil {
			t.Fatalf("validateEncrypted(%v) = %v, %v; want nil, nil", r, got, err)
		}
	}
}

func TestValidateEncrypted_Valid(t *testing.T) {
	got, err := validateEncrypted(encReq(nil))
	if err != nil || got == nil {
		t.Fatalf("got %v, %v", got, err)
	}
	if got.Gen != 1 || got.Epoch != 3 || got.Init != nil || string(got.Ciphertext) != "ct" || len(got.Commitment) != CommitmentBytes {
		t.Fatalf("encSend = %+v", got)
	}
	got, err = validateEncrypted(initReq(nil))
	if err != nil || got == nil || got.Init == nil {
		t.Fatalf("init: got %v, %v", got, err)
	}
	if got.Gen != 1 || got.Epoch != 1 || string(got.Init.Commit) != "c" || string(got.Init.Welcome) != "w" || len(got.Init.DeviceIDs) != 1 {
		t.Fatalf("init = %+v", got.Init)
	}
}

func TestValidateEncrypted_Fields(t *testing.T) {
	big := func(n int) []byte { return make([]byte, n) }
	tests := []struct {
		name  string
		req   *messagingv1.SendMessageRequest
		field string
	}{
		{"text with ciphertext", encReq(func(r *messagingv1.SendMessageRequest) { r.Text = "x" }), "text"},
		{"shared post with ciphertext", encReq(func(r *messagingv1.SendMessageRequest) { r.SharedPostId = "1" }), "shared_post_id"},
		{"only commitment: ciphertext missing", &messagingv1.SendMessageRequest{ReportCommitment: big(32), MlsGeneration: 1, MlsEpoch: 1}, "ciphertext"},
		{"ciphertext too big", encReq(func(r *messagingv1.SendMessageRequest) { r.Ciphertext = big(MaxCiphertextBytes + 1) }), "ciphertext"},
		{"commitment missing", encReq(func(r *messagingv1.SendMessageRequest) { r.ReportCommitment = nil }), "report_commitment"},
		{"commitment short", encReq(func(r *messagingv1.SendMessageRequest) { r.ReportCommitment = big(31) }), "report_commitment"},
		{"commitment long", encReq(func(r *messagingv1.SendMessageRequest) { r.ReportCommitment = big(33) }), "report_commitment"},
		{"generation zero", encReq(func(r *messagingv1.SendMessageRequest) { r.MlsGeneration = 0 }), "mls_generation"},
		{"generation overflow", encReq(func(r *messagingv1.SendMessageRequest) { r.MlsGeneration = math.MaxInt64 + 1 }), "mls_generation"},
		{"epoch zero", encReq(func(r *messagingv1.SendMessageRequest) { r.MlsEpoch = 0 }), "mls_epoch"},
		{"epoch overflow", encReq(func(r *messagingv1.SendMessageRequest) { r.MlsEpoch = math.MaxUint64 }), "mls_epoch"},
		{"init generation 2", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsGeneration = 2 }), "mls_generation"},
		{"init epoch 2", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsEpoch = 2 }), "mls_epoch"},
		{"init commit empty", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsInit.Commit = nil }), "commit"},
		{"init commit too big", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsInit.Commit = big(MaxCommitBytes + 1) }), "commit"},
		{"init welcome empty", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsInit.Welcome = nil }), "welcome"},
		{"init welcome too big", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsInit.Welcome = big(MaxWelcomeBytes + 1) }), "welcome"},
		{"init no device ids", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsInit.WelcomeDeviceIds = nil }), "welcome_device_ids"},
		{"init bad device id", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsInit.WelcomeDeviceIds = []string{"short"} }), "welcome_device_ids"},
		{"init duplicate device ids", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsInit.WelcomeDeviceIds = []string{devA, devA} }), "welcome_device_ids"},
		{"init empty mls_init message", &messagingv1.SendMessageRequest{Ciphertext: []byte("c"), ReportCommitment: big(32), MlsGeneration: 1, MlsEpoch: 1, MlsInit: &messagingv1.MlsInit{}}, "commit"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := validateEncrypted(tt.req)
			if err == nil || got != nil {
				t.Fatalf("got %v, %v; want error on %s", got, err, tt.field)
			}
			if f := fieldOf(t, err); f != tt.field {
				t.Fatalf("field = %q, want %q", f, tt.field)
			}
		})
	}
}

func TestValidateWelcome(t *testing.T) {
	eleven := make([]string, 11)
	for i := range eleven {
		eleven[i] = "device-" + strings.Repeat("x", 8) + string(rune('a'+i)) + "yyyyyyy"
	}
	tests := []struct {
		name    string
		welcome []byte
		ids     []string
		field   string // "" = valid
	}{
		{"both empty", nil, nil, ""},
		{"valid", []byte("w"), []string{devA, devB}, ""},
		{"welcome without ids", []byte("w"), nil, "welcome_device_ids"},
		{"ids without welcome", nil, []string{devA}, "welcome_device_ids"},
		{"too many ids", []byte("w"), eleven, "welcome_device_ids"},
		{"ten ids ok", []byte("w"), eleven[:10], ""},
		{"duplicate", []byte("w"), []string{devA, devA}, "welcome_device_ids"},
		{"invalid id", []byte("w"), []string{"bad id with spaces!!"}, "welcome_device_ids"},
		{"welcome too big", make([]byte, MaxWelcomeBytes+1), []string{devA}, "welcome"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateWelcome(tt.welcome, tt.ids)
			if tt.field == "" {
				if err != nil {
					t.Fatalf("err = %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("want error on %s", tt.field)
			}
			if f := fieldOf(t, err); f != tt.field {
				t.Fatalf("field = %q, want %q", f, tt.field)
			}
		})
	}
}

func TestEncRequestHash(t *testing.T) {
	conv := ConversationID("a", "b")
	base := encRequestHash(conv, 1, 2, []byte("abc"))
	if base != encRequestHash(conv, 1, 2, []byte("abc")) {
		t.Fatal("identical input must hash equal")
	}
	for name, h := range map[string]string{
		"byte":         encRequestHash(conv, 1, 2, []byte("abd")),
		"epoch":        encRequestHash(conv, 1, 3, []byte("abc")),
		"generation":   encRequestHash(conv, 2, 2, []byte("abc")),
		"conversation": encRequestHash(ConversationID("a", "c"), 1, 2, []byte("abc")),
		"shifted":      encRequestHash(conv, 12, 0, []byte("abc")),
		"plaintext":    requestHash(conv, "abc", ""),
	} {
		if h == base {
			t.Errorf("%s change did not change the hash", name)
		}
	}
	if len(base) != 32 {
		t.Fatalf("len = %d, want 32", len(base))
	}
}

func TestCommitDocID_Sorts(t *testing.T) {
	ids := []string{commitDocID(2, 0), commitDocID(1, 10), commitDocID(1, 9)}
	sort.Strings(ids)
	want := []string{commitDocID(1, 9), commitDocID(1, 10), commitDocID(2, 0)}
	for i := range ids {
		if ids[i] != want[i] {
			t.Fatalf("sorted = %v, want %v", ids, want)
		}
	}
	if commitDocID(1, 9) != "0000000001_0000000009" {
		t.Fatalf("commitDocID(1,9) = %q", commitDocID(1, 9))
	}
}

func TestMlsKey(t *testing.T) {
	if got := mlsKey(3, 12); got != "3:12" {
		t.Fatalf("mlsKey = %q", got)
	}
	if mlsKey(1, 23) == mlsKey(12, 3) {
		t.Fatal("keys must be distinct")
	}
}

func TestConvDocEncrypted(t *testing.T) {
	if (ConvDoc{}).encrypted() || (ConvDoc{Encryption: encNone}).encrypted() {
		t.Fatal("plaintext conversation reads as encrypted")
	}
	if !(ConvDoc{Encryption: encMLS}).encrypted() {
		t.Fatal("MLS conversation reads as plaintext")
	}
}

func TestLastDocFields_AlwaysWritesEncrypted(t *testing.T) {
	for _, enc := range []bool{false, true} {
		fields := LastDoc{Encrypted: enc}.fields()
		if v, ok := fields["encrypted"]; !ok || v != enc {
			t.Fatalf("fields = %v, want encrypted=%v written", fields, enc)
		}
	}
}
