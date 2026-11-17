#!/usr/bin/env bash
# Remove everything this project created, in the only order that works:
#   1. app stack       (CloudFormation deletes it AS the execution role, which lives in the bootstrap stack)
#   2. bootstrap stack (artifact bucket, execution role, GitHub deploy role)
# The account's GitHub OIDC provider is shared with classmates and is never touched.
#
# Usage (in a [REAL AWS] terminal):  source scripts/real-aws.sh && scripts/teardown.sh
set -euo pipefail
APP=dso303-exam-namgyelw-app
BOOT=dso303-exam-namgyelw-bootstrap

stack_exists() { aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1; }
out() { aws cloudformation describe-stacks --stack-name "$1" \
          --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null || true; }

empty_bucket() {   # buckets in this project are unversioned, so removing current objects empties them
  local b="$1"
  if [ -z "$b" ] || [ "$b" = "None" ]; then return 0; fi
  if aws s3api head-bucket --bucket "$b" 2>/dev/null; then
    echo "  emptying s3://$b"
    aws s3 rm "s3://$b" --recursive --only-show-errors
  fi
}

echo "Caller: $(aws sts get-caller-identity --query Arn --output text)   region: ${AWS_REGION:-not set}"
read -r -p "Type DELETE to remove $APP and $BOOT: " answer
[ "$answer" = "DELETE" ] || { echo "Aborted - nothing deleted."; exit 1; }

if stack_exists "$APP"; then
  echo "== 1. App stack"
  empty_bucket "$(out "$APP" SubmissionsBucketName)"
  empty_bucket "$(out "$APP" FrontendBucketName)"
  echo "  deleting $APP (CloudFront makes this take about 5-15 minutes)"
  aws cloudformation delete-stack --stack-name "$APP"
  aws cloudformation wait stack-delete-complete --stack-name "$APP"
  echo "  $APP deleted"
else
  echo "== 1. App stack: already gone"
fi

if stack_exists "$BOOT"; then
  echo "== 2. Bootstrap stack"
  empty_bucket "$(out "$BOOT" ArtifactBucketName)"
  echo "  deleting $BOOT (the shared GitHub OIDC provider is not part of it)"
  aws cloudformation delete-stack --stack-name "$BOOT"
  aws cloudformation wait stack-delete-complete --stack-name "$BOOT"
  echo "  $BOOT deleted"
else
  echo "== 2. Bootstrap stack: already gone"
fi

echo
echo "== 3. Leftover check - every list below should be empty"
echo "-- live stacks:"
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?starts_with(StackName,'dso303-exam-namgyelw')].StackName" --output text
echo "-- log groups:"
aws logs describe-log-groups --log-group-name-prefix "$APP" --query 'logGroups[].logGroupName' --output text
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/$APP" --query 'logGroups[].logGroupName' --output text
echo "-- CloudFront distributions for this app:"
aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$APP exam frontend'].Id" --output text
echo "-- IAM roles:"
aws iam list-roles --query "Roles[?starts_with(RoleName,'dso303-exam-namgyelw')].RoleName" --output text
echo "-- resources tagged owner=NamgyelW (the tag index can lag a few minutes behind deletions):"
aws resourcegroupstaggingapi get-resources --tag-filters Key=owner,Values=NamgyelW \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
echo
echo "Done. Left in place on purpose: the account's GitHub OIDC provider (shared with classmates)."
