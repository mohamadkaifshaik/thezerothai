//go:build integration

package apiserver

// Shares end to end over the real Build chain on the emulators (shares design 2026-11-13, PR 5): a post sent in a direct
// message, the per-reader card and its leak matrix (every cause gives the one unavailable form; a mute is not a block),
// RecordPostShare once per account under concurrency, the author never counted, the refusals of a send with a post, the
// replay rules of the request digest, and the kill switch. Every read that must not be served from a 60 s instance cache
// goes through a COLD chain (a new Build over the same emulator project).

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// sharesOn is messagingOn plus both share flags, quotes, private accounts and relaxed share limits. dmShare is the
// FEATURE_DM_POST_SHARE mode (the kill-switch case turns it off).
func sharesOn(dmShare flags.Mode) func(*config.Config) {
	return func(c *config.Config) {
		messagingOn(c)
		c.RateLimit.SharesPerUserPerMinute = 1_000_000
		c.RateLimit.SharesRecordedPerDay = 1_000_000
		c.RateLimit.LikesPerUserPerMinute = 1_000_000
		c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
		c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
		c.FeaturePrivateAccounts = flags.Spec{Name: "private_accounts", Mode: flags.On}
		c.FeatureDMPostShare = flags.Spec{Name: "dm_post_share", Mode: dmShare}
		c.FeatureShareCount = flags.Spec{Name: "share_count", Mode: flags.On}
	}
}

type shareChain struct {
	*dmChain
	eng engagementv1connect.EngagementServiceClient
}

func newShareChain(t *testing.T, dmShare flags.Mode) *shareChain {
	t.Helper()
	d := newDMChain(t, sharesOn(dmShare))
	return &shareChain{dmChain: d, eng: engagementv1connect.NewEngagementServiceClient(http.DefaultClient, d.url)}
}

