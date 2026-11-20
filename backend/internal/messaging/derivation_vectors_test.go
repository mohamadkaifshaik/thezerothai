package messaging

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestDerivationVectors checks the rows of testdata/e2ee/derivations-v1.json that the server computes too; the app's
// Dart test (app/test/core/crypto/mls_derivations_test.dart) runs the same rows.
func TestDerivationVectors(t *testing.T) {
	t.Parallel()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "e2ee", "derivations-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		MessageID []struct {
			UID  string `json:"uid"`
			Key  string `json:"idempotency_key"`
			Want string `json:"want"`
		} `json:"message_id"`
		ReportCommitment []struct {
			ContentHex string `json:"content_hex"`
			WantHex    string `json:"want_hex"`
		} `json:"report_commitment"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.MessageID) == 0 || len(f.ReportCommitment) == 0 {
		t.Fatal("the fixture lost its message_id or report_commitment rows")
	}
	for _, r := range f.MessageID {
		if got := MessageID(r.UID, r.Key); got != r.Want {
			t.Errorf("MessageID(%q, %q) = %s, want %s", r.UID, r.Key, got, r.Want)
		}
	}
	for _, r := range f.ReportCommitment {
		content, err := hex.DecodeString(r.ContentHex)
		if err != nil {
			t.Fatal(err)
		}
		sum := ReportCommitment(content)
		if got := hex.EncodeToString(sum[:]); got != r.WantHex {
			t.Errorf("ReportCommitment(%s) = %s, want %s", r.ContentHex, got, r.WantHex)
		}
	}
}
