package pubsubpublish

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"google.golang.org/api/option"
)

func newTestPublisher(t *testing.T, h http.HandlerFunc) *Publisher {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	p, err := New("p1", "jobs", option.WithEndpoint(srv.URL+"/"), option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestPublish_SendsBase64DataToTheTopic(t *testing.T) {
	var gotPath string
	var gotData string
	p := newTestPublisher(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		var body struct {
			Messages []struct {
				Data string `json:"data"`
			} `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if len(body.Messages) == 1 {
			gotData = body.Messages[0].Data
		}
		_, _ = w.Write([]byte(`{"messageIds":["1"]}`))
	})
	if err := p.Publish(context.Background(), []byte(`{"kind":"x"}`)); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if want := "/v1/projects/p1/topics/jobs:publish"; gotPath != want {
		t.Errorf("path = %q, want %q", gotPath, want)
	}
	if raw, _ := base64.StdEncoding.DecodeString(gotData); string(raw) != `{"kind":"x"}` {
		t.Errorf("data = %q (decoded %q)", gotData, raw)
	}
}

func TestPublish_Errors(t *testing.T) {
	tests := []struct {
		name string
		h    http.HandlerFunc
	}{
		{"server error", func(w http.ResponseWriter, _ *http.Request) { http.Error(w, "no", http.StatusForbidden) }},
		{"no message id", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{}`)) }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := newTestPublisher(t, tt.h).Publish(context.Background(), []byte("x")); err == nil {
				t.Fatal("want an error")
			}
		})
	}
}

func TestNew_RequiresProjectAndTopic(t *testing.T) {
	if _, err := New("", "jobs"); err == nil {
		t.Error("empty project accepted")
	}
	if _, err := New("p", ""); err == nil {
		t.Error("empty topic accepted")
	}
}

func TestNew_UsesTheEmulatorHost(t *testing.T) {
	t.Setenv("PUBSUB_EMULATOR_HOST", "127.0.0.1:1")
	p, err := New("demo-x", "jobs")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.opts) != 2 {
		t.Fatalf("emulator options = %d, want endpoint + no-auth", len(p.opts))
	}
}
