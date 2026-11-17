package apiserver

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"

	moderationv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/publicid"
)

const (
	// publicIDNoneTTL is how long the edge remembers that a uid has no public id (an erased author in a frozen
	// snapshot), so a popular old thread does not re-read it on every page. Identity's own "no profile" entry lasts
	// about 10 s.
	publicIDNoneTTL = 5 * time.Minute
	// publicIDNoneEntries bounds that memory per instance (a uid and a time each: well under 1 MB).
	publicIDNoneEntries = 10_000
)

// publicIDConditionalRules is the rule of every CONDITIONAL user_ref field of the API; both are registered, none is
// passed through untranslated. BuildPlans refuses to start the process when a CONDITIONAL field reachable from an RPC
// has no rule here (or a rule names a field that is not one), so a new CONDITIONAL field cannot ship without a rule.
//   - ReportContentRequest.target_id: a user id only for an ACCOUNT report (reportTargetRule).
//   - Notification.id: the actor's uid as the last "_" segment of an actor-keyed row (notifications.NotificationIDRule,
//     the same span WireNotificationID rewrites in the push).
var publicIDConditionalRules = map[protoreflect.FullName]publicid.Rule{
	reportTargetField:                 reportTargetRule,
	notifications.NotificationIDField: notifications.NotificationIDRule,
}

// reportTargetField is ReportContentRequest.target_id.
const reportTargetField protoreflect.FullName = "dzeroth.moderation.v1.ReportContentRequest.target_id"

// reportTargetTypeNumber is ReportContentRequest.target_type's field number.
var reportTargetTypeNumber = (&moderationv1.ReportContentRequest{}).ProtoReflect().Descriptor().Fields().ByName("target_type").Number()

// reportTargetRule: target_id is a user id, as a whole, exactly when target_type is REPORT_TARGET_TYPE_ACCOUNT. Every
// other target (a post, list, community or beacon Snowflake, a "<convId>:<msgId>" message, an unset or unknown type)
// is not a user id and is left untouched. The edge's usual semantics apply to an ACCOUNT target: a known public id
// becomes the uid, so moderation's self-report check and ReportID see the uid exactly as without the flag; an unknown
// well-formed one reaches the handler unchanged (its NOT_FOUND); anything else is VALIDATION "target_id". The response
// (report_id, already_reported) echoes no target.
func reportTargetRule(parent protoreflect.Message, value string) (publicid.Span, bool) {
	md := parent.Descriptor()
	if md.FullName() != reportTargetField.Parent() {
		return publicid.Span{}, false
	}
	fd := md.Fields().ByNumber(reportTargetTypeNumber)
	if fd == nil || fd.Kind() != protoreflect.EnumKind {
		return publicid.Span{}, false
	}
	return publicid.WholeValue(value), parent.Get(fd).Enum() == protoreflect.EnumNumber(moderationv1.ReportTargetType_REPORT_TARGET_TYPE_ACCOUNT)
}

// publicIDRules is the conditional-rule registry the edge is built with.
func publicIDRules() (*publicid.Rules, error) {
	r := publicid.NewRules()
	for field, rule := range publicIDConditionalRules {
		if err := r.Register(field, rule); err != nil {
			return nil, fmt.Errorf("public ids: %w", err)
		}
	}
	return r, nil
}

// publicIDPlans builds the translation plans for every linked dzeroth service. Called on every start whatever
// FEATURE_PUBLIC_IDS says, so a bad user_ref annotation fails every deploy, not only flagged ones.
func publicIDPlans() (*publicid.Plans, error) {
	rules, err := publicIDRules()
	if err != nil {
		return nil, err
	}
	plans, err := publicid.BuildPlans(publicid.DzerothServices(protoregistry.GlobalFiles), rules)
	if err != nil {
		return nil, fmt.Errorf("public ids: %w", err)
	}
	return plans, nil
}

// publicIDFlags is the part of the flags registry the edge reads (*flags.Registry implements it).
type publicIDFlags interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// publicIDsInterceptor is the edge translation (pkg/platform/publicid), innermost in the chain. The flag is read per
// caller exactly as identity reads it for Profile.public_id (Enabled(uid, public_ids)), from the verified uid
// authn.IDTokenInterceptor put on the context; a request without one is untouched. Globally off (FEATURE_PUBLIC_IDS
// unset or off) the interceptor is the identity: no flag check, no plan walk, no lookup. The process refuses to start
// when the plans do not build or the validator accepts the tombstone id.
func publicIDsInterceptor(fl publicIDFlags, ids identity.PublicIDs, now func() time.Time) (connect.Interceptor, error) {
	if identity.ValidPublicID(publicid.Tombstone) {
		return nil, errors.New("public ids: identity.ValidPublicID accepts the tombstone id")
	}
	if fl == nil || ids == nil {
		return nil, errors.New("public ids: nil flags or lookups")
	}
	plans, err := publicIDPlans()
	if err != nil {
		return nil, err
	}
	none, err := publicid.NewNegativeCache(ids, publicIDNoneEntries, publicIDNoneTTL, now)
	if err != nil {
		return nil, fmt.Errorf("public ids: %w", err)
	}
	tr, err := publicid.NewTranslator(plans, none, identity.ValidPublicID, identity.MaxPublicIDLookups)
	if err != nil {
		return nil, fmt.Errorf("public ids: %w", err)
	}
	var enabled func(context.Context) bool
	if !fl.GloballyOff(identity.PublicIDsFlag) {
		enabled = func(ctx context.Context) bool {
			uid, ok := authn.UIDFromContext(ctx)
			return ok && uid != "" && fl.Enabled(uid, identity.PublicIDsFlag)
		}
	}
	ic, err := publicid.NewInterceptor(tr, enabled, nil)
	if err != nil {
		return nil, fmt.Errorf("public ids: %w", err)
	}
	return ic, nil
}
