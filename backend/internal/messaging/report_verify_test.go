package messaging

import (
	"bytes"
	"context"
	"crypto/sha256"
	"testing"
)

// The prefix is the contract's 12 ASCII bytes, written out here (not the constant) so a change to it fails.
func TestReportCommitment_IsSHA256OfThePrefixAndTheRawBytes(t *testing.T) {
	t.Parallel()
	if len(ReportCommitmentPrefix) != 12 {
		t.Fatalf("prefix is %d bytes, the contract says 12", len(ReportCommitmentPrefix))
	}
	for _, p := range [][]byte{nil, {}, []byte("\x0a\x05hello"), bytes.Repeat([]byte{0xff}, MaxCiphertextBytes)} {
		want := sha256.Sum256(append([]byte("dz-report-v1"), p...))
		if got := ReportCommitment(p); got != want {
			t.Errorf("ReportCommitment(%d bytes) = %x, want %x", len(p), got, want)
		}
	}
}

func TestVerifyReportPayload(t *testing.T) {
	t.Parallel()
	payload := []byte("\x0a\x05hello\x1a\x20" + string(bytes.Repeat([]byte{7}, 32)))
	sum := ReportCommitment(payload)
	changed := bytes.Clone(payload)
	changed[len(changed)-1] ^= 1
	tests := []struct {
		name    string
		m       ReportedMessage
		payload []byte
		want    bool
	}{
		{"exact bytes", ReportedMessage{Encrypted: true, Commitment: sum[:]}, payload, true},
		{"one byte changed", ReportedMessage{Encrypted: true, Commitment: sum[:]}, changed, false},
		{"one byte appended", ReportedMessage{Encrypted: true, Commitment: sum[:]}, append(bytes.Clone(payload), 0), false},
		{"no commitment (swept)", ReportedMessage{Encrypted: true}, payload, false},
		{"short commitment", ReportedMessage{Encrypted: true, Commitment: sum[:31]}, payload, false},
		{"empty payload", ReportedMessage{Encrypted: true, Commitment: sum[:]}, nil, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := VerifyReportPayload(tt.m, tt.payload); got != tt.want {
				t.Errorf("VerifyReportPayload = %v, want %v", got, tt.want)
			}
		})
	}
}

// An encrypted message is reportable like a plaintext one; it carries no text, and its commitment only while
// setEncrypted would show it (VISIBLE, not swept, ciphertext present). A tombstone stays the one ErrNotFound whatever
// bytes are still stored.
func TestReportableMessage_Encrypted(t *testing.T) {
	t.Parallel()
	commit := bytes.Repeat([]byte{9}, CommitmentBytes)
	enc := func(rows []MessageRow) {
		rows[1].Text, rows[1].MlsGen, rows[1].MlsEpoch, rows[1].Ciphertext, rows[1].Commitment = "", 1, 1, []byte("ct"), commit
	}
	tests := []struct {
		name       string
		mutate     func(rows []MessageRow)
		wantErr    error
		wantCommit []byte
	}{
		{name: "visible with its commitment", mutate: enc, wantCommit: commit},
		{name: "swept (ctRemoved)", mutate: func(rows []MessageRow) {
			enc(rows)
			rows[1].CtRemoved = true // bytes left behind on purpose: the flag decides
		}},
		{name: "ciphertext gone", mutate: func(rows []MessageRow) {
			enc(rows)
			rows[1].Ciphertext = nil
		}},
		{name: "taken down, bytes still stored", wantErr: ErrNotFound, mutate: func(rows []MessageRow) {
			enc(rows)
			rows[1].State = msgRemoved
		}},
		{name: "sender deleted the account, bytes still stored", wantErr: ErrNotFound, mutate: func(rows []MessageRow) {
			enc(rows)
			rows[1].State, rows[1].SenderID = msgDeletedAccount, DeletedUID
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			rg := newRig(t, nil)
			rows := rg.putThread(3, nil)
			tt.mutate(rows)
			rg.repo.msgs[aliceBobConv] = rows
			svc, _ := rg.reporter()
			got, err := svc.ReportableMessage(context.Background(), alice, aliceBobConv, msgID(1))
			if tt.wantErr != nil {
				if err != tt.wantErr { //nolint:errorlint // the sentinel itself is the contract
					t.Fatalf("err = %v, want exactly %v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !got.Encrypted || got.Text != "" || got.SenderUID != bob || !bytes.Equal(got.Commitment, tt.wantCommit) {
				t.Errorf("got %+v, want encrypted, no text, commitment %x", got, tt.wantCommit)
			}
			if tt.wantCommit == nil && got.Commitment != nil {
				t.Errorf("commitment = %x, want nil", got.Commitment)
			}
		})
	}
	// A plaintext message is not Encrypted and has no commitment.
	rg := newRig(t, nil)
	rg.putThread(3, nil)
	svc, _ := rg.reporter()
	got, err := svc.ReportableMessage(context.Background(), alice, aliceBobConv, msgID(1))
	if err != nil || got.Encrypted || got.Commitment != nil || got.Text != "secret text 1" {
		t.Errorf("plaintext: got %+v, %v", got, err)
	}
}
