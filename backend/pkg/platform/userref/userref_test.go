package userref

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"

	// Every dzeroth proto package, linked so its descriptors are in protoregistry.GlobalFiles. The guard checks this
	// list against proto/dzeroth, so a new package cannot be skipped silently.
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	_ "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
)

const (
	translate   = commonv1.UserRefKind_USER_REF_KIND_TRANSLATE
	conditional = commonv1.UserRefKind_USER_REF_KIND_CONDITIONAL
	publicID    = commonv1.UserRefKind_USER_REF_KIND_PUBLIC_ID
	notUser     = commonv1.UserRefKind_USER_REF_KIND_NOT_USER
)

// wantAnnotated is every field that carries user_ref, with its kind. Adding, removing or changing an annotation must
// change this table in the same PR, so a reviewer sees every user-id field the edge translation touches.
var wantAnnotated = map[protoreflect.FullName]commonv1.UserRefKind{
	"dzeroth.articles.v1.Article.author_id":                            translate,
	"dzeroth.beacons.v1.ListSharedBeaconsRequest.peer_user_id":         translate,
	"dzeroth.beacons.v1.RemoveParticipantRequest.user_id":              translate,
	"dzeroth.beacons.v1.RespondToJoinRequestRequest.user_id":           translate,
	"dzeroth.billing.v1.EnsureBillingIdentityResponse.app_user_id":     notUser,
	"dzeroth.common.v1.AuthorSnapshot.public_id":                       publicID,
	"dzeroth.common.v1.AuthorSnapshot.user_id":                         translate,
	"dzeroth.communities.v1.SetMemberRoleRequest.user_id":              translate,
	"dzeroth.graph.v1.BlockRequest.user_id":                            translate,
	"dzeroth.graph.v1.FollowRequest.user_id":                           translate,
	"dzeroth.graph.v1.GetProfileRelationshipRequest.user_id":           translate,
	"dzeroth.graph.v1.GetRelationshipsRequest.user_ids":                translate,
	"dzeroth.graph.v1.ListFollowersRequest.user_id":                    translate,
	"dzeroth.graph.v1.ListFollowingRequest.user_id":                    translate,
	"dzeroth.graph.v1.MuteRequest.user_id":                             translate,
	"dzeroth.graph.v1.Relationship.user_id":                            translate,
	"dzeroth.graph.v1.RespondToFollowRequestRequest.requester_user_id": translate,
	"dzeroth.graph.v1.UnblockRequest.user_id":                          translate,
	"dzeroth.graph.v1.UnfollowRequest.user_id":                         translate,
	"dzeroth.graph.v1.UnmuteRequest.user_id":                           translate,
	"dzeroth.identity.v1.GetProfileRequest.public_id":                  publicID,
	"dzeroth.identity.v1.GetProfileRequest.user_id":                    translate,
	"dzeroth.identity.v1.Profile.public_id":                            publicID,
	"dzeroth.identity.v1.Profile.user_id":                              translate,
	"dzeroth.lists.v1.AddListMemberRequest.user_id":                    translate,
	"dzeroth.lists.v1.ListUserListsRequest.contains_user_id":           translate,
	"dzeroth.lists.v1.ListUserListsRequest.owner_id":                   translate,
	"dzeroth.lists.v1.RemoveListMemberRequest.user_id":                 translate,
	"dzeroth.messaging.v1.SendMessageRequest.recipient_user_id":        translate,
	"dzeroth.moderation.v1.ReportContentRequest.target_id":             conditional,
	"dzeroth.notifications.v1.Notification.id":                         conditional,
	"dzeroth.posts.v1.Mention.user_id":                                 translate,
	"dzeroth.timeline.v1.GetUserTimelineRequest.user_id":               translate,
}

// userish matches field names that look like they hold a user id. A string field with such a name must carry
// user_ref, or be in notUserIDs below with the reason it is not a user id.
var userish = regexp.MustCompile(`(^|_)(uids?|user_ids?|(user|author|owner|member|actor|recipient|participant|requester|peer|follower|followee|blocker|blocked|muted|sender|creator|moderator|reporter|organi[sz]er|viewer|target|invitee|inviter)_(user_)?ids?)$`)

// notUserIDs are string fields whose name matches userish but that never hold a user id. Empty today; an entry needs
// the reason next to it.
var notUserIDs = map[protoreflect.FullName]string{}

func dzerothFiles(t *testing.T) []protoreflect.FileDescriptor {
	t.Helper()
	var out []protoreflect.FileDescriptor
	protoregistry.GlobalFiles.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		if strings.HasPrefix(string(fd.Package()), "dzeroth.") {
			out = append(out, fd)
		}
		return true
	})
	return out
}

func eachField(fds []protoreflect.FileDescriptor, fn func(protoreflect.FieldDescriptor)) {
	var walk func(ms protoreflect.MessageDescriptors)
	walk = func(ms protoreflect.MessageDescriptors) {
		for i := range ms.Len() {
			md := ms.Get(i)
			fields := md.Fields()
			for j := range fields.Len() {
				fn(fields.Get(j))
			}
			walk(md.Messages())
		}
	}
	for _, fd := range fds {
		walk(fd.Messages())
	}
}

