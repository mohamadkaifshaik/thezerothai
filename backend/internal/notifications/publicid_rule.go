package notifications

import (
	"google.golang.org/protobuf/reflect/protoreflect"

	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/publicid"
)

// NotificationIDField is the CONDITIONAL user_ref field NotificationIDRule is registered for.
const NotificationIDField protoreflect.FullName = "dzeroth.notifications.v1.Notification.id"

// notificationTypeNumber is Notification.type's field number.
var notificationTypeNumber = (&notificationsv1.Notification{}).ProtoReflect().Descriptor().Fields().ByName("type").Number()

// NotificationIDRule is the edge's rule (publicid.Rule) for Notification.id: the row's type, read from the parent
// Notification, decides; for the actor-keyed types (Type.ActorKeyedID) the span is NotificationIDActorSpan, the last
// "_" segment, which holds the actor's uid in a stored id. Every other type, an unknown or UNSPECIFIED type, and a
// parent that is not a Notification answer ok=false (untouched). Outbound the walker writes the actor's public id, or
// publicid.Tombstone when it has none, into that span: exactly WireNotificationID for every id the fan-out builds, so
// the listed row and the push (fcm.go) carry the same id for the same actor id. (The two differ only on ids the fan-out
// never builds: an empty id or one ending in "_" carries no uid and the walker leaves it as is.) No request carries a
// Notification, so the inbound direction never runs in practice. Pure; never modifies parent.
func NotificationIDRule(parent protoreflect.Message, value string) (publicid.Span, bool) {
	md := parent.Descriptor()
	if md.FullName() != NotificationIDField.Parent() {
		return publicid.Span{}, false
	}
	fd := md.Fields().ByNumber(notificationTypeNumber)
	if fd == nil || fd.Kind() != protoreflect.EnumKind {
		return publicid.Span{}, false
	}
	t := TypeFromProto(notificationsv1.NotificationType(parent.Get(fd).Enum()))
	start, end, ok := NotificationIDActorSpan(value, t)
	if !ok {
		return publicid.Span{}, false
	}
	return publicid.Span{Start: start, End: end}, true
}

var _ publicid.Rule = NotificationIDRule
