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
echo "Cleanup mode: $CLEANUP_MODE"

ROOT_DIR="$(git rev-parse --show-toplevel)"
# Gets absolute path of repository root directory

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

# ------------------------------------------
# Create a directory and log file 
# ------------------------------------------
LOG_ROOT="${ROOT_DIR}/.terraform-run-logs/${COMMIT_SHA}/${RUN_ID}"
mkdir -p "$LOG_ROOT"
LOG_FILE="${LOG_ROOT}/terraform-${COMMAND}.log"
# Log file name per command
# Example: terraform-init.log

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
  echo "----- PRE-CHECK START -----"

  STORAGE_ACCOUNT="prodmyappsacmk01"
  CONTAINER_NAME="mytfstate"
  STATE_KEY="prod/terraform.tfstate"

  fail() {
    echo "❌ PRE-CHECK FAILED: $1"
    echo "🚫 Aborting to prevent accidental deletion"
    exit 1
  }

  warn() {
    echo "⚠️ WARNING: $1"
  }
  
  pass() {
    echo "✅ $1"
  }

  # ------------------------------------------
  # 1. VALIDATE WORKSPACE
  # ------------------------------------------
  #CURRENT_WS=$(terraform workspace show 2>/dev/null || echo "unknown")

  #if [[ "$CURRENT_WS" != "prod" ]]; then
    #fail "Wrong Terraform workspace: $CURRENT_WS (expected: prod)"
  #fi
  
  # ------------------------------------------
  # 2. STATE LIST & COUNTS
  # ------------------------------------------
  echo "#> Checking terraform state list and TF Count..."
  
  TF_STATE_EXIT=0
  STATE_LIST=$(terraform state list 2>/dev/null) || TF_STATE_EXIT=$?

  TF_STATE_EXIT=${TF_STATE_EXIT:-0}

  if [[ "$TF_STATE_EXIT" -ne 0 ]]; then
    fail "Terraform not initialized or backend not accessible"
  fi
  
  echo "$STATE_LIST"
  TF_COUNT=$(echo "$STATE_LIST" | grep -c .)
  pass "State list OK"

  # AZURE vs TF COUNT
  echo "#> Fetching Azure resource count..."

  AZ_COUNT=$(az resource list \
  --resource-group myTFResourceGroup \
  --query "[].id" -o tsv 2>/dev/null | wc -l) || fail "Failed to fetch Azure resources (auth / RG issue)"

  echo "Azure count: $AZ_COUNT"
  echo "TF count: $TF_COUNT"

  # ------------------------------------------
  # 3. CRITICAL SAFETY CHECK
  # ------------------------------------------
  if [[ "$TF_COUNT" -eq 0 && "$AZ_COUNT" -gt 0 ]]; then
    fail "CRITICAL: Azure has resources but Terraform state is EMPTY"
  fi

  # ------------------------------------------
  # 4. DRIFT WARNINGS (non-blocking)
  # ------------------------------------------
  if [[ "$TF_COUNT" -lt "$AZ_COUNT" ]]; then
    warn "Azure has MORE resources than Terraform state (possible unmanaged resources)"
  fi

  if [[ "$TF_COUNT" -gt "$AZ_COUNT" ]]; then
    warn "Terraform state has MORE resources than Azure (possible drift or deletions)"
  fi

  pass "Counts sanity check completed"

  
  # ------------------------------------------
  # 5. STATE PULL VALIDATION
  # ------------------------------------------
  echo "#> Pulling state..."

  if ! terraform state pull > /tmp/tfstate.json 2>/dev/null; then
    fail "Cannot pull remote state"
  fi

  if ! grep -q '"resources"' /tmp/tfstate.json; then
    fail "State JSON invalid"
  fi

  pass "State pull OK"

  # ------------------------------------------
  # 6. BACKEND ACCESS
  # ------------------------------------------
  echo "#> Checking storage access..."
  
  if ! az storage blob list \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER_NAME" \
    --auth-mode login \
    --output none 2>/dev/null; then
    fail "X> Storage backend not accessible"
  fi
  
  pass "Storage access OK"

  # ------------------------------------------
  # 7. STATE FILE EXISTS
  # ------------------------------------------
  echo "#> Checking state blob exists..."
  
  if ! az storage blob show \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER_NAME" \
    --name "$STATE_KEY" \
    --auth-mode login \
    --output none 2>/dev/null; then
    fail "X> State file missing in backend"
  fi
  
  pass "State blob exists"

  echo "----- PRE-CHECK COMPLETE -----"
}

