package billing

import (
	"context"
	"testing"
)

func TestWebhookTransferCustomersAreBoundedAndDeduplicated(t *testing.T) {
	b := testBinding()
	e := InboxEvent{CustomerID: b.CustomerID, Aliases: []string{b.CustomerID, "$RCAnonymousID:foreign"}, TransferredFrom: []string{b.CustomerID}, TransferredTo: []string{"foreign/path"}}
	got := eventCustomers(e)
	if len(got) != 1 || got[0] != b.CustomerID {
		t.Fatal("untrusted or duplicate customer accepted")
	}
	p := &WebhookProcessor{ReadOnly: true}
	if p.AcceptEvent(context.Background(), e) != ErrUnavailable || p.Refresh(context.Background()) != ErrUnavailable {
		t.Fatal("readonly webhook mutated storage")
	}
}
