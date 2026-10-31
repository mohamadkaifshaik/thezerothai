package lists

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// recordingService answers canned views and records what the handler passed it.
type recordingService struct {
	calls                    int
	gotUID                   string
	create                   CreateInput
	update                   UpdateInput
	delKey                   string
	delList                  string
	memKey, memList, memUser string
	getList                  string
	userLists                UserListsInput
	pageSize                 int32
	pageToken                string
}

func (s *recordingService) view() View {
	return View{
		Header:         Header{ID: testListID, Name: "Cricket", Description: "ODI", IsPrivate: true, MemberCount: 3},
		Owner:          identity.Profile{UserID: "owner-1", Handle: "owner", DisplayName: "Owner", AvatarThumbURL: "https://img/t.jpg", Verified: true, IsPrivate: true},
		PinnedByViewer: true,
	}
}

func (s *recordingService) CreateList(_ context.Context, uid string, in CreateInput) (View, error) {
	s.calls++
	s.gotUID, s.create = uid, in
	return s.view(), nil
}

func (s *recordingService) UpdateList(_ context.Context, uid string, in UpdateInput) (View, error) {
	s.calls++
	s.gotUID, s.update = uid, in
	return s.view(), nil
}

func (s *recordingService) AddMember(_ context.Context, uid, key, listID, userID string) (View, error) {
	s.calls++
	s.gotUID, s.memKey, s.memList, s.memUser = uid, key, listID, userID
	return s.view(), nil
}

func (s *recordingService) RemoveMember(_ context.Context, uid, key, listID, userID string) (View, error) {
	s.calls++
	s.gotUID, s.memKey, s.memList, s.memUser = uid, key, listID, userID
	return s.view(), nil
}

func (s *recordingService) DeleteList(_ context.Context, uid, key, listID string) error {
	s.calls++
	s.gotUID, s.delKey, s.delList = uid, key, listID
	return nil
}

func callerCtx(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid})
}

// With the flag on, the three write handlers hand the request fields to the service and render ListInfo from the view.
func TestServer_WritesCallTheService(t *testing.T) {
	t.Parallel()
	svc := &recordingService{}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
	ctx := callerCtx("owner-1")

	private := false
	cr, err := s.CreateList(ctx, connect.NewRequest(&listsv1.CreateListRequest{IdempotencyKey: testKey, Name: "Cricket", Description: "ODI", IsPrivate: &private}))
	if err != nil {
		t.Fatal(err)
	}
	if svc.gotUID != "owner-1" || svc.create.Key != testKey || svc.create.Name != "Cricket" || svc.create.Description != "ODI" || svc.create.IsPrivate == nil || *svc.create.IsPrivate {
		t.Errorf("create input = %+v uid %q", svc.create, svc.gotUID)
	}
	info := cr.Msg.GetList()
	if info.GetListId() != testListID || info.GetName() != "Cricket" || info.GetDescription() != "ODI" || !info.GetIsPrivate() || info.GetMemberCount() != 3 || !info.GetPinnedByViewer() {
		t.Errorf("list info = %v", info)
	}
	if o := info.GetOwner(); o.GetUserId() != "owner-1" || o.GetHandle() != "owner" || o.GetAvatarUrl() != "https://img/t.jpg" || !o.GetVerified() || !o.GetIsPrivate() {
		t.Errorf("owner = %v", o)
	}

	// is_private absent stays nil down to the service (the service applies the private default, F3).
	if _, err := s.CreateList(ctx, connect.NewRequest(&listsv1.CreateListRequest{IdempotencyKey: testKey, Name: "x"})); err != nil {
		t.Fatal(err)
	}
	if svc.create.IsPrivate != nil {
		t.Errorf("an absent is_private reached the service as %v", *svc.create.IsPrivate)
	}

	name := "Renamed"
	ur, err := s.UpdateList(ctx, connect.NewRequest(&listsv1.UpdateListRequest{IdempotencyKey: testKey, ListId: testListID, Name: &name}))
	if err != nil {
		t.Fatal(err)
	}
	if svc.update.ListID != testListID || svc.update.Name == nil || *svc.update.Name != "Renamed" || svc.update.Description != nil || svc.update.IsPrivate != nil {
		t.Errorf("update input = %+v: only the name was sent", svc.update)
	}
	if ur.Msg.GetList().GetListId() != testListID {
		t.Errorf("update response = %v", ur.Msg)
	}

	if _, err := s.DeleteList(ctx, connect.NewRequest(&listsv1.DeleteListRequest{IdempotencyKey: testKey, ListId: testListID})); err != nil {
		t.Fatal(err)
	}
	if svc.delKey != testKey || svc.delList != testListID {
		t.Errorf("delete = %q %q", svc.delKey, svc.delList)
	}
}

