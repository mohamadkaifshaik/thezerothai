#!/usr/bin/env bash
# Compare the configured mobile origin with the canonical URL of the staged service.
set -euo pipefail
if [[ ! $1 =~ ^https://[a-z0-9-]+([.][a-z0-9-]+)*[.]run[.]app$ || ${PROD_API_BASE_URL:-} != "$1" ]]; then
  echo "Mobile API origin must match the production Cloud Run service URL." >&2
  exit 1
fi
