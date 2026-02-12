#!/bin/bash
set -euo pipefail

REPO="vkumarit/terraform_automation_iac"
COMMAND="${1:-}"
TOKEN="${GITHUB_TOKEN:-}"

if [[ -z "$COMMAND" ]]; then
  echo "ERROR: No command provided (init|plan|apply)"
  exit 1
fi

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: GITHUB_TOKEN is not set"
  exit 1
fi

COMMIT_SHA="$(git rev-parse HEAD)"
ROOT_DIR="$(git rev-parse --show-toplevel)"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

LOG_FILE="terraform-${COMMAND}.log"
TF_EXIT=0

echo "Running terraform ${COMMAND}..."
echo "Commit: ${COMMIT_SHA}"
echo "Branch: ${CURRENT_BRANCH}"

# ==========================
# RUN TERRAFORM
# ==========================
if [[ "$COMMAND" == "init" ]]; then

  terraform init -no-color > "$LOG_FILE" 2>&1
  TF_EXIT=$?

elif [[ "$COMMAND" == "plan" ]]; then

  # detailed exit codes:
  # 0 = no changes
  # 1 = error
  # 2 = changes present (NOT failure)
  terraform plan -no-color -detailed-exitcode -out=tfplan.binary > "$LOG_FILE" 2>&1
  TF_EXIT=$?

  if [[ "$TF_EXIT" -eq 1 ]]; then
    echo "Terraform plan FAILED"
    exit 1
  fi

  # treat 0 and 2 as success
  echo "Terraform plan completed (exit code: $TF_EXIT)"
  exit 0

elif [[ "$COMMAND" == "apply" ]]; then

  terraform apply -no-color -auto-approve tfplan.binary > "$LOG_FILE" 2>&1
  TF_EXIT=$?

else
  echo "Unknown command: $COMMAND"
  exit 1
fi

# Stop here unless APPLY
if [[ "$COMMAND" != "apply" ]]; then
  exit "$TF_EXIT"
fi

# ==========================
# CAPTURE OUTPUTS (if success)
# ==========================
if [[ "$TF_EXIT" -eq 0 ]]; then
  terraform output -json > outputs.json 2>/dev/null || true
fi

# ==========================
# MOVE TO ROOT FOR GIT OPS
# ==========================
cd "$ROOT_DIR"

git config user.email "signinvipin@gmail.com"
git config user.name "signinvipin"

git fetch origin || true

if git show-ref --verify --quiet refs/remotes/origin/terraform-logs; then
  git checkout -B terraform-logs origin/terraform-logs
else
  git checkout --orphan terraform-logs
  git rm -rf . >/dev/null 2>&1 || true
fi

RUN_DIR="runs/${COMMIT_SHA}"
mkdir -p "$RUN_DIR"

# Copy logs
cp azuretf/simpletf/*.log "$RUN_DIR/" 2>/dev/null || true
cp azuretf/simpletf/outputs.json "$RUN_DIR/" 2>/dev/null || true

# Create summary
if [[ "$TF_EXIT" -ne 0 ]]; then
  echo "Terraform Apply FAILED" > "$RUN_DIR/summary.txt"
else
  echo "Terraform Apply SUCCEEDED" > "$RUN_DIR/summary.txt"
fi

# Only commit if changes exist
if [[ -n "$(git status --porcelain)" ]]; then
  git add .
  git commit -m "Terraform logs for ${COMMIT_SHA}"
  git push https://x-access-token:${TOKEN}@github.com/${REPO}.git terraform-logs
else
  echo "No changes to commit on terraform-logs branch."
fi

# ==========================
# RETURN TO ORIGINAL BRANCH
# ==========================
git checkout "$CURRENT_BRANCH"

# ==========================
# POST COMMIT COMMENT
# ==========================
if [[ "$TF_EXIT" -ne 0 ]]; then
  MESSAGE="❌ Terraform Apply FAILED

Logs available:
https://github.com/${REPO}/tree/terraform-logs/runs/${COMMIT_SHA}"
else
  MESSAGE="✅ Terraform Apply SUCCEEDED

Logs and outputs available:
https://github.com/${REPO}/tree/terraform-logs/runs/${COMMIT_SHA}"
fi

# Escape newlines safely
JSON_PAYLOAD=$(printf '{"body":"%s"}' "$(echo "$MESSAGE" | sed ':a;N;$!ba;s/\n/\\n/g')")

curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/${REPO}/commits/${COMMIT_SHA}/comments \
  -d "$JSON_PAYLOAD" >/dev/null || true

exit "$TF_EXIT"
