package notifications

import (
	"reflect"
	"strings"
	"testing"
)

// W3-35a (ADR-0025 D4, plan Part B rule 9): a push carries ids and a static per-type line, never post text, a handle or a
// media URL. Push has no text-bearing field, and the FCM message built from it for every notification type (the Part B
// request and accept types included) has the same four data keys, and a title and body that name nobody.
func TestPush_CarriesIdsOnlyForEveryType(t *testing.T) {
	t.Parallel()
	var fields []string
	rt := reflect.TypeOf(Push{})
	for i := 0; i < rt.NumField(); i++ {
		fields = append(fields, rt.Field(i).Name)
	}
	if got, want := strings.Join(fields, ","), "Type,NotificationID,PostID,ActorID,ConversationID"; got != want {
		t.Fatalf("Push fields = %s, want %s: a new field needs a review against 'a push carries no post text'", got, want)
	}
	for _, ty := range []Type{TypeFollow, TypeMention, TypeReply, TypeLike, TypeRepost, TypeQuote, TypeFollowRequest, TypeFollowAccepted} {
		msg := buildMessage("token", Push{Type: ty, NotificationID: "n1", PostID: "p1", ActorID: "a1"})
		if len(msg.Data) != 4 {
			t.Errorf("%s: data keys = %v, want type, notificationId, postId, actorId", ty, msg.Data)
		}
		for k, v := range msg.Data {
			if strings.ContainsAny(v, " @/") {
				t.Errorf("%s: data[%s] = %q looks like free text or a URL", ty, k, v)
			}
		}
		text := msg.Notification.Title + " " + msg.Notification.Body
		if strings.Contains(text, "@") || strings.Contains(text, "http") || strings.Contains(text, "/m/") {
			t.Errorf("%s: title/body %q names an account, a link or an image", ty, text)
		}
	}
}
