package main

import (
	"strings"
	"testing"
)

func TestParseHiddenArgs(t *testing.T) {
	t.Parallel()
	const cid = "0000000000000007001"
	cases := []struct {
		name string
		sub  string
		cid  string
		a    modArgs
		ok   bool
	}{
		{"hidden", "hidden", cid, modArgs{}, true},
		{"hidden with token", "hidden", cid, modArgs{pageToken: "h1.0000000000000007101"}, true},
		{"restore-hidden full", "restore-hidden", cid, modArgs{since: "2026-11-02T09:30:00Z", dryRun: true}, true},
		{"no id", "hidden", "", modArgs{}, false},
		{"short id", "restore-hidden", "12", modArgs{}, false},
		{"hidden is read-only", "hidden", cid, modArgs{dryRun: true}, false},
		{"hidden has no since", "hidden", cid, modArgs{since: "2026-11-02T09:30:00Z"}, false},
		{"bad since", "restore-hidden", cid, modArgs{since: "yesterday"}, false},
		{"bad token", "restore-hidden", cid, modArgs{pageToken: "0000000000000007101"}, false},
		{"token with junk", "hidden", cid, modArgs{pageToken: "h1.12x"}, false},
		{"report is not for this", "restore-hidden", cid, modArgs{report: strings.Repeat("a", 32)}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			err := parseHiddenArgs(tc.sub, tc.cid, tc.a)
			if (err == nil) != tc.ok {
				t.Errorf("err = %v, want ok=%v", err, tc.ok)
			}
		})
	}
}
