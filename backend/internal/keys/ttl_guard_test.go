package keys

// The removed marks expire only through the Firestore TTL policy on keyDeviceRemovals.expireAt (the code never deletes a
// mark except with the account). This guard keeps the Terraform `ttl_fields` entry and the code's collection and field
// names in step, so a rename on either side fails here rather than leaving marks for ever. It reads the module's default;
// applying it is a human `terraform apply`.

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"testing"
)

func TestRemovalMarkTTLFieldIsInTerraform(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "infra", "terraform", "modules", "firestore", "variables.tf"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)key_device_removals_expire_at\s*=\s*\{\s*collection\s*=\s*"([^"]+)"\s*field\s*=\s*"([^"]+)"\s*\}`).FindSubmatch(raw)
	if m == nil {
		t.Fatal("variables.tf has no key_device_removals_expire_at entry in ttl_fields")
	}
	f, ok := reflect.TypeOf(markDoc{}).FieldByName("ExpireAt")
	if !ok {
		t.Fatal("markDoc has no ExpireAt")
	}
	if string(m[1]) != keyDeviceRemovalsCollection || string(m[2]) != f.Tag.Get("firestore") {
		t.Errorf("ttl entry = %s.%s, want %s.%s", m[1], m[2], keyDeviceRemovalsCollection, f.Tag.Get("firestore"))
	}
	if RemovalMarkTTL.Hours() != 90*24 {
		t.Errorf("RemovalMarkTTL = %v, want 90 days (owner decision 2026-11-23)", RemovalMarkTTL)
	}
}
