#!/usr/bin/env bash
# Emit NUL-delimited candidate deployment arguments. Pure validation: no cloud
# calls and no secret contents. References must name pinned Secret Manager versions.
set -euo pipefail
fail() { echo "FAIL: dev billing configuration $*" >&2; exit 2; }
case ${BILLING_CONFIG_ENABLED:-false} in
  '' | false) exit 0 ;;
  true) ;;
  *) fail "opt-in must be true or false" ;;
esac
command -v jq >/dev/null || fail "requires jq"
sales=${BILLING_PURCHASES_ENABLED:-false}
environment=${REVENUECAT_PURCHASE_ENVIRONMENT:-SANDBOX}
case $sales in true | false) ;; *) fail "checkout must be true or false" ;; esac
case $environment in SANDBOX | PRODUCTION) ;; *) fail "receipt environment is invalid" ;; esac
apps=${REVENUECAT_WEBHOOK_APP_IDS:-}
[[ $apps =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] || fail "requires real app IDs"
IFS=',' read -r -a app_ids <<< "$apps"
[ "${#app_ids[@]}" -le 16 ] || fail "has too many apps"
for app in "${app_ids[@]}"; do
  [ "${#app}" -le 128 ] || fail "app ID is too long"
done
[ "$(printf '%s\n' "${app_ids[@]}" | sort -u | wc -l)" -eq "${#app_ids[@]}" ] || fail "has duplicate apps"
products=${REVENUECAT_PRODUCTS_JSON:-}
catalog=$(printf '%s' "$products" | jq -ce '
  select(type == "object" and length > 0 and length <= 32)
  | select(all(to_entries[];
      (.key | test("^[A-Za-z0-9_.:-]+$")) and (.key | length <= 256) and
      (.value | type == "object") and
      (.value | keys == ["Entitlement", "Store"]) and
      (.value.Store == "play_store" or .value.Store == "app_store") and
      (.value.Entitlement == "dzeroth_pro" or .value.Entitlement == "premium_access" or .value.Entitlement == "plus_access")))
') || fail "catalog is missing or invalid"
secret_args=()
for name in REVENUECAT_SECRET_API_KEY REVENUECAT_WEBHOOK_AUTHORIZATION REVENUECAT_WEBHOOK_SIGNING_SECRET; do
  ref_name=${name}_REF
  ref=${!ref_name:-}
  [[ $ref =~ ^[A-Za-z0-9_-]+:[1-9][0-9]*$ ]] || fail "requires pinned secret references"
  secret_args+=("$name=$ref")
done
secret_list=$(IFS=,; printf '%s' "${secret_args[*]}")
printf '%s\0' \
  "--update-env-vars=^|^BILLING_WEBHOOK_ENABLED=true|BILLING_SANDBOX_ENABLED=false|BILLING_PURCHASES_ENABLED=$sales|REVENUECAT_PURCHASE_ENVIRONMENT=$environment|REVENUECAT_WEBHOOK_APP_IDS=$apps|REVENUECAT_PRODUCTS_JSON=$catalog" \
  "--update-secrets=$secret_list"
