#!/usr/bin/env bash
# Usage: check-until-dates.sh [dir]        (default: infra/terraform, relative to the repository root)
# CI gate (ADR-0022): every time-boxed marker "until:YYYY-MM-DD" in *.tf and *.tfvars.example under <dir> must be today
# (UTC) or later. A marker whose date has passed means a credit-mode item was not switched off in time, so the build
# fails until the line is reverted or the date is renewed by a new decision. A marker that is not a real calendar date
# also fails (a typo must not silently disable the check). "until:" followed by a space is prose, not a marker.
# Today comes from the UNTIL_TODAY environment variable (YYYY-MM-DD) when set, else `date -u`; tests set it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
dir=${1:-"$(cd "$here/../.." && pwd)/infra/terraform"}
[ -d "$dir" ] || { echo "FAIL: $dir is not a directory" >&2; exit 2; }

is_date() { # a real calendar date in YYYY-MM-DD form (round trip rejects 2026-02-30)
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ "$(date -u -d "$1" +%F 2>/dev/null)" = "$1" ]
}

today=${UNTIL_TODAY:-$(date -u +%F)}
is_date "$today" || { echo "FAIL: today ('$today') is not a YYYY-MM-DD date (UNTIL_TODAY?)" >&2; exit 2; }

markers=0
while IFS= read -r f; do
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    loc="$f:${hit%%:*}" # file:line (grep -n prints "line:text")
    # Every marker on the line (a line may carry more than one).
    while read -r token; do
      markers=$((markers + 1))
      d=${token#until:}
      if ! is_date "$d"; then
        fail "$loc: malformed marker '$token' (want until:YYYY-MM-DD, a real calendar date)"
      elif [[ $d < $today ]]; then
        fail "$loc: expired marker $token (today is $today UTC). Revert the credit-mode item or renew it with a new ADR decision"
      fi
    done < <(grep -oE 'until:[^[:space:]]+' <<<"${hit#*:}" || true)
  done < <(tr -d '\r' <"$f" | grep -nE 'until:[^[:space:]]' || true)
done < <(find "$dir" -name .terraform -prune -o -type f \( -name '*.tf' -o -name '*.tfvars.example' \) -print | LC_ALL=C sort)

note "$markers until: marker(s) checked against $today"
finish
