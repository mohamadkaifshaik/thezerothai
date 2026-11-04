package messaging

import (
	"context"
	"strings"
	"testing"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
)

// panicRepo panics in the reads that run on errgroup goroutines, which the request's recover interceptor does not cover.
type panicRepo struct{ *fakeRepo }

func (panicRepo) ListEntries(context.Context, string, string, ListQuery) ([]EntryRow, error) {
	panic("boom " + alice)
}

func (panicRepo) ListMessages(context.Context, string, MessageQuery) ([]MessageRow, error) {
	panic("boom " + alice)
}

func wantPanicError(t *testing.T, err error) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), "panic of type string") {
		t.Fatalf("err = %v, want the panic as this call's error", err)
	}
	if strings.Contains(err.Error(), alice) {
		t.Fatalf("the panic value escaped: %v", err)
	}
}

func TestListConversations_PanicOnWorkerFailsTheCallOnly(t *testing.T) {
	rg := newRig(t, nil)
	rg.svc.d.Repo = panicRepo{rg.repo}
	_, err := rg.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: requests})
	wantPanicError(t, err)
}

func TestListMessages_PanicOnWorkerFailsTheCallOnly(t *testing.T) {
	rg := newRig(t, nil)
	rg.repo.convs[aliceBobConv] = ConvDoc{Participants: []string{alice, bob}}
	rg.svc.d.Repo = panicRepo{rg.repo}
	_, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	wantPanicError(t, err)
}
