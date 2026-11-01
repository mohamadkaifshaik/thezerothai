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

# FlutterFire plugins that inject no loader script on web, so script-src carries no hash for them (ADR-0032 D10).
# Each exception is re-proven on every run; when its condition fails the plugin needs a module_of entry instead.
#   no-web-plugin:   the resolved plugin's own pubspec (flutter.plugin.platforms) declares no web platform, and the
#                    app resolves no <name>_web package.
#   ignored:<svc>:   web/flutterfire_config.js lists <svc> in window.flutterfire_ignore_scripts and index.html loads
#                    that file as a plain blocking <script> (no async, defer or type="module") before
#                    flutter_bootstrap.js, so firebase_core_web never injects the loader.
# Anything that cannot be read or verified fails.
declare -A no_loader=(
  [firebase_crashlytics]=no-web-plugin
  [firebase_analytics]=ignored:analytics
)

pkgcfg=$app/.dart_tool/package_config.json
[ -f "$pkgcfg" ] || { echo "FAIL: $pkgcfg missing (run 'flutter pub get' in $app)" >&2; exit 2; }

# Every direct firebase_* dependency (not *_platform_interface / *_web) must be a known module or a proven exception.
mapfile -t all_plugins < <(sed -nE 's/^  (firebase_[a-z_]+):.*/\1/p' "$app/pubspec.yaml" | grep -vE '_(web|platform_interface)$' | sort -u)
plugins=()
for p in "${all_plugins[@]}"; do
  if [ -n "${module_of[$p]:-}" ]; then plugins+=("$p"); continue; fi
  case ${no_loader[$p]:-} in
    no-web-plugin)
      proot=$(jq -r --arg n "$p" '.packages[] | select(.name == $n) | .rootUri' "$pkgcfg")
      proot=${proot#file://}
      case $proot in /[A-Za-z]:*) proot=${proot#/} ;; esac # file:///C:/... on Windows
      [ -n "$proot" ] && [ -f "$proot/pubspec.yaml" ] \
        || { echo "FAIL: cannot read the resolved pubspec of $p to verify it has no web plugin" >&2; exit 2; }
      # The flutter.plugin.platforms block: from "    platforms:" to the next line indented 4 spaces or less.
      platforms=$(awk '/^flutter:/ {f=1; next} f && /^[^ #]/ {f=0} f && /^  plugin:/ {pl=1; next} pl && /^  [^ ]/ {pl=0}
        pl && /^    platforms:/ {pf=1; next} pf && /[^ ]/ && match($0, /^ */) && RLENGTH <= 4 {pf=0} pf {print}' \
        "$proot/pubspec.yaml")
      [ -n "$platforms" ] || { echo "FAIL: $proot/pubspec.yaml has no flutter.plugin.platforms to verify $p" >&2; exit 2; }
      if printf '%s\n' "$platforms" | grep -qE '^      web:'; then
        echo "FAIL: $p now declares a web plugin, so it injects a loader on web; add it to the module map of $0" >&2; exit 1
      fi
      if jq -e --arg n "${p}_web" '.packages[] | select(.name == $n)' "$pkgcfg" >/dev/null; then
        echo "FAIL: $p now resolves ${p}_web, so it injects a loader on web; add it to the module map of $0" >&2; exit 1
      fi ;;
    ignored:*)
      svc=${no_loader[$p]#ignored:} ffcfg=$app/web/flutterfire_config.js index=$app/web/index.html
      grep -qE "flutterfire_ignore_scripts *= *\[[^]]*['\"]$svc['\"]" "$ffcfg" 2>/dev/null \
        || { echo "FAIL: $p is exempt only while $ffcfg ignores '$svc' (window.flutterfire_ignore_scripts)" >&2; exit 1; }
      cfg_tag=$(grep -nE '<script[^>]*src="(/)?flutterfire_config\.js"' "$index" | head -n1)
      boot_line=$(grep -nE '<script[^>]*src="(/)?flutter_bootstrap\.js"' "$index" | head -n1 | cut -d: -f1)
      cfg_line=${cfg_tag%%:*}
      [ -n "$cfg_tag" ] && [ -n "$boot_line" ] && [ "$cfg_line" -lt "$boot_line" ] \
        || { echo "FAIL: $p is exempt only while $index loads flutterfire_config.js before flutter_bootstrap.js" >&2; exit 1; }
      if printf '%s' "$cfg_tag" | grep -qiE '<script[^>]*( async| defer|type="module")'; then
        echo "FAIL: $p is exempt only while $index loads flutterfire_config.js as a plain blocking script" >&2; exit 1
      fi ;;
    *) echo "FAIL: $app/pubspec.yaml depends on $p, which is not in the module map of $0" >&2; exit 1 ;;
  esac
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
