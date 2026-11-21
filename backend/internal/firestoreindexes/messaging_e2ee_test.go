package firestoreindexes_test

import (
	"encoding/json"
	"os"
	"testing"
)

// fieldOverride is one entry of firestore.indexes.json "fieldOverrides". Indexes is nil when the key is absent and empty
// for an exemption ("indexes": []).
type fieldOverride struct {
	CollectionGroup string `json:"collectionGroup"`
	FieldPath       string `json:"fieldPath"`
	Indexes         []struct {
		Order       string `json:"order"`
		ArrayConfig string `json:"arrayConfig"`
		QueryScope  string `json:"queryScope"`
	} `json:"indexes"`
}

func readOverrides(t *testing.T, path string) map[[2]string]fieldOverride {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		FieldOverrides []fieldOverride `json:"fieldOverrides"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	out := map[[2]string]fieldOverride{}
	for _, o := range f.FieldOverrides {
		out[[2]string{o.CollectionGroup, o.FieldPath}] = o
	}
	return out
}

// The end-to-end encrypted messaging fields (E2EE plan 3 Task 9). The byte fields and the report evidence fields are
// exempt from single-field indexing (never queried; large values). The ciphertext retention sweep's collection-group query
// (messaging.SweepCiphertext: messages WHERE ctExpireAt <= now ORDER BY ctExpireAt) needs the COLLECTION_GROUP ascending
// index on messages.ctExpireAt. And five fields are queried by equality on the automatic single-field index, so an
// override on them (an exemption or a list that drops the ascending COLLECTION index) would break a query that the emulator
// never catches: messages.mlsKey (ListEpochMessages), messages.state (ListMessageTombstones), commits.senderId (the
// eraser's RewriteCommitsPage), dmWelcomes.deviceId and dmWelcomes.convId (ListWelcomes and the welcome lookups). The
// ordered ListEpochMessages (mlsKey == k ORDER BY createdAt) needs the composite pinned by
// TestMessagesMlsKeyCreatedAtCompositeIndex.
func TestEncryptedMessagingIndexOverrides(t *testing.T) {
	_, path := locate(t)
	ov := readOverrides(t, path)

	for _, k := range [][2]string{
		{"messages", "ciphertext"}, {"messages", "commitment"}, {"commits", "data"}, {"dmWelcomes", "data"},
		{"evidence", "sharedPostId"}, {"evidence", "encrypted"}, {"evidence", "verified"}, {"evidence", "undecodable"},
	} {
		o, ok := ov[k]
		if !ok || o.Indexes == nil || len(o.Indexes) != 0 {
			t.Errorf("%s.%s must be exempt from indexing (\"indexes\": []), got %+v (present %v)", k[0], k[1], o, ok)
		}
	}

	ct, ok := ov[[2]string{"messages", "ctExpireAt"}]
	hasCG := false
	for _, ix := range ct.Indexes {
		if ix.QueryScope == "COLLECTION_GROUP" && ix.Order == "ASCENDING" {
			hasCG = true
		}
	}
	if !ok || !hasCG {
		t.Errorf("messages.ctExpireAt needs an ASCENDING COLLECTION_GROUP index for the retention sweep, got %+v (present %v)", ct, ok)
	}

	for _, k := range [][2]string{{"messages", "mlsKey"}, {"messages", "state"}, {"commits", "senderId"}, {"dmWelcomes", "deviceId"}, {"dmWelcomes", "convId"}} {
		o, ok := ov[k]
		if !ok {
			continue // no override: the automatic indexes stay
		}
		kept := false
		for _, ix := range o.Indexes {
			if ix.QueryScope == "COLLECTION" && ix.Order == "ASCENDING" {
				kept = true
			}
		}
		if !kept {
			t.Errorf("%s.%s is queried by equality on its automatic index and must stay indexed; the override %+v removes it", k[0], k[1], o)
		}
	}
}

// TestMessagesMlsKeyCreatedAtCompositeIndex pins the composite the ordered ListEpochMessages query needs (messages WHERE
// mlsKey == k ORDER BY createdAt): COLLECTION scope, mlsKey ASCENDING then createdAt ASCENDING, in that order. The emulator
// enforces no index, so only this test notices its removal.
func TestMessagesMlsKeyCreatedAtCompositeIndex(t *testing.T) {
	_, path := locate(t)
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Indexes []struct {
			CollectionGroup string       `json:"collectionGroup"`
			QueryScope      string       `json:"queryScope"`
			Fields          []indexField `json:"fields"`
		} `json:"indexes"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	want := []indexField{{FieldPath: "mlsKey", Order: "ASCENDING"}, {FieldPath: "createdAt", Order: "ASCENDING"}}
	for _, ix := range f.Indexes {
		if ix.CollectionGroup != "messages" || ix.QueryScope != "COLLECTION" || len(ix.Fields) != len(want) {
			continue
		}
		match := true
		for i := range want {
			if ix.Fields[i] != want[i] {
				match = false
			}
		}
		if match {
			return
		}
	}
	t.Errorf("no COLLECTION-scope composite index on messages with mlsKey ASCENDING then createdAt ASCENDING in %s", path)
}
