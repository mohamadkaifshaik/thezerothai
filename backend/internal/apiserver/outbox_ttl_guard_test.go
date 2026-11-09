package apiserver

// The outbox TTL is the backstop that removes an item no sweep ever delivers, and pkg/platform/outbox stamps expireAt on
// every item. This guard keeps the Terraform `ttl_fields` entry and the code's collection and field names in step, so a
// rename on either side fails here rather than leaving items for ever. (It reads the module's default; applying it is a
// human `terraform apply`.)

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
)

func TestOutboxTTLFieldIsInTerraform(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "infra", "terraform", "modules", "firestore", "variables.tf"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)outbox_expire_at\s*=\s*\{\s*collection\s*=\s*"([^"]+)"\s*field\s*=\s*"([^"]+)"\s*\}`).FindSubmatch(raw)
	if m == nil {
		t.Fatal("variables.tf has no outbox_expire_at entry in ttl_fields")
	}
	if string(m[1]) != outbox.Collection || string(m[2]) != "expireAt" {
		t.Errorf("ttl entry = %s.%s, want %s.expireAt", m[1], m[2], outbox.Collection)
	}
	src, err := os.ReadFile(filepath.Join("..", "..", "pkg", "platform", "outbox", "outbox.go"))
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile("firestore:\"expireAt\"").Match(src) {
		t.Error("pkg/platform/outbox no longer writes expireAt")
	}
}
