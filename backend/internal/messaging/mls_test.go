package messaging

import (
	"bytes"
	"errors"
	"math"
	"slices"
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
		{"text with only an epoch", &messagingv1.SendMessageRequest{Text: "x", MlsEpoch: 1}, "text"},
		{"ciphertext only: commitment missing", &messagingv1.SendMessageRequest{Ciphertext: []byte("c")}, "report_commitment"},
		{"init eleven device ids", initReq(func(r *messagingv1.SendMessageRequest) { r.MlsInit.WelcomeDeviceIds = elevenDevices() }), "welcome_device_ids"},
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

// elevenDevices is one device id more than MaxWelcomeDevices, all distinct and well-formed.
func elevenDevices() []string {
	out := make([]string, MaxWelcomeDevices+1)
	for i := range out {
		out[i] = "device-" + strings.Repeat("x", 8) + string(rune('a'+i)) + "yyyyyyy"
	}
	return out
}

// The upper bounds are inclusive: exactly MaxCommitBytes of commit, MaxCiphertextBytes of ciphertext and
// MaxWelcomeDevices ids pass through the init path.
func TestValidateEncrypted_ExactLimitsPass(t *testing.T) {
	got, err := validateEncrypted(initReq(func(r *messagingv1.SendMessageRequest) {
		r.Ciphertext = make([]byte, MaxCiphertextBytes)
		r.MlsInit.Commit = make([]byte, MaxCommitBytes)
		r.MlsInit.WelcomeDeviceIds = elevenDevices()[:MaxWelcomeDevices]
	}))
	if err != nil || got == nil || got.Init == nil {
		t.Fatalf("got %v, %v; want a valid init", got, err)
	}
	if len(got.Init.Commit) != MaxCommitBytes || len(got.Ciphertext) != MaxCiphertextBytes || len(got.Init.DeviceIDs) != MaxWelcomeDevices {
		t.Fatalf("init = %d commit bytes, %d ciphertext bytes, %d ids", len(got.Init.Commit), len(got.Ciphertext), len(got.Init.DeviceIDs))
	}
}

func TestValidateWelcome(t *testing.T) {
	eleven := elevenDevices()
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
	commit := bytes.Repeat([]byte{7}, CommitmentBytes)
	base := encRequestHash(conv, 1, 2, []byte("abc"), commit)
	if base != encRequestHash(conv, 1, 2, []byte("abc"), bytes.Clone(commit)) {
		t.Fatal("identical input must hash equal")
	}
	otherCommit := bytes.Clone(commit)
	otherCommit[31] = 8
	for name, h := range map[string]string{
		"byte":         encRequestHash(conv, 1, 2, []byte("abd"), commit),
		"epoch":        encRequestHash(conv, 1, 3, []byte("abc"), commit),
		"generation":   encRequestHash(conv, 2, 2, []byte("abc"), commit),
		"conversation": encRequestHash(ConversationID("a", "c"), 1, 2, []byte("abc"), commit),
		"shifted":      encRequestHash(conv, 12, 0, []byte("abc"), commit),
		"commitment":   encRequestHash(conv, 1, 2, []byte("abc"), otherCommit),
		"extra part":   encRequestHash(conv, 1, 2, []byte("abc"), commit, "i|00"),
		"plaintext":    requestHash(conv, "abc", ""),
	} {
		if h == base {
			t.Errorf("%s change did not change the hash", name)
		}
	}
	if encRequestHash(conv, 1, 2, []byte("abc"), commit, "i|00") != encRequestHash(conv, 1, 2, []byte("abc"), bytes.Clone(commit), "i|"+"00") {
		t.Error("identical extra parts must hash equal")
	}
	if encRequestHash(conv, 1, 2, []byte("abc"), commit, "i|00") == encRequestHash(conv, 1, 2, []byte("abc"), commit, "i|01") {
		t.Error("a different extra part did not change the hash")
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

func TestWelcomeTargets(t *testing.T) {
	callerActive, peerActive := []string{devAlice1, devAlice2}, []string{devBob1}
	tests := []struct {
		name string
		ids  []string
		want []welcomeTarget // nil = refused
	}{
		{"recipient's", []string{devBob1}, []welcomeTarget{{bob, devBob1}}},
		{"both users', in request order", []string{devAlice2, devBob1}, []welcomeTarget{{alice, devAlice2}, {bob, devBob1}}},
		{"caller's only", []string{devAlice1}, nil},
		{"an inactive or unknown id", []string{devBob1, devBob2}, nil},
		{"none", nil, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := welcomeTargets(tt.ids, alice, bob, callerActive, peerActive)
			if ok != (tt.want != nil) || !slices.Equal(got, tt.want) {
				t.Fatalf("welcomeTargets = %v, %v; want %v", got, ok, tt.want)
			}
		})
	}
	// An id both users registered is the recipient's (stored once, and it counts as the recipient's).
	got, ok := welcomeTargets([]string{devBob1}, alice, bob, []string{devBob1}, []string{devBob1})
	if !ok || len(got) != 1 || got[0].Owner != bob {
		t.Fatalf("shared id = %v, %v; want the recipient's", got, ok)
	}
}

func TestInitDigest(t *testing.T) {
	base := &mlsInit{Commit: []byte("c"), Welcome: []byte("w"), DeviceIDs: []string{devBob1, devAlice1}}
	d := initDigest(base)
	if !strings.HasPrefix(d, "i|") || len(d) != 2+64 {
		t.Fatalf("digest = %q, want i| and 64 hex", d)
	}
	if got := initDigest(&mlsInit{Commit: []byte("c"), Welcome: []byte("w"), DeviceIDs: []string{devAlice1, devBob1}}); got != d {
		t.Error("the same ids in another order digest differently")
	}
	if !slices.Equal(base.DeviceIDs, []string{devBob1, devAlice1}) {
		t.Error("initDigest reordered the request's ids")
	}
	for name, other := range map[string]*mlsInit{
		"commit":           {Commit: []byte("c2"), Welcome: []byte("w"), DeviceIDs: base.DeviceIDs},
		"welcome":          {Commit: []byte("c"), Welcome: []byte("w2"), DeviceIDs: base.DeviceIDs},
		"ids":              {Commit: []byte("c"), Welcome: []byte("w"), DeviceIDs: []string{devBob1}},
		"commit<->welcome": {Commit: []byte("w"), Welcome: []byte("c"), DeviceIDs: base.DeviceIDs},
		"boundary shift":   {Commit: []byte("cw"), Welcome: []byte(""), DeviceIDs: base.DeviceIDs},
	} {
		if initDigest(other) == d {
			t.Errorf("another %s digests the same", name)
		}
	}
	plain := encRequestHash("0123456789abcdef0123456789abcdef", 1, 1, []byte("ct"), testCommitment)
	if with := encRequestHash("0123456789abcdef0123456789abcdef", 1, 1, []byte("ct"), testCommitment, d); with == plain {
		t.Error("the init part does not change the request hash")
	}
}

func TestWelcomeDocID(t *testing.T) {
	conv := "0123456789abcdef0123456789abcdef"
	id := welcomeDocID(conv, 1, 0, devBob1)
	if !ValidID(id) {
		t.Fatalf("id %q is not 32 lower-case hex", id)
	}
	seen := map[string]string{id: "base"}
	for name, other := range map[string]string{
		"device":     welcomeDocID(conv, 1, 0, devBob2),
		"epoch":      welcomeDocID(conv, 1, 1, devBob1),
		"generation": welcomeDocID(conv, 2, 0, devBob1),
		"shifted":    welcomeDocID(conv, 11, 0, devBob1), // "1|10" vs "11|0" style ambiguity
		"shifted2":   welcomeDocID(conv, 1, 10, devBob1),
	} {
		if prev, dup := seen[other]; dup {
			t.Errorf("%s collides with %s", name, prev)
		}
		seen[other] = name
	}
	if welcomeDocID(conv, 1, 0, devBob1) != id {
		t.Error("not deterministic")
	}
}

// encGate's mls_init rows: the device verdict first, then an MLS conversation is STALE_EPOCH with its pair whatever pair the
// init states (it always states (1, 1)); a NONE or new conversation passes.
func TestEncGate_Init(t *testing.T) {
	plain := ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted}
	at11, at34 := mlsConv(1, 1), mlsConv(3, 4)
	good := &encSend{Ciphertext: []byte("c"), Commitment: testCommitment, Gen: 1, Epoch: 1, Init: &mlsInit{DevicesOK: true}}
	bad := &encSend{Ciphertext: []byte("c"), Commitment: testCommitment, Gen: 1, Epoch: 1, Init: &mlsInit{}}
	var stale *staleEpochError
	if err := encGate(nil, good); err != nil {
		t.Errorf("new conversation: %v", err)
	}
	if err := encGate(&plain, good); err != nil {
		t.Errorf("NONE conversation: %v", err)
	}
	for _, c := range []*ConvDoc{nil, &plain, &at11} {
		if err := encGate(c, bad); !errors.Is(err, errWelcomeDevices) {
			t.Errorf("bad devices on %+v: %v", c, err)
		}
	}
	if err := encGate(&at11, good); !errors.As(err, &stale) || stale.Gen != 1 || stale.Epoch != 1 {
		t.Errorf("MLS at (1, 1): %v, want stale (1, 1)", err)
	}
	if err := encGate(&at34, good); !errors.As(err, &stale) || stale.Gen != 3 || stale.Epoch != 4 {
		t.Errorf("MLS at (3, 4): %v, want stale (3, 4)", err)
	}
}
