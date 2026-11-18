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
            (ErrorCode::Internal, "internal"),
        ];
        for (code, s) in all {
            assert_eq!(code.as_str(), s);
        }
    }
}
