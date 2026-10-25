#!/usr/bin/env bash
# Usage: check-firebase-loader-hashes.sh [firebase.json] [app dir]      (defaults: firebase.json, app)
#        check-firebase-loader-hashes.sh --print [app dir]              (print the sha256 hashes, one per line)
# CI gate: the FlutterFire web plugins load the Firebase JS SDK through inline <script> elements, so the Content
# Security Policy in firebase.json can only allow them by sha256 hash. The text of each script is fixed by the plugin
# (see firebase_core_web `_injectSrcScript`): two whitespace variants, one used when the browser has Trusted Types
# and one when it does not, per Firebase module, each importing .../firebasejs/<SDK version>/firebase-<module>.js.
# This script recomputes those hashes from the SDK version pinned in the resolved firebase_core_web package and fails
# when script-src does not contain exactly that set, so a FlutterFire/SDK bump cannot silently break the CSP.
# Needs jq, openssl and a resolved app/.dart_tool/package_config.json (`flutter pub get`).
set -euo pipefail

mode=check
if [ "${1:-}" = "--print" ]; then mode=print; shift; fi
if [ "$mode" = print ]; then app=${1:-app}; conf=; else conf=${1:-firebase.json}; app=${2:-app}; fi

# FlutterFire plugin (pubspec name) -> Firebase JS module. A new firebase_* plugin must be added here on purpose.
declare -A module_of=(
  [firebase_core]=app
  [firebase_auth]=auth
  [firebase_app_check]=app-check
  [firebase_messaging]=messaging
)

pkgcfg=$app/.dart_tool/package_config.json
[ -f "$pkgcfg" ] || { echo "FAIL: $pkgcfg missing (run 'flutter pub get' in $app)" >&2; exit 2; }

# Every direct firebase_* dependency (not *_platform_interface / *_web) must be a known module.
mapfile -t plugins < <(sed -nE 's/^  (firebase_[a-z_]+):.*/\1/p' "$app/pubspec.yaml" | grep -vE '_(web|platform_interface)$' | sort -u)
for p in "${plugins[@]}"; do
  [ -n "${module_of[$p]:-}" ] || { echo "FAIL: $app/pubspec.yaml depends on $p, which is not in the module map of $0" >&2; exit 1; }
done

root=$(jq -r '.packages[] | select(.name == "firebase_core_web") | .rootUri' "$pkgcfg")
[ -n "$root" ] || { echo "FAIL: firebase_core_web is not in $pkgcfg" >&2; exit 2; }
root=${root#file://}
case $root in /[A-Za-z]:*) root=${root#/} ;; esac # file:///C:/... on Windows
sdk=$(grep -rhoE "supportedFirebaseJsSdkVersion = '[0-9][^']*'" "$root/lib" | head -n1 | sed -E "s/.*'([^']*)'/\1/")
[ -n "$sdk" ] || { echo "FAIL: cannot read supportedFirebaseJsSdkVersion from $root/lib" >&2; exit 2; }

hash_of() { printf '%s' "$1" | openssl dgst -sha256 -binary | openssl base64 -A; }

expected=()
for p in "${plugins[@]}"; do
  name=$p mod=${module_of[$p]}
  url="https://www.gstatic.com/firebasejs/$sdk/firebase-$mod.js"
  # Trusted Types variant (Chromium) and plain variant (Firefox, Safari): same text, different indentation.
  tt=$(printf '            window.ff_trigger_%s = async (callback) => {\n              console.debug("Initializing Firebase %s");\n              callback(await import("%s"));\n            };\n          ' "$name" "$name" "$url")
  plain=$(printf '      window.ff_trigger_%s = async (callback) => {\n        console.debug("Initializing Firebase %s");\n        callback(await import("%s"));\n      };\n    ' "$name" "$name" "$url")
  expected+=("sha256-$(hash_of "$tt")" "sha256-$(hash_of "$plain")")
done
mapfile -t expected < <(printf '%s\n' "${expected[@]}" | sort -u)

if [ "$mode" = print ]; then printf '%s\n' "${expected[@]}"; exit 0; fi

csp=$(jq -r '.hosting | (if type == "array" then .[] else . end) | .headers[]?.headers[]?
  | select(.key | test("^Content-Security-Policy")) | .value' "$conf")
[ -n "$csp" ] || { echo "FAIL: no Content-Security-Policy header in $conf" >&2; exit 2; }
script_src=$(printf '%s' "$csp" | tr ';' '\n' | sed -E 's/^ +//' | grep -E '^script-src( |$)' || true)
[ -n "$script_src" ] || { echo "FAIL: no script-src directive in $conf" >&2; exit 1; }
mapfile -t actual < <(printf '%s' "$script_src" | grep -oE "'sha256-[A-Za-z0-9+/=]+'" | tr -d "'" | sort -u)

rc=0
for h in "${expected[@]}"; do
  printf '%s\n' "${actual[@]}" | grep -qxF "$h" || { echo "FAIL: script-src is missing $h (FlutterFire loader, SDK $sdk)" >&2; rc=1; }
done
for h in "${actual[@]}"; do
  printf '%s\n' "${expected[@]}" | grep -qxF "$h" || { echo "FAIL: script-src has a stale hash $h (matches no loader script for SDK $sdk)" >&2; rc=1; }
done
[ "$rc" -eq 0 ] && echo "OK: script-src carries the ${#expected[@]} FlutterFire loader hashes for Firebase JS SDK $sdk"
if [ "$rc" -ne 0 ]; then echo "Regenerate with: bash scripts/csp/check-firebase-loader-hashes.sh --print" >&2; fi
exit "$rc"
