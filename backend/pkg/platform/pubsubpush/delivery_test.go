package pubsubpush

import (
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestReadDelivery(t *testing.T) {
	tests := []struct {
		name    string
		body    string
		want    Delivery
		wantErr bool
	}{
		{"with attempt", `{"message":{"data":"eyJhIjoxfQ==","messageId":"m1"},"subscription":"s","deliveryAttempt":3}`,
			Delivery{MessageID: "m1", Data: []byte(`{"a":1}`), Attempt: 3}, false},
		{"no dead-letter policy omits the attempt", `{"message":{"data":"eyJhIjoxfQ==","messageId":"m2"}}`,
			Delivery{MessageID: "m2", Data: []byte(`{"a":1}`)}, false},
		{"not json", `nope`, Delivery{}, true},
		{"bad base64", `{"message":{"data":"!!!"}}`, Delivery{}, true},
		{"empty data", `{"message":{"messageId":"m3"}}`, Delivery{}, true},
		{"oversized", `{"message":{"data":"` + strings.Repeat("A", MaxDeliveryBytes) + `"}}`, Delivery{}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest("POST", "/internal/pubsub/jobs", strings.NewReader(tt.body))
			got, err := ReadDelivery(httptest.NewRecorder(), r)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				if !errors.Is(err, ErrMalformedDelivery) {
					t.Errorf("err = %v, want ErrMalformedDelivery", err)
				}
				return
			}
			if got.MessageID != tt.want.MessageID || string(got.Data) != string(tt.want.Data) || got.Attempt != tt.want.Attempt {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}
