#!/bin/bash
set -euo pipefail

echo "Pushing all Terraform logs in one commit..."

# Required env vars
: "${GITHUB_TOKEN:?Missing GITHUB_TOKEN}"
: "${BUILD_SOURCESDIRECTORY:?Missing BUILD_SOURCESDIRECTORY}"

REPO="vkumarit/terraform_automation_iac"

COMMIT_SHA=$(git -C "$BUILD_SOURCESDIRECTORY" rev-parse HEAD)

LOG_BASE="${BUILD_SOURCESDIRECTORY}/.terraform-run-logs/${COMMIT_SHA}"

if [[ ! -d "$LOG_BASE" ]]; then
  echo "No logs found at $LOG_BASE — skipping push"
  exit 0
fi

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

RUN_ID="${BUILD_BUILDID:-manual}"
mkdir -p "runs/${COMMIT_SHA}/${RUN_ID}"

echo "Copying logs..."

# Copy logs but NEVER copy terraform state files
rsync -av \
  --exclude="*.tfstate" \
  --exclude="*.tfplan*" \
  --exclude=".terraform*" \
  "$LOG_BASE/" \
  "runs/${COMMIT_SHA}/${RUN_ID}/"

find runs/ -type f -name "*.tfstate*" -delete
find runs/ -type f -name "*.tfplan*" -delete

git add runs/

git commit -m "Terraform logs | commit=${COMMIT_SHA} | run=${RUN_ID}" \
  || echo "Nothing to commit"

echo "Pushing logs..."

#git push origin terraform-logs || echo "WARNING: Push failed"

for i in 1 2 3; do
  if git push origin terraform-logs; then
    echo "Push succeeded"
    break
  else
    echo "Push failed (attempt $i), retrying..."
    sleep 5
  fi
done

rm -rf "$TMP_DIR"

echo "Log push complete."
