#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../billing-config.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export BILLING_CONFIG_ENABLED=false
bash "$script" > "$work/args"
[ ! -s "$work/args" ] || { echo "disabled billing changed candidate configuration" >&2; exit 1; }
export BILLING_CONFIG_ENABLED=true
export BILLING_PURCHASES_ENABLED=false
export REVENUECAT_PURCHASE_ENVIRONMENT=SANDBOX
export REVENUECAT_WEBHOOK_APP_IDS=app-play-fixture
export REVENUECAT_PRODUCTS_JSON='{"premium:monthly":{"Store":"play_store","Entitlement":"dzeroth_pro"}}'
export REVENUECAT_SECRET_API_KEY_REF=rc-api-key:1
export REVENUECAT_WEBHOOK_AUTHORIZATION_REF=rc-webhook-auth:2
export REVENUECAT_WEBHOOK_SIGNING_SECRET_REF=rc-webhook-signing:3
bash "$script" > "$work/args"
tr '\0' '\n' < "$work/args" > "$work/text"
[ "$(wc -l < "$work/text")" -eq 2 ]
grep -qF 'BILLING_PURCHASES_ENABLED=false' "$work/text"
grep -qF 'REVENUECAT_PURCHASE_ENVIRONMENT=SANDBOX' "$work/text"
grep -qF 'REVENUECAT_SECRET_API_KEY=rc-api-key:1' "$work/text"
export BILLING_PURCHASES_ENABLED=true REVENUECAT_PURCHASE_ENVIRONMENT=PRODUCTION
bash "$script" > "$work/args"
tr '\0' '\n' < "$work/args" > "$work/text"
grep -qF 'BILLING_PURCHASES_ENABLED=true' "$work/text"
grep -qF 'REVENUECAT_PURCHASE_ENVIRONMENT=PRODUCTION' "$work/text"
reject() {
  if bash "$script" > "$work/args" 2> "$work/error"; then
    echo "invalid billing configuration was accepted" >&2
    exit 1
  fi
  [ ! -s "$work/args" ] || { echo "invalid configuration emitted deployment arguments" >&2; exit 1; }
}
REVENUECAT_SECRET_API_KEY_REF=rc-api-key:latest reject
REVENUECAT_WEBHOOK_APP_IDS='app-play-fixture,app-play-fixture' reject
REVENUECAT_PURCHASE_ENVIRONMENT=local reject
BILLING_PURCHASES_ENABLED=on reject
REVENUECAT_PRODUCTS_JSON='{"monthly":{"Store":"test_store","Entitlement":"dzeroth_pro"}}' reject
REVENUECAT_PRODUCTS_JSON='{"premium:monthly":{"Store":"play_store","Entitlement":"unknown"}}' reject
REVENUECAT_PRODUCTS_JSON='{"premium|monthly":{"Store":"play_store","Entitlement":"dzeroth_pro"}}' reject
REVENUECAT_PRODUCTS_JSON='{"premium:monthly":{"Store":"play_store","Entitlement":"dzeroth_pro","extra":"|BILLING_PURCHASES_ENABLED=true"}}' reject
echo "billing candidate configuration fixtures passed"
