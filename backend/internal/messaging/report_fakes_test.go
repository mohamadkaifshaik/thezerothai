package messaging

import "context"

// GetMessage answers like the Firestore read of one message: from the thread the test stored with putThread.
func (f *fakeRepo) GetMessage(_ context.Context, convID, msgID string) (MsgDoc, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, r := range f.msgs[convID] {
		if r.ID == msgID {
			return r.MsgDoc, true, nil
		}
	}
	return MsgDoc{}, false, nil
}
