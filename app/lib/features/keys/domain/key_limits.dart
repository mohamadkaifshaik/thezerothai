/// The key directory's numeric limits, in one file with no imports so the
/// service and its records share them without an import cycle.
library;

/// One-time key packages uploaded at first registration, and the level a
/// top-up restores.
const int kKeyPackagePoolTarget = 50;

/// A top-up runs when the server reports fewer than this many.
const int kKeyPackageTopUpBelow = 20;

/// The most one-time key packages the directory stores per device (the
/// backend's `keys.MaxPoolSize`).
const int kMaxKeyPackagePool = 100;

/// The largest key package (and last-resort package) the directory
/// accepts: the backend's `keys.MaxKeyPackageBytes`
/// (backend/internal/keys/model.go).
const int kMaxKeyPackageBytes = 4096;

/// The most key package batches generated per IST day (ruling E): until the
/// core prune exists (Open question 9), a server that keeps the outcome of
/// uploads unknown while the pool count moves must not grow the device
/// state without limit. An honest, flaky network rarely needs more than 4.
/// Cost: a pool that is truly drained can stay empty until the next IST day;
/// the last-resort package still answers claims. When the server reports
/// none (a re-registered device), a last-resort-only batch is still
/// generated and counted at the cap (ruling 1): otherwise the device would
/// be unreachable until IST midnight. A hostile server gains at most one
/// package per run that way (about 24 a day, runs are hourly).
const int kMaxKeyBatchesPerDay = 4;
