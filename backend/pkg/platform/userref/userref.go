// Package userref reads the dzeroth.common.v1.user_ref field option (proto/dzeroth/common/v1/options.proto), the
// marker on every proto field that carries a user id. The public id edge translation (FEATURE_PUBLIC_IDS) will walk
// messages with it; today only the guard test in this package uses it, so nothing changes at runtime.
package userref

import (
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

// Kind returns the field's user_ref kind and whether the option is present at all. A field without the option
// answers (USER_REF_KIND_UNSPECIFIED, false); a field explicitly annotated UNSPECIFIED answers (UNSPECIFIED, true),
// which the guard test rejects.
func Kind(fd protoreflect.FieldDescriptor) (commonv1.UserRefKind, bool) {
	opts, ok := fd.Options().(*descriptorpb.FieldOptions)
	if !ok || opts == nil || !proto.HasExtension(opts, commonv1.E_UserRef) {
		return commonv1.UserRefKind_USER_REF_KIND_UNSPECIFIED, false
	}
	kind, ok := proto.GetExtension(opts, commonv1.E_UserRef).(commonv1.UserRefKind)
	if !ok {
		return commonv1.UserRefKind_USER_REF_KIND_UNSPECIFIED, false
	}
	return kind, true
}

// Translate reports whether the edge translates the field generically (USER_REF_KIND_TRANSLATE).
func Translate(fd protoreflect.FieldDescriptor) bool {
	kind, _ := Kind(fd)
	return kind == commonv1.UserRefKind_USER_REF_KIND_TRANSLATE
}
