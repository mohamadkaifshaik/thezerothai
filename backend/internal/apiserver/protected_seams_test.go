package apiserver

import (
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// L-5: requireProtectedSeams names every missing seam, typed nils included.
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

// The guard for L-5: apiserver.go still passes the protected set or audience to all eight seams and checks them.
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
		"Protected: protectedAuthors,",
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

// F-03: requireAuthorStatusSeams refuses a nil author-status Directory, typed nils included, with its own sentinel.
func TestRequireAuthorStatusSeams(t *testing.T) {
	t.Parallel()
	var nilDir identity.Directory
	var typedNil *fakeAuthorDir
	tests := []struct {
		name  string
		value any
		want  bool // an error is wanted
	}{
		{"wired", &fakeAuthorDir{}, false},
		{"nil interface", nilDir, true},
		{"typed nil pointer", typedNil, true},
		{"untyped nil", nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			err := requireAuthorStatusSeams([]protectedSeam{{"search.PostsDeps.Authors", tt.value}})
			if !tt.want {
				if err != nil {
					t.Fatalf("err = %v, want nil", err)
				}
				return
			}
			if !errors.Is(err, errAuthorStatusSeamMissing) || !strings.Contains(err.Error(), "search.PostsDeps.Authors") {
				t.Fatalf("err = %v, want errAuthorStatusSeamMissing naming the seam", err)
			}
		})
	}
}

// fakeAuthorDir is a non-nil stand-in for the Directory; only its nil-ness matters to the check.
type fakeAuthorDir struct{ identity.Directory }

// The guard for F-03: apiserver.go still hands identity's Directory to SearchPosts and checks it at startup. A source scan
// (no emulator), so a refactor that drops it fails `make ci`.
func TestAuthorStatusSeamWiredInBuild(t *testing.T) {
	t.Parallel()
	b, err := os.ReadFile("apiserver.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, want := range []string{
		"var searchAuthors search.AuthorDirectory = identitySvc.(identity.Directory)",
		"requireAuthorStatusSeams([]protectedSeam{",
		"Authors: searchAuthors,",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("apiserver.go no longer contains %q", want)
		}
	}
}
