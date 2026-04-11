#!/bin/bash
# Tells the system to run this script using bash

set -euo pipefail
# -e  → Exit immediately if any command fails
# -u  → Exit if using an undefined variable
# -o pipefail → If any command in a pipeline fails, the whole pipeline fails
# This makes the script strict and production-safe

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


CURRENT_BRANCH="$(git branch --show-current || true)"
# Gets current branch name
# || true prevents failure if in detached HEAD state


# Add clean-up mode
CLEANUP_MODE="${CLEANUP_MODE:-safe}"

ROOT_DIR="$(git rev-parse --show-toplevel)"
# Gets absolute path of repository root directory

LOG_ROOT="${ROOT_DIR}/.terraform-run-logs/${COMMIT_SHA}"
mkdir -p "$LOG_ROOT"
LOG_FILE="${LOG_ROOT}/terraform-${COMMAND}.log"
# Log file name per command
# Example: terraform-init.log

# ------------------------------------------
# RUN_ID handling (single source of truth)
# ------------------------------------------

RUN_ID="${RUN_ID:-}"

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="local-$(date +%s)"
  echo "Using fallback RUN_ID=$RUN_ID"
else
  echo "Using pipeline RUN_ID=$RUN_ID"
fi

# Export for Terraform
export TF_VAR_run_id="$RUN_ID"

RESOURCE_CACHE_FILE="${RESOURCE_CACHE_FILE:-/tmp/resource_cache.json}"

REPO="vkumarit/terraform_automation_iac"
# GitHub repository where logs will be pushed

# Tag filters (must match Terraform exactly)
TAG_MANAGED_BY="${TAG_MANAGED_BY:-terraform}"
TAG_DEPLOYMENT_ID="${TAG_DEPLOYMENT_ID:-prodmyapp}"

TF_EXIT=0
# Variable to store Terraform exit code

WORK_DIR="$(pwd)"
# Capture original working directory.

#=========================================
# Terraform Pre-check (CRITICAL SAFETY)
#=========================================
precheck_or_fail() {
  echo "========== TERRAFORM PRE-CHECK START =========="

  STORAGE_ACCOUNT="prodmyappsacmk01"
  CONTAINER_NAME="mytfstate"
  STATE_KEY="prod/terraform.tfstate"

  fail() {
    echo "❌ PRE-CHECK FAILED: $1"
    echo "🚫 Aborting to prevent accidental deletion"
    exit 1
  }

  pass() {
    echo "✅ $1"
  }

  # 1. INIT CHECK
  echo "➡️ terraform init validation..."
  if ! terraform init -input=false -no-color >/dev/null 2>&1; then
    fail "Terraform init failed (backend unreachable)"
  fi
  pass "Terraform init OK"

  # 2. STATE LIST
  echo "➡️ Checking terraform state list..."
  STATE_LIST=$(terraform state list 2>/dev/null || true)
  if [[ -z "$STATE_LIST" ]]; then
    fail "Terraform state EMPTY (backend not loaded)"
  fi
  echo "$STATE_LIST"
  pass "State list OK"

  # 7. AZURE vs TF COUNT
  echo "➡️ Comparing Azure vs Terraform..."

  AZ_COUNT=$(az resource list \
    --resource-group myTFResourceGroup \
    --query "[].id" -o tsv | wc -l)

  TF_COUNT=$(terraform state list | wc -l)

  echo "Azure count: $AZ_COUNT"
  echo "TF count: $TF_COUNT"

  if [[ "$TF_COUNT" -eq 0 && "$AZ_COUNT" -gt 0 ]]; then
    fail "CRITICAL: Azure has resources but TF state is EMPTY"
  fi

  pass "Counts consistent"
  
  # 3. STATE PULL
  echo "➡️ Pulling state..."
  if ! terraform state pull > /tmp/tfstate.json 2>/dev/null; then
    fail "Cannot pull remote state"
  fi

  if ! grep -q '"resources"' /tmp/tfstate.json; then
    fail "State JSON invalid"
  fi
  pass "State pull OK"

  # 4. BACKEND ACCESS
  echo "➡️ Checking storage access..."
  if ! az storage blob list \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER_NAME" \
    --auth-mode login \
    --output none 2>/dev/null; then
    fail "Storage backend not accessible"
  fi
  pass "Storage access OK"

  # 5. STATE FILE EXISTS
  echo "➡️ Checking state blob exists..."
  if ! az storage blob show \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER_NAME" \
    --name "$STATE_KEY" \
    --auth-mode login \
    --output none 2>/dev/null; then
    fail "State file missing in backend"
  fi
  pass "State blob exists"

  # 6. PLAN SAFETY
  echo "➡️ Running plan safety check..."
  PLAN_OUTPUT=$(terraform plan -no-color -input=false || true)

  if echo "$PLAN_OUTPUT" | grep -q "Plan: .* to add, 0 to change, 0 to destroy"; then
    fail "Terraform thinks everything is NEW → state mismatch"
  fi

  if echo "$PLAN_OUTPUT" | grep -q "to destroy"; then
    echo "$PLAN_OUTPUT"
    fail "Plan includes DESTROY actions"
  fi

  pass "Plan safe"

  echo "========== PRE-CHECK PASSED =========="
}

