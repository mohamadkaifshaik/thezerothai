package apiserver

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
)

// identity keeps a capped unread count across the fan-out's ForgetUnread because notifications' badge can never
// report more than its cap: the two caps must be the same number (identity cannot import notifications).
func TestUnreadBadgeCapsMatch(t *testing.T) {
	if identity.UnreadBadgeCap != notifications.UnreadBadgeCap {
		t.Fatalf("identity.UnreadBadgeCap = %d, notifications.UnreadBadgeCap = %d: they must match",
			identity.UnreadBadgeCap, notifications.UnreadBadgeCap)
	}
}
