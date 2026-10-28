package cursortest

import "testing"

func TestTamperAlwaysChangesAMiddleCharacter(t *testing.T) {
	for _, tok := range []string{"abcdefgh", "AAAAAAAA", "xyzA", "q", ""} {
		got := Tamper(tok)
		if got == tok {
			t.Errorf("Tamper(%q) = %q, unchanged", tok, got)
		}
		if tok != "" && len(got) != len(tok) {
			t.Errorf("Tamper(%q) changed the length: %q", tok, got)
		}
	}
}
