package identity

import (
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// An export section reads other people's documents (the people the subject follows, lists or reported), so its error
// can name them. Whatever a section returns, the delivery's log line carries neither another person's document path nor
// an edge id, for both archive formats and on the attempt that reaches Error Reporting. The subject's uid is hashed
// first by the compose wrap, which used to leave the edge id "<hash>_<other>" too short for the edge pattern.
func TestExportJob_SectionErrorNamesNobodyElse(t *testing.T) {
	const (
		subject = "SubjectUidAbCdEfGhIjKlMn0123"
		other   = "OtherPersonUidAbCdEfGhIj4567"
	)
	sentinel := errors.New("people source down")
	tests := []struct {
		name string
		err  error
	}{
		{"document path of another person", fmt.Errorf(`graph: export: profiles: rpc error: code = Unavailable desc = "projects/demo-p/databases/(default)/documents/users/%s": %w`, other, sentinel)},
		{"edge id, subject first", fmt.Errorf("graph: decode follow %s_%s: %w", subject, other, sentinel)},
		{"edge id, subject second", fmt.Errorf("graph: decode follow %s_%s: %w", other, subject, sentinel)},
		{"path and edge id together", fmt.Errorf("commit documents/users/%s/x and follows/%s_%s: %w", other, subject, other, sentinel)},
	}
	formats := map[string]func(*harness, string) ExportDoc{"json": newPendingExport, "zip": zipPendingExport}
	for _, tt := range tests {
		for format, pending := range formats {
			for _, attempt := range []int{1, maxDeliveryAttempts} {
				t.Run(fmt.Sprintf("%s/%s/attempt %d", tt.name, format, attempt), func(t *testing.T) {
					h := newHarness(t)
					h.seedActive(subject, "Alice")
					_ = h.l.RegisterExportSection(fakeSection{name: "graph", err: tt.err})
					doc := pending(h, subject)
					if code := h.deliver(JobMessage{Kind: JobKindAccountExport, ExportID: doc.ID}, attempt); code != http.StatusInternalServerError {
						t.Fatalf("status = %d, want 500 (a retry)", code)
					}
					out := h.logs.String()
					for _, raw := range []string{subject, other, "documents/"} {
						if strings.Contains(out, raw) {
							t.Errorf("the log carries %q:\n%s", raw, out)
						}
					}
					if !strings.Contains(out, "export section graph") {
						t.Errorf("the log no longer names the failing section:\n%s", out)
					}
					if attempt == maxDeliveryAttempts && !strings.Contains(out, "ReportedErrorEvent") {
						t.Errorf("the last attempt must reach Error Reporting:\n%s", out)
					}
				})
			}
		}
	}
}

// The error a compose step returns is already scrubbed (not only the log line built from it later), and errors.Is
// still reaches the cause, so the permanent-failure and deadline checks of runExport keep working.
func TestComposeExport_SectionErrorScrubbedAndStillMatches(t *testing.T) {
	const (
		subject = "SubjectUidAbCdEfGhIjKlMn0123"
		other   = "OtherPersonUidAbCdEfGhIj4567"
	)
	sentinel := errors.New("people source down")
	cause := fmt.Errorf("%w: documents/users/%s and follows/%s_%s: %w", errPermanent, other, subject, other, sentinel)
	composers := map[string]func(*Lifecycle, Profile) error{
		"json": func(l *Lifecycle, p Profile) error {
			return l.composeExport(t.Context(), &countingWriter{w: &strings.Builder{}}, p, exportTarget{})
		},
		"zip": func(l *Lifecycle, p Profile) error {
			return l.composeZip(t.Context(), &countingWriter{w: &strings.Builder{}}, p, exportTarget{})
		},
	}
	for name, compose := range composers {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			p := h.seedActive(subject, "Alice")
			_ = h.l.RegisterExportSection(fakeSection{name: "graph", err: cause})
			err := compose(h.l, p)
			if err == nil {
				t.Fatal("a failing section composed")
			}
			for _, raw := range []string{subject, other, "documents/"} {
				if strings.Contains(err.Error(), raw) {
					t.Errorf("the compose error carries %q: %v", raw, err)
				}
			}
			if !errors.Is(err, sentinel) || !errors.Is(err, errPermanent) {
				t.Errorf("errors.Is no longer reaches the cause: %v", err)
			}
		})
	}
}
