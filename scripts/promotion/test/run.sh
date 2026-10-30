#!/usr/bin/env bash
# Fixture tests for the promotion scripts. No network, no credentials. Variants are made from the committed
# fixtures with jq, so the committed files stay small and contain only fake uids.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
p=$(dirname "$here")
fx=$here/fixtures
ceil=$p/flag-ceiling.json
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
failed=0

# expect <name> <want-exit> <command...>   (stdout+stderr are checked for allowlist uid leaks)
expect() {
  local name=$1 want=$2
  shift 2
  bash "$@" >"$tmp/out" 2>&1
  local rc=$?
  if grep -q 'fake-uid' "$tmp/out"; then
    echo "FAIL $name: output leaked an allowlist uid"
    failed=$((failed + 1))
    return
  fi
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL $name: exit $rc, want $want"
    sed 's/^/    /' "$tmp/out"
    failed=$((failed + 1))
  fi
}
# expect_msg <name> <want-exit> <pattern> <command...>: like expect, and the output must contain the pattern
expect_msg() {
  local name=$1 want=$2 pat=$3
  shift 3
  expect "$name" "$want" "$@"
  if ! grep -q -- "$pat" "$tmp/out"; then
    echo "FAIL $name: output lacks '$pat'"
    sed 's/^/    /' "$tmp/out"
    failed=$((failed + 1))
  fi
}
# mut <jq-filter> <fixture> <out-name>
mut() { jq "$1" "$fx/$2" | tr -d '\r' >"$tmp/$3"; }
V="$p/validate-revision.sh"
T="$p/check-traffic.sh"
R="$p/resolve-rollback.sh"
G="$p/check-flag-registry.sh"

# --- validate-revision
expect "revision ok" 0 "$V" "$fx/revision-ok.json" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_ENGAGEMENT","value":"on"}]' revision-ok.json r
expect "engagement on" 1 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_MEDIA","value":"percent"}]' revision-ok.json r
expect "media percent above allowlist" 1 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_FUTURE","value":"off"}]' revision-ok.json r
expect "unknown flag" 1 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_GRAPH_ALLOWLISTT","value":"x"}]' revision-ok.json r
expect "misspelled suffix" 1 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_QUOTES","valueSource":{"secretKeyRef":{"secret":"s","version":"1"}}}]' revision-ok.json r
expect "valueFrom flag" 1 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_REPORTS","value":"off"}]' revision-ok.json r
expect "duplicate env" 1 "$V" "$tmp/r" "$ceil" dev
mut '(.spec.containers[0].env[] | select(.name=="FEATURE_GRAPH") | .value) = "enabled"' revision-ok.json r
expect "bad mode" 1 "$V" "$tmp/r" "$ceil" dev
mut '(.spec.containers[0].env[] | select(.name=="FEATURE_ACCOUNT_LIFECYCLE_ALLOWLIST") | .value) = "fake-uid-A,fake-uid-B,fake-uid-C,fake-uid-D,fake-uid-E,fake-uid-F,fake-uid-G"' revision-ok.json r
expect "allowlist too big" 1 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_REPORTS_PERCENT","value":"5"}]' revision-ok.json r
expect "percent over ceiling" 1 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_REPORTS_PERCENT","value":"500"}]' revision-ok.json r
expect "percent over 100" 1 "$V" "$tmp/r" "$ceil" dev
mut '.metadata.annotations["autoscaling.knative.dev/maxScale"] = "10"' revision-ok.json r
expect "max instances" 1 "$V" "$tmp/r" "$ceil" dev
mut '.metadata.annotations["autoscaling.knative.dev/maxScale"] = "1"' revision-ok.json r
expect "tighter max instances is fine" 0 "$V" "$tmp/r" "$ceil" dev
mut '.metadata.annotations["autoscaling.knative.dev/maxScale"] = "0"' revision-ok.json r
expect "max instances 0 means unlimited" 1 "$V" "$tmp/r" "$ceil" dev
mut '.metadata.annotations["autoscaling.knative.dev/maxScale"] = "abc"' revision-ok.json r
expect "max instances not a number" 1 "$V" "$tmp/r" "$ceil" dev
mut 'del(.metadata.annotations["autoscaling.knative.dev/minScale"])' revision-ok.json r
expect "min instances unset" 1 "$V" "$tmp/r" "$ceil" dev
# graph/posts default to ON in dev when unset (config.go graphDefaultMode); the ceiling says on, so this passes.
mut '.spec.containers[0].env |= map(select(.name != "FEATURE_GRAPH"))' revision-ok.json r
expect "graph unset equals dev default on" 0 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env |= map(select(.name != "FEATURE_REPORTS"))' revision-ok.json r
expect "reports unset equals off" 0 "$V" "$tmp/r" "$ceil" dev
expect "not a revision" 2 "$V" "$fx/service-ok.json" "$ceil" dev
expect "unknown env" 2 "$V" "$fx/revision-ok.json" "$ceil" prod

