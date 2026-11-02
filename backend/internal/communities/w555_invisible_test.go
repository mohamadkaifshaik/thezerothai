package communities

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

// W5-55: the community description and rule text use identity.BioText, which refuses Cf and filler characters. Titles use the
// single-line rule (W5-45) and already did.
func TestW555_InvisibleCharactersRefused(t *testing.T) {
	vectors := map[string]string{
		"zero width space": "a\u200bb", "word joiner": "a\u2060b", "interior BOM": "a\ufeffb",
		"Hangul filler": "a\u3164b", "ZWJ at the end": "a\u200d", "lone tag": "a\U000E0067b",
	}
	for name, v := range vectors {
		t.Run("description/"+name, func(t *testing.T) {
			f := newFixture(ownerUID)
			_, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{Key: goodKey, Name: "Go", Description: v})
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "description"})
			if len(f.repo.creates) != 0 {
				t.Error("repo reached")
			}
		})
		t.Run("rule text/"+name, func(t *testing.T) {
			f := newFixture(ownerUID)
			_, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{Key: goodKey, Name: "Go", Rules: []Rule{{Title: "t", Text: v}}})
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "rules"})
		})
		t.Run("update description/"+name, func(t *testing.T) {
			f := newFixture(ownerUID)
			d := v
			_, err := f.svc.UpdateCommunity(context.Background(), ownerUID, UpdateInput{Key: goodKey, CommunityID: testCID, Description: &d})
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "description"})
		})
		t.Run("update rules/"+name, func(t *testing.T) {
			f := newFixture(ownerUID)
			_, err := f.svc.UpdateCommunity(context.Background(), ownerUID, UpdateInput{Key: goodKey, CommunityID: testCID, Rules: &[]Rule{{Title: "t", Text: v}}})
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "rules"})
		})
	}
}

func TestW555_SequencesAndMultilineAccepted(t *testing.T) {
	f := newFixture(ownerUID)
	text := "\U0001F468\u200d\U0001F469\u200d\U0001F467 \u0915\u094d\u200d\u0937\nline two"
	v, err := f.svc.CreateCommunity(context.Background(), ownerUID, CreateInput{Key: goodKey, Name: "Go", Description: text, Rules: []Rule{{Title: "t", Text: text}}})
	if err != nil {
		t.Fatal(err)
	}
	if v.Community.Description != text || v.Community.Rules[0].Text != text {
		t.Error("accepted text was altered")
	}
}

// W5-55: stored text the new rule would refuse is returned unchanged by a read (the rule runs on write only).
func TestW555_StoredInvisibleTextReadsUnchanged(t *testing.T) {
	f := newFixture(ownerUID)
	old := "a\u200bb"
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID, Description: old, Rules: []Rule{{Title: "t", Text: old}}, MemberCount: 1, CreatedAt: testNow})
	d, err := f.svc.GetCommunity(context.Background(), memberUID, testCID)
	if err != nil {
		t.Fatal(err)
	}
	if d.View.Community.Description != old || d.View.Community.Rules[0].Text != old {
		t.Errorf("read rewrote stored text: %q %q", d.View.Community.Description, d.View.Community.Rules[0].Text)
	}
	if len(f.repo.updates) != 0 {
		t.Error("a read wrote")
	}
}
