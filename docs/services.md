# Service documentation (Task 2)

Every service in the production design, why it was chosen over a realistic alternative, how it is configured, and what it connects to. The **Demo** column says whether the lean AWS deployment in this repository actually runs it (see the README's *Design vs deployed* table for the reasons behind each "No").

Tiers follow the diagram in `architecture/`: **Edge** (global), **Frontend**, **Identity**, **API and compute** (private app subnets in AZ-a and AZ-b), **Network**, **Data** (regional, multi-AZ managed services reached through VPC endpoints), **Async**, **Security**, **Observability and resilience**, **Delivery**.

## Edge

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| Amazon Route 53 | DNS for `exams.<university domain>` and health checks | Alias records to CloudFront work at the zone apex and are free to query; a 100% availability SLA. The university's own DNS server would be a single point of failure outside our control. | Public hosted zone; A/AAAA **alias** records to the CloudFront distribution; health check on `/health` | CloudFront, ACM (DNS validation) | No |
| Amazon CloudFront | Single HTTPS entry point: serves the frontend, caches the exam paper, forwards `/api/*` to API Gateway | Serving straight from an S3 website endpoint would need a public bucket, has no HTTPS on a custom domain, and no edge cache or WAF. CloudFront absorbs the 3,000-student start burst at the edge. | Origin Access Control (OAC) to a private S3 bucket; viewer protocol *redirect-to-https*, TLS 1.2 minimum; managed **CachingOptimized** policy for static files and **CachingDisabled** for `/api/*`; managed **SecurityHeadersPolicy**; price class 200 (includes Asian edge locations) | Route 53, WAF, ACM, S3 (frontend), API Gateway | Yes (default `cloudfront.net` domain, S3 origin only) |
| AWS WAF | Filters malicious traffic before it reaches the app | API Gateway throttling is per route, not per client; WAF blocks per-IP floods and common exploits at the edge, before any Lambda runs. | Web ACL attached to CloudFront; AWS managed **Common Rule Set** and **Known Bad Inputs**; rate-based rule per IP, with the campus NAT addresses in an IP set given a higher limit, because a whole exam hall shares a few public IPs | CloudFront, CloudWatch (metrics, sampled requests) | No |
| AWS Certificate Manager (ACM) | TLS certificates for the custom domain | Free, and renews automatically; an imported or purchased certificate must be rotated by hand and can expire mid-exam. | Public certificate in **us-east-1** (required for CloudFront); DNS validation through Route 53 | CloudFront, Route 53 | No |

## Frontend

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| Amazon S3 (frontend bucket) | Stores the static HTML, CSS and JavaScript | EC2 or ECS web servers would need patching, scaling and paying for idle time; static files need none of that. | Private bucket, all four Block Public Access settings on, SSE, bucket policy allows only **this** distribution (matched on its ARN) and denies non-TLS requests; deployed by `aws s3 sync` plus a CloudFront invalidation | CloudFront, GitHub Actions | Yes |

## Identity

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| Amazon Cognito | Role-based sign-in for students, tutors and administrators | Building our own user table means hashing passwords, MFA and token signing ourselves. Cognito issues JWTs that API Gateway validates natively, and federates to the university's existing identity provider. | User pool federated to the university IdP (SAML/OIDC); groups `students`, `tutors`, `admins` (sent as the `cognito:groups` claim); MFA required for tutors and admins; SPA app client with PKCE and no client secret; access tokens valid 60 minutes | CloudFront (sign-in pages), API Gateway (JWT authorizer), Lambda (reads the groups claim) | No (demo asks for a student ID) |

## API and compute (private app subnets, AZ-a and AZ-b)

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| Amazon API Gateway (HTTP API) | HTTPS front door for every API call | Cheaper and lower-latency than a REST API, with a built-in JWT authorizer. An ALB with containers would need servers running and scaled ahead of the peak. | JWT authorizer using the Cognito user pool; routes per action; stage throttling; CORS limited to the site's origin; access logs to CloudWatch | CloudFront, Cognito, Lambda, CloudWatch | Yes (no authorizer; CORS limited to the CloudFront domain) |
| AWS Lambda | Business logic: exam API and autosave, upload URLs, MCQ marking worker, upload notifier, results emailer | ECS Fargate behind an ALB (as in Labs 6–8) must be scaled ahead of a 5-minute spike and costs money while idle. Lambda scales per request within seconds and costs nothing between exams. | Python 3.12 on **arm64**; 256 MB; 15 s timeout; attached to the private app subnets in **both AZs**; one least-privilege role per function; **provisioned concurrency** on the API function during exam windows; maximum concurrency on queue consumers; log retention set | API Gateway, DynamoDB, S3, SQS, SNS, SES, Secrets Manager, KMS, CloudWatch, X-Ray | Yes (outside a VPC) |

## Network (VPC spanning AZ-a and AZ-b)

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| Amazon VPC | Network isolation for the compute tier | Lambda outside a VPC cannot be given controlled egress, security groups, or a private route to a future VPN link with the university's student information system. | `10.0.0.0/16`; per AZ: one **public** subnet, one **private app** subnet, one **private endpoint** subnet; internet gateway; per-AZ route tables; Lambda security group allows outbound HTTPS only, no inbound | NAT gateways, VPC endpoints, Lambda | No |
| NAT gateway (one per AZ) | Outbound internet for private Lambdas (university IdP and SIS APIs) | A NAT instance must be patched and scaled by us. One NAT per AZ, rather than one shared, means losing an AZ never cuts the other AZ's egress. | One NAT gateway in each public subnet; each private route table points to **its own AZ's** NAT | Internet gateway, private app subnets | No |
| VPC endpoints | Private access to AWS services without the internet | Sending AWS traffic through NAT costs per GB and leaves the private network; gateway endpoints for S3 and DynamoDB are free. | **Gateway** endpoints for S3 and DynamoDB on the private route tables; **interface** endpoints (one network interface per AZ) for SQS, SNS, Secrets Manager, KMS and CloudWatch Logs; endpoint policies limited to this application's resources | Lambda, DynamoDB, S3, SQS, SNS, Secrets Manager, KMS, CloudWatch | No |

## Data (regional services, replicated across AZs by AWS)

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| Amazon DynamoDB | Exams, answer keys, attempts and autosaves, results, submission records | RDS or Aurora Multi-AZ needs instances, a failover and connection management under a burst. Autosave is a high-rate single-item key-value write, which DynamoDB serves in milliseconds and **replicates across multiple AZs on every write**. (In the course account, Aurora was also blocked: the AWS Free Plan only allows express-mode Aurora, at most 2 instances for the whole account.) | **On-demand** capacity; single-table design (`pk`/`sk`); **point-in-time recovery** (per-second, 35 days); encryption with a customer-managed KMS key; deletion protection; conditional writes reject saves after the deadline; reached only through the gateway endpoint; AWS Backup for 5-year retention | Lambda, AWS Backup, KMS | Yes (on-demand, PITR on; AWS-owned key; deletion protection off for same-day teardown) |
| Amazon S3 (submissions bucket) | Stores assignment files (PDF or ZIP, up to 50 MB) | Cheaper and more durable than EBS or EFS, with no server to attach them to. Presigned POST uploads keep 50 MB files off the API (API Gateway's payload limit is 10 MB and Lambda's is 6 MB). | Private, Block Public Access on; **SSE-KMS**; versioning; Object Lock (governance mode) to protect submitted work; **lifecycle**: Standard-IA after 30 days, Glacier Flexible Retrieval after 180 days, expire after 1,825 days (5 years), abort incomplete multipart uploads after 1 day; `ObjectCreated` events on `submissions/` to SQS; CORS allows POST from the site only; HTTPS required | Lambda (presigned URLs), SQS, KMS, AWS Backup, GuardDuty | Yes (SSE-S3, lifecycle, events, CORS, HTTPS-only; no versioning or Object Lock) |

## Async processing

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| Amazon SQS | Buffers MCQ-marking jobs and upload events | Invoking workers directly (S3 straight to Lambda, or marking inside the submit request) means the deadline spike hits every worker at once and a failure is simply lost. A queue smooths the spike, retries, and keeps failures. | Standard queues; visibility timeout 6x the consumer's timeout (90 s); **dead-letter queue** after 3 receives, kept 14 days; SQS-managed encryption; queue policy accepts only our bucket and account; alarm when the DLQ is not empty | S3, Lambda, CloudWatch | Yes (upload queue and DLQ) |
| Amazon SNS | Fans out staff notifications: tutor upload emails and operations alarms | Calling email from each Lambda ties every producer to every consumer. A topic lets us add SMS or a chat channel later without changing code. | One topic per purpose; email subscriptions for tutors; separate alarm topic for on-call staff; encrypted with KMS | Lambda, CloudWatch alarms, SES (bounce reports) | Yes (one topic, one email subscription) |
| Amazon SES | Personalised email to students: results released, upload receipts | SNS email has a fixed format and makes each recipient confirm a subscription, which does not work for 8,000 students. SES sends individual templated messages. | Production access (out of the sandbox); verified university domain with DKIM, SPF and DMARC; email templates; configuration set publishing bounces and complaints to SNS | Lambda (results emailer), SNS | No (the account is in the SES sandbox) |
| Amazon EventBridge Scheduler | Opens and closes exams and releases results at set times | Cron on a server needs a server that is always running. Scheduler creates one-off, serverless schedules per exam, with retries. | A one-time schedule per exam event, created by the admin API; target is a Lambda function; retry policy and a dead-letter queue | Lambda | No (the demo exam is always open) |

## Security

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| AWS KMS | Encryption keys for data at rest | AWS-owned keys encrypt data but give no control or audit. Customer-managed keys add key policies, rotation control and a CloudTrail record of every decrypt. | Separate customer-managed keys for submissions, database and messaging; automatic annual rotation; least-privilege key policies | S3, DynamoDB, SQS, SNS, Secrets Manager, CloudWatch Logs | No (AWS-owned and AWS-managed keys, so teardown leaves nothing behind) |
| AWS Secrets Manager | Third-party credentials: SIS API key, IdP client secret | Environment variables are visible in the console and never rotate; Parameter Store has no built-in rotation. Secrets Manager rotates and audits access. | Encrypted with a customer-managed key; 30-day rotation; read through an interface endpoint and cached inside the function | Lambda, KMS | No (the demo has no third-party secrets) |
| AWS IAM | Identities and least privilege for people, functions and the pipeline | Long-lived access keys can leak; roles issue temporary credentials that expire on their own. | One role per Lambda function; GitHub deploy role trusted only for this repository's **main** branch, pinned by **immutable owner and repo IDs**; separate CloudFormation execution role limited to resources named after the app stack; no access keys anywhere in GitHub | Every service | Yes |
| Amazon GuardDuty | Threat detection, and malware scanning of uploaded files | Student uploads are untrusted files that tutors open on their own machines; without scanning, one infected ZIP reaches staff. | Enabled for the account; **Malware Protection for S3** on the submissions bucket, tagging each object with the scan result; findings sent through EventBridge to SNS | S3, EventBridge, SNS | No |

## Observability and resilience

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| Amazon CloudWatch | Logs, metrics, alarms and a dashboard | Built into Lambda and API Gateway with no agents; a third-party APM adds cost and another vendor. | Structured JSON logs, 90-day retention; alarms on API 5xx rate above 1%, p99 latency above 1 s, Lambda throttles, DynamoDB throttles and a non-empty DLQ; exam-day dashboard; alarm actions to SNS | Every service, SNS | Yes (log groups declared in the template, 7-day retention) |
| AWS X-Ray | Traces each request across API Gateway, Lambda and DynamoDB | Logs alone show that a request was slow, not which hop was slow. | Active tracing on API Gateway and Lambda; sampling rule of a small fixed rate plus a reservoir | API Gateway, Lambda | No |
| AWS CloudTrail | Audit trail of every API call, such as who changed a result | The default 90-day event history is too short for a 5-year records requirement. | Multi-region trail to a dedicated, Object-Locked log bucket; log file validation; data events on the submissions bucket | S3, CloudWatch | Account event history only (used to debug the pipeline) |
| AWS Backup | 5-year retention and off-region copies of exam records | DynamoDB PITR only reaches back 35 days, and lives in the same region. | Backup plan: daily backups kept 35 days, monthly backups kept 5 years in cold storage, copies to a second region; vault lock | DynamoDB, S3, KMS | No |

## Delivery

| Service | Role | Why over an alternative | Key configuration | Connects to | Demo |
|---|---|---|---|---|---|
| AWS SAM (on CloudFormation) | Infrastructure as code for the whole stack | Terraform needs a remote state file and lock table set up first; CDK needs a bootstrap stack that would be shared by 23 students in one account. SAM has neither, and its serverless shorthand keeps templates short. | `template.yaml` (app) and `infra/bootstrap.yaml` (artifact bucket, roles); changesets; deploys through a scoped execution role; stack tags `owner` and `project` on every resource | GitHub Actions, IAM, every deployed resource | Yes |
| GitHub Actions (with OIDC) | CI/CD: every push to `main` redeploys | CodePipeline (Lab 11) needs a console-approved GitHub connection and more resources to manage. Actions keeps the pipeline in the repository, and OIDC means no AWS keys are stored in GitHub. | Trigger on push to `main`; `id-token: write`; steps: validate, `sam deploy`, publish frontend, smoke test; concurrency group so deploys never overlap; in production, a protected environment requiring approval during exam weeks | IAM (OIDC role), CloudFormation, S3, CloudFront | Yes |
