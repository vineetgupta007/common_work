#!/usr/bin/env bash
#
# Azure CLI equivalent of Get-EntraScopeIds.ps1
#
# Enumerates management groups and subscriptions for a tenant, and prints
# managementGroupIds / subscriptionIds JSON following the "management group
# preferred, subscriptions only as fallback" rule.
#
# Requires: az cli, logged in with `az login --tenant <tenant-id>` first
#           (or pass --tenant-id below and this script will do it for you).
#
# Usage:
#   ./get-entra-scope-ids.sh <tenant-id> [--subscriptions-only]

set -euo pipefail

TENANT_ID="${1:?Usage: $0 <tenant-id> [--subscriptions-only]}"
SUBS_ONLY="${2:-}"

echo "Logging in to tenant ${TENANT_ID}..." >&2
az login --tenant "${TENANT_ID}" --only-show-errors >/dev/null

echo "Enumerating subscriptions..." >&2
SUB_IDS_JSON=$(az account list --query "[?state=='Enabled'].id" -o json)
echo "  Found $(echo "${SUB_IDS_JSON}" | jq 'length') enabled subscription(s)" >&2

MG_IDS_JSON="[]"

if [[ "${SUBS_ONLY}" != "--subscriptions-only" ]]; then
  echo "Checking for the Tenant Root Management Group (ID == Tenant ID)..." >&2
  if az account management-group show --name "${TENANT_ID}" --only-show-errors >/dev/null 2>&1; then
    echo "  Tenant Root Management Group is visible — this single ID covers the whole tenant." >&2
    MG_IDS_JSON=$(jq -n --arg id "${TENANT_ID}" '[$id]')
  else
    echo "  Tenant Root Management Group not visible to this identity." >&2
    echo "  (Needs Management Group Reader at root scope — typically granted via" >&2
    echo "   Entra ID 'Elevate access', or by an existing root MG owner.)" >&2
    echo "  Falling back to whatever management groups ARE visible..." >&2

    ALL_MGS=$(az account management-group list --only-show-errors -o json 2>/dev/null || echo "[]")
    MG_COUNT=$(echo "${ALL_MGS}" | jq 'length')

    if [[ "${MG_COUNT}" -gt 0 ]]; then
      echo "  Management group(s) visible to this identity:" >&2
      echo "${ALL_MGS}" | jq -r '.[] | "    - \(.name)  (\(.displayName))"' >&2
      echo "  NOTE: az cli's flat list doesn't show parent/child relationships directly —" >&2
      echo "  verify in the portal (Management Groups blade) which of these are truly" >&2
      echo "  top-level before using one as your single scope." >&2
      MG_IDS_JSON=$(echo "${ALL_MGS}" | jq '[.[].name]')
    else
      echo "  No management groups visible. Falling back to subscriptionIds." >&2
    fi
  fi
fi

# Apply "management group preferred, subscriptions only if none" rule
MG_COUNT_FINAL=$(echo "${MG_IDS_JSON}" | jq 'length')
if [[ "${MG_COUNT_FINAL}" -gt 0 ]]; then
  FINAL_SUB_IDS="[]"
else
  FINAL_SUB_IDS="${SUB_IDS_JSON}"
fi

echo "" >&2
echo "=== Config JSON ===" >&2
jq -n \
  --argjson mg "${MG_IDS_JSON}" \
  --argjson subs "${FINAL_SUB_IDS}" \
  '{managementGroupIds: $mg, subscriptionIds: $subs}'
