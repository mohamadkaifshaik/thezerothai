package billing

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"sync"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Webhook work is coalesced on the existing private binding. No raw payload,
// aliases, store receipts or new user-owned collection is retained. Binding
// erasure atomically removes pending work and the bounded deduplication ring.
const webhookReceiptLimit = 64

type eventReceipt struct{ ID, BodyHash string }
type webhookDocument struct {
	verificationDocument
	Pending  bool           `firestore:"webhookPending"`
	Version  int64          `firestore:"webhookVersion"`
	Receipts []eventReceipt `firestore:"webhookReceipts"`
}

// WebhookProcessor acknowledges only durable acceptance plus a successful
// provider readback. Provider failures return a retryable error to RevenueCat;
// pending work survives request/process crashes and can also be swept by cron.
type WebhookProcessor struct {
	store          *FirestoreBindings
	reconciler     *Reconciler
	ReadOnly       bool
	recoveryMu     sync.Mutex
	recoveryCursor string
}

func NewWebhookProcessor(store *FirestoreBindings, reconciler *Reconciler) (*WebhookProcessor, error) {
	if store == nil || reconciler == nil {
		return nil, ErrInvalidInput
	}
	return &WebhookProcessor{store: store, reconciler: reconciler}, nil
}

func eventCustomers(e InboxEvent) []string {
	ids := append([]string{e.CustomerID}, e.TransferredFrom...)
	ids = append(ids, e.TransferredTo...)
	ids = append(ids, e.Aliases...)
	result := []string{}
	seen := map[string]bool{}
	for _, id := range ids {
		encoded := strings.TrimPrefix(id, "dzb_")
		decoded, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
		if strings.HasPrefix(id, "dzb_") && err == nil && len(decoded) == 32 && !seen[id] {
			result = append(result, id)
			seen[id] = true
		}
	}
	return result
}

func (p *WebhookProcessor) AcceptEvent(ctx context.Context, e InboxEvent) error {
	if p.ReadOnly {
		return ErrUnavailable
	}
	if e.ID == "" || len(e.ID) > 256 || len(e.BodyHash) != 64 || !validEnvironment(e.Environment) || len(e.TransferredFrom)+len(e.TransferredTo)+len(e.Aliases) > 64 {
		return ErrInvalidInput
	}
	// Stage every affected binding before readback. Transfers revoke the old
	// account through provider verification; they never allocate a new binding.
	uids := []string{}
	for _, customer := range eventCustomers(e) {
		uid, err := p.store.stageWebhook(ctx, e, customer)
		if err != nil {
			return err
		}
		if uid != "" {
			uids = append(uids, uid)
		}
	}
	for _, uid := range uids {
		if err := p.process(ctx, uid); err != nil {
			return err
		}
	}
	return nil
}

func (r *FirestoreBindings) stageWebhook(ctx context.Context, e InboxEvent, customer string) (string, error) {
	var uid string
	sum := sha256.Sum256([]byte(e.ID))
	id := hex.EncodeToString(sum[:])
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		uid = ""
		owner, err := tx.Get(r.client.Collection("billingCustomerOwners").Doc(bindingKey(e.Environment, customer)))
		if status.Code(err) == codes.NotFound {
			return nil
		}
		if err != nil {
			return err
		}
		value, err := owner.DataAt("uid")
		if err != nil {
			return ErrOwnership
		}
		candidate, ok := value.(string)
		if !ok || !validUID(candidate) {
			return ErrOwnership
		}
		d, err := r.readVerification(ctx, tx, candidate)
		if errors.Is(err, ErrOwnership) || errors.Is(err, ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		if d.Environment != e.Environment || d.CustomerID != customer {
			return ErrOwnership
		}
		ref := r.client.Collection("billingCustomers").Doc(candidate)
		snap, err := tx.Get(ref)
		if err != nil {
			return err
		}
		var work webhookDocument
		if snap.DataTo(&work) != nil {
			return ErrUnavailable
		}
		for _, rec := range work.Receipts {
			if rec.ID == id {
				if rec.BodyHash != e.BodyHash {
					return ErrInvalidInput
				}
				if work.Pending {
					uid = candidate
				}
				return nil
			}
		}
		if d.Generation < 0 || d.Generation == 1<<63-1 || work.Version < 0 || work.Version == 1<<63-1 {
			return ErrUnavailable
		}
		receipts := append(work.Receipts, eventReceipt{id, e.BodyHash})
		if len(receipts) > webhookReceiptLimit {
			receipts = receipts[len(receipts)-webhookReceiptLimit:]
		}
		uid = candidate
		// Fence in-flight verification and remove the old projection immediately.
		return tx.Update(ref, []firestore.Update{
			{Path: "verificationGeneration", Value: d.Generation + 1},
			{Path: "verifiedSnapshot", Value: firestore.Delete},
			{Path: "webhookPending", Value: true},
			{Path: "webhookVersion", Value: work.Version + 1},
			{Path: "webhookReceipts", Value: receipts},
		})
	})
	if err != nil {
		return "", ErrUnavailable
	}
	return uid, nil
}

