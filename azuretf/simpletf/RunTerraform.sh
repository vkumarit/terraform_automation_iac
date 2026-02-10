#!/bin/bash
set -u
set -o pipefail

# ==========================
# HARDENING / MEMORY CONTROL
# ==========================
export TF_CLI_ARGS_plan="-parallelism=5"
export TF_CLI_ARGS_apply="-parallelism=5"

export TF_PLUGIN_CACHE_DIR="$PWD/.terraform-plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

# ==========================
# CONFIG
# ==========================
REPO="vkumarit/terraform_automation_iac"
COMMAND="$1"
LOG_FILE="terraform-${COMMAND}.log"

TOKEN="${GITHUB_TOKEN}"
COMMIT_SHA="$(git rev-parse HEAD)"

command -v jq >/dev/null 2>&1 || {
  echo "jq is required but not installed"
  exit 2
}

# ==========================
# CREATE CHECK RUN EARLY
# ==========================
CHECK_RUN_ID=$(
  curl -sf -X POST "https://api.github.com/repos/${REPO}/check-runs" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "{
      \"name\": \"Terraform ${COMMAND^}\",
      \"head_sha\": \"${COMMIT_SHA}\",
      \"status\": \"in_progress\"
    }" | jq -r '.id'
)

if [[ -z "$CHECK_RUN_ID" || "$CHECK_RUN_ID" == "null" ]]; then
  echo "Failed to create GitHub Check Run"
  exit 3
fi

# ==========================
# RUN TERRAFORM
# ==========================
TF_EXIT=0

if [[ "$COMMAND" == "init" ]]; then
  if compgen -G "$TF_PLUGIN_CACHE_DIR/*" > /dev/null; then
    terraform init -no-color -plugin-dir="$TF_PLUGIN_CACHE_DIR" \
      > "$LOG_FILE" 2>&1 || TF_EXIT=$?
  else
    terraform init -no-color \
      > "$LOG_FILE" 2>&1 || TF_EXIT=$?
  fi

elif [[ "$COMMAND" == "plan" ]]; then
  terraform plan -no-color -out=tfplan.binary \
    > "$LOG_FILE" 2>&1 || TF_EXIT=$?

elif [[ "$COMMAND" == "apply" ]]; then
  terraform apply -no-color -auto-approve tfplan.binary \
    > "$LOG_FILE" 2>&1 || TF_EXIT=$?

else
  echo "Unknown command: $COMMAND"
  TF_EXIT=1
fi

# ==========================
# PARSE ERRORS → ANNOTATIONS (max 50)
# ==========================
echo "[" > annotations.json

awk '
/│ Error:/ {
  err=$0
  gsub(/.*Error: /,"",err)
}
/on .* line [0-9]+/ {
  match($0,/on ([^ ]+) line ([0-9]+)/,m)
  file=m[1]; line=m[2]
}
/╵/ {
  if(err!="") {
    if(count < 50) {
      if(count > 0) printf(",")
      printf("{\"path\":\"%s\",\"start_line\":%s,\"end_line\":%s,\"annotation_level\":\"failure\",\"message\":\"%s\",\"title\":\"Terraform Error\"}", file, line, line, err)
    }
    count++
  }
  err=""; file=""; line=""
}
BEGIN { count=0 }
' "$LOG_FILE" >> annotations.json

echo "]" >> annotations.json

# ==========================
# DECIDE RESULT
# ==========================
if [[ "$TF_EXIT" -ne 0 ]]; then
  CONCLUSION="failure"
  SUMMARY="Terraform ${COMMAND^} failed"
else
  CONCLUSION="success"
  SUMMARY="Terraform ${COMMAND^} succeeded"
fi

# ==========================
# COMPLETE CHECK RUN
# ==========================
curl -sf -X PATCH "https://api.github.com/repos/${REPO}/check-runs/${CHECK_RUN_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "{
    \"status\": \"completed\",
    \"conclusion\": \"${CONCLUSION}\",
    \"output\": {
      \"title\": \"Terraform ${COMMAND^}\",
      \"summary\": \"${SUMMARY}\",
      \"annotations\": $(cat annotations.json)
    }
  }"

exit "$TF_EXIT"
