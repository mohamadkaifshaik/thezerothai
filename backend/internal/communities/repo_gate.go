package communities

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// MemberInTx reads the member doc inside the caller's transaction: never cached, so a
// ban made on another instance a second ago is seen. A missing doc (or one with another state) is MemberNone with a nil error: the
// NotFound of tx.Get must never leave this method, because CreatePost reads a NotFound from its own transaction as a vanished parent.
// It implements TxMemberReader for PostGate.
func (r *FirestoreRepo) MemberInTx(ctx context.Context, tx *firestore.Transaction, communityID, uid string) (MemberState, error) {
	if r == nil || r.client == nil {
		return MemberNone, errors.New("communities: repo has no firestore client")
	}
	snap, err := tx.Get(r.memberRef(communityID, uid))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return MemberNone, nil
		}
		return MemberNone, logger.RedactErr(fmt.Errorf("communities: get member in tx: %w", err), communityID, uid)
	}
	var d memberDoc
	if err := snap.DataTo(&d); err != nil {
		return MemberNone, logger.RedactErr(fmt.Errorf("communities: decode member: %w", err), communityID, uid)
	}
	switch MemberState(d.State) {
	case MemberJoined, MemberBanned:
		return MemberState(d.State), nil
	}
	return MemberNone, nil
}