# --- check-traffic
expect "serving ok" 0 "$T" "$fx/service-ok.json" "$ceil" dev serving
mut '.status.traffic[0].percent = 50' service-ok.json s
expect "split traffic" 1 "$T" "$tmp/s" "$ceil" dev serving
mut '.status.traffic[0] |= (del(.revisionName) | .latestRevision = true)' service-ok.json s
expect "latestRevision" 1 "$T" "$tmp/s" "$ceil" dev serving
mut '.status.traffic[0].tag = "surprise"' service-ok.json s
expect "unexpected tag" 1 "$T" "$tmp/s" "$ceil" dev serving
mut '.status.traffic[1].percent = 5' service-ok.json s
expect "two holders" 1 "$T" "$tmp/s" "$ceil" dev serving
mut '.status.traffic = []' service-ok.json s
expect "no traffic" 1 "$T" "$tmp/s" "$ceil" dev serving
mut '.status.traffic += [{"revisionName":"api-00002-bbb","tag":"candidate"}]' service-ok.json s
expect "staged ok" 0 "$T" "$tmp/s" "$ceil" dev staged api-00002-bbb api-00001-aaa
expect "staged wrong serving" 1 "$T" "$tmp/s" "$ceil" dev staged api-00002-bbb api-00009-zzz
expect "staged missing candidate" 1 "$T" "$fx/service-ok.json" "$ceil" dev staged api-00002-bbb api-00001-aaa

# --- resolve-rollback (last-good is api-00000-zzz; its revision JSON is the ok revision renamed)
mut '.metadata.name = "api-00000-zzz"' revision-ok.json lg
expect "rollback ok" 0 "$R" "$fx/service-ok.json" "$tmp/lg" "$fx/images-ok.json" "$ceil" dev
mut '.status.traffic |= map(select(.tag != "last-good"))' service-ok.json s
expect "no last-good tag" 1 "$R" "$tmp/s" "$tmp/lg" "$fx/images-ok.json" "$ceil" dev
mut '.metadata.name = "api-00005-xxx"' revision-ok.json lg2
expect "wrong revision json" 1 "$R" "$fx/service-ok.json" "$tmp/lg2" "$fx/images-ok.json" "$ceil" dev
echo '[]' >"$tmp/noimg"
expect "image deleted" 1 "$R" "$fx/service-ok.json" "$tmp/lg" "$tmp/noimg" "$ceil" dev
jq '.metadata.name="api-00000-zzz" | .spec.containers[0].image = "example/api:latest"' "$fx/revision-ok.json" >"$tmp/lg4"
expect "tag-pinned image" 1 "$R" "$fx/service-ok.json" "$tmp/lg4" "$fx/images-ok.json" "$ceil" dev
jq '.metadata.name="api-00000-zzz" | .spec.containers[0].env += [{"name":"FEATURE_ENGAGEMENT","value":"on"}]' "$fx/revision-ok.json" >"$tmp/lg5"
expect "rollback target over ceiling" 1 "$R" "$fx/service-ok.json" "$tmp/lg5" "$fx/images-ok.json" "$ceil" dev