#=========================================
# Cleanup function
#=========================================

cleanup() {
  echo "--------------------------------"
  echo "Running SAFE orphan cleanup"
  echo "--------------------------------"

  # ------------------------------------------
  # 1. Build Terraform state IDs
  # ------------------------------------------
  terraform state list | while read r; do
    [[ "$r" == data.* ]] && continue

    ID=$(terraform state show -json "$r" 2>/dev/null | jq -r '.attributes.id // empty')
    [[ -n "$ID" ]] && echo "$ID"
  done | sort -u > /tmp/tf_ids.txt

  if [[ ! -s /tmp/tf_ids.txt ]]; then
    echo "WARNING: No Terraform-managed resources found. Skipping cleanup."
    return 0
  fi

  TF_COUNT=$(wc -l < /tmp/tf_ids.txt)
  echo "TF_COUNT=$TF_COUNT"

  # ------------------------------------------
  # 2. Build Azure managed resource list
  # (ONLY what Terraform should manage)
  # ------------------------------------------
  az resource list \
    --resource-group myTFResourceGroup \
    --query "[?tags.managed_by=='$TAG_MANAGED_BY' && tags.deployment_id=='$TAG_DEPLOYMENT_ID'].{id:id, created:tags.creation_time}" \
    -o json > /tmp/az_resources.json

  AZ_COUNT=$(jq length /tmp/az_resources.json)
  echo "AZ_COUNT=$AZ_COUNT"

  if [[ "$AZ_COUNT" -eq 0 ]]; then
    echo "No managed Azure resources found."
    return 0
  fi

  echo "--------------------------------"
  echo "Checking for UNTAGGED resources..."
  echo "--------------------------------"

  az resource list \
    --resource-group myTFResourceGroup \
    --query "[?tags.managed_by==null].id" \
    -o tsv > /tmp/untagged.txt

  if [[ -s /tmp/untagged.txt ]]; then
    echo "⚠️ Untagged resources detected (manual review required):"
    cat /tmp/untagged.txt
  else
    echo "No untagged resources found."
  fi

  # ------------------------------------------
  # 4. Extract Azure IDs
  # ------------------------------------------
  jq -r '.[].id' /tmp/az_resources.json | sort -u > /tmp/az_ids.txt

  # ------------------------------------------
  # 5. Detect TRUE orphans (Azure - TF)
  # ------------------------------------------
  grep -Fxv -f /tmp/tf_ids.txt /tmp/az_ids.txt > /tmp/orphan_ids.txt || true

  if [[ ! -s /tmp/orphan_ids.txt ]]; then
    echo "No orphan resources found."
    return 0
  fi

  echo "Potential orphans:"
  cat /tmp/orphan_ids.txt

  # ------------------------------------------
  # 6. SAFETY: Skip very recent resources
  # ------------------------------------------
  echo "Filtering out recent resources (<10 min)..."

  > /tmp/safe_delete_ids.txt

  NOW_EPOCH=$(date +%s)

  while read -r id; do
    CREATED=$(jq -r --arg ID "$id" '.[] | select(.id==$ID) | .created' /tmp/az_resources.json)

    if [[ -z "$CREATED" || "$CREATED" == "null" ]]; then
      echo "Skipping (no timestamp): $id"
      continue
    fi

    CREATED_EPOCH=$(date -d "$CREATED" +%s 2>/dev/null || echo 0)
    AGE=$(( NOW_EPOCH - CREATED_EPOCH ))

    if [[ "$AGE" -gt 600 ]]; then
      echo "$id" >> /tmp/safe_delete_ids.txt
    else
      echo "Skipping recent: $id"
    fi
  done < /tmp/orphan_ids.txt

  if [[ ! -s /tmp/safe_delete_ids.txt ]]; then
    echo "No safe resources to delete."
    return 0
  fi

  # ------------------------------------------
  # Count IDs once (DRY)
  # ------------------------------------------
  COUNT=$(wc -l < /tmp/safe_delete_ids.txt)
  
  # ------------------------------------------
  # DRY-RUN MODE
  # ------------------------------------------
  if [[ "$CLEANUP_MODE" == "dry-run" ]]; then
    echo "DRY RUN: $COUNT resources would be deleted:"
    cat /tmp/safe_delete_ids.txt
    return 0
  fi

  # ------------------------------------------
  # 7. DELETE (final step)
  # ------------------------------------------
  
  echo "Final delete count: $COUNT"
  
  echo "Deleting verified orphan resources..."

  while read -r id; do
    echo "Deleting: $id"
    az resource delete --ids "$id" || true
  done < /tmp/safe_delete_ids.txt

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
  
  #echo "Running pre-check..."
  #precheck_or_fail
  
  echo "Refreshing Terraform state..."
  terraform apply -input=false -refresh-only -auto-approve -lock-timeout=10m -no-color \
    2>&1 | tee -a "$LOG_FILE" || true
    
  echo "Running terraform plan..."
  
  terraform plan -input=false -parallelism=1 -no-color -detailed-exitcode -lock-timeout=10m -out=tfplan 2>&1 | tee "$LOG_FILE"
  # -parallelism=5 (only with plan & apply) > reduce memory usage 
  # -detailed-exitcode:
  #   0 > no changes
  #   1 > error
  #   2 > changes present

  TF_EXIT=${PIPESTATUS[0]}
    
  # ------------------------------------------
  # Handle terraform plan exit codes FIRST
  # ------------------------------------------
  if [[ "$TF_EXIT" -eq 1 ]]; then
    echo "Terraform plan failed"
    echo "FAILED" > "${LOG_ROOT}/plan.status"
    exit 1
  fi
  
  # ------------------------------------------
  # Write status cleanly
  # ------------------------------------------
  if [[ "$TF_EXIT" -eq 0 ]]; then
    echo "NO_CHANGES" > "${LOG_ROOT}/plan.status"
  else
    echo "CHANGES_PRESENT" > "${LOG_ROOT}/plan.status"
  fi

  # Normalize exit code (important for pipeline)
  TF_EXIT=0
  
  set -e

elif [[ "$COMMAND" == "apply" ]]; then

  set +e
  
  echo "Running pre-check before apply..."
  precheck_or_fail

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

    echo "Terraform apply failed. Synchronizing Terraform state with Azure..." | tee -a "$LOG_FILE"
      
    # Only read the real infrastructure and update the state file with -refresh-only.
    # Do NOT create, modify, or destroy infrastructure.
    terraform apply -input=false -refresh-only -auto-approve -lock-timeout=10m -no-color 2>&1 | tee -a "$LOG_FILE" || true
    
    # Re-exec script (clean process), frees memory, avoids Terraform/JQ leaks
    RUN_ID="$RUN_ID" exec "$0" recovery
  else
    echo "SUCCEEDED" > "${LOG_ROOT}/apply.status"
    
    terraform output -json > "${LOG_ROOT}/outputs.json" 2>/dev/null || true
    # If apply succeeded, export outputs to JSON file
  fi

elif [[ "$COMMAND" == "recovery" ]]; then
  
  set +e      
  TF_EXIT=1    

  echo "===== POST-FAIL CLEANUP ====="

  echo "Step 1: Refresh state from Azure..."

  REFRESH_EXIT=0
  terraform apply -refresh-only -auto-approve -lock-timeout=10m -no-color \
    2>&1 | tee -a "$LOG_FILE" || REFRESH_EXIT=$?

  if [[ "$REFRESH_EXIT" -ne 0 ]]; then
    echo "CRITICAL: refresh-only failed → skipping cleanup"
    exit 1
  fi

  echo "Step 2: Running safety precheck..."
  precheck_or_fail

  echo "Step 3: Running cleanup..."

  cleanup

  echo "Post-fail cleanup completed"
  echo "Recovery finished. Pipeline ready for next run after fix."

  rm -f "$RESOURCE_CACHE_FILE"
fi

# ------------------------------------------
# Create summary file for logs
# ------------------------------------------

LOG_ROOT="${ROOT_DIR}/.terraform-run-logs/${COMMIT_SHA}/${RUN_ID}"

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