// TestGuard_LinksEveryProtoPackage: the blank imports above cover every package under proto/dzeroth, so the guard
// below sees every message.
func TestGuard_LinksEveryProtoPackage(t *testing.T) {
	entries, err := os.ReadDir(filepath.Join("..", "..", "..", "..", "proto", "dzeroth"))
	if err != nil {
		t.Fatalf("read proto/dzeroth: %v", err)
	}
	var want []string
	for _, e := range entries {
		if e.IsDir() {
			want = append(want, "dzeroth."+e.Name()+".v1")
		}
	}
	var got []string
	for _, fd := range dzerothFiles(t) {
		if p := string(fd.Package()); !slices.Contains(got, p) {
			got = append(got, p)
		}
	}
	slices.Sort(want)
	slices.Sort(got)
	if !slices.Equal(got, want) {
		t.Fatalf("linked dzeroth packages = %v, want %v (add the missing blank import)", got, want)
	}
}

// TestGuard_UserIDFieldsCarryUserRef walks every dzeroth message: the annotated set is exactly wantAnnotated, every
// annotation is a non-UNSPECIFIED kind on a string or repeated string field, and every string field named like a user
// id is annotated or listed in notUserIDs.
func TestGuard_UserIDFieldsCarryUserRef(t *testing.T) {
	got := map[protoreflect.FullName]commonv1.UserRefKind{}
	eachField(dzerothFiles(t), func(f protoreflect.FieldDescriptor) {
		kind, ok := Kind(f)
		if ok {
			got[f.FullName()] = kind
			if kind == commonv1.UserRefKind_USER_REF_KIND_UNSPECIFIED {
				t.Errorf("%s: user_ref = UNSPECIFIED; pick a kind", f.FullName())
			}
			if f.Kind() != protoreflect.StringKind || f.IsMap() {
				t.Errorf("%s: user_ref on a %v field; only string and repeated string are supported", f.FullName(), f.Kind())
			}
			if kind == commonv1.UserRefKind_USER_REF_KIND_PUBLIC_ID && f.Name() != "public_id" {
				t.Errorf("%s: PUBLIC_ID kind on a field not named public_id", f.FullName())
			}
			return
		}
		if f.Kind() != protoreflect.StringKind || !userish.MatchString(string(f.Name())) {
			return
		}
		if _, listed := notUserIDs[f.FullName()]; !listed {
			t.Errorf("%s looks like a user id but has no (dzeroth.common.v1.user_ref) option; annotate it or list it in notUserIDs", f.FullName())
		}
	})
	for name, want := range wantAnnotated {
		if g, ok := got[name]; !ok {
			t.Errorf("%s: want user_ref %v, field missing or not annotated", name, want)
		} else if g != want {
			t.Errorf("%s: user_ref = %v, want %v", name, g, want)
		}
	}
	for name, g := range got {
		if _, ok := wantAnnotated[name]; !ok {
			t.Errorf("%s: annotated %v but not in wantAnnotated; add it", name, g)
		}
	}
}

func TestKind(t *testing.T) {
	profile := (&identityv1.Profile{}).ProtoReflect().Descriptor().Fields()
	snapshot := (&commonv1.AuthorSnapshot{}).ProtoReflect().Descriptor().Fields()
	for _, tc := range []struct {
		name          string
		field         protoreflect.FieldDescriptor
		want          commonv1.UserRefKind
		wantPresent   bool
		wantTranslate bool
	}{
		{"profile user_id", profile.ByName("user_id"), translate, true, true},
		{"profile public_id", profile.ByName("public_id"), publicID, true, false},
		{"profile handle has no option", profile.ByName("handle"), commonv1.UserRefKind_USER_REF_KIND_UNSPECIFIED, false, false},
		{"author snapshot user_id", snapshot.ByName("user_id"), translate, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.field == nil {
				t.Fatal("field not found")
			}
			kind, present := Kind(tc.field)
			if kind != tc.want || present != tc.wantPresent {
				t.Errorf("Kind = (%v, %v), want (%v, %v)", kind, present, tc.want, tc.wantPresent)
			}
			if got := Translate(tc.field); got != tc.wantTranslate {
				t.Errorf("Translate = %v, want %v", got, tc.wantTranslate)
			}
		})
	}
}

// TestKind_NoOptions: a field whose descriptor has no options at all (FieldOptions nil) reads as absent.
func TestKind_NoOptions(t *testing.T) {
	fd := (&descriptorpb.FieldDescriptorProto{}).ProtoReflect().Descriptor().Fields().ByName("name")
	if kind, ok := Kind(fd); ok || kind != commonv1.UserRefKind_USER_REF_KIND_UNSPECIFIED {
		t.Errorf("Kind = (%v, %v), want (UNSPECIFIED, false)", kind, ok)
	}
}