# --- resolve-rollback.sh rollback floors (W3-42): a throwaway git repo with commits before, at and after the floor
fr=$tmp/floorrepo
git init -q "$fr" && git -C "$fr" config user.email t@example.invalid && git -C "$fr" config user.name t && git -C "$fr" config commit.gpgsign false
git -C "$fr" commit -q --allow-empty -m before && c_before=$(git -C "$fr" rev-parse HEAD)
git -C "$fr" commit -q --allow-empty -m floor && c_floor=$(git -C "$fr" rev-parse HEAD)
git -C "$fr" commit -q --allow-empty -m after && c_after=$(git -C "$fr" rev-parse HEAD)
git -C "$fr" checkout -q -b side "$c_before" && git -C "$fr" commit -q --allow-empty -m sideways && c_side=$(git -C "$fr" rev-parse HEAD)
git -C "$fr" checkout -q - 2>/dev/null
mut '.metadata.name = "api-00000-zzz"' revision-ok.json lg
jq --arg c "$c_floor" '.rollback_floors.PRIVATE_ACCOUNTS = {"commit": $c, "pr": 1, "reason": "test"}' "$ceil" >"$tmp/ceil-floor"
# lg-pa / lg-pa-off: last-good with FEATURE_PRIVATE_ACCOUNTS allowlist / off; img <commit...>: images.json whose digest carries those tags
jq '.metadata.name = "api-00000-zzz" | .spec.containers[0].env += [{"name":"FEATURE_PRIVATE_ACCOUNTS","value":"allowlist"}]' "$fx/revision-ok.json" >"$tmp/lg-pa"
jq '.metadata.name = "api-00000-zzz" | .spec.containers[0].env += [{"name":"FEATURE_PRIVATE_ACCOUNTS","value":"off"}]' "$fx/revision-ok.json" >"$tmp/lg-pa-off"
img() { jq --argjson t "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '.[0].tags += $t' "$fx/images-ok.json" >"$tmp/img-c"; }
export ROLLBACK_REPO=$fr
img "$c_before"
expect_msg "floor: flag allowlist, image before the floor, refused" 1 "older than" "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-floor" dev
expect_msg "floor: refusal names the rollback floor" 1 "PRIVATE_ACCOUNTS rollback floor" "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-floor" dev
img "$c_side"
expect_msg "floor: a commit on another branch is not at or after the floor" 1 "older than, or not provably after" "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-floor" dev
img "$c_floor"
expect "floor: image exactly at the floor passes" 0 "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-floor" dev
img "$c_after"
expect "floor: image after the floor passes" 0 "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-floor" dev
img "$c_before"
expect "floor: flag off on the target, pre-floor image passes" 0 "$R" "$fx/service-ok.json" "$tmp/lg-pa-off" "$tmp/img-c" "$tmp/ceil-floor" dev
expect "floor: flag unset (code default off), pre-floor image passes" 0 "$R" "$fx/service-ok.json" "$tmp/lg" "$tmp/img-c" "$tmp/ceil-floor" dev
img "$c_before" "$c_after"
expect "floor: any commit tag before the floor refuses" 1 "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-floor" dev
expect_msg "floor: no commit tag, flag allowlist, refused" 1 "no commit tag" "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$fx/images-ok.json" "$tmp/ceil-floor" dev
jq '.[0].tags += ["last-good", "serving", "ABCDEF", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' "$fx/images-ok.json" >"$tmp/img-c"
expect_msg "floor: tags that are not a full commit sha do not count" 1 "no commit tag" "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-floor" dev
expect "floor: no commit tag but flag off, passes" 0 "$R" "$fx/service-ok.json" "$tmp/lg-pa-off" "$fx/images-ok.json" "$tmp/ceil-floor" dev
img "$(printf '%040d' 7)"
expect_msg "floor: commit unknown to the checkout, refused" 1 "older than, or not provably after" "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-floor" dev
img "$c_after"
jq 'del(.rollback_floors)' "$tmp/ceil-floor" >"$tmp/ceil-nofloor"
expect "floor: no floors recorded, no check" 0 "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$fx/images-ok.json" "$tmp/ceil-nofloor" dev
jq '.rollback_floors.PRIVATE_ACCOUNTS.commit = "abc123"' "$tmp/ceil-floor" >"$tmp/ceil-badfloor"
expect_msg "floor: malformed floor commit, refused" 1 "not a 40-hex commit" "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-badfloor" dev
jq --arg c "$(printf '%040d' 9)" '.rollback_floors.PRIVATE_ACCOUNTS.commit = $c' "$tmp/ceil-floor" >"$tmp/ceil-missing"
expect_msg "floor: floor commit not in the checkout (shallow), refused" 1 "not in the checkout" "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-missing" dev
ROLLBACK_REPO=$tmp expect_msg "floor: not a git checkout at all, refused" 1 "not in the checkout" "$R" "$fx/service-ok.json" "$tmp/lg-pa" "$tmp/img-c" "$tmp/ceil-floor" dev
unset ROLLBACK_REPO
# the committed floor is well formed and the registry check accepts the extra key
expect "floor: committed ceiling floor is a 40-hex commit" 0 -c '[[ "$(jq -r .rollback_floors.PRIVATE_ACCOUNTS.commit "$0" | tr -d "\r")" =~ ^[0-9a-f]{40}$ ]]' "$ceil"
expect "floor: registry check still ok with rollback_floors" 0 "$G" "$fx/config-ok.go.txt" "$ceil"
# a floor must name a flag the ceiling knows
expect "floor: every floor flag is a registered flag" 0 -c 'jq -e ".flags as \$f | [.rollback_floors // {} | keys[] | select(startswith(\"_\")|not) | select(. as \$k | \$f | index(\$k) | not)] | length == 0" "$0" >/dev/null' "$ceil"

# --- check-flag-registry
expect "registry ok" 0 "$G" "$fx/config-ok.go.txt" "$ceil"
grep -v '"QUOTES"' "$fx/config-ok.go.txt" >"$tmp/cfg"
expect "flag missing from code" 1 "$G" "$tmp/cfg" "$ceil"
{ cat "$fx/config-ok.go.txt"; echo '	featureNew, err := flags.LoadSpec("NEWTHING", "newthing", flags.Off)'; } >"$tmp/cfg"
expect "flag missing from ceiling" 1 "$G" "$tmp/cfg" "$ceil"
sed 's/"QUOTES", "quotes", flags.Off/"QUOTES", "quotes", flags.On/' "$fx/config-ok.go.txt" >"$tmp/cfg"
expect "code default on" 1 "$G" "$tmp/cfg" "$ceil"
echo 'x = [{ name = "FEATURE_NOPE", value = "off" }]' >"$tmp/tf"
expect "terraform unknown flag" 1 "$G" "$fx/config-ok.go.txt" "$ceil" "$tmp/tf"
echo 'x = [{ name = "FEATURE_QUOTES_PERCENT", value = "0" }]' >"$tmp/tf"
expect "terraform known flag" 0 "$G" "$fx/config-ok.go.txt" "$ceil" "$tmp/tf"

# --- review findings (PR #165 review): each was a fail-open path before the fix
jq '.envs.dev.flags.ENGAGEMENT.mode = "Off"' "$ceil" >"$tmp/ceil-typo"
mut '.spec.containers[0].env += [{"name":"FEATURE_ENGAGEMENT","value":"on"}]' revision-ok.json r
expect "ceiling mode typo (validator)" 1 "$V" "$tmp/r" "$tmp/ceil-typo" dev
expect "ceiling mode typo (registry)" 1 "$G" "$fx/config-ok.go.txt" "$tmp/ceil-typo"
sed 's/"QUOTES", "quotes", flags.Off/"QUOTES", quotesWire, flags.On/' "$fx/config-ok.go.txt" >"$tmp/cfg"
expect "LoadSpec line the parser cannot read" 1 "$G" "$tmp/cfg" "$ceil"
{ cat "$fx/config-ok.go.txt"; echo '	featureM2, err := flags.LoadSpec("MEDIA2", "media2", flags.On)'; } >"$tmp/cfg"
expect "flag name with a digit" 1 "$G" "$tmp/cfg" "$ceil"
grep -v 'graphDefaultMode = flags.Off' "$fx/config-ok.go.txt" >"$tmp/cfg"
expect "graphDefaultMode without prod override" 1 "$G" "$tmp/cfg" "$ceil"
mut '.status.observedGeneration = 4' service-ok.json s
expect "stale status" 1 "$T" "$tmp/s" "$ceil" dev serving
mut '.status.conditions = [{"type":"Ready","status":"False"}]' service-ok.json s
expect "service not ready" 1 "$T" "$tmp/s" "$ceil" dev serving
mut '.metadata.name = "api-00000-zzz"' revision-ok.json lg
jq 'map(.package = "example-docker.pkg.dev/other-proj/api/api")' "$fx/images-ok.json" >"$tmp/img-other"
expect "images from another repository" 1 "$R" "$fx/service-ok.json" "$tmp/lg" "$tmp/img-other" "$ceil" dev
mut '.status.traffic[1].revisionName = "api-00001-aaa"' service-ok.json s
mut '.metadata.name = "api-00001-aaa"' revision-ok.json lg6
expect "last-good is the serving revision" 1 "$R" "$tmp/s" "$tmp/lg6" "$fx/images-ok.json" "$ceil" dev

# --- check-field-overrides.sh: any change to fieldOverrides must be acknowledged on purpose
F="$p/check-field-overrides.sh"
iok=$fx/indexes-ok.json
aok=$fx/field-overrides-ok.ack
expect "overrides unchanged" 0 "$F" "$iok" "$aok"
jq '.fieldOverrides += [{"collectionGroup":"posts","fieldPath":"newfield","indexes":[]}]' "$iok" >"$tmp/i"
expect "new exemption needs an ack" 1 "$F" "$tmp/i" "$aok"
jq '.fieldOverrides[0].indexes = [{"order":"ASCENDING","queryScope":"COLLECTION"}]' "$iok" >"$tmp/i"
expect "changed override needs an ack" 1 "$F" "$tmp/i" "$aok"
jq '.fieldOverrides |= .[0:1]' "$iok" >"$tmp/i"
expect "removed override needs an ack" 1 "$F" "$tmp/i" "$aok"
jq '.fieldOverrides |= reverse' "$iok" >"$tmp/i"
expect "reordered overrides are the same set" 0 "$F" "$tmp/i" "$aok"
jq '.fieldOverrides |= map({indexes, fieldPath, collectionGroup})' "$iok" | sed 's/$//' >"$tmp/i"
expect "CRLF and key order inside overrides do not matter" 0 "$F" "$tmp/i" "$aok"
jq '.indexes += [{"collectionGroup":"posts","queryScope":"COLLECTION","fields":[{"fieldPath":"x","order":"ASCENDING"}]}]' "$iok" >"$tmp/i"
expect "adding a composite index needs no ack" 0 "$F" "$tmp/i" "$aok"
printf '# no hash here
' >"$tmp/a"
expect "ack without a hash fails" 1 "$F" "$iok" "$tmp/a"
printf 'sha256=%064d
' 0 >"$tmp/a"
expect "wrong ack hash fails" 1 "$F" "$iok" "$tmp/a"
expect "missing ack file is a usage error" 2 "$F" "$iok" "$tmp/does-not-exist"
echo '{"indexes":[]}' >"$tmp/i"
expect "no fieldOverrides at all is checked too" 1 "$F" "$tmp/i" "$aok"
jq '.fieldOverrides += [.fieldOverrides[0]]' "$iok" >"$tmp/i"
expect "duplicate overrides are rejected" 1 "$F" "$tmp/i" "$aok"
echo '{"fieldOverrides":[{"collectionGroup":"x","fieldPath":"y","indexes":true}]}' >"$tmp/i"
expect "odd override shapes fail with 1, not a jq crash" 1 "$F" "$tmp/i" "$aok"
echo '{"fieldOverrides":"nope"}' >"$tmp/i"
expect "non-array fieldOverrides is rejected" 1 "$F" "$tmp/i" "$aok"
{ cat "$aok"; cat "$aok"; } >"$tmp/a"
expect "two sha256 lines in the ack are rejected" 1 "$F" "$iok" "$tmp/a"
tr 'a-f' 'A-F' <"$aok" | sed 's/SHA256=/sha256=/' >"$tmp/a"
expect "uppercase hex in the ack is rejected" 1 "$F" "$iok" "$tmp/a"
sed 's/$//' "$aok" >"$tmp/a"
expect "a CRLF ack still works" 0 "$F" "$iok" "$tmp/a"
# the file the gate checks must be the file firebase.json deploys
fbj=$p/../../firebase.json
if [ -f "$fbj" ]; then
  if [ "$(jq -r '.firestore | if type == "object" then .indexes else "multi-database" end' "$fbj" | tr -d $'')" = "firebase/firestore.indexes.json" ]; then pass=$((pass+1)); else echo "FAIL firebase.json no longer deploys firebase/firestore.indexes.json as a single database file; the fieldOverrides gate would check the wrong file"; failed=$((failed+1)); fi
fi
# the real repository files must be consistent right now
expect "repository fieldOverrides ack is current" 0 "$F" "$p/../../firebase/firestore.indexes.json" "$p/../../firebase/field-overrides.ack"

# --- deploy-dev.yml invariants (static): additive indexes only, in the right order
wf=$p/../../.github/workflows/deploy-dev.yml
if [ -f "$wf" ]; then
  code=$(grep -v '^[[:space:]]*#' "$wf" | tr -d '') # commands only; comments may mention these words
  if grep -qE -- '--force|firebase deploy[^#]*[[:space:]]-f([[:space:]]|$)' <<<"$code"; then echo "FAIL deploy-dev.yml must never pass --force/-f to firebase deploy (it would delete indexes the serving backend may need)"; failed=$((failed+1)); else pass=$((pass+1)); fi
  if ! grep -q 'promote-dev.sh' <<<"$code"; then
    pass=$((pass+1)) # the workflow does not call the orchestrator yet (PR 2a): the wiring checks below apply once it does
  else
    # Any way of invoking the script counts (bash, exec, a run block): the first mention is the promote step.
    idx=$(grep -n 'firebase deploy --only firestore:indexes' <<<"$code" | head -1 | cut -d: -f1); prm=$(grep -n 'promote-dev.sh' <<<"$code" | head -1 | cut -d: -f1)
    rul=$(grep -n 'firebase deploy --only firestore:rules' <<<"$code" | head -1 | cut -d: -f1); hos=$(grep -n 'firebase deploy --only hosting' <<<"$code" | head -1 | cut -d: -f1)
    if [ -n "$idx" ] && [ -n "$rul" ] && [ -n "$hos" ] && [ "$idx" -lt "$prm" ] && [ "$prm" -lt "$rul" ] && [ "$rul" -lt "$hos" ]; then pass=$((pass+1)); else echo "FAIL deploy-dev.yml order must be indexes < promote-dev.sh < rules < hosting"; failed=$((failed+1)); fi
    # the fieldOverrides gate must run before any cloud access, and must not be conditional
    fo=$(grep -n 'check-field-overrides.sh' <<<"$code" | head -1 | cut -d: -f1); auth=$(grep -n 'google-github-actions/auth@' <<<"$code" | head -1 | cut -d: -f1)
    if [ -n "$fo" ] && [ -n "$auth" ] && [ "$fo" -lt "$auth" ]; then pass=$((pass+1)); else echo "FAIL deploy-dev.yml must run check-field-overrides.sh before the GCP auth step"; failed=$((failed+1)); fi
    if grep -B4 'check-field-overrides.sh' <<<"$code" | grep -q 'if:'; then echo "FAIL deploy-dev.yml: the fieldOverrides gate must not be conditional (no if:)"; failed=$((failed+1)); else pass=$((pass+1)); fi
    # every live-change step must be gated on the effective mode, and the recover step must exist
    gated=$(grep -c "steps.mode.outputs.dry_run == 'false'" <<<"$code" || true)
    if [ "$gated" -ge 7 ]; then pass=$((pass+1)); else echo "FAIL deploy-dev.yml: only $gated steps are gated on dry_run == 'false' (need install, indexes, wait, stale check, recover, rules, hosting)"; failed=$((failed+1)); fi
    if [ "$(grep -c 'PROMOTE_MARKER:' <<<"$code")" -ge 2 ]; then pass=$((pass+1)); else echo "FAIL deploy-dev.yml: both the promote step and the recover step must set PROMOTE_MARKER"; failed=$((failed+1)); fi
    if [ "$(grep -n 'timeout-minutes:' <<<"$code" | wc -l)" -ge 4 ]; then pass=$((pass+1)); else echo "FAIL deploy-dev.yml: job, index wait, promote and recover steps must each have a timeout-minutes"; failed=$((failed+1)); fi
    if grep -q 'RECOVER: "true"' <<<"$code" && grep -q 'always()' <<<"$code"; then pass=$((pass+1)); else echo "FAIL deploy-dev.yml must run the always() recover step (RECOVER=true)"; failed=$((failed+1)); fi
  fi
fi

# --- authenticated-smoke.sh and prod-smoke.sh: their own fixture file (fake curl), run here so the required CI step covers it
expect "authenticated smoke tests" 0 "$here/smoke-test.sh"
expect "bookmarks smoke tests (dev-only, W2-16)" 0 "$here/bookmarks-smoke-test.sh"

# --- check-until-dates.sh (ADR-0022): a time-boxed marker must not outlive its date
U="$p/check-until-dates.sh"
ud="$tmp/until"
mkdir -p "$ud/envs/prod" "$ud/.terraform"
export UNTIL_TODAY=2026-12-22
printf 'resource "x" "y" {\n  a = 1\n}\n' >"$ud/envs/prod/main.tf"
expect_msg "until: no markers pass" 0 "0 until: marker" "$U" "$ud"
printf 'a = 1 # cost-approved: ADR-0022 until:2026-12-31\n' >"$ud/envs/prod/main.tf"
expect_msg "until: future date passes" 0 "1 until: marker" "$U" "$ud"
printf 'a = 1 # cost-approved: ADR-0022 until:2026-12-22\n' >"$ud/envs/prod/main.tf"
expect "until: today passes" 0 "$U" "$ud"
printf 'a = 1 # cost-approved: ADR-0022 until:2026-12-21\n' >"$ud/envs/prod/main.tf"
expect_msg "until: past date fails" 1 "expired marker until:2026-12-21" "$U" "$ud"
printf 'a = 1 # until:2026-13-45\n' >"$ud/envs/prod/main.tf"
expect_msg "until: impossible month fails clearly" 1 "malformed marker" "$U" "$ud"
printf 'a = 1 # until:2026-02-30\n' >"$ud/envs/prod/main.tf"
expect_msg "until: 30 February fails clearly" 1 "malformed marker" "$U" "$ud"
printf 'a = 1 # until:soon\n' >"$ud/envs/prod/main.tf"
expect_msg "until: not a date fails clearly" 1 "want until:YYYY-MM-DD" "$U" "$ud"
printf 'a = 1 # until:2026-12-2\n' >"$ud/envs/prod/main.tf"
expect_msg "until: short date fails clearly" 1 "malformed marker" "$U" "$ud"
printf 'a = 1 # prose until: the date passes\n' >"$ud/envs/prod/main.tf"
expect_msg "until: followed by a space is prose, not a marker" 0 "0 until: marker" "$U" "$ud"
printf 'a = 1 # until:2026-12-31 and until:2026-12-01\n' >"$ud/envs/prod/main.tf"
expect_msg "until: a second marker on the same line is checked" 1 "expired marker until:2026-12-01" "$U" "$ud"
printf 'a = 1 # until:2026-12-21\r\n' >"$ud/envs/prod/main.tf"
expect_msg "until: CRLF file, past date fails" 1 "expired marker until:2026-12-21" "$U" "$ud"
printf 'a = 1 # until:2026-12-22\r\n' >"$ud/envs/prod/main.tf"
expect "until: CRLF file, today passes" 0 "$U" "$ud"
printf 'a = 1 # until:2020-01-01\n' >"$ud/envs/prod/terraform.tfvars.example"
printf 'a = 1\n' >"$ud/envs/prod/main.tf"
expect_msg "until: tfvars.example is scanned" 1 "terraform.tfvars.example" "$U" "$ud"
rm -f "$ud/envs/prod/terraform.tfvars.example"
printf 'a = 1 # until:2020-01-01\n' >"$ud/.terraform/provider.tf"
printf 'a = 1 # until:2020-01-01\n' >"$ud/envs/prod/notes.md"
expect "until: .terraform and other file types are ignored" 0 "$U" "$ud"
UNTIL_TODAY=2026-12-23 expect_msg "until: the date override is honoured (a day later)" 0 "0 until: marker" "$U" "$ud"
printf 'a = 1 # until:2026-12-22\n' >"$ud/envs/prod/main.tf"
UNTIL_TODAY=2026-12-23 expect "until: marker expires the day after" 1 "$U" "$ud"
UNTIL_TODAY=tomorrow expect_msg "until: a bad UNTIL_TODAY is a usage error" 2 "not a YYYY-MM-DD" "$U" "$ud"
unset UNTIL_TODAY
expect "until: missing directory is a usage error" 2 "$U" "$tmp/does-not-exist"

echo "promotion fixture tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
