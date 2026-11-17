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
// Shared messages: two callers on one allowlist chain, one flagged and one not, fetch the same pages concurrently;
// the unflagged one never sees a public id and the flagged one never a uid (Notification.id, CONDITIONAL with its rule
// in PR 4c, is left out of the scan).

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/rand"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/userref"
)

// pubChainCfg turns on every module an inbound-translating RPC belongs to, with the abuse limits relaxed, and sets
// FEATURE_PUBLIC_IDS to mode (allow = its allowlist).
func pubChainCfg(mode flags.Mode, allow ...string) func(*config.Config) {
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
		spec := flags.Spec{Name: identity.PublicIDsFlag, Mode: mode, Allowlist: map[string]struct{}{}}
		for _, u := range allow {
			spec.Allowlist[u] = struct{}{}
		}
		c.FeaturePublicIDs = spec
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
				if s, ok := val.(string); ok && s != "" && (strings.HasSuffix(k, "Token") || strings.HasSuffix(k, "At")) {
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
	on := newChain(t, pubChainCfg(flags.On))
	off := newChain(t, pubChainCfg(flags.Off))
	tok, uid := mintToken(t, "")
	on.createProfile(t, tok) // flag on: minted at signup
	me := pubStoredID(t, on, uid)

	// Fixtures the RPCs act on, all the caller's own.
	var fx pubFixtures
	lr, err := listsv1connect.NewListServiceClient(http.DefaultClient, on.url).CreateList(ctx, authed(tok, &listsv1.CreateListRequest{IdempotencyKey: contractKey("pubid-list"), Name: "Parity"}))
	if err != nil {
		t.Fatalf("CreateList: %v", err)
	}
	fx.listID = lr.Msg.GetList().GetListId()
	cr, err := communitiesv1connect.NewCommunityServiceClient(http.DefaultClient, on.url).CreateCommunity(ctx, authed(tok, &communitiesv1.CreateCommunityRequest{
		IdempotencyKey: contractKey("pubid-cm"), Name: "Parity " + uniqueHandle("c"), Description: "d"}))
	if err != nil {
		t.Fatalf("CreateCommunity: %v", err)
	}
	fx.communityID = cr.Msg.GetCommunity().GetCommunityId()
	br, err := beaconsv1connect.NewBeaconServiceClient(http.DefaultClient, on.url).CreateBeacon(ctx, authed(tok, &beaconsv1.CreateBeaconRequest{
		IdempotencyKey: contractKey("pubid-bc"), Audience: &beaconsv1.CreateBeaconRequest_Public{Public: true},
		Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE, Title: "Coffee", Venue: "Hall",
		StartAt: timestamppb.New(time.Now().Add(time.Hour)), DurationMinutes: 30, OpenSpots: 3,
		Cost: beaconsv1.BeaconCost_BEACON_COST_FREE, ChatPreference: beaconsv1.ChatPreference_CHAT_PREFERENCE_QUIET,
	}))
	if err != nil {
		t.Fatalf("CreateBeacon: %v", err)
	}
	fx.beaconID = br.Msg.GetView().GetBeacon().GetBeaconId()

	methods := map[string]protoreflect.MethodDescriptor{}
	for _, sd := range publicIDServices() {
		ms := sd.Methods()
		for i := range ms.Len() {
			methods["/"+string(sd.FullName())+"/"+string(ms.Get(i).Name())] = ms.Get(i)
		}
	}
	covered := 0
	for _, proc := range publicIDInboundRPCs(t) {
		md := methods[proc]
		fields := pubTranslateFields(md.Input(), nil, map[protoreflect.FullName]bool{})
		if len(fields) == 0 {
			t.Errorf("%s: plans translate its request but no TRANSLATE field found by the test's own walk", proc)
			continue
		}
		for _, path := range fields {
			name := proc + " " + path.String()
			// Malformed (an old client's raw uid): VALIDATION naming the leaf field, from the edge.
			st, _, body, err := pubPost(on.url, tok, proc, pubRequest(t, md, proc, fx, path, uid))
			if err != nil {
				t.Fatalf("%s malformed: %v", name, err)
			}
			if code, d := pubDetail(body); st != http.StatusBadRequest || code != "invalid_argument" || d == nil ||
				d.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION || d.GetMetadata()["field"] != string(path.leaf().Name()) {
				t.Errorf("%s: a raw uid with the flag on = %d %s, want VALIDATION field=%s", name, st, body, path.leaf().Name())
			}
			if reason, excluded := publicIDParityExcluded[proc]; excluded {
				t.Logf("%s: unknown-id parity excluded: %s", name, reason)
				continue
			}
			// Unknown: flag off with an unknown uid vs flag on with an unknown public id.
			unknownUID, unknownPub := pubUnknownUID(), pubUnknown()
			ost, oct, obody, err := pubPost(off.url, tok, proc, pubRequest(t, md, proc, fx, path, unknownUID))
			if err != nil {
				t.Fatalf("%s off: %v", name, err)
			}
			nst, nct, nbody, err := pubPost(on.url, tok, proc, pubRequest(t, md, proc, fx, path, unknownPub))
			if err != nil {
				t.Fatalf("%s on: %v", name, err)
			}
			masks := map[string]string{unknownUID: "<ID>", unknownPub: "<ID>", uid: "<ME>", me: "<ME>"}
			if ost != nst || oct != nct || pubNormalize(obody, masks) != pubNormalize(nbody, masks) {
				t.Errorf("%s: unknown id differs between the forms (a bug to report)\n  off/uid: %d %s %s\n  on/pub:  %d %s %s", name, ost, oct, obody, nst, nct, nbody)
			}
			// The baseline must reach the user id: not a flag gate, not another field's VALIDATION.
			if code, d := pubDetail(obody); d != nil {
				if d.GetReason() == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED ||
					(d.GetReason() == commonv1.ErrorReason_ERROR_REASON_VALIDATION && d.GetMetadata()["field"] != string(path.leaf().Name())) {
					t.Errorf("%s: the flag-off baseline stops before the user id: %s %v (fix the fixture)", name, code, d)
				}
			}
			t.Logf("%s: unknown id answers %d %s", name, ost, pubNormalize(obody, masks))
			covered++
		}
	}
	t.Logf("parity: %d (rpc, field) pairs compared", covered)
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
	env := newChain(t, pubChainCfg(flags.Allowlist, fUID))
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
	sawPub, sawUID := false, false
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
			sawPub = sawPub || strings.Contains(body, aPub)
			continue
		}
		for _, p := range []string{fPub, nPub, aPub, bPub} {
			if strings.Contains(body, p) {
				t.Errorf("%s: the unflagged caller saw a public id: %s", r.proc, body)
			}
		}
		sawUID = sawUID || strings.Contains(body, a.uid)
	}
	if !sawPub || !sawUID {
		t.Errorf("the pages carried no author id (flagged saw A's public id: %v; unflagged saw A's uid: %v): the scan proved nothing", sawPub, sawUID)
	}
}

// pubDropNotificationIDs removes Notification.id (CONDITIONAL, rule in PR 4c: until then it still embeds the actor's
// uid for actor-keyed types) from a ListNotifications body before the uid scan.
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
