# Acknowledged hash of firebase/firestore.indexes.json "fieldOverrides" (single-field index exemptions).
# `firebase deploy --only firestore:indexes` applies them with the composite indexes; a new or changed override can REMOVE
# single-field indexing, which is NOT additive. CI (scripts/promotion/check-field-overrides.sh) fails until this hash is updated
# on purpose in the same reviewed PR. Update only after confirming the serving backend and the rollback target do not need the
# index (expand/contract). Recompute: the failing check prints the new hash.
sha256=252fe4904f83e6f057eb7fbdb599cc6226052586d8ea44b35155dc3b8a49d113