func (e *shareChain) post(t *testing.T, u dmUser, text string) string {
	t.Helper()
	r, err := e.posts.CreatePost(context.Background(), authed(u.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("sh-post"), Text: text}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	return r.Msg.GetPost().GetPost().GetPostId()
}

func (e *shareChain) sendPost(from, to dmUser, key, text, postID string) (*messagingv1.SendMessageResponse, error) {
	r, err := e.msg.SendMessage(context.Background(), authed(from.token, &messagingv1.SendMessageRequest{
		IdempotencyKey: key, Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: to.uid}, Text: text, SharedPostId: postID,
	}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *shareChain) record(u dmUser, postID string) (*engagementv1.RecordPostShareResponse, error) {
	r, err := e.eng.RecordPostShare(context.Background(), authed(u.token, &engagementv1.RecordPostShareRequest{
		IdempotencyKey: contractKey("sh-rec"), PostId: postID, Channel: engagementv1.ShareChannel_SHARE_CHANNEL_COPY_LINK,
	}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

// card is the shared post of the newest message reader sees in the conversation with peer.
func (e *shareChain) card(t *testing.T, reader, peer dmUser) *postsv1.EmbeddedPost {
	t.Helper()
	r, err := e.msg.ListMessages(context.Background(), authed(reader.token, &messagingv1.ListMessagesRequest{ConversationId: messaging.ConversationID(reader.uid, peer.uid)}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(r.Msg.GetMessages()) == 0 {
		t.Fatal("no message")
	}
	return r.Msg.GetMessages()[0].GetSharedPost()
}

func (e *shareChain) storedCount(t *testing.T, postID string) int64 {
	t.Helper()
	s, err := e.fs.Doc("posts/" + postID).Get(context.Background())
	if err != nil {
		t.Fatalf("read post: %v", err)
	}
	v, _ := s.DataAt("shareCount")
	n, _ := v.(int64)
	return n
}

func (e *shareChain) graphOp(t *testing.T, op string, who, target dmUser) {
	t.Helper()
	ctx := context.Background()
	var err error
	switch op {
	case "block":
		_, err = e.graph.Block(ctx, authed(who.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("sh-blk"), UserId: target.uid}))
	case "mute":
		_, err = e.graph.Mute(ctx, authed(who.token, &graphv1.MuteRequest{IdempotencyKey: contractKey("sh-mute"), UserId: target.uid}))
	}
	if err != nil {
		t.Fatalf("%s: %v", op, err)
	}
}

func (e *shareChain) protect(t *testing.T, u dmUser) {
	t.Helper()
	v := true
	if _, err := e.identity.UpdateProfile(context.Background(), authed(u.token, &identityv1.UpdateProfileRequest{IdempotencyKey: contractKey("sh-priv"), IsPrivate: &v})); err != nil {
		t.Fatalf("protect: %v", err)
	}
}

func (e *shareChain) update(t *testing.T, path, field string, value any) {
	t.Helper()
	if _, err := e.fs.Doc(path).Update(context.Background(), []firestore.Update{{Path: field, Value: value}}); err != nil {
		t.Fatal(err)
	}
}

// A share is a message with a post id: the card, the stored id, the preview flag, the count once per account (DM and
// outside shares merged), the author never counted, the request digest's replay rules, and 10 concurrent outside shares
// by one account counting once.
func TestSharesChain_SendCountAndReplay(t *testing.T) {
	ctx := context.Background()
	w := newShareChain(t, flags.On)
	a, b, c, d := w.user(t), w.user(t), w.user(t), w.user(t)
	p := w.post(t, c, "a post worth sending")
	url := "https://dzeroth.app/post/" + p

	first, err := w.sendPost(a, b, "share-key-first-0001", url, p)
	if err != nil {
		t.Fatalf("share: %v", err)
	}
	if first.GetMessage().GetSharedPost().GetPostId() != p || first.GetMessage().GetSharedPost().GetUnavailable() || !first.GetConversation().GetLastMessage().GetSharedPost() {
		t.Fatalf("response = %v, want the live card and the preview flag", first)
	}
	msgDoc, err := w.fs.Doc("conversations/" + first.GetMessage().GetConversationId() + "/messages/" + first.GetMessage().GetId()).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := msgDoc.DataAt("sharedPostId"); v != p {
		t.Fatalf("stored sharedPostId = %v, want %s (the id only)", v, p)
	}
	if got := w.storedCount(t, p); got != 1 {
		t.Fatalf("shareCount after the first share = %d, want 1", got)
	}

	// The replay answers the stored message and records nothing; the same key with another post is a reused key.
	replay, err := w.sendPost(a, b, "share-key-first-0001", url, p)
	if err != nil || !proto.Equal(replay.GetMessage(), first.GetMessage()) {
		t.Fatalf("replay = %v, %v; want the first message", replay.GetMessage(), err)
	}
	other := w.post(t, c, "another post")
	_, err = w.sendPost(a, b, "share-key-first-0001", url, other)
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "idempotency_key")
	// A message without a post keeps the pre-shares digest: it replays, and the same key with a post is a reused key.
	plainFirst, err := w.send(a, b, "share-key-plain-0001", "no post here")
	if err != nil {
		t.Fatalf("plain send: %v", err)
	}
	if again, err := w.send(a, b, "share-key-plain-0001", "no post here"); err != nil || !proto.Equal(again.GetMessage(), plainFirst.GetMessage()) {
		t.Fatalf("plain replay = %v, %v; want the first message", again.GetMessage(), err)
	}
	_, err = w.sendPost(a, b, "share-key-plain-0001", "no post here", p)
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "idempotency_key")

	// A second share by the same account, the author's own share, and an outside share by the recipient.
	if _, err := w.sendPost(a, b, contractKey("sh-again"), url, p); err != nil {
		t.Fatal(err)
	}
	if _, err := w.sendPost(c, b, contractKey("sh-own"), url, p); err != nil {
		t.Fatal(err)
	}
	if got := w.storedCount(t, p); got != 1 {
		t.Fatalf("shareCount after a repeat and the author's share = %d, want 1", got)
	}
	r, err := w.record(b, p)
	if err != nil || !r.GetCounted() || r.GetEngagement().GetShareCount() != 2 {
		t.Fatalf("RecordPostShare = %v, %v; want counted with share_count 2", r, err)
	}
	if r, err := w.record(b, p); err != nil || r.GetCounted() {
		t.Fatalf("repeat RecordPostShare = %v, %v; want not counted", r, err)
	}
	if r, err := w.record(c, p); err != nil || r.GetCounted() {
		t.Fatalf("the author's RecordPostShare = %v, %v; want not counted", r, err)
	}

	// Ten concurrent outside shares by one account count once.
	var wg sync.WaitGroup
	for range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := w.record(d, p); err != nil {
				t.Errorf("concurrent RecordPostShare: %v", err)
			}
		}()
	}
	wg.Wait()
	if got := w.storedCount(t, p); got != 3 {
		t.Fatalf("shareCount after 10 concurrent shares by one account = %d, want 3", got)
	}
	// GetPost shows the count through a cold chain.
	cold := newShareChain(t, flags.On)
	g, err := cold.posts.GetPost(ctx, authed(a.token, &postsv1.GetPostRequest{PostId: p}))
	if err != nil || g.Msg.GetPost().GetPost().GetShareCount() != 3 {
		t.Fatalf("GetPost share_count = %d, %v; want 3", g.Msg.GetPost().GetPost().GetShareCount(), err)
	}
	// The marker holds no channel, conversation or recipient.
	m, err := w.fs.Doc("postShares/" + p + "_" + a.uid).Get(ctx)
	if err != nil || len(m.Data()) != 3 {
		t.Fatalf("marker = %v, %v; want postId, uid and createdAt only", m.Data(), err)
	}
}

// The leak matrix of the card, per reader, each read through a cold chain: every reason the reader may not see the post
// gives the one unavailable form (post_id + unavailable only); the sender, who still may, sees the live card; a mute shows it.
func TestSharesChain_CardLeakMatrix(t *testing.T) {
	ctx := context.Background()
	w := newShareChain(t, flags.On)
	unavailable := func(id string) *postsv1.EmbeddedPost { return &postsv1.EmbeddedPost{PostId: id, Unavailable: true} }

	type world struct{ a, b, c dmUser }
	tests := []struct {
		name string
		// change makes the post unavailable to b (or not) after a shared it; it may create another post to share.
		setup        func(t *testing.T, x world) string
		change       func(t *testing.T, x world, postID string)
		wantB, wantA bool // the reader sees the live card
	}{
		{name: "deleted", change: func(t *testing.T, x world, id string) {
			if _, err := w.posts.DeletePost(ctx, authed(x.c.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("sh-del"), PostId: id})); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "taken down", change: func(t *testing.T, _ world, id string) { w.update(t, "posts/"+id, "moderation", "TAKEN_DOWN") }},
		{name: "author suspended", change: func(t *testing.T, x world, _ string) { w.update(t, "users/"+x.c.uid, "status", "SUSPENDED") }},
		{name: "author deleting", change: func(t *testing.T, x world, _ string) { w.update(t, "users/"+x.c.uid, "status", "DELETING") }},
		{name: "author blocks the reader", change: func(t *testing.T, x world, _ string) { w.graphOp(t, "block", x.c, x.b) }, wantA: true},
		{name: "reader blocks the author", change: func(t *testing.T, x world, _ string) { w.graphOp(t, "block", x.b, x.c) }, wantA: true},
		{name: "author turns protected", change: func(t *testing.T, x world, _ string) { w.protect(t, x.c) }},
		{name: "QUOTE whose embedded author blocks the reader", setup: func(t *testing.T, x world) string {
			e := w.user(t)
			orig := w.post(t, e, "quoted")
			q, err := w.posts.CreatePost(ctx, authed(x.c.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("sh-q"), Text: "quote", QuoteOfPostId: orig}))
			if err != nil {
				t.Fatal(err)
			}
			w.graphOp(t, "block", e, x.b)
			return q.Msg.GetPost().GetPost().GetPostId()
		}, change: func(*testing.T, world, string) {}, wantA: true},
		{name: "reader mutes the author (shown)", change: func(t *testing.T, x world, _ string) { w.graphOp(t, "mute", x.b, x.c) }, wantA: true, wantB: true},
		{name: "nothing changed", change: func(*testing.T, world, string) {}, wantA: true, wantB: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			x := world{a: w.user(t), b: w.user(t), c: w.user(t)}
			var id string
			if tt.setup != nil {
				id = tt.setup(t, x)
			} else {
				id = w.post(t, x.c, "shared in "+tt.name)
			}
			// The sender may see the post when it sends it (the QUOTE case blocks only b).
			if _, err := w.sendPost(x.a, x.b, contractKey("sh-leak"), "https://dzeroth.app/post/"+id, id); err != nil {
				t.Fatalf("share: %v", err)
			}
			tt.change(t, x, id)
			cold := newShareChain(t, flags.On)
			for _, rd := range []struct {
				name         string
				reader, peer dmUser
				want         bool
			}{{"recipient", x.b, x.a, tt.wantB}, {"sender", x.a, x.b, tt.wantA}} {
				got := cold.card(t, rd.reader, rd.peer)
				if rd.want {
					if got.GetUnavailable() || got.GetPostId() != id || got.GetAuthor() == nil {
						t.Errorf("%s: card = %v, want the live card of %s", rd.name, got, id)
					}
					continue
				}
				if !proto.Equal(got, unavailable(id)) {
					t.Errorf("%s: card = %v, want exactly the unavailable form", rd.name, got)
				}
			}
		})
	}
}

