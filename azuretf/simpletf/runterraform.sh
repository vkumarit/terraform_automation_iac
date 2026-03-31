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

# Use pipeline run ID to delete orphaned resources,
# if terraform crashed after creating resources but not recorded by state before crash.
RUN_ID="${RUN_ID:-}"
# Verify 
if [[ "$COMMAND" != "init" && -z "$RUN_ID" ]]; then
  echo "ERROR: RUN_ID environment variable not set (required for plan/apply)"
  exit 1
fi

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

#xxx
#echo "DEBUG: ARM_CLIENT_SECRET length: ${#ARM_CLIENT_SECRET}"
#az login --service-principal \
#   --username "$ARM_CLIENT_ID" \
#   --password "$ARM_CLIENT_SECRET" \
#   --tenant "$ARM_TENANT_ID" --output none && echo "SP login OK"
#xxx

#cd azuretf/simpletf - remove if pipeline working good
# Move into Terraform working directory

if [[ "$COMMAND" == "init" ]]; then

  set +e
  # Temporarily disable exit-on-error
  # So we can capture terraform exit code manually

  terraform init -upgrade -reconfigure -no-color -lock-timeout=5m 2>&1 | tee "$LOG_FILE"
  # Run terraform init
  # -upgrade Terraform ignores cached versions, re-evaluates provider constraints and 
  # -upgrade forces Terraform to download azurerm v4.1.0. (fresh) 
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
  
    terraform plan -input=false -parallelism=5 -no-color -detailed-exitcode -lock-timeout=10m -out=tfplan.binary 2>&1 | tee "$LOG_FILE"
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
  if [[ ! -f "tfplan.binary" ]]; then
    echo "ERROR: tfplan.binary not found. Plan stage must run first."
    exit 1
  fi

  # -----------------------------
  # Block bulk destroy operations
  # -----------------------------
  DESTROY_COUNT=$(terraform show -json tfplan.binary | jq '
  [
    .resource_changes[]
    | select(.change.actions | index("delete"))
  ] | length
  ')

  # Limit delete/replace 
  MAX_DESTROY=5

  if [[ "$DESTROY_COUNT" -gt "$MAX_DESTROY" ]]; then
    echo "ERROR: Too many destructive changes detected ($DESTROY_COUNT resources)."
    exit 1
  fi
  
  # ------------------------------------------
  # Run terraform apply 
  # ------------------------------------------
  terraform apply -input=false -parallelism=5 -no-color -auto-approve -lock-timeout=10m tfplan.binary 2>&1 | tee "$LOG_FILE"
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
    echo "===== Terraform Recovery Phase =====" | tee -a "$LOG_FILE"

    echo "Synchronizing Terraform state with Azure..."
    
    # Only read the real infrastructure and update the state file with -refresh-only.
    # Do NOT create, modify, or destroy infrastructure.
    terraform apply -input=false -refresh-only -auto-approve -lock-timeout=10m -no-color 2>&1 | tee -a "$LOG_FILE" || true

    # ------------------------------------------
    # Auto-detect and clean partially created resources
    # ------------------------------------------
    echo "Detecting partially created/broken resources..."
    
    PLAN_OUT="tfplan.recovery"
    terraform plan -input=false -parallelism=5 -lock-timeout=10m -no-color -out="$PLAN_OUT" -detailed-exitcode || true
    terraform show -json "$PLAN_OUT" > tfplan.recovery.json

    BROKEN_RESOURCES=$(jq -r '
      .resource_changes[]
      | select(.change.actions == ["create"])
      | select(
          (.change.after.provisioning_state? != "Succeeded")
          or (.change.after? == null)
        )
      | .address
    ' tfplan.recovery.json)

    if [[ -n "$BROKEN_RESOURCES" ]]; then
        COUNT=$(printf '%s\n' "$BROKEN_RESOURCES" | sed '/^$/d' | wc -l)
        echo "Broken resources detected: $COUNT"
        
        echo "Detected partially created/broken resources:"
        printf '%s\n' "$BROKEN_RESOURCES"

        for res in $BROKEN_RESOURCES; do
            echo "Destroying $res in Azure..."
            terraform destroy -target="$res" -auto-approve -parallelism=2 -lock-timeout=10m -no-color || true

            echo "Removing $res from Terraform state..."
            terraform state rm "$res" || true
        done
    else
        echo "No broken resources detected. Recovery complete."
    fi

    echo "Scanning Azure for orphan resources created during this pipeline run..."

    # --------------------------------------------------
    # OPTION 1: Azure CLI resource listing
    # --------------------------------------------------
    #ORPHAN_IDS=$(az resource list \
    #  --tag creation_run_id="$RUN_ID" \
    #  --query "[].id" -o tsv 2>/dev/null || true)

    # --------------------------------------------------
    # OPTION 2: Azure Resource Graph (faster for large environments)
    # --------------------------------------------------
    ORPHAN_IDS=$(az graph query -q "
    Resources
    | where resourceGroup == 'myTFResourceGroup'
    | where tags.managed_by == 'terraform'
    | where tags.creation_run_id == '$RUN_ID'
    | project id, type
    " --query "data" -o json 2>/dev/null || echo "[]")
    # " | where resourceGroup == 'myTFResourceGroup' " - scoped orphaned resources scan search to RG,
    # ``` "data[].id" -o tsv ``` - outputs only IDs as text.
    # ``` "data" -o json ``` - outputs ID + TYPE as json.
    # ``` echo "[]" ``` - if query fails, prevents script crash and gives valid json
    # instead of entire subscription.

    if [[ -n "$ORPHAN_IDS" && "$ORPHAN_IDS" != "[]" ]]; then
        ORPHAN_ID_LIST=$(echo "$ORPHAN_IDS" | jq -r '.[].id')
    else
        ORPHAN_ID_LIST=""
    fi
    
    echo "Building Terraform state resource ID list..."

    STATE_IDS=$(terraform state list | while read r; do
      terraform state show -json "$r" 2>/dev/null | jq -r '.attributes.id // empty'
    done)
    
    STATE_IDS_SET=$(echo "$STATE_IDS" | sort -u)
    
    if [[ -n "$ORPHAN_IDS" && "$ORPHAN_IDS" != "[]" ]]; then
        echo "Orphan Azure resources detected:"
        echo "$ORPHAN_IDS" | jq .

        # ------------------------------------------
        # Function: delete safely by type
        # ------------------------------------------
        delete_by_type() {
            TYPE_FILTER=$1
            echo "$ORPHAN_IDS" | jq -c ".[] | select(.type | test(\"$TYPE_FILTER\"))" | while read res; do

                ID=$(echo "$res" | jq -r '.id')

                if printf '%s\n' "$STATE_IDS_SET" | grep -Fxq "$ID"; then
                    # grep -Fxq "$ID" - avoids partial matches, accidental deletes
                    echo "Skipping managed resource: $ID"
                    continue
                fi
                
                echo "Deleting [$TYPE_FILTER]: $ID"
                az resource delete --ids "$ID" || true
            done
        }

        # ------------------------------------------
        # Dependency-aware deletion
        # ------------------------------------------

        delete_by_type "virtualMachines"
        delete_by_type "networkInterfaces"
        delete_by_type "disks"
        delete_by_type "publicIPAddresses"
        delete_by_type "networkSecurityGroups"
        delete_by_type "virtualNetworks"

        # ------------------------------------------
        # Fallback: delete remaining
        # ------------------------------------------
        echo "$ORPHAN_IDS" | jq -c '.[]' | while read res; do

            ID=$(echo "$res" | jq -r '.id')

            if printf '%s\n' "$STATE_IDS_SET" | grep -Fxq "$ID"; then
                echo "Skipping managed resource: $ID"
                continue
            fi

            echo "Deleting remaining resource: $ID"
            az resource delete --ids "$ID" || true

        done

    else
        echo "No tagged orphan Azure resources found."
    fi
    
    # ------------------------------------------
    # Untagged: orphaned resources cleanup (safety net)
    # ------------------------------------------
    echo "Scanning for UNTAGGED orphan resources (safety net)..."

    ALL_RESOURCES=$(az resource list \
      --resource-group myTFResourceGroup \
      --query "[].id" -o tsv 2>/dev/null || true)

    echo "$ALL_RESOURCES" | grep -v '^$' | while read -r ID; do

        # Skip if managed in Terraform state
        if printf '%s\n' "$STATE_IDS_SET" | grep -Fxq "$ID"; then
            echo "Skipping managed resource: $ID"
            continue
        fi

        # Skip if already handled as tagged orphan
        if [[ -n "$ORPHAN_ID_LIST" ]] && printf '%s\n' "$ORPHAN_ID_LIST" | grep -Fxq "$ID"; then
            echo "Skipping already processed tagged orphan: $ID"
            continue
        fi

        # Delete remaining untagged orphan
        echo "Deleting UNTAGGED orphan: $ID"
        az resource delete --ids "$ID" || true

    done
    
    echo "Recovery finished. Pipeline ready for next run after code/config fix."
    
    set -e

  else
    echo "SUCCEEDED" > "${LOG_ROOT}/apply.status"
  fi 

  # ------------------------------------------
  # Export outputs 
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