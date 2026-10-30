//go:build integration

package apiserver

import (
	"net/http"
	"strings"
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// TestRoutes_EveryRouteRefusesAnUnauthenticatedCaller probes the real handler that Build returns (the whole chain, over
// the emulators): every Connect procedure linked into the binary, and every /internal/* path, must refuse a caller
// that presents nothing, under both App Check modes and under the /api prefix Firebase Hosting uses. Only /health and
// /healthz answer without credentials. routes.go makes this true by construction; this test proves the built handler.
func TestRoutes_EveryRouteRefusesAnUnauthenticatedCaller(t *testing.T) {
	for _, mode := range []config.AppCheckMode{config.AppCheckMonitor, config.AppCheckEnforce} {
		t.Run(string(mode), func(t *testing.T) {
			env := newChain(t, func(c *config.Config) {
				c.AppCheck = mode
				c.InternalOIDCAudience = "https://probe.example.test"
				c.InternalOIDCAllowedEmails = []string{"push@probe.example.test"}
			})

			post := func(path string) int {
				t.Helper()
				req, err := http.NewRequest(http.MethodPost, env.url+path, strings.NewReader("{}"))
				if err != nil {
					t.Fatal(err)
				}
				req.Header.Set("Content-Type", "application/json")
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatalf("POST %s: %v", path, err)
				}
				defer resp.Body.Close()
				return resp.StatusCode
			}

			var procs []string
			protoregistry.GlobalFiles.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
				if !strings.HasPrefix(string(fd.Package()), "dzeroth.") {
					return true
				}
				for i := 0; i < fd.Services().Len(); i++ {
					svc := fd.Services().Get(i)
					for j := 0; j < svc.Methods().Len(); j++ {
						procs = append(procs, "/"+string(svc.FullName())+"/"+string(svc.Methods().Get(j).Name()))
					}
				}
				return true
			})
			if len(procs) < 20 {
				t.Fatalf("only %d linked procedures found; the probe is not seeing the services", len(procs))
			}
			for _, p := range procs {
				for _, prefix := range []string{"", "/api"} {
					if got := post(prefix + p); got != http.StatusUnauthorized {
						t.Errorf("POST %s%s without credentials = %d, want 401", prefix, p, got)
					}
				}
			}

			for _, p := range []string{
				"/internal/", "/internal/unknown/path",
				"/internal/pubsub/jobs", "/internal/cron/daily-maintenance", "/internal/cron/publish-scheduled", "/internal/cron/trends-refresh", "/internal/pubsub/notifications-fanout",
			} {
				for _, prefix := range []string{"", "/api"} {
					if got := post(prefix + p); got != http.StatusUnauthorized {
						t.Errorf("POST %s%s without credentials = %d, want 401", prefix, p, got)
					}
				}
			}

			for p := range publicRoutes {
				resp, err := http.Get(env.url + p)
				if err != nil {
					t.Fatal(err)
				}
				resp.Body.Close()
				if resp.StatusCode != http.StatusOK {
					t.Errorf("GET %s = %d, want 200", p, resp.StatusCode)
				}
			}
		})
	}
}
