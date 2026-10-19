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
  "$@" >"$tmp/out" 2>&1
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
mut '.spec.containers[0].env += [{"name":"FEATURE_MEDIA","value":"allowlist"}]' revision-ok.json r
expect "media allowlist above off" 1 "$V" "$tmp/r" "$ceil" dev
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
mut '(.spec.containers[0].env[] | select(.name=="FEATURE_ACCOUNT_LIFECYCLE_ALLOWLIST") | .value) = "fake-uid-A,fake-uid-B"' revision-ok.json r
expect "allowlist too big" 1 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_REPORTS_PERCENT","value":"5"}]' revision-ok.json r
expect "percent over ceiling" 1 "$V" "$tmp/r" "$ceil" dev
mut '.spec.containers[0].env += [{"name":"FEATURE_REPORTS_PERCENT","value":"500"}]' revision-ok.json r
expect "percent over 100" 1 "$V" "$tmp/r" "$ceil" dev
mut '.metadata.annotations["autoscaling.knative.dev/maxScale"] = "10"' revision-ok.json r
expect "max instances" 1 "$V" "$tmp/r" "$ceil" dev
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

echo "promotion fixture tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