// The refusals of a send with a post: the GetPost bytes for a post the caller may not see, PROTECTED_ACCOUNT for a protected
// author's post sent by someone else (the author may send it, and a non-follower recipient sees it unavailable), the
// CANNOT_MESSAGE bytes of a block unchanged by the post, FEATURE_DISABLED dm_post_share for a caller without the flag, and
// the kill switch turning every card unavailable.
func TestSharesChain_Refusals(t *testing.T) {
	ctx := context.Background()
	w := newShareChain(t, flags.On)
	a, b, c := w.user(t), w.user(t), w.user(t)

	// Not visible: GetPost's NOT_FOUND bytes, nothing written.
	p := w.post(t, c, "soon taken down")
	w.update(t, "posts/"+p, "moderation", "TAKEN_DOWN")
	cold := newShareChain(t, flags.On)
	_, sendErr := cold.sendPost(a, b, contractKey("sh-nf"), "x", p)
	_, getErr := cold.posts.GetPost(ctx, authed(a.token, &postsv1.GetPostRequest{PostId: p}))
	if sendErr == nil || wireBytes(t, sendErr) != wireBytes(t, getErr) {
		t.Fatalf("send = %v, GetPost = %v; want the same bytes", sendErr, getErr)
	}
	if _, found := w.convDoc(t, a, b); found {
		t.Fatal("a refused share created the conversation")
	}

	// Protected author (owner decision Q1): a non-follower cannot see the post (GetPost's NOT_FOUND), an approved follower
	// who can see it gets PROTECTED_ACCOUNT with nothing written, and only the author may send it.
	prot, fol := w.user(t), w.user(t)
	pp := w.post(t, prot, "protected post")
	w.protect(t, prot)
	w.follow(t, fol, prot) // a follow request, the account is protected
	if _, err := w.graph.RespondToFollowRequest(ctx, authed(prot.token, &graphv1.RespondToFollowRequestRequest{
		IdempotencyKey: contractKey("sh-accept"), RequesterUserId: fol.uid, Accept: true,
	})); err != nil {
		t.Fatalf("approve: %v", err)
	}
	cold = newShareChain(t, flags.On)
	_, err := cold.sendPost(a, b, contractKey("sh-prot"), "x", pp)
	wantReason(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	_, err = cold.sendPost(fol, b, contractKey("sh-prot-fol"), "x", pp)
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, "", "")
	if _, found := w.convDoc(t, fol, b); found {
		t.Fatal("a refused protected share created the conversation")
	}
	if _, err := cold.sendPost(fol, prot, contractKey("sh-prot-plain"), "x", ""); err != nil {
		t.Fatalf("the approved follower can still message without the post: %v", err)
	}
	if _, err := cold.sendPost(prot, b, contractKey("sh-prot-own"), "x", pp); err != nil {
		t.Fatalf("the protected author's own share: %v", err)
	}
	if got := w.storedCount(t, pp); got != 0 {
		t.Fatalf("the author's own share counted: share_count = %d", got)
	}
	if got := cold.card(t, b, prot); !got.GetUnavailable() {
		t.Fatalf("a non-follower's card of a protected post = %v, want unavailable", got)
	}

	// A block: the same CANNOT_MESSAGE bytes with or without a post.
	q := w.post(t, c, "fine post")
	blocker, blocked := w.user(t), w.user(t)
	w.graphOp(t, "block", blocker, blocked)
	_, plain := w.send(blocked, blocker, contractKey("sh-blk-plain"), "hi")
	_, withPost := w.sendPost(blocked, blocker, contractKey("sh-blk-post"), "hi", q)
	if plain == nil || wireBytes(t, plain) != wireBytes(t, withPost) {
		t.Fatalf("plain = %v, with a post = %v; want the same CANNOT_MESSAGE bytes", plain, withPost)
	}

	// The kill switch: dm_post_share off refuses the send for the caller and turns every existing card unavailable.
	if _, err := w.sendPost(a, b, contractKey("sh-ok"), "x", q); err != nil {
		t.Fatal(err)
	}
	off := newShareChain(t, flags.Off)
	_, err = off.sendPost(a, b, contractKey("sh-off"), "x", q)
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "dm_post_share")
	if got := off.card(t, b, a); !proto.Equal(got, &postsv1.EmbeddedPost{PostId: q, Unavailable: true}) {
		t.Fatalf("card while globally off = %v, want unavailable", got)
	}
}

