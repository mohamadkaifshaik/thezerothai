package pubsubpush

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
)

// MaxDeliveryBytes caps a push request body (a Pub/Sub message is at most 10 MB; ours are a few hundred bytes).
const MaxDeliveryBytes = 64 << 10

// Delivery is one decoded Pub/Sub push request: the message payload plus the delivery attempt.
type Delivery struct {
	// MessageID is Pub/Sub's id of the message (stable across redeliveries); logging only.
	MessageID string
	// Data is the decoded message payload.
	Data []byte
	// Attempt is the 1-based delivery attempt, 0 when the subscription has no dead-letter policy (Pub/Sub then omits it).
	Attempt int
}

// pushEnvelope is the JSON body of a push request (https://cloud.google.com/pubsub/docs/push#receive_push).
// Message.Data is a base64 string in the JSON, which encoding/json decodes into []byte.
type pushEnvelope struct {
	Message struct {
		Data      []byte `json:"data"`
		MessageID string `json:"messageId"`
	} `json:"message"`
	DeliveryAttempt int `json:"deliveryAttempt"`
}

// ErrMalformedDelivery is returned by ReadDelivery for a body that is not a push envelope. A malformed request
// can never become valid, so handlers acknowledge it (2xx) instead of letting Pub/Sub redeliver it into the DLQ.
var ErrMalformedDelivery = errors.New("pubsubpush: malformed push request")

// ReadDelivery decodes the push envelope from r's body, reading at most MaxDeliveryBytes. The caller owns
// the response.
func ReadDelivery(w http.ResponseWriter, r *http.Request) (Delivery, error) {
	var env pushEnvelope
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, MaxDeliveryBytes)).Decode(&env); err != nil {
		return Delivery{}, fmt.Errorf("%w: %w", ErrMalformedDelivery, err)
	}
	if len(env.Message.Data) == 0 {
		return Delivery{}, fmt.Errorf("%w: empty message data", ErrMalformedDelivery)
	}
	return Delivery{MessageID: env.Message.MessageID, Data: env.Message.Data, Attempt: env.DeliveryAttempt}, nil
}