// The flag gate runs first: outside the flag the service is never called, in every mode, for every write handler.
func TestServer_WritesAreGatedBeforeTheService(t *testing.T) {
	t.Parallel()
	allow := map[string]struct{}{"in": {}}
	modes := []struct {
		name    string
		spec    flags.Spec
		uid     string
		wantOff bool
	}{
		{"off", flags.Spec{Name: FlagName, Mode: flags.Off, Allowlist: allow}, "in", true},
		{"allowlist, listed", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "in", false},
		{"allowlist, unlisted", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allow}, "out", true},
		{"percent 0", flags.Spec{Name: FlagName, Mode: flags.Percent}, "in", true},
		{"percent 100", flags.Spec{Name: FlagName, Mode: flags.Percent, Percent: 100}, "out", false},
		{"on", flags.Spec{Name: FlagName, Mode: flags.On}, "out", false},
	}
	rpcs := map[string]func(s *Server, ctx context.Context) error{
		"CreateList": func(s *Server, ctx context.Context) error {
			_, err := s.CreateList(ctx, connect.NewRequest(&listsv1.CreateListRequest{IdempotencyKey: testKey, Name: "x"}))
			return err
		},
		"UpdateList": func(s *Server, ctx context.Context) error {
			_, err := s.UpdateList(ctx, connect.NewRequest(&listsv1.UpdateListRequest{IdempotencyKey: testKey, ListId: testListID}))
			return err
		},
		"DeleteList": func(s *Server, ctx context.Context) error {
			_, err := s.DeleteList(ctx, connect.NewRequest(&listsv1.DeleteListRequest{IdempotencyKey: testKey, ListId: testListID}))
			return err
		},
		"AddListMember": func(s *Server, ctx context.Context) error {
			_, err := s.AddListMember(ctx, connect.NewRequest(&listsv1.AddListMemberRequest{IdempotencyKey: testKey, ListId: testListID, UserId: "u2"}))
			return err
		},
		"RemoveListMember": func(s *Server, ctx context.Context) error {
			_, err := s.RemoveListMember(ctx, connect.NewRequest(&listsv1.RemoveListMemberRequest{IdempotencyKey: testKey, ListId: testListID, UserId: "u2"}))
			return err
		},
		"GetList": func(s *Server, ctx context.Context) error {
			_, err := s.GetList(ctx, connect.NewRequest(&listsv1.GetListRequest{ListId: testListID}))
			return err
		},
		"ListUserLists": func(s *Server, ctx context.Context) error {
			_, err := s.ListUserLists(ctx, connect.NewRequest(&listsv1.ListUserListsRequest{}))
			return err
		},
		"ListListMembers": func(s *Server, ctx context.Context) error {
			_, err := s.ListListMembers(ctx, connect.NewRequest(&listsv1.ListListMembersRequest{ListId: testListID}))
			return err
		},
	}
	for rpc, call := range rpcs {
		for _, m := range modes {
			t.Run(rpc+"/"+m.name, func(t *testing.T) {
				t.Parallel()
				svc := &recordingService{}
				err := call(NewServer(flags.NewRegistry(m.spec), svc), callerCtx(m.uid))
				if m.wantOff {
					assertDisabled(t, err)
					if svc.calls != 0 {
						t.Errorf("the service was called %d times outside the flag", svc.calls)
					}
					return
				}
				if err != nil || svc.calls != 1 {
					t.Errorf("err = %v calls = %d, want success and one service call", err, svc.calls)
				}
			})
		}
	}
}

func (s *recordingService) GetList(_ context.Context, uid, listID string) (View, error) {
	s.calls++
	s.gotUID, s.getList = uid, listID
	return s.view(), nil
}

func (s *recordingService) ListUserLists(_ context.Context, uid string, in UserListsInput) (UserLists, error) {
	s.calls++
	s.gotUID, s.userLists = uid, in
	return UserLists{Lists: []View{s.view()}, ContainingIDs: []string{testListID}, NextPageToken: "next"}, nil
}

func (s *recordingService) ListListMembers(_ context.Context, uid, listID string, pageSize int32, token string) (MembersPage, error) {
	s.calls++
	s.gotUID, s.getList, s.pageSize, s.pageToken = uid, listID, pageSize, token
	return MembersPage{Items: []graph.ListItem{{
		User:         identity.Profile{UserID: "m1", Handle: "m1", DisplayName: "Em One", AvatarThumbURL: "https://img/m.jpg", IsPrivate: true},
		Relationship: graph.Relationship{UserID: "m1", FollowState: graph.FollowStateFollowing},
	}}, NextPageToken: "next"}, nil
}

// With the flag on, the three read handlers pass the request fields through and render the page.
func TestServer_ReadsCallTheService(t *testing.T) {
	t.Parallel()
	svc := &recordingService{}
	s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
	ctx := callerCtx("viewer-1")

	gr, err := s.GetList(ctx, connect.NewRequest(&listsv1.GetListRequest{ListId: testListID}))
	if err != nil || svc.getList != testListID || svc.gotUID != "viewer-1" || gr.Msg.GetList().GetListId() != testListID {
		t.Fatalf("GetList = %v, %v (list %q uid %q)", gr, err, svc.getList, svc.gotUID)
	}

	ur, err := s.ListUserLists(ctx, connect.NewRequest(&listsv1.ListUserListsRequest{OwnerId: "owner-1", ContainsUserId: "u2", PageSize: 7, PageToken: "t"}))
	if err != nil {
		t.Fatal(err)
	}
	if got := svc.userLists; got.OwnerID != "owner-1" || got.ContainsUserID != "u2" || got.PageSize != 7 || got.PageToken != "t" {
		t.Errorf("input = %+v", got)
	}
	if len(ur.Msg.GetLists()) != 1 || ur.Msg.GetContainingListIds()[0] != testListID || ur.Msg.GetNextPageToken() != "next" {
		t.Errorf("response = %v", ur.Msg)
	}

	mr, err := s.ListListMembers(ctx, connect.NewRequest(&listsv1.ListListMembersRequest{ListId: testListID, PageSize: 9, PageToken: "p"}))
	if err != nil {
		t.Fatal(err)
	}
	if svc.getList != testListID || svc.pageSize != 9 || svc.pageToken != "p" {
		t.Errorf("members input = %q %d %q", svc.getList, svc.pageSize, svc.pageToken)
	}
	u := mr.Msg.GetUsers()
	if len(u) != 1 || u[0].GetUser().GetUserId() != "m1" || !u[0].GetUser().GetIsPrivate() || u[0].GetRelationship().GetUserId() != "m1" || mr.Msg.GetNextPageToken() != "next" {
		t.Errorf("members response = %v", mr.Msg)
	}
}
