package messaging

import (
	"context"
	"slices"
	"strconv"
	"strings"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
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

// ListEpochMessagesByTime is the ordered epoch query: (createdAt, id) ascending, StartAfter a full position, StartAt a
// time-only one. It records "epochtime|conv|key|<after micros>|<after id>|limit".
func (f *fakeRepo) ListEpochMessagesByTime(_ context.Context, convID, key string, after cursor.Cursor, limit int) ([]MessageRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	pos := ""
	if !after.CreatedAt.IsZero() {
		pos = strconv.FormatInt(after.CreatedAt.UnixMicro(), 10)
	}
	f.syncCalls = append(f.syncCalls, "epochtime|"+convID+"|"+key+"|"+pos+"|"+after.DocID+"|"+strconv.Itoa(limit))
	if f.syncErr != nil {
		return nil, f.syncErr
	}
	if f.orderErr != nil {
		return nil, orderIndexErr(f.orderErr)
	}
	var rows []MessageRow
	for _, r := range f.msgs[convID] {
		if r.MlsKey != key {
			continue
		}
		c := r.CreatedAt.Compare(after.CreatedAt)
		switch {
		case after.DocID != "" && (c < 0 || (c == 0 && r.ID <= after.DocID)):
			continue
		case after.DocID == "" && !after.CreatedAt.IsZero() && c < 0:
			continue
		}
		rows = append(rows, r)
	}
	slices.SortFunc(rows, func(a, b MessageRow) int {
		if c := a.CreatedAt.Compare(b.CreatedAt); c != 0 {
			return c
		}
		return strings.Compare(a.ID, b.ID)
	})
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, nil
}

// ListTombstones runs the two per-state queries on the stored messages (id order, exclusive after-id, Limit each) and
// merges them with the repo's mergeTombstones. It records "tombstones|conv|after|limit".
func (f *fakeRepo) ListTombstones(_ context.Context, convID, afterID string, limit int) ([]TombstoneRow, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.syncCalls = append(f.syncCalls, "tombstones|"+convID+"|"+afterID+"|"+strconv.Itoa(limit))
	if f.syncErr != nil {
		return nil, false, f.syncErr
	}
	if f.tombOverride != nil {
		rows, more := f.tombOverride()
		return rows, more, nil
	}
	var lists [2][]TombstoneRow
	for i, st := range [2]string{msgRemoved, msgDeletedAccount} {
		for _, r := range f.msgs[convID] {
			if r.State == st && r.ID > afterID {
				lists[i] = append(lists[i], TombstoneRow{ID: r.ID, State: r.State})
			}
		}
		slices.SortFunc(lists[i], func(a, b TombstoneRow) int { return strings.Compare(a.ID, b.ID) })
		if len(lists[i]) > limit {
			lists[i] = lists[i][:limit]
		}
	}
	rows, more := mergeTombstones(lists[0], lists[1], limit)
	return rows, more, nil
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
