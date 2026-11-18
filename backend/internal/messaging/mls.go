package messaging

import (
	"crypto/sha256"
	"encoding/hex"
	"math"
	"strconv"
	"time"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// Limits of the encrypted-message contract. The server checks sizes and shapes only; it never parses MLS bytes.
const (
	MaxCiphertextBytes  = 8192
	CommitmentBytes     = 32
	MaxCommitBytes      = 16384
	MaxWelcomeBytes     = 65536
	MaxWelcomeDevices   = 10
	CiphertextRetention = 30 * 24 * time.Hour
)

// encSend is a validated encrypted SendMessage request.
type encSend struct {
	Ciphertext, Commitment []byte
	Gen, Epoch             int64
	Init                   *mlsInit
}

// mlsInit is the validated group creation that starts encryption.
type mlsInit struct {
	Commit, Welcome []byte
	DeviceIDs       []string
}

// validateEncrypted validates the encrypted shape of a SendMessage request. A request carrying none of ciphertext,
// report_commitment, mls_generation, mls_epoch or mls_init is plaintext: it returns nil, nil and is left to the plaintext
// path. Errors are VALIDATION carrying the proto field name.
func validateEncrypted(req *messagingv1.SendMessageRequest) (*encSend, error) {
	if len(req.GetCiphertext()) == 0 && len(req.GetReportCommitment()) == 0 && req.GetMlsGeneration() == 0 &&
		req.GetMlsEpoch() == 0 && req.GetMlsInit() == nil {
		return nil, nil
	}
	if req.GetText() != "" {
		return nil, apierr.Validation("text", "text must be empty for an encrypted message")
	}
	if req.GetSharedPostId() != "" {
		return nil, apierr.Validation("shared_post_id", "shared_post_id must be empty for an encrypted message")
	}
	if n := len(req.GetCiphertext()); n < 1 || n > MaxCiphertextBytes {
		return nil, apierr.Validation("ciphertext", "ciphertext must be 1-"+strconv.Itoa(MaxCiphertextBytes)+" bytes")
	}
	if len(req.GetReportCommitment()) != CommitmentBytes {
		return nil, apierr.Validation("report_commitment", "report_commitment must be exactly "+strconv.Itoa(CommitmentBytes)+" bytes")
	}
	init := req.GetMlsInit()
	gen, epoch := req.GetMlsGeneration(), req.GetMlsEpoch()
	if gen < 1 || gen > math.MaxInt64 || (init != nil && gen != 1) {
		return nil, apierr.Validation("mls_generation", "mls_generation is not valid for this request")
	}
	if epoch < 1 || epoch > math.MaxInt64 || (init != nil && epoch != 1) {
		return nil, apierr.Validation("mls_epoch", "mls_epoch is not valid for this request")
	}
	out := &encSend{Ciphertext: req.GetCiphertext(), Commitment: req.GetReportCommitment(), Gen: int64(gen), Epoch: int64(epoch)}
	if init == nil {
		return out, nil
	}
	if n := len(init.GetCommit()); n < 1 || n > MaxCommitBytes {
		return nil, apierr.Validation("commit", "commit must be 1-"+strconv.Itoa(MaxCommitBytes)+" bytes")
	}
	if len(init.GetWelcome()) == 0 {
		return nil, apierr.Validation("welcome", "welcome is required to start encryption")
	}
	if len(init.GetWelcomeDeviceIds()) == 0 {
		return nil, apierr.Validation("welcome_device_ids", "welcome_device_ids is required to start encryption")
	}
	if err := validateWelcome(init.GetWelcome(), init.GetWelcomeDeviceIds()); err != nil {
		return nil, err
	}
	out.Init = &mlsInit{Commit: init.GetCommit(), Welcome: init.GetWelcome(), DeviceIDs: init.GetWelcomeDeviceIds()}
	return out, nil
}

// validateWelcome checks a welcome and the device ids it is stored for: both empty is valid (a commit that adds nobody);
// one without the other, more than MaxWelcomeDevices ids, a duplicate or a malformed id is VALIDATION welcome_device_ids;
// a welcome over MaxWelcomeBytes is VALIDATION welcome.
func validateWelcome(welcome []byte, deviceIDs []string) error {
	if len(welcome) == 0 && len(deviceIDs) == 0 {
		return nil
	}
	if len(welcome) > MaxWelcomeBytes {
		return apierr.Validation("welcome", "welcome must be at most "+strconv.Itoa(MaxWelcomeBytes)+" bytes")
	}
	if len(welcome) == 0 || len(deviceIDs) == 0 || len(deviceIDs) > MaxWelcomeDevices {
		return apierr.Validation("welcome_device_ids", "welcome and welcome_device_ids go together: 1-"+strconv.Itoa(MaxWelcomeDevices)+" device ids")
	}
	seen := make(map[string]struct{}, len(deviceIDs))
	for _, id := range deviceIDs {
		if _, dup := seen[id]; dup || !keys.ValidDeviceID(id) {
			return apierr.Validation("welcome_device_ids", "welcome_device_ids must be distinct, valid device ids")
		}
		seen[id] = struct{}{}
	}
	return nil
}

// encRequestHash is the request hash of an encrypted send (the encrypted counterpart of requestHash, same digest32): it
// binds the conversation, the (generation, epoch) and the SHA-256 of the ciphertext. Every part has a fixed shape (hex id,
// decimal numbers, hex digest) and is "|"-separated, so no two inputs share an encoding. A retry must resend identical
// bytes; different bytes under the same key read as a reused key.
func encRequestHash(convID string, gen, epoch int64, ciphertext []byte) string {
	sum := sha256.Sum256(ciphertext)
	return digest32("send-enc|" + convID + "|" + strconv.FormatInt(gen, 10) + "|" + strconv.FormatInt(epoch, 10) + "|" + hex.EncodeToString(sum[:]))
}
