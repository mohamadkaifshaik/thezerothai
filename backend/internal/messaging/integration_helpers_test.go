//go:build integration

package messaging

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// itEnv is the real FirestoreRepo on the emulator behind the real service, with fake social, directory and seams. A
// project id of its own keeps every test's data apart.
type itEnv struct {
	t      *testing.T
	fs     *firestore.Client
	repo   *FirestoreRepo
	social *fakeSocial
	profs  *fakeProfiles
	events *recEvents
	badge  *recBadge
	limits Limits
	reg    *flags.Registry
	clock  atomic.Int64 // unix micro; advance with tick
	svc    *service
}

func newIT(t *testing.T, mut func(*itEnv)) *itEnv {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	fs, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int64()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = fs.Close() })
	e := &itEnv{
		t: t, fs: fs, repo: NewFirestoreRepo(fs, quota.New(fs)),
		social: &fakeSocial{snaps: map[string]graph.Snapshot{}}, events: &recEvents{}, badge: &recBadge{},
		limits: Limits{RequestMaxUnanswered: 3, DMNewPerDay: 20, NewAccountDMNewPerDay: 5, NewAccountSendsPerDay: 50, NewAccountWindow: 72 * time.Hour, ConversationCacheEntries: 100},
		reg:    flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}),
	}
	e.clock.Store(time.Now().UTC().Truncate(time.Second).UnixMicro())
	e.profs = &fakeProfiles{profiles: map[string]identity.Profile{}}
	e.addUser(alice, "alice", false)
	e.addUser(bob, "bob", false)
	if mut != nil {
		mut(e)
	}
	e.svc = e.newService()
	return e
}

func (e *itEnv) now() time.Time { return time.UnixMicro(e.clock.Load()).UTC() }

// tick moves the clock forward and returns the new instant (messages sort by it, so a test advances it between sends).
func (e *itEnv) tick(d time.Duration) time.Time {
	return time.UnixMicro(e.clock.Add(d.Microseconds())).UTC()
}

// newService builds another service instance over the same storage (a second Cloud Run instance).
func (e *itEnv) newService() *service {
	return New(e.reg, Deps{
		Repo: e.repo, Social: e.social, Profiles: e.profs, Events: e.events, Badge: e.badge, Limits: e.limits, Now: e.now,
	}).(*service)
}

func (e *itEnv) addUser(uid, handle string, isNew bool) {
	created := time.Now().Add(-30 * 24 * time.Hour)
	if isNew {
		created = time.Now().Add(-time.Hour)
	}
	e.profs.mu.Lock()
	e.profs.profiles[uid] = activeProfile(uid, handle, created)
	e.profs.mu.Unlock()
}

func (e *itEnv) setSocial(uid string, s graph.Snapshot) {
	e.social.mu.Lock()
	e.social.snaps[uid] = s
	e.social.mu.Unlock()
}

// mutual makes a and b follow each other.
func (e *itEnv) mutual(a, b string) {
	e.setSocial(a, graph.Snapshot{Following: map[string]bool{b: true}})
	e.setSocial(b, graph.Snapshot{Following: map[string]bool{a: true}})
}

// send runs one SendMessage on svc under its own budget counter.
func (e *itEnv) send(from string, req *messagingv1.SendMessageRequest) (*messagingv1.SendMessageResponse, *budget.Counter, error) {
	return e.sendOn(e.svc, from, req)
}

func (e *itEnv) sendOn(svc *service, from string, req *messagingv1.SendMessageRequest) (*messagingv1.SendMessageResponse, *budget.Counter, error) {
	ctx, c := budget.WithCounter(context.Background())
	resp, err := svc.Send(ctx, from, req)
	return resp, c, err
}

func (e *itEnv) must(from string, req *messagingv1.SendMessageRequest) *messagingv1.SendMessageResponse {
	e.t.Helper()
	resp, _, err := e.send(from, req)
	if err != nil {
		e.t.Fatalf("send: %v", err)
	}
	return resp
}

func (e *itEnv) conv(id string) (ConvDoc, bool) {
	e.t.Helper()
	snap, err := e.fs.Collection("conversations").Doc(id).Get(context.Background())
	if err != nil {
		return ConvDoc{}, false
	}
	var c ConvDoc
	if err := snap.DataTo(&c); err != nil {
		e.t.Fatal(err)
	}
	return c, true
}

