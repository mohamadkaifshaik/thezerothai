package moderation

import (
	"bytes"
	"testing"
)

// TestDecodeContent_GroupNestingBoundary pins protowire's recursion limit (DefaultRecursionLimit 10000: 10001 nested
// groups are accepted, 10002 refused); the app's Dart decoder uses the same boundary (message_content_codec_test.dart).
func TestDecodeContent_GroupNestingBoundary(t *testing.T) {
	t.Parallel()
	const maxGroups = 10001
	nest := func(n int) []byte {
		return append(bytes.Repeat([]byte{0x0b}, n), bytes.Repeat([]byte{0x0c}, n)...)
	}
	if _, ok := decodeContent(nest(maxGroups)); !ok {
		t.Errorf("%d nested groups: want wire ok", maxGroups)
	}
	if _, ok := decodeContent(nest(maxGroups + 1)); ok {
		t.Errorf("%d nested groups: want not wire ok", maxGroups+1)
	}
}
