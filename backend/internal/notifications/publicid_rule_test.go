package notifications

import (
	"context"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/reflect/protoreflect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/publicid"
)

// ruleResolver is publicid.Resolver over a fixed uid -> public id table.
type ruleResolver map[string]string

func (r ruleResolver) PublicIDsForUIDs(_ context.Context, uids []string) (map[string]string, error) {
	out := map[string]string{}
	for _, u := range uids {
		if p, ok := r[u]; ok {
			out[u] = p
		}
	}
	return out, nil
}

func (r ruleResolver) UIDsForPublicIDs(_ context.Context, ids []string) (map[string]string, error) {
	out := map[string]string{}
	for _, id := range ids {
		for u, p := range r {
			if p == id {
				out[id] = u
			}
		}
	}
	return out, nil
}

// ruleTranslator is the edge walker over the NotificationService only, with NotificationIDRule registered as in
// production (apiserver registers the same function).
func ruleTranslator(t *testing.T, res publicid.Resolver) *publicid.Translator {
	t.Helper()
	rules := publicid.NewRules()
	if err := rules.Register(NotificationIDField, NotificationIDRule); err != nil {
		t.Fatal(err)
	}
	svc := notificationsv1.File_dzeroth_notifications_v1_notifications_proto.Services().ByName("NotificationService")
	plans, err := publicid.BuildPlans([]protoreflect.ServiceDescriptor{svc}, rules)
	if err != nil {
		t.Fatalf("BuildPlans: %v", err)
	}
	tr, err := publicid.NewTranslator(plans, res, identity.ValidPublicID, identity.MaxPublicIDLookups)
	if err != nil {
		t.Fatal(err)
	}
	return tr
}

// The listed row id the edge writes equals WireNotificationID (the push's notificationId, fcm.go) for every type the
// real id builder makes, whether the actor has a public id or not, and never carries the actor's uid.
func TestNotificationIDRule_EqualsWireNotificationIDForEveryType(t *testing.T) {
	t.Parallel()
	for _, mapped := range []bool{true, false} {
		res := ruleResolver{}
		pub := ""
		if mapped {
			res[wireActorUID] = wirePubID
			pub = wirePubID
		}
		tr := ruleTranslator(t, res)
		for _, ty := range allTypes {
			if ty.pushOnly() {
				continue // never listed
			}
			stored := notificationID(ty, wireActorUID, subjectFor(ty), t0)
			resp := &notificationsv1.ListNotificationsResponse{Notifications: []*notificationsv1.Notification{{
				Id: stored, Type: typeToProto(ty), Actor: &commonv1.AuthorSnapshot{UserId: wireActorUID},
			}}}
			if _, err := tr.TranslateResponse(context.Background(), nil, resp); err != nil {
				t.Fatalf("%s: %v", ty, err)
			}
			n := resp.GetNotifications()[0]
			if want := WireNotificationID(stored, ty, pub); n.GetId() != want {
				t.Errorf("%s (mapped=%v): listed id %q, push id %q", ty, mapped, n.GetId(), want)
			}
			if !ty.ActorKeyedID() && n.GetId() != stored {
				t.Errorf("%s: a row id that names no actor changed: %q -> %q", ty, stored, n.GetId())
			}
			js, err := protojson.Marshal(resp)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(js), wireActorUID) {
				t.Errorf("%s (mapped=%v): the actor's uid survived: %s", ty, mapped, js)
			}
		}
	}
}

func TestNotificationIDRule_Untouched(t *testing.T) {
	t.Parallel()
	id := "follow_" + wireActorUID
	for name, parent := range map[string]protoreflect.Message{
		"unspecified type":   (&notificationsv1.Notification{Id: id}).ProtoReflect(),
		"unknown type":       (&notificationsv1.Notification{Id: id, Type: notificationsv1.NotificationType(999)}).ProtoReflect(),
		"like row":           (&notificationsv1.Notification{Id: id, Type: notificationsv1.NotificationType_NOTIFICATION_TYPE_LIKE}).ProtoReflect(),
		"not a Notification": (&commonv1.AuthorSnapshot{UserId: id}).ProtoReflect(),
	} {
		if sp, ok := NotificationIDRule(parent, id); ok {
			t.Errorf("%s: span %+v, want untouched", name, sp)
		}
	}
	sp, ok := NotificationIDRule((&notificationsv1.Notification{Id: id, Type: notificationsv1.NotificationType_NOTIFICATION_TYPE_FOLLOW}).ProtoReflect(), id)
	if !ok || id[sp.Start:sp.End] != wireActorUID {
		t.Errorf("follow row: span %+v ok=%v, want the actor segment", sp, ok)
	}
}
