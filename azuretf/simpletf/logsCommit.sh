#!/bin/bash

set -euo pipefail

echo "========================================="
echo "Starting Terraform Logs Push"
echo "========================================="

# ------------------------------------------
# Validate token
# ------------------------------------------
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN not set"
  exit 0
fi

# ------------------------------------------
# Basic variables
# ------------------------------------------
COMMIT_SHA="$(git rev-parse HEAD)"
REPO="vkumarit/terraform_automation_iac"
LOG_ROOT=".terraform-run-logs/${COMMIT_SHA}"

echo "Commit SHA: ${COMMIT_SHA}"
echo "Log directory: ${LOG_ROOT}"

# ------------------------------------------
# Ensure logs exist
# ------------------------------------------
if [[ ! -d "${LOG_ROOT}" ]]; then
  echo "No logs directory found. Nothing to push."
  exit 0
fi

# ------------------------------------------
# Create summary file
# ------------------------------------------
INIT_STATUS=$(cat "${LOG_ROOT}/init.status" 2>/dev/null || echo "INIT SKIPPED")
PLAN_STATUS=$(cat "${LOG_ROOT}/plan.status" 2>/dev/null || echo "PLAN SKIPPED")
APPLY_STATUS=$(cat "${LOG_ROOT}/apply.status" 2>/dev/null || echo "APPLY SKIPPED")

{
  echo "Terraform Run Summary"
  echo "---------------------"
  echo "Commit : ${COMMIT_SHA}"
  echo ""
  echo "INIT  : ${INIT_STATUS}"
  echo "PLAN  : ${PLAN_STATUS}"
  echo "APPLY : ${APPLY_STATUS}"
} > "${LOG_ROOT}/summary.txt"

echo "Summary file created."

# ------------------------------------------
# Clone terraform-logs branch
# ------------------------------------------
TMP_DIR="$(mktemp -d)"

echo "Cloning terraform-logs branch..."

git clone --branch terraform-logs \
  "https://${GITHUB_TOKEN}@github.com/${REPO}.git" \
  "${TMP_DIR}" 2>/dev/null || {
    git clone "https://${GITHUB_TOKEN}@github.com/${REPO}.git" "${TMP_DIR}"
    cd "${TMP_DIR}"
    git checkout -b terraform-logs
  }

cd "${TMP_DIR}"

# ------------------------------------------
# Copy logs into runs/<commit>
# ------------------------------------------
mkdir -p "runs/${COMMIT_SHA}"

cp -r "${BUILD_SOURCESDIRECTORY}/${LOG_ROOT}/"* "runs/${COMMIT_SHA}/"

# ------------------------------------------
# Commit and push (single commit)
# ------------------------------------------
git add runs/

git commit -m "Terraform full run logs for ${COMMIT_SHA}" >/dev/null 2>&1 || {
  echo "Nothing new to commit."
}

git push origin terraform-logs

echo "Logs pushed successfully in single commit."

# ------------------------------------------
# Cleanup
# ------------------------------------------
cd /
rm -rf "${TMP_DIR}"

echo "Finished."
echo "========================================="
