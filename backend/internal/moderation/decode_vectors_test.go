package moderation

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"unicode/utf8"
)

// TestDecodeContent_SharedVectors runs every row of testdata/report_payload_decode.json, the rows the app's Dart decoder
// runs too (client plan), through decodeContent.
func TestDecodeContent_SharedVectors(t *testing.T) {
	t.Parallel()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "report_payload_decode.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Cases []struct {
			Name             string `json:"name"`
			PayloadHex       string `json:"payload_hex"`
			WantText         string `json:"want_text"`
			WantSharedPostID string `json:"want_shared_post_id"`
			WantWireOK       bool   `json:"want_wire_ok"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	// The fixture has 27 rows (shared with the app's decoder tests): fewer means it was truncated or lost rows.
	const minCases = 27
	if len(f.Cases) < minCases {
		t.Fatalf("%d cases, want at least %d: the fixture lost rows", len(f.Cases), minCases)
	}
	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			t.Parallel()
			raw, err := hex.DecodeString(c.PayloadHex)
			if err != nil {
				t.Fatal(err)
			}
			got, ok := decodeContent(raw)
			if ok != c.WantWireOK || got.Text != c.WantText || got.SharedPostID != c.WantSharedPostID {
				t.Errorf("decodeContent = %+v, %v; want text %q, shared %q, wire ok %v", got, ok, c.WantText, c.WantSharedPostID, c.WantWireOK)
			}
			if !utf8.ValidString(got.Text) || !utf8.ValidString(got.SharedPostID) {
				t.Errorf("decoded strings are not valid UTF-8: %+v", got)
			}
		})
	}
}
