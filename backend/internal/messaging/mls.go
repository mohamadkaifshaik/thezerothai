package messaging

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math"
	"slices"
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
	// CommitRetention and WelcomeRetention set expireAt on commit and welcome documents (creation + 30 days; global
	// constraints, "Retention"): the TTL field of a policy the owner applies.
	CommitRetention  = 30 * 24 * time.Hour
	WelcomeRetention = 30 * 24 * time.Hour
)

// encSend is a validated encrypted SendMessage request.
type encSend struct {
	Ciphertext, Commitment []byte
	Gen, Epoch             int64
	Init                   *mlsInit
}

// mlsInit is the validated group creation that starts encryption. DeviceIDs is the request's format-checked list; the
// service fills Targets and DevicesOK from the key directory before the transaction (checkWelcomeDevices), and the
// transaction applies the verdict only after every existing refusal (encGate).
type mlsInit struct {
	Commit, Welcome []byte
	DeviceIDs       []string
	// Targets is, per DeviceIDs entry and in the same order, the user whose welcome inbox the device belongs to; set only
	// when DevicesOK.
	Targets []welcomeTarget
	// DevicesOK: every id is an ACTIVE device of the caller or the recipient and at least one is the recipient's.
	DevicesOK bool
}

// welcomeTarget is one device a welcome is stored for, with the user who owns it (users/{Owner}/dmWelcomes).
type welcomeTarget struct {
	Owner, DeviceID string
}

// errWelcomeDevices is the welcome-device verdict "no" (VALIDATION welcome_device_ids, without saying which id).
var errWelcomeDevices = errors.New("messaging: welcome devices are not active devices of the participants")

// welcomeTargets decides the welcome-device rule of an mls_init from the ACTIVE device ids of the caller and the
// recipient: every id must be one of them and at least one the recipient's; ok is false otherwise (and targets nil). An
// id both users registered (device ids are client-chosen) is taken as the recipient's, so the rule "at least one of the
// recipient's" cannot be met by a device of the caller alone and the welcome is stored once.
func welcomeTargets(ids []string, caller, recipient string, callerActive, recipientActive []string) (targets []welcomeTarget, ok bool) {
	targets = make([]welcomeTarget, 0, len(ids))
	peerHas := false
	for _, id := range ids {
		switch {
		case slices.Contains(recipientActive, id):
			targets, peerHas = append(targets, welcomeTarget{Owner: recipient, DeviceID: id}), true
		case slices.Contains(callerActive, id):
			targets = append(targets, welcomeTarget{Owner: caller, DeviceID: id})
		default:
			return nil, false
		}
	}
	if !peerHas {
		return nil, false
	}
	return targets, true
}

// initDigest is the tagged extra part of encRequestHash for an mls_init: "i|" and the hex SHA-256 of the length-prefixed
// commit, welcome and sorted device ids, so a retry with another commit, welcome or device set is not the same request,
// while the same set in another order is.
func initDigest(in *mlsInit) string {
	ids := slices.Clone(in.DeviceIDs)
	slices.Sort(ids)
	parts := append([]string{"init1", string(in.Commit), string(in.Welcome)}, ids...)
	sum := sha256.Sum256([]byte(lengthPrefixed(parts...)))
	return "i|" + hex.EncodeToString(sum[:])
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
	in := req.GetMlsInit()
	gen, epoch := req.GetMlsGeneration(), req.GetMlsEpoch()
	if gen < 1 || gen > math.MaxInt64 || (in != nil && gen != 1) {
		return nil, apierr.Validation("mls_generation", "mls_generation is not valid for this request")
	}
	if epoch < 1 || epoch > math.MaxInt64 || (in != nil && epoch != 1) {
		return nil, apierr.Validation("mls_epoch", "mls_epoch is not valid for this request")
	}
	out := &encSend{Ciphertext: req.GetCiphertext(), Commitment: req.GetReportCommitment(), Gen: int64(gen), Epoch: int64(epoch)}
	if in == nil {
		return out, nil
	}
	if n := len(in.GetCommit()); n < 1 || n > MaxCommitBytes {
		return nil, apierr.Validation("commit", "commit must be 1-"+strconv.Itoa(MaxCommitBytes)+" bytes")
	}
	if len(in.GetWelcome()) == 0 {
		return nil, apierr.Validation("welcome", "welcome is required to start encryption")
	}
	if len(in.GetWelcomeDeviceIds()) == 0 {
		return nil, apierr.Validation("welcome_device_ids", "welcome_device_ids is required to start encryption")
	}
	if err := validateWelcome(in.GetWelcome(), in.GetWelcomeDeviceIds()); err != nil {
		return nil, err
	}
	out.Init = &mlsInit{Commit: in.GetCommit(), Welcome: in.GetWelcome(), DeviceIDs: in.GetWelcomeDeviceIds()}
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
// binds the conversation, the (generation, epoch), the SHA-256 of the ciphertext and the report commitment (hex), so a
// retry with the same ciphertext but another commitment is not the same request. extra appends further parts for a
// request that carries more (mls_init: initDigest); each must have a fixed shape of its own and start with a tag ("i|" and a
// hex digest, say), so a request without extra parts keeps this exact hash. Every part has a fixed shape (hex id, decimal
// numbers, hex digests) and is "|"-separated, so no two inputs share an encoding. A retry must resend identical bytes;
// different bytes under the same key read as a reused key.
func encRequestHash(convID string, gen, epoch int64, ciphertext, commitment []byte, extra ...string) string {
	sum := sha256.Sum256(ciphertext)
	s := "send-enc|" + convID + "|" + strconv.FormatInt(gen, 10) + "|" + strconv.FormatInt(epoch, 10) + "|" + hex.EncodeToString(sum[:]) +
		"|" + hex.EncodeToString(commitment)
	for _, part := range extra {
		s += "|" + part
	}
	return digest32(s)
}

// encGate is the encryption rule of a send, applied by the send transaction to the conversation it read (nil: none yet),
// after every existing refusal and before any write: a plaintext request (enc nil) into an MLS conversation is
// ErrEncryptionRequired; an encrypted request into a plaintext or new conversation is errNeedsInit (VALIDATION
// ciphertext: encryption starts only with mls_init); an encrypted request whose pair is not the conversation's current
// pair is a *staleEpochError carrying the current pair. A request carrying mls_init is answered by its own rule, in the
// proto's order: the welcome-device verdict first (errWelcomeDevices), then an already MLS conversation (another device
// started first) is a *staleEpochError with its pair, whatever pair the request states (an init always states (1, 1),
// which may equal the current pair); a NONE or new conversation passes.
func encGate(conv *ConvDoc, enc *encSend) error {
	encrypted := conv != nil && conv.encrypted()
	switch {
	case enc == nil && encrypted:
		return ErrEncryptionRequired
	case enc == nil:
		return nil
	case enc.Init != nil && !enc.Init.DevicesOK:
		return errWelcomeDevices
	case enc.Init != nil && encrypted:
		return &staleEpochError{Gen: conv.MlsGen, Epoch: conv.MlsEpoch}
	case enc.Init != nil:
		return nil
	case !encrypted:
		return errNeedsInit
	case enc.Gen != conv.MlsGen || enc.Epoch != conv.MlsEpoch:
		return &staleEpochError{Gen: conv.MlsGen, Epoch: conv.MlsEpoch}
	}
	return nil
}

// wirePair is a stored generation or epoch as the uint64 the wire carries (stored values are >= 1; anything else is 0).
func wirePair(v int64) uint64 {
	if v < 1 {
		return 0
	}
	return uint64(v)
}
