package communities

import (
	"context"
	"sort"
)

// listingState is the fakeRepo's directory and member-page data (guarded by fakeRepo.mu).
type listingState struct {
	rank       []Community            // ListByMemberCount answers these, in this order
	pages      map[string][]MemberRow // cid|filter -> rows, newest first
	dirCalls   int
	memberQs   []MembersQuery
	dirErr     error
	membersErr error
}

func pageKey(cid string, banned bool) string {
	if banned {
		return cid + "|banned"
	}
	return cid + "|joined"
}

func (r *fakeRepo) ListByMemberCount(ctx context.Context, limit int) ([]Community, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lst.dirCalls++
	if r.lst.dirErr != nil {
		return nil, r.lst.dirErr
	}
	out := append([]Community(nil), r.lst.rank...)
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (r *fakeRepo) ListMembers(ctx context.Context, q MembersQuery) ([]MemberRow, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lst.memberQs = append(r.lst.memberQs, q)
	if r.lst.membersErr != nil {
		return nil, r.lst.membersErr
	}
	rows := append([]MemberRow(nil), r.lst.pages[pageKey(q.CommunityID, q.Banned)]...)
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].At.After(rows[j].At) })
	if q.After != nil {
		for i, row := range rows {
			if row.UID == q.After.DocID {
				rows = rows[i+1:]
				break
			}
		}
	}
	if len(rows) > q.Limit {
		rows = rows[:q.Limit]
	}
	return rows, nil
}

func (s *fakeService) ListCommunities(_ context.Context, uid, token string) ([]View, error) {
	s.dirCalls++
	s.gotUser = uid
	_ = token
	return s.dirViews, s.err
}

func (s *fakeService) ListCommunityMembers(_ context.Context, uid string, in MembersInput) (MembersPage, error) {
	s.membersIn, s.gotUser = append(s.membersIn, in), uid
	return s.members, s.err
}
