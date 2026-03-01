#!/bin/bash
# Tells the system to run this script using bash

set -euo pipefail
# -e  → Exit immediately if any command fails
# -u  → Exit if using an undefined variable
# -o pipefail → If any command in a pipeline fails, the whole pipeline fails
# This makes the script strict and production-safe

REPO="vkumarit/terraform_automation_iac"
# GitHub repository where logs will be pushed

COMMAND="${1:-}"
# First argument passed to script (init|plan|apply)
# ${1:-} means: use $1, or empty if not provided

TOKEN="${GITHUB_TOKEN:-}"
# Reads GitHub token from environment variable
# If not set, becomes empty

if [[ -z "$COMMAND" ]]; then
  # If COMMAND is empty
  echo "ERROR: No command provided (init|plan|apply)"
  exit 1
fi
# Ensures script is always called with an argument

COMMIT_SHA="$(git rev-parse HEAD)"
# Gets current commit hash of checked-out repo

ROOT_DIR="$(git rev-parse --show-toplevel)"
# Gets absolute path of repository root directory

CURRENT_BRANCH="$(git branch --show-current || true)"
# Gets current branch name
# || true prevents failure if in detached HEAD state

LOG_ROOT="${ROOT_DIR}/.terraform-run-logs/${COMMIT_SHA}"
mkdir -p "$LOG_ROOT"
LOG_FILE="${LOG_ROOT}/terraform-${COMMAND}.log"
# Log file name per command
# Example: terraform-init.log

WORK_DIR="$(pwd)"
# Capture original working directory.
TF_EXIT=0
# Variable to store Terraform exit code

echo "========================================="
echo "Running terraform ${COMMAND}"
echo "Commit: ${COMMIT_SHA}"
echo "Branch: ${CURRENT_BRANCH:-DETACHED}"
echo "========================================="
# Prints useful debug info in pipeline logs

# ==========================================
# RUN TERRAFORM
# ==========================================

#cd azuretf/simpletf - remove if pipeline working good
# Move into Terraform working directory

if [[ "$COMMAND" == "init" ]]; then

  set +e
  # Temporarily disable exit-on-error
  # So we can capture terraform exit code manually

  terraform init -parallelism=5 -no-color -lock-timeout=5m 2>&1 | tee "$LOG_FILE"
  # Run terraform init
  # -parallelism=5 > reduce memory usage
  # -no-color removes ANSI colors
  # -lock-timeout waits up to 5 minutes for backend lock
  # 2>&1 sends stderr to stdout
  # tee writes output to file AND prints to console

  TF_EXIT=${PIPESTATUS[0]}
  # Capture actual terraform exit code (not tee exit code)

  if [[ "$TF_EXIT" -ne 0 ]]; then
    echo "FAILED" > "${LOG_ROOT}/init.status"
  else
    echo "SUCCEEDED" > "${LOG_ROOT}/init.status"
  fi
  # .status writing
  
  set -e
  # Re-enable strict error mode

elif [[ "$COMMAND" == "plan" ]]; then

  set +e

  echo "Pre-check: verifying backend state access..."
  terraform state pull > /dev/null 2>&1
  if [[ $? -ne 0 ]]; then
  #Or 
  #if ! terraform state pull > /dev/null 2>&1; then
    echo "ERROR: Cannot access remote state. It may be locked or backend unreachable."
    TF_EXIT=1
  else
    echo "Backend reachable. Running terraform plan..."
  
    terraform plan -parallelism=5 -no-color -detailed-exitcode -lock-timeout=10m -out=tfplan.binary 2>&1 | tee "$LOG_FILE"
    # -parallelism=5 > reduce memory usage
    # -detailed-exitcode:
    #   0 > no changes
    #   1 > error
    #   2 > changes present

    TF_EXIT=${PIPESTATUS[0]}

    # If changes detected (exit 2), treat as success
    if [[ "$TF_EXIT" -eq 2 ]]; then
    TF_EXIT=0
    fi
  fi
  
  if [[ "$TF_EXIT" -ne 0 ]]; then
    echo "FAILED" > "${LOG_ROOT}/plan.status"
  else
    echo "SUCCEEDED" > "${LOG_ROOT}/plan.status"
  fi
  # .status writing
  
  set -e

elif [[ "$COMMAND" == "apply" ]]; then

  set +e

  terraform apply -parallelism=5 -no-color -auto-approve -lock-timeout=10m tfplan.binary 2>&1 | tee "$LOG_FILE"
  # -parallelism=5 > reduce memory usage
  # -auto-approve skips confirmation
  # Uses previously generated plan file

  TF_EXIT=${PIPESTATUS[0]}

  if [[ "$TF_EXIT" -ne 0 ]]; then
    echo "FAILED" > "${LOG_ROOT}/apply.status"
  else
    echo "SUCCEEDED" > "${LOG_ROOT}/apply.status"
  fi
  # .status writing
  
  set -e

  if [[ "$TF_EXIT" -eq 0 ]]; then
    terraform output -json > "${LOG_ROOT}/outputs.json" 2>/dev/null || true
  fi
  # If apply succeeded, export outputs to JSON file

else
  echo "Unknown command: $COMMAND"
  exit 1
fi

# ------------------------------------------
# Create summary file for logs
# ------------------------------------------
LOG_ROOT="${ROOT_DIR}/.terraform-run-logs/${COMMIT_SHA}"

INIT_STATUS=$(cat "${LOG_ROOT}/init.status" 2>/dev/null || echo "INIT SKIPPED")
PLAN_STATUS=$(cat "${LOG_ROOT}/plan.status" 2>/dev/null || echo "PLAN SKIPPED")
APPLY_STATUS=$(cat "${LOG_ROOT}/apply.status" 2>/dev/null || echo "APPLY SKIPPED")

{
  echo "========================================="
  echo "Terraform Run Summary"
  echo "---------------------"
  echo "Commit : ${COMMIT_SHA}"
  echo ""
  echo "INIT  : ${INIT_STATUS}"
  echo "PLAN  : ${PLAN_STATUS}"
  echo "APPLY : ${APPLY_STATUS}"
  echo "========================================="
} > "${LOG_ROOT}/summary.txt"

echo "Summary file created."

# ------------------------------------------
# Commit and push logs
# ------------------------------------------
set +e   # temporarily disable exit-on-error

TMP_DIR=$(mktemp -d)
echo "Cloning terraform-logs branch..."

git clone --branch terraform-logs \
  "https://${GITHUB_TOKEN}@github.com/${REPO}.git" \
  "$TMP_DIR" 2>/dev/null || {
    git clone "https://${GITHUB_TOKEN}@github.com/${REPO}.git" "$TMP_DIR"
    cd "$TMP_DIR"
    git checkout -b terraform-logs
  }

cd "$TMP_DIR"

mkdir -p "runs/${COMMIT_SHA}"
cp -r "${LOG_ROOT}/"* "runs/${COMMIT_SHA}/"

git add runs/
git commit -m "Terraform full run logs for ${COMMIT_SHA}" >/dev/null 2>&1 || echo "Nothing to commit"
git push origin terraform-logs

rm -rf "$TMP_DIR"
echo "Terraform logs pushed successfully."

set -e   # re-enable strict error handling

exit "$TF_EXIT"
# Exit script with terraform’s actual exit code
# This makes Azure DevOps mark pipeline correctly