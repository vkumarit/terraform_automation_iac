#!/bin/bash
set -euo pipefail

# ==========================
# CONFIG
# ==========================
REPO="your-org/your-repo"        # 🔴 CHANGE THIS
COMMAND="$1"                    # init | plan | apply
LOG_FILE="terraform-${COMMAND}.log"

TOKEN="${GITHUB_TOKEN}"
COMMIT_SHA="$(git rev-parse HEAD)"

# ==========================
# RUN TERRAFORM
# ==========================
echo "Running terraform ${COMMAND}..."

if [[ "$COMMAND" == "init" ]]; then
  terraform init -no-color > "$LOG_FILE" 2>&1 || true
elif [[ "$COMMAND" == "plan" ]]; then
  terraform plan -no-color -out=tfplan.binary > "$LOG_FILE" 2>&1 || true
elif [[ "$COMMAND" == "apply" ]]; then
  terraform apply -no-color -auto-approve tfplan.binary > "$LOG_FILE" 2>&1 || true
else
  echo "Unknown command: $COMMAND"
  exit 1
fi

# ==========================
# CREATE GITHUB CHECK RUN
# ==========================
CHECK_RUN_ID=$(
  curl -s -X POST "https://api.github.com/repos/${REPO}/check-runs" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    -d "{
      \"name\": \"Terraform ${COMMAND^}\",
      \"head_sha\": \"${COMMIT_SHA}\",
      \"status\": \"in_progress\"
    }" | grep -oP '"id":\K[0-9]+'
)

echo "GitHub Check Run ID: ${CHECK_RUN_ID}"

# ==========================
# PARSE ERRORS → ANNOTATIONS
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
END {}
' "$LOG_FILE" >> annotations.json

echo "]" >> annotations.json

# ==========================
# DETERMINE RESULT
# ==========================
if grep -q '"annotation_level":"failure"' annotations.json; then
  CONCLUSION="failure"
  SUMMARY="Terraform ${COMMAND^} failed"
else
  CONCLUSION="success"
  if [[ "$COMMAND" == "plan" ]]; then
    SUMMARY=$(grep -E "Plan:|No changes" "$LOG_FILE" | head -n1 || echo "Terraform Plan successful")
  else
    SUMMARY="Terraform ${COMMAND^} successful"
  fi
fi

# ==========================
# COMPLETE CHECK RUN
# ==========================
curl -s -X PATCH "https://api.github.com/repos/${REPO}/check-runs/${CHECK_RUN_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  -d "{
    \"status\": \"completed\",
    \"conclusion\": \"${CONCLUSION}\",
    \"output\": {
      \"title\": \"Terraform ${COMMAND^}\",
      \"summary\": \"${SUMMARY}\",
      \"annotations\": $(cat annotations.json)
    }
  }"

echo "Terraform ${COMMAND} → GitHub Checks updated"

