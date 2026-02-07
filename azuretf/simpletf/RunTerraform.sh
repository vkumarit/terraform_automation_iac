#!/bin/bash
set -u
set -o pipefail

# ==========================
# CONFIG
# ==========================
REPO="vkumarit/terraform_automation_iac"
COMMAND="$1"
LOG_FILE="terraform-${COMMAND}.log"

TOKEN="${GITHUB_TOKEN}"
COMMIT_SHA="$(git rev-parse HEAD)"

echo "Running terraform ${COMMAND}..."

# ==========================
# RUN TERRAFORM (NON-FATAL)
# ==========================
TF_EXIT=0

if [[ "$COMMAND" == "init" ]]; then
  terraform init -no-color > "$LOG_FILE" 2>&1 || TF_EXIT=$?
elif [[ "$COMMAND" == "plan" ]]; then
  terraform plan -no-color -out=tfplan.binary > "$LOG_FILE" 2>&1 || TF_EXIT=$?
elif [[ "$COMMAND" == "apply" ]]; then
  terraform apply -no-color -auto-approve tfplan.binary > "$LOG_FILE" 2>&1 || TF_EXIT=$?
else
  echo "Unknown command: $COMMAND"
  exit 1
fi

# ==========================
# CREATE CHECK RUN
# ==========================
CHECK_RUN_ID=$(
  curl -s -X POST "https://api.github.com/repos/${REPO}/check-runs" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "{
      \"name\": \"Terraform ${COMMAND^}\",
      \"head_sha\": \"${COMMIT_SHA}\",
      \"status\": \"in_progress\"
    }" | jq -r '.id'
)

# ==========================
# PARSE ERRORS
# ==========================
echo "[" > annotations.json
FIRST=1

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
    if(!first) printf(",")
    printf("{\"path\":\"%s\",\"start_line\":%s,\"end_line\":%s,\"annotation_level\":\"failure\",\"message\":\"%s\",\"title\":\"Terraform Error\"}", file, line, line, err)
    first=0
  }
  err=""; file=""; line=""
}
BEGIN { first=1 }
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
# COMPLETE CHECK
# ==========================
curl -s -X PATCH "https://api.github.com/repos/${REPO}/check-runs/${CHECK_RUN_ID}" \
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
