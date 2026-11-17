# Online Exam Platform on AWS (DSO303)

Namgyel Wangchuk (02230291), DSO303 Cloud, CST.

A cloud architecture for a university of 8,000 students and 400 staff that runs timed MCQ and short-answer exams with 30-second autosave, auto-marks MCQs, accepts assignment uploads (PDF or ZIP, up to 50 MB) and emails people when work arrives or results are released. It is designed for an exam-week peak of 3,000 students starting one exam within 5 minutes, 99.9% availability, survival of one Availability Zone, an RPO of 5 minutes, an RTO of 1 hour, 5-year records and encryption in transit and at rest.

The **production design** is fully serverless across two Availability Zones (edge, frontend, identity, API, private compute subnets, regional multi-AZ data, async processing, security, observability, CI/CD). A **lean version** of it was deployed to a real AWS account from code, demonstrated, and then torn down.

## Where everything is

| Rubric item | Where to look |
|---|---|
| AWS architecture design | `architecture/`: diagram, component placement by tier and AZ, both request walkthroughs, the 300-word peak and AZ-loss section, and how each target is met (`architecture/walkthroughs.md`) |
| AWS service documentation | `docs/services.md`: every service with its role, the alternative it beat, its configuration, what it connects to, and whether the demo runs it |
| Implementation: Cloud Architecture Lab | `architecture/` (diagram) and `evidence/` (the full build, both flows and the AZ-failure simulation) |
| Implementation: AWS deployment | `evidence/aws/`: frontend, API, database, S3 uploads and the async step, all on real AWS (see the evidence index below) |
| Implementation: IaC and CI/CD | `infra/bootstrap.yaml`, `template.yaml`, `samconfig.toml`, `.github/workflows/deploy.yml`, `scripts/`; pipeline evidence in `evidence/cicd/` |

## Repository layout

```
.github/workflows/deploy.yml   CI/CD: push to main -> validate -> deploy -> publish frontend -> smoke test
infra/bootstrap.yaml           Deployed once: artifact bucket, CloudFormation execution role, GitHub OIDC deploy role
template.yaml                  The application (AWS SAM): DynamoDB, S3, SQS + DLQ, SNS, Lambda, HTTP API, CloudFront
samconfig.toml                 Deploy settings shared by laptop and CI (stack, region, bucket, role, email)
src/                           Lambda code: api.py (exam API, autosave, submit, upload URLs), notifier.py (async), health.py
frontend/index.html            The exam page (autosave every 30 s, resume, timer, submit, direct-to-S3 upload)
scripts/real-aws.sh            Switches a terminal to real AWS and refuses to run against the Floci emulator
scripts/publish-frontend.sh    Builds config.js from stack outputs, syncs to S3, invalidates CloudFront
scripts/smoke-test.sh          End-to-end test: exam, autosave, resume, submit, upload, async notification
scripts/teardown.sh            Deletes everything in the right order and checks for leftovers
architecture/                  Diagram and walkthroughs (Task 1)
docs/services.md               Service table (Task 2)
evidence/                      Screenshots and command output
```

## Design vs deployed

The deployment had to fit about $8 of a shared $200 credit, a shared account with 23 students, and one day. Each difference below is deliberate.

