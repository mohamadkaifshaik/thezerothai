//go:build integration

package apiserver

// The public id edge (FEATURE_PUBLIC_IDS) through the real Build chain.
//
// Parity: for every RPC whose request carries a translated user id (driven from the plans, publicIDInboundRPCs), a
// well-formed but unknown public id from a flagged caller gets exactly the answer an unknown uid gets with the flag
// off (status, content type, body with its ErrorDetail; the echoed id, the caller's own id, page tokens and
// timestamps masked), and a malformed id (the caller's raw uid, as an old client would send) gets VALIDATION naming
// the field before the handler runs. Two chains (flag on, flag off) over the same emulator, the same caller and the
// same fixtures, so the flag is the only variable.
//
// Each unknown-id case must also give the answer the handler documents for an unknown user (pubUnknownAnswer, read off
// the handlers), so the comparison is known to exercise the user-id path, and no document anywhere names an unknown id
// afterwards (no edge, request, member, ban, participant, conversation or array entry).
//
// Shared messages: two callers on one allowlist chain, one flagged and one not, fetch the same pages concurrently;
// the unflagged one never sees a public id, the flagged one never a uid and never the tombstone (every seeded account is
// live and minted, so a tombstone would mean a message translated twice). Notification.id is removed before the scan:
// it is NOT annotated yet and still carries the actor's raw uid for flagged callers, a known gap that PR 4c closes.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/publicid"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/userref"
)

// pubChainCfg turns on every module an inbound-translating RPC belongs to, lifts every rate limit, lets creators call
// CreateCommunity (COMMUNITY_CREATORS: empty means nobody), and sets FEATURE_PUBLIC_IDS to mode (allow = its allowlist).
func pubChainCfg(mode flags.Mode, allow, creators []string) func(*config.Config) {
	return func(c *config.Config) {
		w320Base(c)
		w320AllW3On(c)
		listsOn(c)
		communitiesOn(c)
		messagingOn(c)
		beaconNotifsOn(c)
		w328On(c)                                                                        // private_accounts: RespondToFollowRequest's gate
		c.FeatureChatSharedPlans = flags.Spec{Name: "chat_shared_plans", Mode: flags.On} // ListSharedBeacons' gate
		c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
		c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
		c.Communities.Creators = creators
		pubRelaxAllLimits(c)
		spec := flags.Spec{Name: identity.PublicIDsFlag, Mode: mode, Allowlist: map[string]struct{}{}}
		for _, u := range allow {
			spec.Allowlist[u] = struct{}{}
		}
		c.FeaturePublicIDs = spec
	}
}

