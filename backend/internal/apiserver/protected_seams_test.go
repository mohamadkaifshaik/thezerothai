package apiserver

import (
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// W3-36 L-5: requireProtectedSeams names every missing seam, typed nils included.
func TestRequireProtectedSeams(t *testing.T) {
	t.Parallel()
	var typedNil *identity.ProtectedSetLoader
	var nilAud engagement.RowAudience
	tests := []struct {
		name      string
		seams     []protectedSeam
		wantNames []string
	}{
		{"all wired", []protectedSeam{{"a", &identity.ProtectedSetLoader{}}, {"b", struct{}{}}}, nil},
		{"nil interface", []protectedSeam{{"engagement.Deps.Audience", nilAud}, {"ok", &identity.ProtectedSetLoader{}}}, []string{"engagement.Deps.Audience"}},
		{"typed nil pointer", []protectedSeam{{"loader", typedNil}}, []string{"loader"}},
		{"untyped nil", []protectedSeam{{"x", nil}, {"y", nil}}, []string{"x", "y"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := requireProtectedSeams(tt.seams)
			if len(tt.wantNames) == 0 {
				if err != nil {
					t.Fatalf("err = %v, want nil", err)
				}
				return
			}
			if !errors.Is(err, errProtectedSeamMissing) {
				t.Fatalf("err = %v, want errProtectedSeamMissing", err)
			}
			for _, n := range tt.wantNames {
				if !strings.Contains(err.Error(), n) {
					t.Errorf("err %q does not name %q", err, n)
				}
			}
		})
	}
}

// The W3-35a guard for L-5: apiserver.go still passes the protected set or audience to all eight seams and checks them.
// A source scan (no emulator), so a refactor that drops a site fails `make ci`, not only the integration suite.
func TestProtectedSeamsAllWiredInBuild(t *testing.T) {
	t.Parallel()
	b, err := os.ReadFile("apiserver.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, want := range []string{
		"protectedAuthors := identity.NewProtectedSetLoader(",
		"Protected:               protectedAuthors,",
		"identity.WithProtectedAuthors(protectedAuthors",
		"Audience:  notifAudience,",
		"posts.WithProtectedAuthors(protectedAuthors)",
		"Audience: engAudience,",
		"timeline.WithProtectedAuthors(protectedAuthors)",
		"posts.NewSnapshotAudience(protectedAuthors)",
		"Audience: searchAudience,",
		"requireProtectedSeams([]protectedSeam{",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("apiserver.go no longer contains %q", want)
		}
	}
}