// msgs returns the conversation's messages oldest first, with their ids.
func (e *itEnv) msgs(convID string) map[string]MsgDoc {
	e.t.Helper()
	docs, err := e.fs.Collection("conversations").Doc(convID).Collection("messages").Documents(context.Background()).GetAll()
	if err != nil {
		e.t.Fatal(err)
	}
	out := map[string]MsgDoc{}
	for _, d := range docs {
		var m MsgDoc
		if err := d.DataTo(&m); err != nil {
			e.t.Fatal(err)
		}
		out[d.Ref.ID] = m
	}
	return out
}

func (e *itEnv) entry(uid, folder, convID string) (EntryDoc, bool) {
	e.t.Helper()
	snap, err := e.fs.Collection("users").Doc(uid).Collection(folder).Doc(convID).Get(context.Background())
	if err != nil {
		return EntryDoc{}, false
	}
	var d EntryDoc
	if err := snap.DataTo(&d); err != nil {
		e.t.Fatal(err)
	}
	return d, true
}

func (e *itEnv) dmNew(uid string) int64 {
	e.t.Helper()
	snap, err := e.fs.Collection("quotas").Doc(uid).Get(context.Background())
	if err != nil {
		return 0
	}
	var r quota.Record
	if err := snap.DataTo(&r); err != nil {
		e.t.Fatal(err)
	}
	return r.DMNew
}

// treeDocs lists every document path left under conversations/{id}, the conversation document included.
func (e *itEnv) treeDocs(id string) []string {
	e.t.Helper()
	var out []string
	ctx := context.Background()
	ref := e.fs.Collection("conversations").Doc(id)
	if snap, err := ref.Get(ctx); err == nil && snap.Exists() {
		out = append(out, "conversations/"+id)
	}
	it := ref.Collection("messages").Documents(ctx)
	for {
		d, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			e.t.Fatal(err)
		}
		out = append(out, shortPath(d.Ref.Path))
	}
	slices.Sort(out)
	return out
}

func shortPath(p string) string {
	const marker = "/documents/"
	for i := 0; i+len(marker) <= len(p); i++ {
		if p[i:i+len(marker)] == marker {
			return p[i+len(marker):]
		}
	}
	return p
}

// seedConversation writes a conversation, its entries and messages directly, for the lifecycle tests. msgs are
// (sender, text) pairs, one second apart from base.
func (e *itEnv) seedConversation(a, b, state string, base time.Time, msgs ...[2]string) string {
	e.t.Helper()
	ctx := context.Background()
	id := ConversationID(a, b)
	doc := ConvDoc{Kind: kindDirect, Participants: sortedPair(a, b), State: state, CreatedAt: base, UpdatedAt: base}
	if state == stateRequest {
		doc.RequestFrom, doc.RequestTo, doc.RequestCount = a, b, int64(min(len(msgs), 3))
	}
	if _, err := e.fs.Collection("conversations").Doc(id).Set(ctx, doc); err != nil {
		e.t.Fatal(err)
	}
	var last [2]string
	for i, m := range msgs {
		at := base.Add(time.Duration(i) * time.Second)
		mid := fmt.Sprintf("%032x", rand.Uint64())
		if _, err := e.fs.Collection("conversations").Doc(id).Collection("messages").Doc(mid).Set(ctx, MsgDoc{SenderID: m[0], Text: m[1], State: msgVisible, RequestHash: "h", CreatedAt: at}); err != nil {
			e.t.Fatal(err)
		}
		last = m
	}
	for _, side := range [][2]string{{a, b}, {b, a}} {
		uid, peer := side[0], side[1]
		folder := dmInboxCollection
		if state == stateRequest && uid == b {
			folder = dmRequestsCollection
		}
		ent := EntryDoc{
			PeerID: peer, Peer: PeerDoc{Handle: "h-" + peer, DisplayName: "Name " + peer}, LastMessageAt: base.Add(time.Duration(len(msgs)) * time.Second),
			Last: LastDoc{MessageID: "m", FromSelf: last[0] == uid, Snippet: last[1], State: msgVisible}, CreatedAt: base,
		}
		if _, err := e.fs.Collection("users").Doc(uid).Collection(folder).Doc(id).Set(ctx, ent); err != nil {
			e.t.Fatal(err)
		}
	}
	return id
}

type (
	firestoreUpdate = firestore.Update
	identityProfile = identity.Profile
)