// pubTimestamp is a protojson Timestamp value (any key: BeaconView's `since`, say), masked like the *At keys.
var pubTimestamp = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}`)

// pubRelaxAllLimits lifts every per-minute and per-day limit in RateLimitConfig (all int or int64 counts, where higher
// is more permissive): one caller makes about 70 calls in the parity test, several to the same procedure, and the
// limits have their own tests. Done by reflection so a limit added later cannot throttle this test.
func pubRelaxAllLimits(c *config.Config) {
	v := reflect.ValueOf(&c.RateLimit).Elem()
	for i := range v.NumField() {
		f := v.Field(i)
		if f.CanSet() && f.Type() != reflect.TypeOf(time.Duration(0)) && (f.Kind() == reflect.Int || f.Kind() == reflect.Int64) {
			f.SetInt(1_000_000)
		}
	}
}

// pubPost POSTs a Connect JSON request. Safe from any goroutine (no testing.T).
func pubPost(url, token, procedure, body string) (status int, contentType, out string, err error) {
	req, err := http.NewRequest(http.MethodPost, url+procedure, bytes.NewReader([]byte(body)))
	if err != nil {
		return 0, "", "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header.Get("Content-Type"), string(b), err
}

// pubStoredID is users/{uid}.publicId (minted at signup while the flag is not globally off).
func pubStoredID(t *testing.T, e *chainEnv, uid string) string {
	t.Helper()
	snap, err := e.fs.Doc("users/" + uid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := snap.DataAt("publicId")
	pub, _ := raw.(string)
	if !identity.ValidPublicID(pub) {
		t.Fatalf("users/%s.publicId = %v, want a minted id", uid, raw)
	}
	return pub
}

const pubAlphabet = "0123456789abcdefghjkmnpqrstvwxyz"

// pubUnknown is a well-formed public id nobody holds; pubUnknownUID a Firebase-shaped uid nobody holds (same length
// as a real one, so a length-dependent answer cannot differ).
func pubUnknown() string {
	b := []byte("u0")
	for len(b) < 27 {
		b = append(b, pubAlphabet[rand.Intn(len(pubAlphabet))])
	}
	return string(b)
}

func pubUnknownUID() string {
	const alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	b := []byte("NoSuch")
	for len(b) < 28 {
		b = append(b, alnum[rand.Intn(len(alnum))])
	}
	return string(b)
}

// pubField is one translated request field: its path from the request root (all but the last are singular messages).
type pubField []protoreflect.FieldDescriptor

func (f pubField) leaf() protoreflect.FieldDescriptor { return f[len(f)-1] }

func (f pubField) String() string {
	var parts []string
	for _, fd := range f {
		parts = append(parts, string(fd.Name()))
	}
	return strings.Join(parts, ".")
}

// pubTranslateFields lists every TRANSLATE field reachable from md through singular message fields, read from the
// user_ref option independently of the plan builder.
func pubTranslateFields(md protoreflect.MessageDescriptor, prefix pubField, seen map[protoreflect.FullName]bool) []pubField {
	if seen[md.FullName()] {
		return nil
	}
	seen[md.FullName()] = true
	defer delete(seen, md.FullName())
	var out []pubField
	fields := md.Fields()
	for i := range fields.Len() {
		fd := fields.Get(i)
		path := append(append(pubField{}, prefix...), fd)
		if k, ok := userref.Kind(fd); ok && k == commonv1.UserRefKind_USER_REF_KIND_TRANSLATE {
			out = append(out, path)
			continue
		}
		if fd.Message() != nil && !fd.IsList() && !fd.IsMap() {
			out = append(out, pubTranslateFields(fd.Message(), path, seen)...)
		}
	}
	return out
}

// set writes v into the field at path of m (a repeated field gets the one element v).
func (f pubField) set(m protoreflect.Message, v string) {
	for _, fd := range f[:len(f)-1] {
		m = m.Mutable(fd).Message()
	}
	leaf := f.leaf()
	if leaf.IsList() {
		l := m.Mutable(leaf).List()
		l.Append(protoreflect.ValueOfString(v))
		return
	}
	m.Set(leaf, protoreflect.ValueOfString(v))
}

func pubSetStr(m protoreflect.Message, name, v string) {
	if fd := m.Descriptor().Fields().ByName(protoreflect.Name(name)); fd != nil {
		m.Set(fd, protoreflect.ValueOfString(v))
	}
}

func pubSetEnum(m protoreflect.Message, name string, n protoreflect.EnumNumber) {
	m.Set(m.Descriptor().Fields().ByName(protoreflect.Name(name)), protoreflect.ValueOfEnum(n))
}

// pubFixtures are the caller's own objects the RPCs act on.
type pubFixtures struct {
	listID, communityID, beaconID string
}

// pubBase fills, per procedure, the request fields other than the user id, so the handler reaches the user id. An RPC
// without an entry needs nothing beyond idempotency_key and page_size (filled generically).
var pubBase = map[string]func(m protoreflect.Message, fx pubFixtures){
	"/dzeroth.lists.v1.ListService/AddListMember":    func(m protoreflect.Message, fx pubFixtures) { pubSetStr(m, "list_id", fx.listID) },
	"/dzeroth.lists.v1.ListService/RemoveListMember": func(m protoreflect.Message, fx pubFixtures) { pubSetStr(m, "list_id", fx.listID) },
	"/dzeroth.communities.v1.CommunityService/SetMemberRole": func(m protoreflect.Message, fx pubFixtures) {
		pubSetStr(m, "community_id", fx.communityID)
		pubSetEnum(m, "action", protoreflect.EnumNumber(communitiesv1.MemberRoleAction_MEMBER_ROLE_ACTION_BAN))
	},
	"/dzeroth.beacons.v1.BeaconService/RespondToJoinRequest": func(m protoreflect.Message, fx pubFixtures) {
		pubSetStr(m, "beacon_id", fx.beaconID)
		pubSetEnum(m, "response", protoreflect.EnumNumber(beaconsv1.JoinResponse_JOIN_RESPONSE_ACCEPT))
	},
	"/dzeroth.beacons.v1.BeaconService/RemoveParticipant": func(m protoreflect.Message, fx pubFixtures) { pubSetStr(m, "beacon_id", fx.beaconID) },
	"/dzeroth.messaging.v1.MessagingService/SendMessage":  func(m protoreflect.Message, _ pubFixtures) { pubSetStr(m, "text", "hello there") },
}

// pubRequest builds the request of proc with the user id field at path set to v and a fresh idempotency key.
func pubRequest(t *testing.T, md protoreflect.MethodDescriptor, proc string, fx pubFixtures, path pubField, v string) string {
	t.Helper()
	mt, err := protoregistry.GlobalTypes.FindMessageByName(md.Input().FullName())
	if err != nil {
		t.Fatal(err)
	}
	m := mt.New()
	pubSetStr(m, "idempotency_key", contractKey("pubid"))
	if fd := m.Descriptor().Fields().ByName("page_size"); fd != nil && fd.Kind() == protoreflect.Int32Kind {
		m.Set(fd, protoreflect.ValueOfInt32(20))
	}
	if base := pubBase[proc]; base != nil {
		base(m, fx)
	}
	path.set(m, v)
	b, err := protojson.Marshal(m.Interface())
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// pubNormalize masks ids (each to its label), then page tokens and timestamps, in a JSON body, and drops publicId:
// with the flag on every AuthorSnapshot and Profile in a response carries it (filled by the edge, or by identity),
// with it off never, by design; that is not an unknown-id difference.
func pubNormalize(body string, masks map[string]string) string {
	for id, label := range masks {
		body = strings.ReplaceAll(body, id, label)
	}
	var v any
	if json.Unmarshal([]byte(body), &v) != nil {
		return body
	}
	var walk func(any) any
	walk = func(x any) any {
		switch y := x.(type) {
		case map[string]any:
			delete(y, "publicId")
			for k, val := range y {
				if s, ok := val.(string); ok && s != "" && (strings.HasSuffix(k, "Token") || strings.HasSuffix(k, "At") || pubTimestamp.MatchString(s)) {
					y[k] = "<" + k + ">"
					continue
				}
				y[k] = walk(val)
			}
			return y
		case []any:
			for i := range y {
				y[i] = walk(y[i])
			}
			return y
		}
		return x
	}
	out, _ := json.Marshal(walk(v))
	return string(out)
}

// pubDetail decodes the ErrorDetail of a Connect JSON error body (nil when there is none).
func pubDetail(body string) (code string, d *commonv1.ErrorDetail) {
	var e struct {
		Code    string `json:"code"`
		Details []struct {
			Type  string `json:"type"`
			Value string `json:"value"`
		} `json:"details"`
	}
	if json.Unmarshal([]byte(body), &e) != nil {
		return "", nil
	}
	for _, det := range e.Details {
		if det.Type != "dzeroth.common.v1.ErrorDetail" {
			continue
		}
		raw, err := base64.RawStdEncoding.DecodeString(strings.TrimRight(det.Value, "="))
		if err != nil {
			continue
		}
		var out commonv1.ErrorDetail
		if proto.Unmarshal(raw, &out) == nil {
			return e.Code, &out
		}
	}
	return e.Code, nil
}

func TestPublicIDs_ParityUnknownAndMalformed(t *testing.T) {
	skipIfNoEmulators(t)
	ctx := context.Background()
	// The caller is minted first so both chains can name it in COMMUNITY_CREATORS.
	tok, uid := mintToken(t, "")
	on := newChain(t, pubChainCfg(flags.On, nil, []string{uid}))
	off := newChain(t, pubChainCfg(flags.Off, nil, []string{uid}))
	on.createProfile(t, tok) // flag on: minted at signup
	me := pubStoredID(t, on, uid)

	// Fixtures the RPCs act on, all the caller's own, created through the flag-on chain (the same Firestore as the
	// flag-off one). A failure names the step and the chain.
	var fx pubFixtures
	lr, err := listsv1connect.NewListServiceClient(http.DefaultClient, on.url).CreateList(ctx, authed(tok, &listsv1.CreateListRequest{IdempotencyKey: contractKey("pubid-list"), Name: "Parity"}))
	if err != nil {
		t.Fatalf("fixture CreateList (flag-on chain): %v", err)
	}
	fx.listID = lr.Msg.GetList().GetListId()
	cr, err := communitiesv1connect.NewCommunityServiceClient(http.DefaultClient, on.url).CreateCommunity(ctx, authed(tok, &communitiesv1.CreateCommunityRequest{
		IdempotencyKey: contractKey("pubid-cm"), Name: "Parity " + uniqueHandle("c"), Description: "d"}))
	if err != nil {
		t.Fatalf("fixture CreateCommunity (flag-on chain, caller in COMMUNITY_CREATORS): %v", err)
	}
	fx.communityID = cr.Msg.GetCommunity().GetCommunityId()
	br, err := beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, on.url).CreateBeacon(ctx, authed(tok, &beaconsv1.CreateBeaconRequest{
		IdempotencyKey: contractKey("pubid-bc"), Audience: &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Title: "Coffee", Venue: "Hall",
		StartAt: timestamppb.New(time.Now().Add(time.Hour)), DurationMinutes: 30, OpenSpots: 3,
		Cost: beaconsv1.BeaconCost_BEACON_COST_FREE, ChatPreference: beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET,
	}))
	if err != nil {
		t.Fatalf("fixture CreateBeacon (flag-on chain): %v", err)
	}
	fx.beaconID = br.Msg.GetView().GetBeacon().GetBeaconId()
	if fx.listID == "" || fx.communityID == "" || fx.beaconID == "" {
		t.Fatalf("fixtures incomplete: %+v", fx)
	}

	methods := map[string]protoreflect.MethodDescriptor{}
	for _, sd := range publicIDServices() {
		ms := sd.Methods()
		for i := range ms.Len() {
			methods["/"+string(sd.FullName())+"/"+string(ms.Get(i).Name())] = ms.Get(i)
		}
	}
	// One subtest per RPC and per field, so one failing case does not hide the others.
	env := &pubParityEnv{on: on, off: off, tok: tok, uid: uid, me: me, fx: fx}
	for _, proc := range publicIDInboundRPCs(t) {
		t.Run(strings.TrimPrefix(proc, "/dzeroth."), func(t *testing.T) {
			md, ok := methods[proc]
			if !ok {
				t.Fatal("not in the registry")
			}
			fields := pubTranslateFields(md.Input(), nil, map[protoreflect.FullName]bool{})
			if len(fields) == 0 {
				t.Fatal("plans translate its request but the test's own walk finds no TRANSLATE field")
			}
			for _, path := range fields {
				t.Run(path.String(), func(t *testing.T) {
					pubParityCase(t, env, md, proc, path)
				})
			}
		})
	}
	t.Run("no side effects", func(t *testing.T) { pubNoSideEffects(t, env) })
}

// pubParityEnv is what every parity case shares: both chains, the caller and its fixtures, and every unknown id sent.
type pubParityEnv struct {
	on, off      *chainEnv
	tok, uid, me string
	fx           pubFixtures
	unknown      []string
}

// pubAnswer is the documented answer to an unknown user: the Connect code ("ok" for success) and, for an error, the
// ErrorDetail reason and an optional metadata reason.
type pubAnswer struct {
	code       string
	reason     commonv1.ErrorReason
	metaReason string
}

var (
	pubOK       = pubAnswer{code: "ok"}
	pubNotFound = pubAnswer{code: "not_found", reason: commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED}
)

// pubUnknownAnswer is what each handler answers today for a well-formed user id nobody holds, keyed by procedure and
// field path, read off the handlers (the file and function named). It documents unknown-user behaviour per RPC; the
// parity suite asserts the flag-off baseline gives exactly it, so the comparison is known to reach the user id.
var pubUnknownAnswer = map[string]pubAnswer{
	// graph/rpcs.go: Follow, Block, Mute map ErrNotFoundOrBlocked to NOT_FOUND; the undo RPCs are idempotent no-ops.
	"/dzeroth.graph.v1.GraphService/Follow user_id":   pubNotFound,
	"/dzeroth.graph.v1.GraphService/Unfollow user_id": pubOK,
	"/dzeroth.graph.v1.GraphService/Block user_id":    pubNotFound,
	"/dzeroth.graph.v1.GraphService/Unblock user_id":  pubOK,
	"/dzeroth.graph.v1.GraphService/Mute user_id":     pubNotFound,
	"/dzeroth.graph.v1.GraphService/Unmute user_id":   pubOK,
	// graph/follow_requests.go + repo_requests.go: no pending request is a replay outcome, answered with the relationship.
	"/dzeroth.graph.v1.GraphService/RespondToFollowRequest requester_user_id": pubOK,
	// graph/lists.go: relationships are computed from the caller's own snapshot (NONE for a stranger).
	"/dzeroth.graph.v1.GraphService/GetRelationships user_ids": pubOK,
	// graph/relationship.go and follows_list.go: a target without a profile is NOT_FOUND (identity's GetProfile shape).
	"/dzeroth.graph.v1.GraphService/GetProfileRelationship user_id": pubNotFound,
	"/dzeroth.graph.v1.GraphService/ListFollowers user_id":          pubNotFound,
	"/dzeroth.graph.v1.GraphService/ListFollowing user_id":          pubNotFound,
	// identity/service.go GetProfile: NOT_FOUND.
	"/dzeroth.identity.v1.IdentityService/GetProfile user_id": pubNotFound,
	// timeline/service.go user() -> checkVisible: identity.ProfileNotFoundError.
	"/dzeroth.timeline.v1.TimelineService/GetUserTimeline user_id": pubNotFound,
	// lists/service_read.go otherOwner: ProfileNotFoundError; contains_user_id only filters the caller's own lists.
	"/dzeroth.lists.v1.ListService/ListUserLists owner_id":         pubNotFound,
	"/dzeroth.lists.v1.ListService/ListUserLists contains_user_id": pubOK,
	// lists/service_members.go: AddMember's targetVerdict refuses ErrNotFound; RemoveMember of a non-member is a no-op.
	"/dzeroth.lists.v1.ListService/AddListMember user_id":    pubNotFound,
	"/dzeroth.lists.v1.ListService/RemoveListMember user_id": pubOK,
	// communities/service_moderation.go SetMemberRole: errUserNotFound.
	"/dzeroth.communities.v1.CommunityService/SetMemberRole user_id": pubNotFound,
	// beacons/service_participation.go + repo_participation.go: no participant row is the state conflict of the RPC.
	"/dzeroth.beacons.v1.BeaconService/RespondToJoinRequest user_id": {code: "failed_precondition", reason: commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, metaReason: "not_requested"},
	"/dzeroth.beacons.v1.BeaconService/RemoveParticipant user_id":    {code: "failed_precondition", reason: commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, metaReason: "not_participant"},
	// beacons/service_shared.go ListShared: a missing peer is an empty page.
	"/dzeroth.beacons.v1.BeaconService/ListSharedBeacons peer_user_id": pubOK,
	// messaging/service_send.go: a recipient without an ACTIVE profile is the one CANNOT_MESSAGE refusal.
	"/dzeroth.messaging.v1.MessagingService/SendMessage recipient_user_id": {code: "failed_precondition", reason: commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE},
}

// pubCheckAnswer asserts the flag-off baseline is the documented unknown-user answer.
func pubCheckAnswer(t *testing.T, key string, status int, body string) {
	t.Helper()
	want, ok := pubUnknownAnswer[key]
	if !ok {
		t.Errorf("no documented unknown-user answer for %q: read the handler and add it to pubUnknownAnswer", key)
		return
	}
	if want.code == "ok" {
		if status != http.StatusOK {
			t.Errorf("unknown user (flag-off chain) = %d %s, want 200 (%s)", status, body, key)
		}
		return
	}
	code, d := pubDetail(body)
	if code != want.code || d == nil || d.GetReason() != want.reason || (want.metaReason != "" && d.GetMetadata()["reason"] != want.metaReason) {
		t.Errorf("unknown user (flag-off chain) = %d %s, want %s %v reason=%q (%s)", status, body, want.code, want.reason, want.metaReason, key)
	}
}

// pubNoSideEffects: no document names an unknown id after every case ran, on either chain's form.
func pubNoSideEffects(t *testing.T, e *pubParityEnv) {
	ctx := context.Background()
	fs := e.on.fs
	if len(e.unknown) == 0 {
		t.Fatal("no unknown id was sent")
	}
	// Documents whose data (any field, arrays included) must not mention an unknown id.
	holders := []string{"graph/" + e.uid, "users/" + e.uid, "lists/" + e.fx.listID, "communities/" + e.fx.communityID, "beacons/" + e.fx.beaconID, "communityMemberships/" + e.uid}
	data := map[string]string{}
	for _, path := range holders {
		snap, err := fs.Doc(path).Get(ctx)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				continue
			}
			t.Fatalf("read %s: %v", path, err)
		}
		data[path] = fmt.Sprint(snap.Data())
	}
	for _, x := range e.unknown {
		for _, path := range []string{
			"follows/" + e.uid + "_" + x, "follows/" + x + "_" + e.uid,
			"followRequests/" + e.uid + "_" + x, "followRequests/" + x + "_" + e.uid,
			"graph/" + x, "users/" + x, "communityMemberships/" + x,
			"communities/" + e.fx.communityID + "/communityMembers/" + x,
			"beacons/" + e.fx.beaconID + "/beaconParticipants/" + x,
			"users/" + x + "/beaconMemberships/" + e.fx.beaconID,
			"conversations/" + messaging.ConversationID(e.uid, x),
		} {
			if fsDocExists(t, fs, path) {
				t.Errorf("an unknown-id call wrote %s", path)
			}
		}
		for path, d := range data {
			if strings.Contains(d, x) {
				t.Errorf("%s names an unknown id after the calls: %s", path, d)
			}
		}
	}
}

// pubParityCase is one (rpc, field): the malformed half on the flag-on chain, then the unknown-id parity.
func pubParityCase(t *testing.T, e *pubParityEnv, md protoreflect.MethodDescriptor, proc string, path pubField) {
	// Malformed (an old client's raw uid): VALIDATION naming the leaf field, from the edge.
	st, _, body, err := pubPost(e.on.url, e.tok, proc, pubRequest(t, md, proc, e.fx, path, e.uid))
	if err != nil {
		t.Fatalf("malformed (flag-on chain): %v", err)
	}
	if code, d := pubDetail(body); st != http.StatusBadRequest || code != "invalid_argument" || d == nil ||
		d.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION || d.GetMetadata()["field"] != string(path.leaf().Name()) {
		t.Errorf("a raw uid with the flag on (flag-on chain) = %d %s, want VALIDATION field=%s", st, body, path.leaf().Name())
	}
	if reason, excluded := publicIDParityExcluded[proc]; excluded {
		t.Logf("unknown-id parity excluded: %s", reason)
		return
	}
	// Unknown: flag off with an unknown uid vs flag on with an unknown public id.
	unknownUID, unknownPub := pubUnknownUID(), pubUnknown()
	e.unknown = append(e.unknown, unknownUID, unknownPub)
	ost, oct, obody, err := pubPost(e.off.url, e.tok, proc, pubRequest(t, md, proc, e.fx, path, unknownUID))
	if err != nil {
		t.Fatalf("unknown uid (flag-off chain): %v", err)
	}
	nst, nct, nbody, err := pubPost(e.on.url, e.tok, proc, pubRequest(t, md, proc, e.fx, path, unknownPub))
	if err != nil {
		t.Fatalf("unknown public id (flag-on chain): %v", err)
	}
	masks := map[string]string{unknownUID: "<ID>", unknownPub: "<ID>", e.uid: "<ME>", e.me: "<ME>"}
	if ost != nst || oct != nct || pubNormalize(obody, masks) != pubNormalize(nbody, masks) {
		t.Errorf("unknown id differs between the forms (a bug to report)\n  flag-off chain, uid:      %d %s %s\n  flag-on chain, public id: %d %s %s", ost, oct, obody, nst, nct, nbody)
	}
	// The baseline must reach the user id: not a flag gate, not another field's VALIDATION.
	if code, d := pubDetail(obody); d != nil {
		if d.GetReason() == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED ||
			(d.GetReason() == commonv1.ErrorReason_ERROR_REASON_VALIDATION && d.GetMetadata()["field"] != string(path.leaf().Name())) {
			t.Errorf("the flag-off baseline (flag-off chain) stops before the user id: %s %v (fix the fixture or the chain config)", code, d)
		}
	}
	pubCheckAnswer(t, proc+" "+path.String(), ost, obody)
	t.Logf("unknown id answers %d %s", ost, pubNormalize(obody, masks))
}

// publicIDServices is every dzeroth service in the registry (the same list the plans are built from).
func publicIDServices() []protoreflect.ServiceDescriptor {
	var out []protoreflect.ServiceDescriptor
	protoregistry.GlobalFiles.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		if strings.HasPrefix(string(fd.Package()), "dzeroth.") {
			for i := range fd.Services().Len() {
				out = append(out, fd.Services().Get(i))
			}
		}
		return true
	})
	return out
}

func TestPublicIDs_SharedPagesRace(t *testing.T) {
	skipIfNoEmulators(t)
	ctx := context.Background()
	fTok, fUID := mintToken(t, "")
	nTok, nUID := mintToken(t, "")
	env := newChain(t, pubChainCfg(flags.Allowlist, []string{fUID}, nil))
	w := newW320BM(env)
	env.createProfile(t, fTok)
	env.createProfile(t, nTok)
	a, b := w.user(t), w.user(t)
	fPub, nPub, aPub, bPub := pubStoredID(t, env, fUID), pubStoredID(t, env, nUID), pubStoredID(t, env, a.uid), pubStoredID(t, env, b.uid)

	// F and N follow A (each in its own id form; A is unflagged, so it names them by uid); A follows both (FOLLOW
	// notifications with A as actor).
	for _, f := range []struct{ tok, target string }{{fTok, aPub}, {nTok, a.uid}, {a.token, fUID}, {a.token, nUID}} {
		if _, err := w.graph.Follow(ctx, authed(f.tok, &graphv1.FollowRequest{IdempotencyKey: contractKey("pubid-f"), UserId: f.target})); err != nil {
			t.Fatalf("Follow: %v", err)
		}
	}
	pb := w.post(t, b, "b's post")
	pa := w.post(t, a, "a's post")
	q, err := env.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("pubid-q"), Text: "a quotes b", QuoteOfPostId: pb}))
	if err != nil {
		t.Fatalf("quote: %v", err)
	}
	quote := q.Msg.GetPost().GetPost().GetPostId()

	type page struct {
		proc string
		req  func(flagged bool) proto.Message
	}
	idOf := func(flagged bool) string {
		if flagged {
			return aPub
		}
		return a.uid
	}
	pages := []page{
		{timelinev1connect.TimelineServiceGetHomeTimelineProcedure, func(bool) proto.Message { return &timelinev1.GetHomeTimelineRequest{PageSize: 20} }},
		{timelinev1connect.TimelineServiceGetUserTimelineProcedure, func(f bool) proto.Message {
			return &timelinev1.GetUserTimelineRequest{UserId: idOf(f), PageSize: 20}
		}},
		{postsv1connect.PostServiceGetPostProcedure, func(bool) proto.Message { return &postsv1.GetPostRequest{PostId: quote} }},
		{postsv1connect.PostServiceGetPostProcedure, func(bool) proto.Message { return &postsv1.GetPostRequest{PostId: pa} }},
		{postsv1connect.PostServiceGetThreadProcedure, func(bool) proto.Message { return &postsv1.GetThreadRequest{PostId: pb, PageSize: 20} }},
		{notificationsv1connect.NotificationServiceListNotificationsProcedure, func(bool) proto.Message {
			return &notificationsv1.ListNotificationsRequest{PageSize: 20}
		}},
		{identityv1connect.IdentityServiceGetProfileProcedure, func(f bool) proto.Message {
			return &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: idOf(f)}}
		}},
		{graphv1connect.GraphServiceListFollowersProcedure, func(f bool) proto.Message {
			return &graphv1.ListFollowersRequest{UserId: idOf(f), PageSize: 20}
		}},
	}

	type result struct {
		flagged    bool
		proc, body string
		status     int
		err        error
	}
	const rounds = 6
	results := make(chan result, rounds*len(pages)*2)
	var wg sync.WaitGroup
	for range rounds {
		for _, p := range pages {
			for _, flagged := range []bool{true, false} {
				wg.Add(1)
				go func() {
					defer wg.Done()
					tok := nTok
					if flagged {
						tok = fTok
					}
					body, err := protojson.Marshal(p.req(flagged))
					if err != nil {
						results <- result{flagged: flagged, proc: p.proc, err: err}
						return
					}
					st, _, out, err := pubPost(env.url, tok, p.proc, string(body))
					results <- result{flagged: flagged, proc: p.proc, body: out, status: st, err: err}
				}()
			}
		}
	}
	wg.Wait()
	close(results)

	uids := []string{fUID, nUID, a.uid, b.uid}
	sawUID := false
	// Pages that must carry both seeded authors' public ids for the flagged caller (A's quote embeds B's post; the home
	// timeline is pull-on-read, so it holds A's posts as soon as they are written).
	mustCarry := map[string]bool{timelinev1connect.TimelineServiceGetHomeTimelineProcedure: true}
	quoteSeen := map[bool]bool{}
	for r := range results {
		if r.err != nil || r.status != http.StatusOK {
			t.Errorf("%s (flagged=%v): %d %v %s", r.proc, r.flagged, r.status, r.err, r.body)
			continue
		}
		body := r.body
		if r.flagged {
			if r.proc == notificationsv1connect.NotificationServiceListNotificationsProcedure {
				body = pubDropNotificationIDs(t, body)
			}
			for _, u := range uids {
				if strings.Contains(body, u) {
					t.Errorf("%s: the flagged caller saw a uid: %s", r.proc, body)
				}
			}
			if strings.Contains(body, publicid.Tombstone) {
				t.Errorf("%s: the flagged caller saw the tombstone (every seeded account is minted): %s", r.proc, body)
			}
			isQuote := r.proc == postsv1connect.PostServiceGetPostProcedure && strings.Contains(body, quote)
			if mustCarry[r.proc] || isQuote {
				if !strings.Contains(body, aPub) || !strings.Contains(body, bPub) {
					t.Errorf("%s: the flagged page lacks a seeded author's public id (A %v, B %v): %s", r.proc, strings.Contains(body, aPub), strings.Contains(body, bPub), body)
				}
				quoteSeen[isQuote] = true
			}
			continue
		}
		for _, p := range []string{fPub, nPub, aPub, bPub} {
			if strings.Contains(body, p) {
				t.Errorf("%s: the unflagged caller saw a public id: %s", r.proc, body)
			}
		}
		sawUID = sawUID || strings.Contains(body, a.uid)
	}
	if !sawUID || !quoteSeen[true] || !quoteSeen[false] {
		t.Errorf("the asserted pages were not seen (unflagged saw A's uid %v, flagged quote %v, flagged home %v): the scan proved nothing", sawUID, quoteSeen[true], quoteSeen[false])
	}
}

// pubDropNotificationIDs removes Notification.id from a ListNotifications body before the uid scan. Known gap, not a
// pass: the field is not annotated yet, so flagged callers still receive the actor's raw uid in it for FOLLOW,
// FOLLOW_REQUEST, FOLLOW_ACCEPTED, REPOST and BEACON_REQUEST rows until PR 4c annotates it and registers its rule
// (see publicIDPassThrough). PR 4c removes this helper.
func pubDropNotificationIDs(t *testing.T, body string) string {
	t.Helper()
	var v map[string]any
	if err := json.Unmarshal([]byte(body), &v); err != nil {
		t.Fatalf("notifications body: %v", err)
	}
	if ns, ok := v["notifications"].([]any); ok {
		for _, n := range ns {
			if m, ok := n.(map[string]any); ok {
				delete(m, "id")
			}
		}
	}
	out, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}
