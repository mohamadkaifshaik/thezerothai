// Package publicid translates user ids between the internal form (Firebase uids, which every module keeps) and the
// wire form (public ids, FEATURE_PUBLIC_IDS) in Connect request and response messages. It reads the
// dzeroth.common.v1.user_ref field option through pkg/platform/userref once, at plan construction, and never on the hot
// path.
//
// Four parts:
//   - Plans (BuildPlans): for every method of every dzeroth service, a flat list of steps for the input and the output
//     message type, memoised by full name and safe for recursive types. A type with no user reference in its
//     transitive closure has a nil plan. Construction fails closed on anything the walker cannot translate safely.
//   - Rules: the registry of per-field rules for USER_REF_KIND_CONDITIONAL fields.
//   - Translator: the walker. TranslateRequest (wire -> internal) and TranslateResponse (internal -> wire) each make at
//     most one batched resolver call per chunk of distinct ids and mutate the message in place.
//   - NewInterceptor: the Connect unary interceptor that runs the Translator for a caller with FEATURE_PUBLIC_IDS on,
//     innermost in the chain (after mw.ErrorMapping); NegativeCache, the bounded "uid has no public id" Resolver
//     decorator in front of identity.
//
// internal/apiserver (public_ids_wiring.go) builds the plans from protoregistry.GlobalFiles at startup (a bad
// annotation refuses to start the process) and installs the interceptor. This package must not import
// backend/internal/*; the identity lookups, the id validator and the per-caller flag check are injected.
package publicid

import "context"

// Tombstone is the wire id of an account that has no public id (an erased author in a frozen snapshot, or an account
// not yet backfilled). Outbound it replaces such a uid in every translated field, so a row is never dropped and never
// carries "" (which several requests read as "the caller"). It can never be minted: a real public id encodes 128 bits
// in 26 base32 characters, so its first body character is always 0-7, and "z" is 31. The validator therefore rejects
// it; inbound the walker recognises it before validation and passes it to the handler unchanged, exactly like a
// well-formed public id that resolves to nobody.
const Tombstone = "uzzzzzzzzzzzzzzzzzzzzzzzzzz"

// Resolver is the batch lookup the walker needs (identity.PublicIDs implements it). Both methods answer only the ids
// they know: a missing key means "no such pair", not an error. The walker never sends more than the Translator's
// batch size in one call.
type Resolver interface {
	PublicIDsForUIDs(ctx context.Context, uids []string) (map[string]string, error)
	UIDsForPublicIDs(ctx context.Context, publicIDs []string) (map[string]string, error)
}

// Learner is an optional Resolver extension: the walker reports the uid -> public id pairs it learned outside the
// resolver (a handler that set the PUBLIC_ID field itself), so a cache in front of identity can drop what it believed
// about those uids. pairs must not be retained or modified.
type Learner interface {
	LearnPublicIDs(pairs map[string]string)
}
