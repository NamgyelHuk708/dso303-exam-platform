# Online Exam and Assignment Platform on AWS

**DSO303 Cloud: Assignment 2.** Namgyel Wangchuk (02230291), College of Science and Technology.

## Summary

A university with 8,000 students and 400 staff is moving its exams and assignment submissions online. This repository contains the cloud architecture for that platform, a working deployment of it on AWS, and the evidence that it works.

The platform lets students sit timed MCQ and short-answer exams with **answers autosaved every 30 seconds**, has MCQs **marked automatically**, accepts **assignment uploads (PDF or ZIP, up to 50 MB)**, and **emails tutors** when work arrives. It is designed for an exam-week peak of **3,000 students starting one exam within 5 minutes**, **99.9% availability**, survival of the **loss of one Availability Zone**, an **RPO of 5 minutes**, an **RTO of 1 hour**, **5-year record retention**, and **encryption in transit and at rest**.

The **production design** is serverless and spans two Availability Zones: a global edge (Route 53, CloudFront, WAF), a Cognito sign-in, an API Gateway and Lambda tier in private subnets in both AZs, DynamoDB and S3 for data, SQS, SNS and SES for asynchronous work, and KMS, CloudWatch, CloudTrail and AWS Backup around it.

A **lean version** of that design was deployed to a real AWS account **entirely from code** (AWS SAM), redeployed automatically by **GitHub Actions on every push to `main`** with no stored AWS keys, tested end to end, and then torn down. Every difference between the design and the deployment is listed, with its reason, in [Design vs deployed](#design-vs-deployed).

## Where to find each rubric item

| Rubric item | Where to look |
|---|---|
| **AWS architecture design** | [`architecture/architecture-diagram.png`](architecture/architecture-diagram.png) and [`architecture/walkthroughs.md`](architecture/walkthroughs.md): component placement by tier and AZ, both request walkthroughs, the exam peak and AZ loss (295 words), and how each target is met |
| **AWS service documentation** | [`docs/services.md`](docs/services.md): every service with its role, the alternative it was chosen over, its configuration, what it connects to, and whether the demo runs it |
| **Implementation: Cloud Architecture Lab** | Build and scenarios in [`architecture/`](architecture/) (four JSON files); results and screenshots in [`evidence/simulator/`](evidence/simulator/): full build, walkthrough 1, walkthrough 2, and AZ-A failure for both walkthroughs |
| **Implementation: AWS deployment** | [`evidence/aws/`](evidence/aws/) (command output, browser, emails) and [`evidence/console/`](evidence/console/) (AWS Console): frontend, API, database, S3 upload and the async step, all on real AWS |
| **Implementation: IaC and CI/CD** | [`infra/bootstrap.yaml`](infra/bootstrap.yaml), [`template.yaml`](template.yaml), [`samconfig.toml`](samconfig.toml), [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml), [`scripts/`](scripts/); pipeline evidence in [`evidence/cicd/`](evidence/cicd/) |

## Key design decisions

**Serverless rather than containers.** The hardest moment is 3,000 students starting within 5 minutes. Lambda and API Gateway scale per request within seconds and cost nothing between exams, whereas EC2 or ECS capacity has to be scaled up before the peak and paid for while idle.

**DynamoDB as the database.** Autosave is a single-item write repeated every 30 seconds by every student, which is about 100 writes per second at peak. DynamoDB on-demand handles this without capacity planning or connection pooling, and **stores every write in multiple Availability Zones before confirming it**, so there is no failover to wait for when an AZ is lost. Point-in-time recovery restores the table to any second in the last 35 days.

- *Aurora* was tried first, but the course account is on the AWS Free Plan, which only allows Aurora in "express" mode with at most two instances for the whole shared account.
- *RDS Multi-AZ* would also have worked, but it needs Lambda inside a VPC with NAT gateways or endpoints, and connection pooling (RDS Proxy) for 3,000 near-simultaneous students. For a key-value autosave workload, DynamoDB is the simpler and more resilient choice.

**Uploads go straight to S3.** The API returns a **presigned POST** that is valid for 5 minutes, for one key and one file type, with an S3-enforced limit of 50 MB. A 40 MB file therefore never passes through API Gateway (10 MB limit) or Lambda (6 MB limit).

**A queue between the upload and the notification.** S3 publishes each new submission to SQS, and a Lambda worker records it and emails the tutor through SNS. A burst of uploads at a deadline is absorbed by the queue, failures are retried, and anything that fails three times waits in a dead-letter queue instead of being lost.

**No AWS keys in GitHub.** The pipeline gets short-lived credentials through **OIDC**. The deploy role trusts only this repository's `main` branch, identified by GitHub's **immutable owner and repository IDs**, so even a renamed or re-created repository with the same name could not use it. The deploy role can only change the app stack, and CloudFormation builds that stack through a separate execution role limited to resources named after the stack.

## Repository layout

```
.github/workflows/deploy.yml   CI/CD: push to main -> validate -> deploy -> publish frontend -> smoke test
infra/bootstrap.yaml           Deployed once: artifact bucket, CloudFormation execution role, GitHub OIDC deploy role
template.yaml                  The application (AWS SAM): DynamoDB, S3, SQS + DLQ, SNS, Lambda, HTTP API, CloudFront
samconfig.toml                 Deploy settings used by both the laptop and CI
src/                           Lambda code: api.py (exam, autosave, submit, upload URL), notifier.py (async), health.py
frontend/index.html            Exam page: 30-second autosave, resume after refresh, timer, submit, direct-to-S3 upload
scripts/real-aws.sh            Points a terminal at real AWS and refuses to run against the Floci emulator
scripts/publish-frontend.sh    Writes config.js from stack outputs, syncs to S3, invalidates CloudFront
scripts/smoke-test.sh          End-to-end test of the live system (also run by the pipeline)
scripts/teardown.sh            Deletes everything in the right order and checks for leftovers
architecture/                  Diagram, walkthroughs, Cloud Architecture Lab JSON files (Task 1, Task 3)
docs/services.md               Service table (Task 2)
evidence/                      aws/, console/, cicd/, simulator/
```

## Design vs deployed

The deployment had to fit about $8 of a $200 credit shared by 23 students, run in a shared account, and be built and removed in one day. Each difference is deliberate.

| Production design | Deployed demo | Why |
|---|---|---|
| Route 53, custom domain, ACM certificate | CloudFront's default `*.cloudfront.net` domain | No domain is owned for the course; the default domain still serves HTTPS |
| AWS WAF on CloudFront | Not deployed | Web ACLs and rules are charged monthly; demo traffic needs no filtering |
| Cognito sign-in with groups and a JWT authorizer | The page asks for a student ID | Not part of the deployment rubric item; covered in the design, service table and walkthroughs |
| VPC with Lambda in private subnets in both AZs, a NAT gateway per AZ, VPC endpoints | Lambda outside a VPC | NAT gateways and interface endpoints are charged per hour; every deployed service is already regional and multi-AZ |
| DynamoDB with a customer-managed KMS key, deletion protection, AWS Backup for 5 years | DynamoDB on-demand with PITR, default encryption, deletion protection off | Same-day teardown: a customer-managed key cannot be deleted for 7 days, and deletion protection would block removal |
| Submissions bucket with SSE-KMS, versioning and Object Lock | SSE-S3 encryption, 5-year lifecycle rules, event notifications, CORS, HTTPS-only policy | Object Lock would keep the bucket undeletable for years in a shared account |
| MCQ marking through an SQS queue | Marking runs inside the submit request; the deployed async step is upload, SQS (with DLQ), Lambda, SNS email | The rubric asks for one async step, and this chain is exactly walkthrough 2 |
| SES email to students | SNS email to one address | The shared account is in the SES sandbox |
| EventBridge Scheduler, X-Ray, CloudTrail trail, GuardDuty | Not deployed | Time and cost; CloudWatch Logs (with retention) and the CloudTrail event history were used |
| Provisioned concurrency and a raised Lambda quota | Neither | The account's Lambda limit is 10 per region, which leaves nothing to reserve |
| Region ap-south-1 (Mumbai), nearest to the university | us-west-2 (Oregon) | Lambda concurrency is shared per region, and no other students were using us-west-2 |

## Deploy

All commands run from the repository root. You need the AWS CLI, the AWS SAM CLI, Python 3, git, and an IAM user with administrator rights in the target account.

### 1. Open a terminal pointed at real AWS

```bash
source scripts/real-aws.sh
```

This clears every `AWS_*` environment variable (so nothing points at the Floci emulator), selects the `dso-real` profile and the us-west-2 region, and stops unless the caller is the expected user in the expected account. The prompt then starts with a red `[REAL AWS us-west-2]`. For another account, edit `EXPECTED_ACCOUNT` and `EXPECTED_USER` at the top of the script.

### 2. Bootstrap the account (once)

The GitHub OIDC provider is shared by the whole account. Create it only if it does not exist, and never delete it, because others may depend on it:

```bash
aws iam list-open-id-connect-providers
# only if token.actions.githubusercontent.com is missing:
aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com --thumbprint-list ab9d0263244dd0326eb67015705a667e79cfe998
```

Deploy the bootstrap stack and read its outputs:

```bash
aws cloudformation deploy --stack-name dso303-exam-namgyelw-bootstrap \
  --template-file infra/bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM \
  --tags owner=NamgyelW project=dso303-exam
aws cloudformation describe-stacks --stack-name dso303-exam-namgyelw-bootstrap \
  --query 'Stacks[0].Outputs' --output table
```

Put `ArtifactBucketName` into `s3_bucket` and `CfnExecutionRoleArn` into `role_arn` in `samconfig.toml`, and put `GitHubDeployRoleArn` into `role-to-assume` in `.github/workflows/deploy.yml`.

For a different GitHub repository, change the trust policy's `sub` value in `infra/bootstrap.yaml`. GitHub's format is `repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main`; the two IDs are the `owner.id` and `id` fields at `https://api.github.com/repos/OWNER/REPO`.

### 3. Deploy the application

Put the address that should receive upload notifications into `parameter_overrides` in `samconfig.toml`, then:

```bash
sam validate --lint && sam deploy
```

Open the "AWS Notification - Subscription Confirmation" email and confirm it; until then, no notifications are delivered.

### 4. Publish the frontend and test the system

```bash
scripts/publish-frontend.sh        # prints the CloudFront URL of the exam page
scripts/smoke-test.sh my-run-1     # exam, autosave, resume, submit, upload, async email
```

### 5. Continuous deployment

From then on, every push to `main` runs [`deploy.yml`](.github/workflows/deploy.yml): GitHub obtains temporary AWS credentials through OIDC, then runs `sam validate --lint`, `sam deploy`, `scripts/publish-frontend.sh` and `scripts/smoke-test.sh`. The **Run workflow** button on the Actions page starts a run by hand.

## Tear down

1. On GitHub, open **Actions**, then **Deploy to AWS**, then the **...** menu, and choose **Disable workflow**, so a later push cannot try to deploy into a removed account.
2. In a real-AWS terminal:

   ```bash
   source scripts/real-aws.sh
   scripts/teardown.sh
   ```

   The script asks you to type `DELETE`, empties the three buckets, deletes the **app stack first** (CloudFormation deletes it using the execution role, which lives in the bootstrap stack), then deletes the **bootstrap stack**, and finally lists anything left over: stacks, log groups, CloudFront distributions, IAM roles and tagged resources. Every list should be empty. Deleting the CloudFront distribution takes about 5 to 15 minutes.
3. The account's GitHub OIDC provider is left in place on purpose, because it is shared.

## Evidence

### Real AWS: command output, browser and email ([`evidence/aws/`](evidence/aws/))

| File | Shows |
|---|---|
| [`00-identity.txt`](evidence/aws/00-identity.txt) | Commands ran against the real AWS account as NamgyelW, not the emulator |
| [`01-bootstrap-stack.txt`](evidence/aws/01-bootstrap-stack.txt) | Bootstrap stack created from code, with its tags and outputs |
| [`02-health-api.txt`](evidence/aws/02-health-api.txt) | API Gateway to Lambda to DynamoDB, a real write and read |
| [`03-dynamodb-table-pitr.txt`](evidence/aws/03-dynamodb-table-pitr.txt) | On-demand table with point-in-time recovery enabled |
| [`04-submissions-bucket-config.txt`](evidence/aws/04-submissions-bucket-config.txt) | Lifecycle rules (IA at 30 days, Glacier at 180, delete at 1,825), encryption, public access blocked |
| [`05-smoke-test-run-1.txt`](evidence/aws/05-smoke-test-run-1.txt) | End to end: exam without the answer key, autosave, resume, marking (2 of 3), presigned upload accepted by S3 (`204`), `.exe` rejected, notifier log, database records |
| [`06-upload-email-run-1.png`](evidence/aws/06-upload-email-run-1.png), [`13-upload-email-run-2.png`](evidence/aws/13-upload-email-run-2.png) | Tutor notification emails produced by the async step |
| [`07-dlq-empty.txt`](evidence/aws/07-dlq-empty.txt) | No failed messages in the dead-letter queue |
| [`08-frontend-start.png`](evidence/aws/08-frontend-start.png) | The exam page on its CloudFront URL, with the version footer |
| [`09-autosave.png`](evidence/aws/09-autosave.png) | Autosave working: "All changes saved at ..." |
| [`10-resume.png`](evidence/aws/10-resume.png) | Answers restored after a page refresh |
| [`11-upload.png`](evidence/aws/11-upload.png) | A real PDF uploaded straight to S3 from the browser |
| [`12-submit.png`](evidence/aws/12-submit.png) | Submitted, with the auto-marked MCQ score |
| [`14-frontend-bucket-private.txt`](evidence/aws/14-frontend-bucket-private.txt) | Direct S3 access refused (`403`): CloudFront is the only way in |
| [`15-teardown.txt`](evidence/aws/15-teardown.txt) | Teardown output and an empty leftover check |

### AWS Console ([`evidence/console/`](evidence/console/))

All taken in US West (Oregon) while the system was running.

| File | Shows |
|---|---|
| [`01-cloudformation-stacks.png`](evidence/console/01-cloudformation-stacks.png) | Both stacks (bootstrap and app) deployed from code, in US West (Oregon) |
| [`02-app-stack-resources.png`](evidence/console/02-app-stack-resources.png) | Every resource in the app stack, all complete |
| [`03-dynamodb-backups.png`](evidence/console/03-dynamodb-backups.png) | DynamoDB point-in-time recovery switched on (RPO evidence) |
| [`04-dynamodb-items.png`](evidence/console/04-dynamodb-items.png) | Real exam, attempt, result and upload items written by the app |
| [`05-s3-submissions-objects.png`](evidence/console/05-s3-submissions-objects.png) | Uploaded assignment files in the submissions bucket |
| [`06-s3-lifecycle.png`](evidence/console/06-s3-lifecycle.png) | Lifecycle rules: Standard-IA, Glacier, deletion after 5 years |
| [`07-lambda-functions.png`](evidence/console/07-lambda-functions.png) | The API, notifier and health functions (Python 3.12) |
| [`08-api-gateway-routes.png`](evidence/console/08-api-gateway-routes.png) | The HTTP API routes |
| [`09a-sqs-upload-queue.png`](evidence/console/09a-sqs-upload-queue.png) | The upload queue between S3 and the notifier |
| [`09b-sqs-dead-letter-queue.png`](evidence/console/09b-sqs-dead-letter-queue.png) | The dead-letter queue, empty: no message failed |
| [`10-sns-subscription.png`](evidence/console/10-sns-subscription.png) | Tutor email subscription confirmed |
| [`11-cloudfront-distribution.png`](evidence/console/11-cloudfront-distribution.png) | The CloudFront distribution serving the exam page |
| [`12-cloudwatch-notifier-logs.png`](evidence/console/12-cloudwatch-notifier-logs.png) | The notifier's `"notified": true` log line: the async step ran |
| [`12a-notifier-log-group-retention-tags.png`](evidence/console/12a-notifier-log-group-retention-tags.png) | Log group created by CloudFormation, 1-week retention, `owner` and `project` tags |
| [`13-iam-github-role-trust.png`](evidence/console/13-iam-github-role-trust.png) | GitHub deploy role trusted only through OIDC, for this repository's `main` branch |

### CI/CD ([`evidence/cicd/`](evidence/cicd/))

| File | Shows |
|---|---|
| [`01-oidc-trust-policy.txt`](evidence/cicd/01-oidc-trust-policy.txt) | The deploy role trusts only this repository's `main` branch, pinned by immutable IDs |
| [`02-actions-runs-list.png`](evidence/cicd/02-actions-runs-list.png) | Pipeline runs triggered by pushes to `main` |
| [`03-run-steps-green.png`](evidence/cicd/03-run-steps-green.png) | Every step of a run succeeded |
| [`04-assumed-identity.png`](evidence/cicd/04-assumed-identity.png) | The pipeline ran as the deploy role through OIDC, with no stored keys |
| [`05-ci-smoke-test.png`](evidence/cicd/05-ci-smoke-test.png) | The pipeline tested the live system after deploying |
| [`06-site-updated.png`](evidence/cicd/06-site-updated.png) | The live page showing the new commit after a push |

### Cloud Architecture Lab ([`evidence/simulator/`](evidence/simulator/))

| File | Shows |
|---|---|
| [`01-full-build.png`](evidence/simulator/01-full-build.png) | The full production design: two AZs, public, private app and private endpoint subnets, every service in its tier |
| [`02-walkthrough1-200.png`](evidence/simulator/02-walkthrough1-200.png) | Walkthrough 1 (open exam, autosave) completes with 200 |
| [`03-walkthrough2-202.png`](evidence/simulator/03-walkthrough2-202.png) | Walkthrough 2 (40 MB upload, tutor notified) accepted with 202, workers in both AZs |
| [`04-az-a-failed-walkthrough1.png`](evidence/simulator/04-az-a-failed-walkthrough1.png) | AZ-A failed: walkthrough 1 still completes through the AZ-B Lambda |
| [`05-az-a-failed-walkthrough2.png`](evidence/simulator/05-az-a-failed-walkthrough2.png) | AZ-A failed: SQS redelivers to the AZ-B worker, nothing lost |
| [`SIMULATION-RESULTS.md`](evidence/simulator/SIMULATION-RESULTS.md) | Summary of every scenario and its result |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| Changeset refused: execution role not allowed to run the SAM transform | When a stack uses a service role, CloudFormation runs the transform as that role | Allowed `CreateChangeSet` on the transform for the execution role |
| Aurora cluster creation refused | The account is on the AWS Free Plan: Aurora only in express mode, at most 2 instances per account | Chose DynamoDB, and removed the unused RDS and EC2 permissions |
| Lambda creation failed with S3 `AccessDenied` | Lambda fetches the code package with the credentials of whoever creates the function | Gave the execution role read access to the artifact bucket |
| Queue trigger failed while tagging | Stack tags are copied to every taggable resource, including the SQS trigger | Allowed tagging on event source mappings only |
| Pipeline could not assume its role | GitHub's `sub` claim now contains immutable owner and repository IDs | Printed the token's claims to find the real value; the trust policy now matches it, which is also safer |
| Linter rejected the Aurora version | `cfn-lint`'s built-in version list was older than the live AWS API | Suppressed that single rule on that single resource, with a comment |
| Circular reference between the bucket and its queue policy | Each referred to the other | The queue policy matches the bucket by name pattern plus account ID |

## Limitations

- **Not deployed:** Cognito, WAF, Route 53 and a custom domain, the VPC tier, SES, EventBridge Scheduler, X-Ray, AWS Backup and GuardDuty (see [Design vs deployed](#design-vs-deployed)).
- **The demo trusts the typed student ID.** Anyone could save answers under another ID. In the design, the student's identity comes from the Cognito token, not from the browser.
- **The exam timer runs in the browser.** The design records the start time and deadline on the server and rejects saves after the deadline.
- **The peak was not load-tested.** Handling 3,000 starts in 5 minutes is supported by the reasoning in `architecture/walkthroughs.md` and by the simulator, not by a load test. The course account's Lambda limit of 10 would throttle a real peak; production needs a quota increase.
- **No live AZ failure was tested.** An AZ cannot be switched off in a real account; AZ loss was modelled in the Cloud Architecture Lab. The deployed services are regional, and DynamoDB's multi-AZ storage is AWS-documented behaviour that cannot be seen in the console.
- **Availability, RPO and RTO are design targets, not measurements.** Point-in-time recovery was enabled, but no restore was performed.
- **Five-year retention** is configured through S3 lifecycle rules only; Object Lock and AWS Backup are in the design.

## Cost

Everything deployed was pay-per-use (Lambda, API Gateway, DynamoDB on-demand, S3, SQS, SNS, CloudFront) and was deleted the same day. The expected cost is well under one dollar. The Cloud Architecture Lab estimates the full production design at about $206 a month, mainly NAT gateways, WAF and VPC endpoints.
