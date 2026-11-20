//! The one error type every public function returns.
//!
//! Messages carry codes and sizes only: never key material, state, plaintext or wire bytes.

use std::fmt;

/// Stable machine-readable error codes, shared with the Dart side through [`ErrorCode::as_str`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    /// The caller passed an argument outside the documented limits or of the wrong shape.
    BadInput,
    /// A state blob could not be decoded, or its contents are inconsistent (including a group blob passed with
    /// the device blob of another device).
    CorruptState,
    /// A message belongs to an epoch this state cannot process.
    WrongEpoch,
    /// This device is no longer a member of the group.
    Evicted,
    /// A commit is already waiting for the server's decision.
    PendingCommit,
    /// Confirm or discard was called with no commit waiting.
    NoPendingCommit,
    /// The message was already processed.
    Duplicate,
    /// The wire message names this device's own leaf as its sender: this device's own application message or its
    /// own commit, echoed back. No state is returned. Returned only at the group's current epoch: an own commit
    /// processed after `confirm_commit` is `WrongEpoch`.
    ///
    /// **Not authenticated.** OpenMLS decides this from the sender data alone, before the content is decrypted or
    /// the signature checked, and every member holds the sender-data secret: any member can forge it and the
    /// server can replay this device's real ciphertext. Callers decide what to believe (addendum R7).
    OwnLeaf,
    /// An unexpected failure inside the engine or OpenMLS.
    Internal,
}

impl ErrorCode {
    pub fn as_str(&self) -> &'static str {
        match self {
            ErrorCode::BadInput => "bad_input",
            ErrorCode::CorruptState => "corrupt_state",
            ErrorCode::WrongEpoch => "wrong_epoch",
            ErrorCode::Evicted => "evicted",
            ErrorCode::PendingCommit => "pending_commit",
            ErrorCode::NoPendingCommit => "no_pending_commit",
            ErrorCode::Duplicate => "duplicate",
            ErrorCode::OwnLeaf => "own_leaf",
            ErrorCode::Internal => "internal",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MlsError {
    pub code: ErrorCode,
    pub message: String,
}

impl MlsError {
    pub(crate) fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        MlsError {
            code,
            message: message.into(),
        }
    }

    pub(crate) fn bad_input(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::BadInput, message)
    }

    pub(crate) fn corrupt_state(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::CorruptState, message)
    }

    pub(crate) fn internal(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Internal, message)
    }
}

impl fmt::Display for MlsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code.as_str(), self.message)
    }
}

impl std::error::Error for MlsError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_have_stable_strings() {
        let all = [
            (ErrorCode::BadInput, "bad_input"),
            (ErrorCode::CorruptState, "corrupt_state"),
            (ErrorCode::WrongEpoch, "wrong_epoch"),
            (ErrorCode::Evicted, "evicted"),
            (ErrorCode::PendingCommit, "pending_commit"),
            (ErrorCode::NoPendingCommit, "no_pending_commit"),
            (ErrorCode::Duplicate, "duplicate"),
            (ErrorCode::OwnLeaf, "own_leaf"),
            (ErrorCode::Internal, "internal"),
        ];
        for (code, s) in all {
            assert_eq!(code.as_str(), s);
        }
    }
}
