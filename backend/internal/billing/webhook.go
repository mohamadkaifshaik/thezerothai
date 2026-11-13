package billing

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"time"
)

// EventInbox must durably commit before returning nil. Processing is separate:
// an authenticated event is a reconciliation hint, never an access grant.
type EventInbox interface {
	AcceptEvent(context.Context, InboxEvent) error
}

type InboxEvent struct {
	ID              string      `json:"id"`
	AppID           string      `json:"app_id"`
	CustomerID      string      `json:"app_user_id"`
	Environment     Environment `json:"environment"`
	Type            string      `json:"type"`
	TransferredFrom []string    `json:"transferred_from"`
	TransferredTo   []string    `json:"transferred_to"`
	Aliases         []string    `json:"aliases"`
	BodyHash        string      `json:"-"`
}

// NewWebhookHandler requires the exact configured Authorization value and an
// explicit app/environment allowlist. Production registration additionally wraps
// this with NewSignedWebhookHandler and uses the durable WebhookProcessor.
func NewWebhookHandler(inbox EventInbox, authorization string, env Environment, appIDs []string) (http.Handler, error) {
	if inbox == nil || len(authorization) < 32 || !validEnvironment(env) || len(appIDs) == 0 {
		return nil, ErrInvalidInput
	}
	allowed := make(map[string]bool, len(appIDs))
	for _, id := range appIDs {
		if id == "" {
			return nil, ErrInvalidInput
		}
		allowed[id] = true
	}
	expected := sha256.Sum256([]byte(authorization))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		actual := sha256.Sum256([]byte(r.Header.Get("Authorization")))
		if len(r.Header.Values("Authorization")) != 1 || subtle.ConstantTimeCompare(actual[:], expected[:]) != 1 {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		const maxBody = 256 * 1024
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
		if err != nil {
			w.WriteHeader(http.StatusRequestEntityTooLarge)
			return
		}
		var envelope struct {
			Event InboxEvent `json:"event"`
		}
		if json.Unmarshal(body, &envelope) != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		e := envelope.Event
		if e.ID == "" || len(e.ID) > 256 || e.Type == "" || !allowed[e.AppID] || e.Environment != env {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		h := sha256.Sum256(body)
		e.BodyHash = hex.EncodeToString(h[:])
		if len(e.TransferredFrom)+len(e.TransferredTo)+len(e.Aliases) > 64 {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		if err := inbox.AcceptEvent(ctx, e); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	}), nil
}
