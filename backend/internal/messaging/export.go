package messaging

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// ExportSource is the storage side of the `messages` export section (FirestoreRepo in production).
type ExportSource interface {
	ExportConversations(ctx context.Context, uid string) ([]ExportConv, error)
	ExportMessages(ctx context.Context, uid, convID string, after *ExportMsg) ([]ExportMsg, error)
}

var _ ExportSource = (*FirestoreRepo)(nil)

// HandleSource looks up the current handles of the peers (identity.Directory satisfies it through Profiles).
type HandleSource interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error)
}

// peerLookupChunk bounds one directory call (ADR-0008 T6: at most 50 ids).
const peerLookupChunk = 50

// exportConversation is one element of the section's `conversations` list. It names the peer by handle at export time
// and never by uid, and it carries no conversation or message id (both derive from the uids).
type exportConversation struct {
	PeerHandle  string       `json:"peerHandle"`
	PeerDeleted bool         `json:"peerDeleted,omitempty"`
	State       string       `json:"state"`
	CreatedAt   time.Time    `json:"createdAt"`
	ClearedAt   *time.Time   `json:"clearedAt,omitempty"`
	Messages    []exportItem `json:"messages"`
}

// exportItem is one message: the user's own with its text (F5), a received one as its time and the word "received" only.
type exportItem struct {
	Direction string    `json:"direction"` // "sent" | "received"
	At        time.Time `json:"at"`
	State     string    `json:"state,omitempty"`
	Text      *string   `json:"text,omitempty"`
}

type exporter struct {
	src     ExportSource
	handles HandleSource
}

// NewExporter builds the `messages` export section (ADR-0027 D8, F5) on an ExportSource and a handle lookup.
func NewExporter(src ExportSource, handles HandleSource) Exporter {
	return &exporter{src: src, handles: handles}
}

// ExportUser implements Exporter: {"conversations":[...]} streamed to w, conversations newest first (by creation), each
// with its messages newest first. Own messages carry their full text; received ones only a time and "received" (F5, the
// peer's words are the peer's data); no peer uid appears. Reads: one per conversation, one per message of both sides
// (the section orders the two), at most 50 peers per directory call; about 620 for the reference account (20
// conversations, 300 own and 300 received messages). Memory: the conversation list and one page of 500 messages.
func (x *exporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	convs, err := x.src.ExportConversations(ctx, uid)
	if err != nil {
		return err
	}
	sort.SliceStable(convs, func(i, j int) bool {
		if !convs[i].CreatedAt.Equal(convs[j].CreatedAt) {
			return convs[i].CreatedAt.After(convs[j].CreatedAt)
		}
		return convs[i].ID > convs[j].ID
	})
	handles, err := x.peerHandles(ctx, convs)
	if err != nil {
		return err
	}
	if _, err := io.WriteString(w, `{"conversations":[`); err != nil {
		return fmt.Errorf("messaging: write messages export: %w", err)
	}
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false) // a file the user reads: & < > stay as typed
	for i, c := range convs {
		if i > 0 {
			if _, err := io.WriteString(w, ","); err != nil {
				return fmt.Errorf("messaging: write messages export: %w", err)
			}
		}
		if err := x.writeConversation(ctx, uid, enc, c, handles[c.PeerUID]); err != nil {
			return err
		}
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("messaging: write messages export: %w", err)
	}
	return nil
}

// writeConversation encodes one conversation. Its messages are collected one page at a time and written as a single
// object, so a conversation's memory is its own messages (at most the user's volume in one conversation).
func (x *exporter) writeConversation(ctx context.Context, uid string, enc *json.Encoder, c ExportConv, handle string) error {
	item := exportConversation{PeerHandle: handle, PeerDeleted: c.PeerGone, State: c.State, CreatedAt: c.CreatedAt, Messages: []exportItem{}}
	if !c.ClearedAt.IsZero() {
		cleared := c.ClearedAt
		item.ClearedAt = &cleared
	}
	var after *ExportMsg
	for {
		page, err := x.src.ExportMessages(ctx, uid, c.ID, after)
		if err != nil {
			return err
		}
		for _, m := range page {
			row := exportItem{Direction: "received", At: m.CreatedAt}
			if m.FromSelf {
				text := m.Text
				row = exportItem{Direction: "sent", At: m.CreatedAt, State: m.State, Text: &text}
			}
			item.Messages = append(item.Messages, row)
		}
		if len(page) < lifecyclePage {
			break
		}
		last := page[len(page)-1]
		after = &last
	}
	if err := enc.Encode(item); err != nil {
		return fmt.Errorf("messaging: write messages export: %w", err)
	}
	return nil
}

// peerHandles maps each live peer uid to its current handle in directory calls of at most 50. A deleted or suspended
// peer is absent (empty handle).
func (x *exporter) peerHandles(ctx context.Context, convs []ExportConv) (map[string]string, error) {
	seen := map[string]bool{}
	var uids []string
	for _, c := range convs {
		if c.PeerUID != "" && !c.PeerGone && !seen[c.PeerUID] {
			seen[c.PeerUID] = true
			uids = append(uids, c.PeerUID)
		}
	}
	out := make(map[string]string, len(uids))
	for start := 0; start < len(uids); start += peerLookupChunk {
		got, err := x.handles.GetProfiles(ctx, uids[start:min(start+peerLookupChunk, len(uids))])
		if err != nil {
			return nil, fmt.Errorf("messaging: export peer handles: %w", err)
		}
		for uid, p := range got {
			out[uid] = p.Handle
		}
	}
	return out, nil
}