| Production design | Deployed demo | Why |
|---|---|---|
| Route 53, custom domain, ACM certificate | CloudFront default `*.cloudfront.net` domain | No domain is owned for the course; the default domain still gives HTTPS |
| AWS WAF on CloudFront | Not deployed | A web ACL and its rules have a monthly charge; demo traffic needs no filtering |
| Cognito sign-in with groups and a JWT authorizer | The page asks for a student ID | Not part of the deployment rubric item; the design, service table and walkthroughs cover it |
| VPC with Lambda in private subnets, one NAT gateway per AZ, VPC endpoints | Lambda outside a VPC; no VPC | Two NAT gateways and interface endpoints are billed per hour; every deployed service is regional and multi-AZ by itself |
| DynamoDB with a customer-managed KMS key, deletion protection and AWS Backup (5 years) | DynamoDB on-demand with PITR; AWS-owned key; deletion protection off | Same-day teardown: a customer-managed key cannot be deleted for 7 days, and deletion protection would block it |
| Submissions bucket with SSE-KMS, versioning and Object Lock | SSE-S3, lifecycle rules, event notifications, CORS, HTTPS-only | Object Lock would keep the bucket undeletable for years in a shared account |
| Asynchronous MCQ marking through SQS | Marking runs inside the submit request; the deployed async step is upload, then SQS (with DLQ), then Lambda, then SNS email | The rubric asks for one async step; the upload chain is exactly walkthrough 2 |
| SES email to students | SNS email to one address | The shared account is in the SES sandbox |
| EventBridge Scheduler, X-Ray, CloudTrail trail, GuardDuty | Not deployed | Time and cost; CloudWatch Logs (declared with retention) and CloudTrail event history were used |
| Provisioned concurrency and a raised Lambda quota | None | The course account's Lambda limit is 10 per region, which leaves no room to reserve concurrency |
| Region ap-south-1, nearest to the university | us-west-2 | Lambda concurrency is shared per region; us-west-2 had no other students' functions |
| Aurora was considered for the database | DynamoDB | The account is on the AWS Free Plan, which only allows Aurora in express mode, at most 2 instances for the whole account; DynamoDB is multi-AZ on every write and suits autosave anyway |

## Deploy

### Prerequisites

AWS CLI, AWS SAM CLI, Python 3, git, and an IAM user with admin rights in the target account. All commands run from the repository root.

### 1. Open a real-AWS terminal

```bash
source scripts/real-aws.sh
```

It clears every `AWS_*` variable (so nothing points at the Floci emulator), selects the `dso-real` profile and us-west-2, and refuses to continue unless the caller is the expected user and account. The prompt then starts with a red `[REAL AWS us-west-2]`. To use another account, edit `EXPECTED_ACCOUNT` and `EXPECTED_USER` at the top of the script.

### 2. Bootstrap (once per account)

The GitHub OIDC provider is account-wide. Check whether it exists; create it only if it does not, and never delete it, because others may depend on it:

```bash
aws iam list-open-id-connect-providers
# only if token.actions.githubusercontent.com is missing:
aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com --thumbprint-list ab9d0263244dd0326eb67015705a667e79cfe998
```

Then deploy the bootstrap stack:

```bash
aws cloudformation deploy --stack-name dso303-exam-namgyelw-bootstrap \
  --template-file infra/bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM \
  --tags owner=NamgyelW project=dso303-exam
aws cloudformation describe-stacks --stack-name dso303-exam-namgyelw-bootstrap \
  --query 'Stacks[0].Outputs' --output table
```

Copy `ArtifactBucketName` into `s3_bucket` and `CfnExecutionRoleArn` into `role_arn` in `samconfig.toml`, and `GitHubDeployRoleArn` into `role-to-assume` in `.github/workflows/deploy.yml`.

For a different repository, update the trust policy's `sub` value in `infra/bootstrap.yaml`. GitHub pins it with immutable IDs, in the form `repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main`; the two IDs are the `owner.id` and `id` fields of `https://api.github.com/repos/OWNER/REPO`.

### 3. Deploy the application

Set your email address in `parameter_overrides` in `samconfig.toml`, then:

```bash
sam validate --lint && sam deploy
```

Confirm the "AWS Notification - Subscription Confirmation" email, or upload notifications will not be delivered.

### 4. Publish the frontend and test

```bash
scripts/publish-frontend.sh          # prints the CloudFront URL
scripts/smoke-test.sh my-first-run   # exam, autosave, resume, submit, upload, async email
```

### 5. Continuous deployment

