//go:build integration

package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/search"
)

// End-to-end emulator test of `opsctl trends`: the real run flag handling and output over the real
// search.TrendsStore.
func TestTrends_Integration_CLI(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	runCLI := func(args ...string) (code int, stdout, stderr string) {
		open := func(context.Context, string) (*backends, error) {
			return &backends{trends: search.NewTrendsRepo(client), close: func() {}}, nil
		}
		var out, errOut bytes.Buffer
		code = run(ctx, args, strings.NewReader(""), &out, &errOut, open, func() time.Time { return time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC) })
		return code, out.String(), errOut.String()
	}
	steps := []struct {
		name string
		args []string
		want []string
	}{
		{"hide", []string{"trends", "hide", "#Sl_u\u200dr"}, []string{`hidden: "slur" (1 on the list)`, "wrote=true"}},
		{"hide again", []string{"trends", "hide", "slur"}, []string{"already hidden", "wrote=false"}},
		{"list", []string{"trends", "list"}, []string{"1 hidden key(s)", "slur"}},
		{"unhide", []string{"trends", "unhide", "SLUR"}, []string{`unhidden: "slur" (0 on the list)`, "wrote=true"}},
		{"unhide again", []string{"trends", "unhide", "slur"}, []string{"not on the hide list", "wrote=false"}},
		{"list empty", []string{"trends", "list"}, []string{"0 hidden key(s)"}},
	}
	for _, s := range steps {
		code, out, errOut := runCLI(append(s.args, "--project", project)...)
		if code != 0 {
			t.Fatalf("%s: code %d stderr %q", s.name, code, errOut)
		}
		for _, w := range s.want {
			if !strings.Contains(out, w) {
				t.Errorf("%s: output lacks %q:\n%s", s.name, w, out)
			}
		}
	}
}
