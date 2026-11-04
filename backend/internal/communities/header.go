package communities

import communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"

// HeaderProto renders the light Community header from a document and the caller's role. It is the exported
// form of the handlers' own renderer, for callers that already hold both (timeline's GetCommunityTimeline puts it on every response).
func HeaderProto(c Community, role Role) *communitiesv1.Community {
	return toProtoCommunity(View{Community: c, Role: role})
}