#=========================================
# Cleanup function
#=========================================

cleanup_orphans() {
  echo "========================================="
  echo "Running STATE vs AZURE cleanup"
  echo "========================================="

  echo "Cleanup mode: $CLEANUP_MODE"

  echo "Fetching Azure resources (mode: $CLEANUP_MODE)..."

  if [[ "$CLEANUP_MODE" == "safe" ]]; then
    
    # RUN_ID CHECK
    if [[ -z "$RUN_ID" ]]; then
      echo "ERROR: RUN_ID missing → refusing cleanup"
      exit 1
    fi
    
    echo "SMART cleanup (run-aware)"
    
    echo "Filtering by tags:"
    echo "  managed_by=$TAG_MANAGED_BY"
    echo "  deployment_id=$TAG_DEPLOYMENT_ID"

    az resource list \
      --resource-group myTFResourceGroup \
      --query "[?tags.managed_by=='$TAG_MANAGED_BY' && tags.deployment_id=='$TAG_DEPLOYMENT_ID'].{id:id, run:tags.creation_run_id}" \
      -o json > /tmp/az_resources.json

    #--------------------------------
    # Extract only old-run resources
    #--------------------------------
    
    CURRENT_RUN="$RUN_ID"

    jq -r --arg RUN "$CURRENT_RUN" '
      .[]
      | select(.run != $RUN)
      | .id
    ' /tmp/az_resources.json > /tmp/az_ids.txt
    
  else
    echo "WARNING: Running AGGRESSIVE cleanup (no tag filter)"

    az resource list \
      --resource-group myTFResourceGroup \
      --query "[].id" -o tsv > /tmp/az_ids.txt
  fi
  
  echo "Azure resource count: $(wc -l < /tmp/az_ids.txt)"
  cat /tmp/az_ids.txt
  
  echo "Building Terraform state ID list..."

  terraform state list | while read r; do
    # Skip data resources
    if [[ "$r" == data.* ]]; then
      continue
    fi

    ID=$(terraform state show -json "$r" 2>/dev/null | jq -r '.attributes.id // empty')

    # Only keep ARM-style IDs
    if [[ "$ID" == /subscriptions/* ]]; then
      echo "$ID"
    fi
  done | sort -u > /tmp/tf_ids.txt
  
  echo "TF resource count: $(wc -l < /tmp/tf_ids.txt)"
  cat /tmp/tf_ids.txt
  
  echo "Finding orphan resources..."

  grep -Fxv -f /tmp/tf_ids.txt /tmp/az_ids.txt > /tmp/orphan_ids.txt || true

  if [[ ! -s /tmp/orphan_ids.txt ]]; then
    echo "No orphan resources found."
    return
  fi

  echo "Orphan resources detected: $(wc -l < /tmp/orphan_ids.txt)"
  cat /tmp/orphan_ids.txt

  echo "Deleting orphan resources..."

  for i in {1..3}; do
    while read -r id; do
      echo "Deleting: $id"
      az resource delete --ids "$id" || true
    done < /tmp/orphan_ids.txt
    sleep 2
  done

  echo "Cleanup complete."
}

echo "========================================="
echo "Running terraform ${COMMAND}"
echo "Commit: ${COMMIT_SHA}"
echo "Branch: ${CURRENT_BRANCH:-DETACHED}"
echo "========================================="
# Prints useful debug info in pipeline logs

# ==========================================
# RUN TERRAFORM
# ==========================================

if [[ "$COMMAND" == "init" ]]; then

  set +e
  # Temporarily disable exit-on-error
  # So we can capture terraform exit code manually

  #terraform init -upgrade -reconfigure -no-color -lock-timeout=5m 2>&1 | tee "$LOG_FILE"
  
  # First try migration
  terraform init -upgrade -input=false -no-color -lock-timeout=5m -migrate-state 2>&1 | tee "$LOG_FILE"

  TF_EXIT=${PIPESTATUS[0]}
  # Capture actual terraform exit code (not tee exit code)

  if [[ "$TF_EXIT" -ne 0 ]]; then
    echo "Terraform init with migrate-state failed, retrying with reconfigure..." | tee -a "$LOG_FILE"

    terraform init -upgrade -reconfigure -input=false -no-color -lock-timeout=5m 2>&1 | tee -a "$LOG_FILE"

    TF_EXIT=${PIPESTATUS[0]}
  fi
  
  # Run terraform init
  # -upgrade Terraform ignores cached versions, re-evaluates provider constraints and 
  # -upgrade forces Terraform to download azurerm v4.1.0. (fresh) 
  # -no-color removes ANSI colors
  # -lock-timeout waits up to 5 minutes for backend lock
  # -migrate-state will move the statefile to configured backend, once migrated no issues
  # 2>&1 sends stderr to stdout
  # tee writes output to file AND prints to console

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
  
  echo "===== PRE-CLEAN PHASE ====="
  
  precheck_or_fail
  
  echo "Refreshing Terraform state..."
  if ! terraform apply -input=false -refresh-only -auto-approve -lock-timeout=10m -no-color \
    2>&1 | tee -a "$LOG_FILE"; then

    echo "WARNING: refresh-only failed, proceeding with cleanup cautiously"
  fi
  
  CLEANUP_MODE=safe cleanup_orphans

  echo "Pre-check: verifying backend state access..."
  terraform state pull > /dev/null 2>&1
  if [[ $? -ne 0 ]]; then
  #Or 
  #if ! terraform state pull > /dev/null 2>&1; then
    echo "ERROR: Cannot access remote state. It may be locked or backend unreachable."
    TF_EXIT=1
  else
    echo "Backend reachable. Running terraform plan..."
  
    terraform plan -input=false -parallelism=1 -no-color -detailed-exitcode -lock-timeout=10m -out=tfplan 2>&1 | tee "$LOG_FILE"
    # -parallelism=5 (only with plan & apply) > reduce memory usage 
    # -detailed-exitcode:
    #   0 > no changes
    #   1 > error
    #   2 > changes present

    TF_EXIT=${PIPESTATUS[0]}

    # If changes detected (exit 2), treat as success
    if [[ "$TF_EXIT" -eq 0 ]]; then
      echo "NO_CHANGES" > "${LOG_ROOT}/plan.status"
    elif [[ "$TF_EXIT" -eq 2 ]]; then
      echo "CHANGES_PRESENT" > "${LOG_ROOT}/plan.status"
      TF_EXIT=0
    else
      echo "FAILED" > "${LOG_ROOT}/plan.status"
    fi
  fi
  # .status writing
  
  set -e

elif [[ "$COMMAND" == "apply" ]]; then

  set +e

  # ------------------------------------------
  # Ensure plan status before apply
  # ------------------------------------------
  PLAN_STATUS_FILE="${LOG_ROOT}/plan.status"

  if [[ -f "$PLAN_STATUS_FILE" ]]; then
    PLAN_STATUS=$(cat "$PLAN_STATUS_FILE")

    if [[ "$PLAN_STATUS" == "NO_CHANGES" ]]; then
      echo "Terraform plan reported no changes. Skipping apply."
      exit 0
    fi
  fi
  
  # ------------------------------------------
  # Ensure plan file exists
  # ------------------------------------------
  if [[ ! -f "tfplan" ]]; then
    echo "ERROR: tfplan not found. Plan stage must run first."
    exit 1
  fi

  # -----------------------------
  # Block bulk destroy operations &
  # prevent pipeline crash from parsing issues.
  # -----------------------------
  DESTROY_COUNT=$(terraform show -json tfplan 2>/dev/null | jq '
  [
    .resource_changes[]
    | select(.change.actions | index("delete"))
  ] | length
  ' || echo 0)

  # Limit delete/replace 
  MAX_DESTROY=5

  if [[ "$DESTROY_COUNT" -gt "$MAX_DESTROY" ]]; then
    echo "ERROR: Too many destructive changes detected ($DESTROY_COUNT resources)."
    exit 1
  fi
  
  # ------------------------------------------
  # Run terraform apply 
  # ------------------------------------------
  terraform apply -input=false -parallelism=1 -refresh=false -no-color -auto-approve -lock-timeout=10m tfplan 2>&1 | tee "$LOG_FILE"
  # -input=false 
  # -parallelism=5 (only with plan & apply) > reduce memory usage
  # -auto-approve skips manual confirmation
  # Uses previously generated plan file

  TF_EXIT=${PIPESTATUS[0]}

  # ------------------------------------------
  # Status writing 
  # ------------------------------------------
  if [[ "$TF_EXIT" -ne 0 ]]; then
    echo "FAILED" > "${LOG_ROOT}/apply.status"
    
    # ------------------------------------------
    # Auto-Destroy for DEV / TEST
    # ------------------------------------------
    #echo "Terraform apply FAILED."
    #echo "Destroying partially created infrastructure..."
  
    #terraform destroy -parallelism=5 -auto-approve -no-color 2>&1 | tee -a "$LOG_FILE"

    echo "Terraform apply failed." | tee -a "$LOG_FILE"
    echo "===== Terraform Recovery Phase (Step 1: State Sync) =====" | tee -a "$LOG_FILE"

    echo "Synchronizing Terraform state with Azure..."
    
    # Only read the real infrastructure and update the state file with -refresh-only.
    # Do NOT create, modify, or destroy infrastructure.
    terraform apply -input=false -refresh-only -auto-approve -lock-timeout=10m -no-color 2>&1 | tee -a "$LOG_FILE" || true
    
    echo "Recovery Step 1 complete. Starting Step 2 in fresh process..."

    # Re-exec script (clean process), frees memory, avoids Terraform/JQ leaks
    RUN_ID="$RUN_ID" exec "$0" recovery
  else
    echo "SUCCEEDED" > "${LOG_ROOT}/apply.status"
    
    terraform output -json > "${LOG_ROOT}/outputs.json" 2>/dev/null || true
    # If apply succeeded, export outputs to JSON file
  fi

elif [[ "$COMMAND" == "recovery" ]]; then
  
  set +e      
  # allows recovery steps to continue even if something fails
  
  TF_EXIT=1    
  # ensures final pipeline status = FAILED no matter what
  
  # ------------------------------------------
  # Auto-detect and clean partially created resources
  # ------------------------------------------

  echo "===== POST-FAIL CLEANUP ====="

  echo "Post-fail: state has been refreshed from Azure"
  echo "Now enforcing: AZURE == TERRAFORM STATE"

  echo "Collecting and comparing resources..."
  
  CLEANUP_MODE=aggressive cleanup_orphans

  echo "Post-fail cleanup completed"
  echo "All resources not present in Terraform state have been removed"

  echo "Recovery finished. Pipeline ready for next run after fix."

  rm -f "$RESOURCE_CACHE_FILE"

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

if git push origin terraform-logs; then
  echo "Terraform logs pushed successfully."
else
  echo "WARNING: Failed to push Terraform logs."
fi

rm -rf "$TMP_DIR"

set -e   # re-enable strict error handling

exit "$TF_EXIT"
# Exit script with terraform’s actual exit code
# This makes Azure DevOps mark pipeline correctly