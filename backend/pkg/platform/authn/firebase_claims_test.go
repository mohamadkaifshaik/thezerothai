package authn

import (
	"reflect"
	"testing"

	fbauth "firebase.google.com/go/v4/auth"
)

func TestClaimsFromToken_IdentitiesAndEmail(t *testing.T) {
	t.Parallel()
	tok := &fbauth.Token{
		UID: "u1",
		Claims: map[string]interface{}{
			"email":          "a@example.com",
			"email_verified": true,
			"auth_time":      float64(1700000000),
			"firebase":       map[string]interface{}{"sign_in_provider": "google.com"},
		},
		Firebase: fbauth.FirebaseInfo{
			SignInProvider: "google.com",
			Identities: map[string]interface{}{
				"google.com": []interface{}{"g-sub-1"},
				"email":      []interface{}{"a@example.com"},
				"bogus":      "not-a-list",
				"mixed":      []interface{}{42, "", "ok"},
				"empty":      []interface{}{},
			},
		},
	}
	got := claimsFromToken(tok)
	if got.SignInProvider != "google.com" || !got.EmailVerified || got.UID != "u1" || got.AuthTime.IsZero() {
		t.Fatalf("existing fields wrong: %+v", got)
	}
	want := map[string][]string{
		"google.com": {"g-sub-1"},
		"email":      {"a@example.com"},
		"mixed":      {"ok"},
	}
	if !reflect.DeepEqual(got.Identities, want) {
		t.Fatalf("Identities = %v, want %v", got.Identities, want)
	}
}

func TestClaimsFromToken_AbsentClaimsAreEmpty(t *testing.T) {
	t.Parallel()
	got := claimsFromToken(&fbauth.Token{UID: "u2", Claims: map[string]interface{}{}})
	if got.Identities != nil || got.UID != "u2" {
		t.Fatalf("absent claims should leave Identities empty: %+v", got)
	}
}
