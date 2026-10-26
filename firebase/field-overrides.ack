# Acknowledged hash of firebase/firestore.indexes.json "fieldOverrides" (single-field index exemptions).
# `firebase deploy --only firestore:indexes` applies them with the composite indexes; a new or changed override can REMOVE
# single-field indexing, which is NOT additive. CI (scripts/promotion/check-field-overrides.sh) fails until this hash is updated
# on purpose in the same reviewed PR. Update only after confirming the serving backend and the rollback target do not need the
# index (expand/contract). Recompute: the failing check prints the new hash.
sha256=33440531e602b7928f5cafbd3b37cbcf6e190e9af8c848ac1a235857a6b19002