From now on, every push to `main` runs `.github/workflows/deploy.yml`: GitHub gets temporary AWS credentials through OIDC (no keys are stored in GitHub), then runs `sam validate --lint`, `sam deploy`, `scripts/publish-frontend.sh` and `scripts/smoke-test.sh`. A run can also be started by hand with **Run workflow** on the Actions page.

## Tear down

1. On GitHub, open **Actions**, then **Deploy to AWS**, then the **...** menu, and choose **Disable workflow**, so a later push does not try to deploy into a torn-down account.
2. In a real-AWS terminal:

   ```bash
   source scripts/real-aws.sh
   scripts/teardown.sh
   ```

   It asks you to type `DELETE`, empties the buckets, deletes the **app stack first** (CloudFormation deletes it as the execution role, which lives in the bootstrap stack), then the bootstrap stack, and finally lists any leftovers: stacks, log groups, CloudFront distributions, IAM roles and tagged resources. Every list should be empty. Deleting the CloudFront distribution takes about 5–15 minutes.
3. The account's GitHub OIDC provider is left in place on purpose.

## Evidence index

| File | Shows |
|---|---|
| `evidence/aws/00-identity.txt` | Real AWS account and user (not the emulator) |
| `evidence/aws/01-bootstrap-stack.txt` | Bootstrap stack, its tags and outputs |
| `evidence/aws/02-health-api.txt` | API to Lambda to DynamoDB, write and read |
| `evidence/aws/03-dynamodb-table-pitr.txt` | On-demand table, point-in-time recovery enabled |
| `evidence/aws/04-submissions-bucket-config.txt` | Lifecycle rules (IA, Glacier, 5-year expiry), encryption, public access blocked |
| `evidence/aws/05-smoke-test-run-1.txt` | End to end: exam without answer key, autosave, resume, marking (2 of 3), presigned upload (`204`), rejected `.exe`, queue, notifier log, DynamoDB records |
| `evidence/aws/06-upload-email-run-1.png`, `13-upload-email-run-2.png` | Tutor notification emails from the async step |
| `evidence/aws/07-dlq-empty.txt` | No failed messages in the dead-letter queue |
| `evidence/aws/08`–`12-*.png` | Browser: CloudFront URL and version, autosave status, resume after refresh, upload, submit |
| `evidence/aws/14-frontend-bucket-private.txt` | Direct S3 access refused (`403`); CloudFront is the only way in |
| `evidence/cicd/01-oidc-trust-policy.txt` | Deploy role trusts only this repository's `main` branch, pinned by immutable IDs |
| `evidence/cicd/02`–`06-*.png` | Pipeline runs, all steps green, assumed role (no keys), smoke test in CI, live page updated by a push |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| Changeset failed: execution role not allowed `CreateChangeSet` on the Serverless transform | When a stack uses a service role, CloudFormation runs the SAM transform as that role | Allowed the transform for the execution role |
| Aurora cluster creation refused | The account is on the AWS Free Plan: Aurora only in express mode, 2 instances per account | Switched to DynamoDB (multi-AZ by design) and removed the unused RDS and EC2 permissions |
| Lambda creation failed with S3 `AccessDenied` | Lambda fetches the code zip using the credentials of whoever creates the function | Gave the execution role read access to the artifact bucket |
| Event source mapping failed on tagging | Stack tags are copied to every taggable resource, including event source mappings | Allowed tagging on event source mappings only |
| Pipeline could not assume its role | GitHub's `sub` claim now includes immutable owner and repo IDs | Diagnosed by printing the token's claims; trust policy now matches the ID-pinned value (also safer against repo renames) |
| `cfn-lint` rejected Aurora 17.9 | The linter's bundled version list was older than the live API | Ignored that one rule on that one resource, with a comment |
| Circular dependency between the bucket and its queue policy | Each referred to the other | Queue policy matches the bucket by name pattern plus account ID |

## Cost

All resources were pay-per-use (Lambda, API Gateway, DynamoDB on-demand, S3, SQS, SNS, CloudFront) and were deleted the same day; the expected cost is well under one dollar.
