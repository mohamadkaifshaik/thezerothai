#!/usr/bin/env bash
# Produce Flutter's JSON defines file from the same catalog used by the API.
set -euo pipefail
case ${BILLING_CONFIG_ENABLED:-false} in
  false) echo '{}'; exit 0 ;;
  true) ;;
  *) echo 'Invalid billing opt-in' >&2; exit 2 ;;
esac
case $1 in
  android) store=play_store; prefix=goog_ ;;
  ios) store=app_store; prefix=appl_ ;;
  *) exit 2 ;;
esac
catalog=$(jq -ce --arg store "$store" '
  select(type == "object" and length > 0)
  | with_entries(select(.value.Store == $store and .value.Entitlement == "plus_access")
    | .value = "plus")
' <<< "${REVENUECAT_PRODUCTS_JSON:?Missing production catalog}")
if [[ "$catalog" == '{}' && -z ${REVENUECAT_PUBLIC_API_KEY:-} ]]; then
  echo '{"BILLING_STATUS_ENABLED":"true"}'
  exit 0
fi
if [[ $(jq 'length' <<< "$catalog") != 1 || ! ${REVENUECAT_PUBLIC_API_KEY:-} =~ ^${prefix}[a-zA-Z0-9_]+$ ]]; then
  echo "Configure matching products and a public SDK key for $store" >&2
  exit 2
fi
jq -n --arg catalog "$catalog" --arg key "$REVENUECAT_PUBLIC_API_KEY" \
  '{BILLING_STATUS_ENABLED:"true", REVENUECAT_MONTHLY_PRODUCTS_JSON:$catalog, REVENUECAT_PUBLIC_API_KEY:$key}'