func (p *WebhookProcessor) process(ctx context.Context, uid string) error {
	ref := p.store.client.Collection("billingCustomers").Doc(uid)
	snap, err := ref.Get(ctx)
	if status.Code(err) == codes.NotFound {
		return nil
	}
	if err != nil {
		return ErrUnavailable
	}
	var before webhookDocument
	if snap.DataTo(&before) != nil {
		return ErrUnavailable
	}
	if !before.Pending {
		return nil
	}
	if _, err = p.reconciler.Refresh(ctx, uid); err != nil {
		return err
	}
	err = p.store.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		_, err := p.store.readVerification(ctx, tx, uid)
		if err != nil {
			return err
		}
		snap, err := tx.Get(ref)
		if err != nil {
			return err
		}
		var current webhookDocument
		if snap.DataTo(&current) != nil {
			return ErrUnavailable
		}
		if current.Version != before.Version {
			return ErrUnavailable
		}
		return tx.Update(ref, []firestore.Update{{Path: "webhookPending", Value: false}})
	})
	if err != nil {
		return ErrUnavailable
	}
	return nil
}

// Refresh is the bounded recovery backstop. No composite index or TTL policy
// is needed: terminal receipts remain bounded on the binding itself.
func (p *WebhookProcessor) Refresh(ctx context.Context) error {
	if p.ReadOnly || !recoveryTimeAvailable(ctx) {
		return ErrUnavailable
	}
	// An overlapping recovery must not wait past its request deadline.
	if !p.recoveryMu.TryLock() {
		return ErrUnavailable
	}
	defer p.recoveryMu.Unlock()
	query := p.store.client.Collection("billingCustomers").Where("webhookPending", "==", true).OrderBy(firestore.DocumentID, firestore.Asc).Limit(50)
	if p.recoveryCursor != "" {
		query = query.StartAfter(p.store.client.Collection("billingCustomers").Doc(p.recoveryCursor))
	}
	docs, err := query.Documents(ctx).GetAll()
	if err != nil {
		return ErrUnavailable
	}
	if len(docs) == 0 {
		p.recoveryCursor = ""
		return nil
	}
	var failed bool
	for _, doc := range docs {
		if !recoveryTimeAvailable(ctx) {
			failed = true
			break
		}
		// Advance even on failure so a poison item cannot starve later work.
		p.recoveryCursor = doc.Ref.ID
		if p.process(ctx, doc.Ref.ID) != nil {
			failed = true
		}
	}
	if ctx.Err() == nil && len(docs) < 50 {
		p.recoveryCursor = ""
	}
	if failed {
		return ErrUnavailable
	}
	return nil
}

func recoveryTimeAvailable(ctx context.Context) bool {
	if ctx.Err() != nil {
		return false
	}
	deadline, bounded := ctx.Deadline()
	return !bounded || time.Until(deadline) >= RecoveryAttemptBudget
}
