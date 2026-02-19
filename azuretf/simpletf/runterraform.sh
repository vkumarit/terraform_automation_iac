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
#push_logs() {
# This function runs automatically when script exits
# (because of trap below)

#  cd "$ROOT_DIR"
  # Go back to repo root

#  git config user.email "signinvipin@gmail.com"
#  git config user.name "signinvipin"
  # Set git author for commits

#  git fetch origin || true
  # Fetch latest remote branches
  # || true prevents failure if fetch fails

  # Clean working directory before branch switch
  
#  git reset --hard
  # - Discards ALL changes to tracked files. 
  # - Resets working tree to match the last committed state (HEAD).
  # - Terraform or pipeline steps may modify tracked files, and Git 
  #   will refuse to checkout another branch if files differ.
  
#  git clean -fd
  # - Deletes all untracked files and directories.
  # - Uses -f > force removal and -d > include directories.
  # - Terraform creates untracked files (.terraform/, tfplan.binary, etc.).
  #   These can block branch checkout if not removed.
  
#  if git show-ref --verify --quiet refs/heads/terraform-logs; then
#    git branch -D terraform-logs
#  fi
  # If local terraform-logs branch exists, delete it
  # Ensures clean branch recreation

#  if git ls-remote --exit-code --heads origin terraform-logs >/dev/null 2>&1; then
#    git checkout -b terraform-logs origin/terraform-logs
#  else
#    git checkout --orphan terraform-logs
    # Create brand new orphan branch (no history)

#    git rm -rf . >/dev/null 2>&1 || true
    # Remove all files from working tree

#    git reset --hard
    # Ensure clean working directory
#  fi

#  RUN_DIR="runs/${COMMIT_SHA}/${COMMAND}"
  # Create structured logs folder:
  # runs/<commit>/<init|plan|apply>

#  mkdir -p "$RUN_DIR"
  # Create folder if it doesn’t exist

#  cp azuretf/simpletf/terraform-*.log "$RUN_DIR/" 2>/dev/null || true
  # Copy terraform logs into run directory
  # Suppress errors if no log exists

#  if [[ "$TF_EXIT" -ne 0 ]]; then
#    echo "${COMMAND} FAILED" > "$RUN_DIR/summary.txt"
#  else
#    echo "${COMMAND} SUCCEEDED" > "$RUN_DIR/summary.txt"
#  fi
  # Write success/failure status file

#  if [[ -n "$(git status --porcelain runs/)" ]]; then
  # Only commit if there are changes in runs/

#    git add runs/
    # Stage only logs folder (prevents repo bloat)

#    git commit -m "Terraform ${COMMAND} logs for ${COMMIT_SHA}"
    # Commit logs

#    git remote set-url origin "https://${TOKEN}@github.com/${REPO}.git"
    # Set authenticated remote using PAT

#    git push origin terraform-logs
    # Push logs branch to GitHub
#  fi

#  if [[ -n "$CURRENT_BRANCH" ]]; then
#    git checkout "$CURRENT_BRANCH" || true
#  fi
  # Switch back to original branch
#}

#trial code
push_logs() {
  echo "Pushing logs safely..."

  if [[ -z "$TOKEN" ]]; then
    echo "ERROR: GITHUB_TOKEN not set"
    return 0
  fi
  # Prevents weird git clone failures if token is empty.
  
  TMP_DIR=$(mktemp -d)
  
  git clone https://${TOKEN}@github.com/${REPO}.git "$TMP_DIR"

  mkdir -p "$TMP_DIR/runs/${COMMIT_SHA}/${COMMAND}"

  cp "${WORK_DIR}/${LOG_FILE}" "$TMP_DIR/runs/${COMMIT_SHA}/${COMMAND}/terraform-${COMMAND}.log"

  if [[ "$TF_EXIT" -ne 0 ]]; then
    echo "${COMMAND} FAILED" > "$TMP_DIR/runs/${COMMIT_SHA}/${COMMAND}/summary.txt"
  else
    echo "${COMMAND} SUCCEEDED" > "$TMP_DIR/runs/${COMMIT_SHA}/${COMMAND}/summary.txt"
  fi
  
  cd "$TMP_DIR" || exit 1

  git checkout terraform-logs
  git add runs/
  git commit -m "Terraform ${COMMAND} logs for ${COMMIT_SHA}" || echo "Nothing to commit"
  git push origin terraform-logs

  cd "$ROOT_DIR" || exit 1
  rm -rf "$TMP_DIR"
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

  terraform plan -no-color -detailed-exitcode -lock-timeout=5m -out=tfplan.binary 2>&1 | tee "$LOG_FILE"
  # -detailed-exitcode:
  #   0 → no changes
  #   1 → error
  #   2 → changes present

  TF_EXIT=${PIPESTATUS[0]}

  set -e
  
  # If changes detected (exit 2), treat as success
  if [[ "$TF_EXIT" -eq 2 ]]; then
    TF_EXIT=0
  fi

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


