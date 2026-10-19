#!/usr/bin/env bash
# Usage: check-field-overrides.sh <firestore.indexes.json> <field-overrides.ack>
# `firebase deploy --only firestore:indexes` applies `fieldOverrides` (single-field index exemptions) together with the composite
# indexes. Composite indexes are additive, but a NEW or CHANGED override can remove single-field indexing and break queries the
# serving backend, or the rollback target, still needs. So any change to `fieldOverrides` must be acknowledged on purpose: the ack
# file holds the sha256 of the canonicalised overrides, and this check fails until a reviewed commit updates it.
# Prints counts and the hash only (names of collection groups/fields are not secret but are kept out of the output anyway).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
need_tool jq
need_tool sha256sum
[ $# -eq 2 ] || { echo "usage: $0 <firestore.indexes.json> <field-overrides.ack>" >&2; exit 2; }
idx=$1
ack=$2
need_file "$idx"
need_file "$ack"

# The overrides must be an array of objects with a unique (collectionGroup, fieldPath); anything else fails with a clear message.
shape=$(jq -r 'if (.fieldOverrides // []) | type != "array" then "not-array"
  elif ((.fieldOverrides // []) | map(type) | unique | any(. != "object")) then "not-objects"
  elif ((.fieldOverrides // []) | map([.collectionGroup, .fieldPath]) | (length != (unique | length))) then "duplicates"
  else "ok" end' "$idx" 2>/dev/null | tr -d $'') || shape=unparsable
[ -n "$shape" ] || shape=unparsable
case $shape in
  ok) ;;
  unparsable) echo "FAIL: cannot parse $idx" >&2; exit 1 ;;
  not-array) fail "fieldOverrides is not an array" ;;
  not-objects) fail "fieldOverrides contains non-object entries" ;;
  duplicates) fail "fieldOverrides has duplicate (collectionGroup, fieldPath) entries" ;;
esac
[ "$shape" = ok ] || finish

# Canonical form: overrides sorted by (collectionGroup, fieldPath), keys sorted, compact; CR removed.
canon=$(jq -S -c '(.fieldOverrides // []) | sort_by(.collectionGroup, .fieldPath)' "$idx" | tr -d $'') || { echo "FAIL: cannot parse $idx" >&2; exit 1; }
have=$(printf '%s' "$canon" | sha256sum | cut -d' ' -f1)
total=$(printf '%s' "$canon" | jq 'length')
# The acknowledgement must hold exactly one lowercase 'sha256=<64 hex>' line (CR stripped first).
acklines=$(tr -d $'' <"$ack" | grep -c '^sha256=' || true)
want=$(tr -d $'' <"$ack" | grep -E '^sha256=[0-9a-f]{64}$' | head -n 1 | cut -d= -f2 || true)

if [ "$acklines" != "1" ] || [ -z "$want" ]; then
  fail "$ack must contain exactly one line of the form sha256=<64 lowercase hex> (found $acklines sha256= line(s))"
elif [ "$have" != "$want" ]; then
  fail "fieldOverrides changed: $total override(s) now hash to $have, acknowledged $want"
  echo "      A new or changed override can REMOVE single-field indexing, which is not additive. If this change is intended and the" >&2
  echo "      serving backend and rollback target do not need the index, update $ack in the same reviewed PR (expand/contract)." >&2
else
  note "fieldOverrides unchanged: $total override(s) (acknowledged $have)"
fi
finish
