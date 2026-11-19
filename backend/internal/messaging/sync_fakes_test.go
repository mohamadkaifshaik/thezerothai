package messaging

import (
	"context"
	"slices"
	"strconv"
	"strings"
)

// The fake repo's sync reads, with the Firestore repo's semantics: document-id order, exclusive after-id, Limit.

func (f *fakeRepo) ListCommits(_ context.Context, q CommitsQuery) (CommitsPage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.syncCalls = append(f.syncCalls, "commits|"+q.ConvID)
	if f.syncErr != nil {
		return CommitsPage{}, f.syncErr
	}
	conv, ok := f.convs[q.ConvID]
	if !ok || peerOf(conv.Participants, q.UID) == "" {
		return CommitsPage{}, ErrNotFound
	}
	page := CommitsPage{Conv: conv}
	if !conv.encrypted() {
		return page, nil
	}
	prefix := q.ConvID + "/"
	var ids []string
	for k := range f.commits {
		if id, ok := strings.CutPrefix(k, prefix); ok && id > q.AfterID {
			ids = append(ids, id)
		}
	}
	slices.Sort(ids)
	for _, id := range ids {
		if len(page.Rows) == q.Limit {
			break
		}
		page.Rows = append(page.Rows, CommitRow{ID: id, CommitDoc: f.commits[prefix+id]})
	}
	return page, nil
}

func (f *fakeRepo) ListEpochMessages(_ context.Context, convID, key, afterID string, limit int) ([]MessageRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.syncCalls = append(f.syncCalls, "epoch|"+convID+"|"+key+"|"+afterID)
	if f.syncErr != nil {
		return nil, f.syncErr
	}
	var rows []MessageRow
	for _, r := range f.msgs[convID] {
		if r.MlsKey == key && r.ID > afterID {
			rows = append(rows, r)
		}
	}
	slices.SortFunc(rows, func(a, b MessageRow) int { return strings.Compare(a.ID, b.ID) })
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, nil
}

func (f *fakeRepo) ListWelcomes(_ context.Context, uid, deviceID string, limit int) ([]WelcomeRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.syncCalls = append(f.syncCalls, "welcomes|"+uid+"|"+deviceID)
	if f.syncErr != nil {
		return nil, f.syncErr
	}
	var rows []WelcomeRow
	for _, w := range f.welcomeRows[uid] {
		if w.DeviceID == deviceID {
			rows = append(rows, w)
		}
	}
	slices.SortFunc(rows, func(a, b WelcomeRow) int { return strings.Compare(a.ID, b.ID) })
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, nil
}

func (f *fakeRepo) AckWelcomes(_ context.Context, uid string, ids []string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.syncCalls = append(f.syncCalls, "ack|"+uid+"|"+strconv.Itoa(len(ids)))
	if f.syncErr != nil {
		return f.syncErr
	}
	f.welcomeRows[uid] = slices.DeleteFunc(f.welcomeRows[uid], func(w WelcomeRow) bool { return slices.Contains(ids, w.ID) })
	return nil
}
