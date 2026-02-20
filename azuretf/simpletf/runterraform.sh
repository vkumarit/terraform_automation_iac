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

LOG_FILE="terraform-${COMMAND}.log"
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
# ALWAYS PUSH LOGS FUNCTION
# ==========================================
push_logs() {
# This function runs automatically when script exits
# (because of trap below)

  echo "Pushing logs safely..."

  # Never allow logging failure to break Terraform result
  set +e
  
  if [[ -z "$TOKEN" ]]; then
    echo "ERROR: GITHUB_TOKEN not set"
    return 0
  fi
  # Prevents weird git clone failures if token is empty.
  
  TMP_DIR=$(mktemp -d)
  
  # Clone repo and ensure terraform-logs branch exists
  git clone --branch terraform-logs \
    https://${TOKEN}@github.com/${REPO}.git "$TMP_DIR" \
    2>/dev/null || {
      git clone https://${TOKEN}@github.com/${REPO}.git "$TMP_DIR"
      cd "$TMP_DIR" || exit 0
      git checkout -b terraform-logs
    }

  # Move into the cloned repo
  cd "$TMP_DIR" || return 0

  mkdir -p "$TMP_DIR/runs/${COMMIT_SHA}/${COMMAND}"

  cp "${WORK_DIR}/${LOG_FILE}" "$TMP_DIR/runs/${COMMIT_SHA}/${COMMAND}/terraform-${COMMAND}.log"

  if [[ "$TF_EXIT" -ne 0 ]]; then
    echo "${COMMAND} FAILED" > "$TMP_DIR/runs/${COMMIT_SHA}/${COMMAND}/summary.txt"
  else
    echo "${COMMAND} SUCCEEDED" > "$TMP_DIR/runs/${COMMIT_SHA}/${COMMAND}/summary.txt"
  fi
  
  git add runs/
  
  # Commit safely — don't fail if nothing to commit
  git commit -m "Terraform ${COMMAND} logs for ${COMMIT_SHA}" >/dev/null 2>&1 || echo "Nothing to commit"
  
  # Push safely — ignore any errors so Terraform result is not blocked
  git push origin terraform-logs >/dev/null 2>&1 || echo "WARNING: Failed to push logs"

  cd "$ROOT_DIR" || return 0
  rm -rf "$TMP_DIR"
  
  echo "Log push attempt finished (non-blocking)."
  
  # Restore default error behavior
  set -e
}


trap push_logs EXIT
# VERY IMPORTANT:
# Whenever the script exits (success OR failure),
# automatically run push_logs()

# ==========================================
# RUN TERRAFORM
# ==========================================

#cd azuretf/simpletf - remove if pipeline working good
# Move into Terraform working directory

if [[ "$COMMAND" == "init" ]]; then

  set +e
  # Temporarily disable exit-on-error
  # So we can capture terraform exit code manually

  terraform init -no-color -lock-timeout=5m 2>&1 | tee "$LOG_FILE"
  # Run terraform init
  # -no-color removes ANSI colors
  # -lock-timeout waits up to 5 minutes for backend lock
  # 2>&1 sends stderr to stdout
  # tee writes output to file AND prints to console

  TF_EXIT=${PIPESTATUS[0]}
  # Capture actual terraform exit code (not tee exit code)

  set -e
  # Re-enable strict error mode

elif [[ "$COMMAND" == "plan" ]]; then

  set +e

  echo "Pre-check: verifying backend state access..."
  terraform state pull > /dev/null 2>&1

  if [[ $? -ne 0 ]]; then
    echo "ERROR: Cannot access remote state. It may be locked or backend unreachable."
    TF_EXIT=1
  else
    echo "Backend reachable. Running terraform plan..."
  
    terraform plan -no-color -detailed-exitcode -lock-timeout=10m -out=tfplan.binary 2>&1 | tee "$LOG_FILE"
    # -detailed-exitcode:
    #   0 → no changes
    #   1 → error
    #   2 → changes present

    TF_EXIT=${PIPESTATUS[0]}

    # If changes detected (exit 2), treat as success
    if [[ "$TF_EXIT" -eq 2 ]]; then
    TF_EXIT=0
    fi
  fi
  
  set -e

elif [[ "$COMMAND" == "apply" ]]; then

  set +e

  terraform apply -no-color -auto-approve -lock-timeout=5m tfplan.binary 2>&1 | tee "$LOG_FILE"
  # -auto-approve skips confirmation
  # Uses previously generated plan file

  TF_EXIT=${PIPESTATUS[0]}

  set -e

  if [[ "$TF_EXIT" -eq 0 ]]; then
    terraform output -json > outputs.json 2>/dev/null || true
  fi
  # If apply succeeded, export outputs to JSON file

else
  echo "Unknown command: $COMMAND"
  exit 1
fi

exit "$TF_EXIT"
# Exit script with terraform’s actual exit code
# This makes Azure DevOps mark pipeline correctly


