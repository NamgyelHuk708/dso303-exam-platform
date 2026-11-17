#!/usr/bin/env bash
# Publish frontend/ to the private S3 bucket behind CloudFront, with a generated config.js.
# Used locally and by GitHub Actions.  Usage: scripts/publish-frontend.sh
set -euo pipefail
STACK=dso303-exam-namgyelw-app
out() { aws cloudformation describe-stacks --stack-name "$STACK" \
          --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
API=$(out ApiUrl); BUCKET=$(out FrontendBucketName); DIST=$(out DistributionId); URL=$(out FrontendUrl)
VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo local) built $(date -u +%Y-%m-%dT%H:%MZ)"

BUILD=$(mktemp -d)
cp -r frontend/. "$BUILD/"
cat > "$BUILD/config.js" <<CFG
window.APP_CONFIG = { apiUrl: "$API", version: "$VERSION" };
CFG

# Small site: no-cache makes browsers revalidate, so a new deploy shows up immediately
aws s3 sync "$BUILD/" "s3://$BUCKET/" --delete --cache-control "no-cache"
aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*" \
  --query 'Invalidation.{Id:Id,Status:Status}' --output text
rm -rf "$BUILD"
echo "Published version: $VERSION"
echo "Open: $URL"