// Account erasure lowers Post.share_count (owner decision Q4): the deleted account's markers from a direct-message share
// and from an outside share are exported, then removed with their counts, another account's share survives, and the
// deleted account's message keeps no post id nor the inbox preview flag.
func TestSharesChain_ErasureLowersCount(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, sharesOn(flags.On))
	msg := messagingv1connect.NewMessagingServiceClient(http.DefaultClient, e.url)
	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, e.url)
	a, b, c, d := e.newUser(t), e.newUser(t), e.newUser(t), e.newUser(t) // a is deleted, c is the author

	mk := func(text string) string {
		t.Helper()
		r, err := e.posts.CreatePost(ctx, authed(c.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("shl-post"), Text: text}))
		if err != nil {
			t.Fatalf("CreatePost: %v", err)
		}
		return r.Msg.GetPost().GetPost().GetPostId()
	}
	record := func(u testUser, postID string) {
		t.Helper()
		if _, err := eng.RecordPostShare(ctx, authed(u.token, &engagementv1.RecordPostShareRequest{
			IdempotencyKey: contractKey("shl-rec"), PostId: postID, Channel: engagementv1.ShareChannel_SHARE_CHANNEL_SHARE_SHEET,
		})); err != nil {
			t.Fatalf("RecordPostShare: %v", err)
		}
	}
	count := func(postID string) int64 { return fsInt(t, e.fs, "posts/"+postID, "shareCount") }
	pDM, pOut := mk("sent in a message"), mk("shared outside")

	sent, err := msg.SendMessage(ctx, authed(a.token, &messagingv1.SendMessageRequest{
		IdempotencyKey: contractKey("shl-send"), Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: b.uid},
		Text: "https://dzeroth.app/post/" + pDM, SharedPostId: pDM,
	}))
	if err != nil {
		t.Fatalf("share in a message: %v", err)
	}
	record(a, pOut)
	record(d, pDM)
	if count(pDM) != 2 || count(pOut) != 1 {
		t.Fatalf("counts before = %d, %d; want 2, 1", count(pDM), count(pOut))
	}

	_, raw := e.exportOf(t, a, contractKey("shl-export"))
	var doc struct {
		Engagement struct {
			Shares []struct {
				PostID string `json:"postId"`
			} `json:"shares"`
		} `json:"engagement"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("export: %v", err)
	}
	exported := map[string]bool{}
	for _, s := range doc.Engagement.Shares {
		exported[s.PostID] = true
	}
	if len(doc.Engagement.Shares) != 2 || !exported[pDM] || !exported[pOut] {
		t.Fatalf("exported shares = %+v, want %s and %s", doc.Engagement.Shares, pDM, pOut)
	}

	e.pull(t)
	if _, err := e.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: contractKey("shl-delete")})); err != nil {
		t.Fatalf("DeleteAccount: %v", err)
	}
	if _, err := e.fs.Doc("users/"+a.uid).Update(ctx, []firestore.Update{{Path: "deletionRequestedAt", Value: time.Now().Add(-5 * time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	for round := 0; ; round++ {
		msgs := e.pull(t)
		if len(msgs) == 0 {
			break
		}
		if round > 10 {
			t.Fatal("the deletion job did not finish")
		}
		for _, m := range msgs {
			if code := e.deliver(t, m); code != http.StatusNoContent && code != http.StatusTooManyRequests {
				t.Fatalf("delivery = %d", code)
			}
		}
	}

	if fsDocExists(t, e.fs, "users/"+a.uid) {
		t.Fatal("users doc survived")
	}
	for _, path := range []string{"postShares/" + pDM + "_" + a.uid, "postShares/" + pOut + "_" + a.uid} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived", path)
		}
	}
	if !fsDocExists(t, e.fs, "postShares/"+pDM+"_"+d.uid) {
		t.Error("another account's share marker was removed")
	}
	if count(pDM) != 1 || count(pOut) != 0 {
		t.Errorf("counts after = %d, %d; want 1, 0", count(pDM), count(pOut))
	}
	convID := sent.Msg.GetMessage().GetConversationId()
	docs, err := e.fs.Collection("conversations").Doc(convID).Collection("messages").Limit(10).Documents(ctx).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range docs {
		if _, err := m.DataAt("sharedPostId"); err == nil {
			t.Errorf("message %s kept sharedPostId", m.Ref.ID[:8])
		}
	}
	if s, err := e.fs.Doc("users/" + b.uid + "/dmRequests/" + convID).Get(ctx); err == nil && s.Exists() {
		if v, _ := s.DataAt("last.sharedPost"); v == true {
			t.Error("the peer's preview still flags a shared post")
		}
	}
	if s, err := e.fs.Doc("users/" + b.uid + "/dmInbox/" + convID).Get(ctx); err == nil && s.Exists() {
		if v, _ := s.DataAt("last.sharedPost"); v == true {
			t.Error("the peer's preview still flags a shared post")
		}
	}
}
