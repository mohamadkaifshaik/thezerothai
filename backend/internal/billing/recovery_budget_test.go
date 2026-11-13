package billing

import (
	"context"
	"testing"
)

func TestRecoveryDoesNotStartWithInsufficientProviderBudget(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), ProviderRequestTimeout)
	defer cancel()
	// No store is configured: starting storage work would panic. A short cron
	// context must refuse before invalidating any customer's verification.
	p := &WebhookProcessor{}
	if err := p.Refresh(ctx); err != ErrUnavailable {
		t.Fatalf("short-budget recovery: %v", err)
	}
}

func TestOverlappingRecoveryDoesNotWaitPastDeadline(t *testing.T) {
	p := &WebhookProcessor{}
	p.recoveryMu.Lock()
	defer p.recoveryMu.Unlock()
	if err := p.Refresh(context.Background()); err != ErrUnavailable {
		t.Fatalf("overlapping recovery: %v", err)
	}
}
