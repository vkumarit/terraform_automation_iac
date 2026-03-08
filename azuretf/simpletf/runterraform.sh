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

#TOKEN="${GITHUB_TOKEN:-}"
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

  terraform init -reconfigure -no-color -lock-timeout=5m 2>&1 | tee "$LOG_FILE"
  # Run terraform init
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
    # -parallelism=5 (only with plan & apply) > reduce memory usage 
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

  # ------------------------------------------
  # Ensure plan file exists
  # ------------------------------------------
  if [[ ! -f "tfplan.binary" ]]; then
    echo "ERROR: tfplan.binary not found. Plan stage must run first."
    exit 1
  fi

  # ------------------------------------------
  # Create state backup before apply DON"T PUSH TFSTATE TO REPO KEEP ON VM
  # ------------------------------------------
  echo "Creating state backup before apply..."

  STATE_BACKUP_DIR="/tmp/terraform-state-backups"
  mkdir -p "$STATE_BACKUP_DIR"

  BACKUP_FILE="${STATE_BACKUP_DIR}/${COMMIT_SHA}_pre_apply_backup.tfstate"
  
  terraform state pull > "$BACKUP_FILE" 2>/dev/null

  if [[ $? -ne 0 ]]; then
    echo "WARNING: Could not backup remote state."
  else
    echo "State backup saved at $BACKUP_FILE"
  fi

  # -----------------------------
  # Block bulk destroy operations
  # -----------------------------
  DESTROY_COUNT=$(terraform show -json tfplan.binary | jq '[.resource_changes[] | select(.change.actions[] == "delete")] | length')
  
  if [[ "$DESTROY_COUNT" -gt 0 ]]; then
    echo "Destroy operations are blocked in all environments."
    exit 1
  fi
  
  # ------------------------------------------
  # Run terraform apply (existing logic)
  # ------------------------------------------
  terraform apply -parallelism=5 -no-color -auto-approve -lock-timeout=10m tfplan.binary 2>&1 | tee "$LOG_FILE"
  # -parallelism=5 (only with plan & apply) > reduce memory usage
  # -auto-approve skips manual confirmation
  # Uses previously generated plan file

  TF_EXIT=${PIPESTATUS[0]}

  # ------------------------------------------
  # Status writing (existing logic)
  # ------------------------------------------
  if [[ "$TF_EXIT" -ne 0 ]]; then
    echo "FAILED" > "${LOG_ROOT}/apply.status"

    # ------------------------------------------
    # Auto-Destroy for DEV / TEST
    # ------------------------------------------
    #echo "Terraform apply FAILED."
    #echo "Destroying partially created infrastructure..."
  
    #terraform destroy -parallelism=5 -auto-approve -no-color 2>&1 | tee -a "$LOG_FILE"

    # ------------------------------------------
    # Rollback attempt for PROD
    # ------------------------------------------
    if [[ -f "$BACKUP_FILE" ]]; then
      echo "Terraform apply FAILED. Attempting state rollback..."

      if ! terraform state push "$BACKUP_FILE" >/dev/null 2>&1; then
        echo "WARNING: State rollback failed."
      else
        echo "State rollback completed."
      fi

      echo "Previous state restored. Running terraform apply to reconcile..."

      terraform apply -parallelism=5 -no-color -auto-approve -lock-timeout=10m 2>/dev/null || true

      echo "Rollback attempt completed."
      
      rm -f "$BACKUP_FILE"
    else
      echo "Rollback not possible: state backup missing."
    fi

  else
    echo "SUCCEEDED" > "${LOG_ROOT}/apply.status"

    if [[ -f "$BACKUP_FILE" ]]; then
      rm -f "$BACKUP_FILE"
      echo "State backup removed after successful apply."
    fi
  fi
  # .status writing
  
  set -e

  # ------------------------------------------
  # Export outputs (existing logic)
  # ------------------------------------------
  if [[ "$TF_EXIT" -eq 0 ]]; then
    terraform output -json > "${LOG_ROOT}/outputs.json" 2>/dev/null || true
  fi
  # If apply succeeded, export outputs to JSON file
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

# --------------------------------------------------
# Copy logs but NEVER copy terraform state files
# --------------------------------------------------
rsync -av \
  --exclude="*.tfstate" \
  --exclude="*.tfstate.backup" \
  --exclude="*.tfplan*" \
  --exclude=".terraform*" \
  "${LOG_ROOT}/" "runs/${COMMIT_SHA}/"

# Extra protection in case tfstate tfplan still there
find runs/ -type f -name "*.tfstate*" -delete
find runs/ -type f -name "*.tfplan*" -delete

git add runs/

git commit -m "Terraform full run logs for ${COMMIT_SHA}" >/dev/null 2>&1 || echo "Nothing to commit"

git push origin terraform-logs

rm -rf "$TMP_DIR"

echo "Terraform logs pushed successfully."

# --------------------------------------------------
# FINAL SAFETY CLEANUP
# If backup state still exists (unexpected case),
# remove it so secrets never remain on the agent
# --------------------------------------------------
if [[ -n "${BACKUP_FILE:-}" && -f "${BACKUP_FILE}" ]]; then
  rm -f "$BACKUP_FILE"
  echo "Final cleanup: removed temporary Terraform state backup."
fi

set -e   # re-enable strict error handling

exit "$TF_EXIT"
# Exit script with terraform’s actual exit code
# This makes Azure DevOps mark pipeline correctly