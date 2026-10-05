#!/usr/bin/env bash
# Block Terraform that adds fixed-monthly-cost resources unless the line is marked
#   # cost-approved: ADR-NNNN
# Exit 2 = block with message to Claude. Never blocks non-Terraform files.
. "${0%/*}/lib.sh" || exit 2
require_jq
input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
case "$f" in *.tf|*.tf.json|*.tfvars) ;; *) exit 0 ;; esac

text=$(printf '%s' "$input" | jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits // [] | .[].new_string)] | map(select(. != null)) | join("\n")')

pattern='resource[[:space:]]+"(google_container_cluster|google_container_node_pool|google_spanner_instance|google_redis_instance|google_redis_cluster|google_memorystore_[a-z_]+|google_sql_database_instance|google_alloydb_[a-z_]+|google_compute_instance|google_compute_instance_template|google_compute_global_forwarding_rule|google_compute_forwarding_rule|google_compute_security_policy|google_compute_router_nat|google_vpc_access_connector|google_kms_crypto_key|google_clouddeploy_[a-z_]+|google_filestore_instance|google_vertex_ai_[a-z_]+|google_discovery_engine_[a-z_]+|google_dataflow_[a-z_]+|google_composer_environment|google_compute_address|google_compute_global_address|google_compute_vpn_gateway|google_compute_ha_vpn_gateway|google_compute_url_map|google_compute_target_https_proxy|google_dns_managed_zone|google_pubsub_lite_[a-z_]+|google_bigtable_instance|google_dataproc_cluster)"'

hits=$(printf '%s\n' "$text" | grep -nE "$pattern" | grep -v 'cost-approved: ADR-[0-9]\{4\}')
mins=$(printf '%s\n' "$text" | grep -nE '(min_instance_count|min_instances)[[:space:]]*=[[:space:]]*[1-9]' | grep -v 'cost-approved: ADR-[0-9]\{4\}')

if [ -n "$hits$mins" ]; then
  {
    echo "cost-guard: fixed-monthly-cost infrastructure blocked in $f:"
    [ -n "$hits" ] && printf '%s\n' "$hits"
    [ -n "$mins" ] && printf '%s\n' "$mins"
    echo "Stage 0 is free-tier only (see CLAUDE.md and the free-tier-budget skill)."
    echo "If this is intended, the architect must write an ADR with a Cost impact section, the human must accept it,"
    echo "and the resource line must carry the comment:  # cost-approved: ADR-NNNN"
  } >&2
  exit 2
fi
exit 0
