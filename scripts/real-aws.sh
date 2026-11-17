# scripts/real-aws.sh - switch THIS terminal to real AWS. Usage: source scripts/real-aws.sh
# Refuses to run unless the caller is NamgyelW in the course account (Floci reports 000000000000).

(return 0 2>/dev/null) || { echo "real-aws: run it as 'source scripts/real-aws.sh'"; exit 1; }

EXPECTED_ACCOUNT=363242104805
EXPECTED_USER=NamgyelW
REAL_REGION=us-west-2

# 1. Remove every AWS_* variable (e.g. AWS_PROFILE=floci from floci-env)
for v in $(env | grep -o '^AWS_[A-Z0-9_]*'); do unset "$v"; done

# 2. Point at the real profile and region
export AWS_PROFILE=dso-real
export AWS_REGION=$REAL_REGION
export AWS_DEFAULT_REGION=$REAL_REGION
export SAM_CLI_TELEMETRY=0

# 3. Verify identity before allowing anything else
identity=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1)
if [ $? -ne 0 ]; then
  echo "real-aws: identity check FAILED: $identity"
  unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION
  return 1
fi
read -r acct arn <<< "$identity"
if [ "$acct" != "$EXPECTED_ACCOUNT" ] || [[ "$arn" != *":user/$EXPECTED_USER" ]]; then
  echo "real-aws: REFUSING - this is $acct $arn, not $EXPECTED_USER@$EXPECTED_ACCOUNT"
  unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION
  return 1
fi

# 4. Red prompt tag, added only once even if sourced twice
[[ "$PS1" == *"[REAL AWS"* ]] || PS1="\[\e[41;97m\][REAL AWS $REAL_REGION]\[\e[0m\] $PS1"
echo "real-aws: OK  $arn  region=$AWS_REGION"
