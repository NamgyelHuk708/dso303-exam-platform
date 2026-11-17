# Architecture and request walkthroughs (Task 1)

The diagram in this folder shows the **production** design. The lean deployment that actually runs in AWS is a subset of it; the README's *Design vs deployed* table lists every difference and the reason for it.

Region: **ap-south-1 (Mumbai)** for production, the nearest AWS region to the university. The demo was deployed to us-west-2 because the shared course account's Lambda concurrency limit (10 per region) was untouched there. Two Availability Zones are used, called **AZ-a** and **AZ-b** below.

## 1. Component placement

| Tier | Where it runs | Components |
|---|---|---|
| Users | Internet | Students (8,000), tutors and administrators (400) in browsers |
| Edge | Global, outside the region | Route 53 (DNS), CloudFront (CDN, single entry point), AWS WAF (web ACL on CloudFront), ACM certificate |
| Frontend | Regional, multi-AZ by AWS | S3 frontend bucket (private, reachable only through CloudFront OAC) |
| Identity | Regional, multi-AZ by AWS | Cognito user pool, federated to the university IdP; groups `students`, `tutors`, `admins` |
| API | Regional, multi-AZ by AWS | API Gateway HTTP API with a Cognito JWT authorizer |
| Network: public subnets | **AZ-a** `10.0.0.0/24`, **AZ-b** `10.0.1.0/24` | One NAT gateway in each; internet gateway attached to the VPC |
| Compute: private app subnets | **AZ-a** `10.0.10.0/24`, **AZ-b** `10.0.11.0/24` | Lambda functions (exam API and autosave, upload-URL issuer, MCQ marking worker, upload notifier, results emailer), attached to **both** subnets |
| Network: private endpoint subnets | **AZ-a** `10.0.20.0/24`, **AZ-b** `10.0.21.0/24` | Interface VPC endpoints (one network interface per AZ) for SQS, SNS, Secrets Manager, KMS, CloudWatch Logs; gateway endpoints for S3 and DynamoDB on the private route tables |
| Data | Regional, replicated across AZs by AWS; reached **only** through the gateway endpoints | DynamoDB table (on-demand, PITR, KMS); S3 submissions bucket (SSE-KMS, versioning, Object Lock, lifecycle IA 30 d, Glacier 180 d, expire 1,825 d) |
| Async | Regional, multi-AZ by AWS | SQS marking queue and upload queue, each with a dead-letter queue; SNS topics (tutor notifications, alarms); SES (student emails); EventBridge Scheduler (exam open, close, results release) |
| Security | Regional | KMS customer-managed keys, Secrets Manager, IAM roles (one per function, GitHub OIDC deploy role), GuardDuty with Malware Protection for S3 |
| Observability and resilience | Regional | CloudWatch (logs, metrics, alarms, dashboard), X-Ray, CloudTrail (trail to a locked log bucket), AWS Backup (5-year plan, copy to a second region) |
| Delivery | Outside AWS, then CloudFormation | GitHub repository, then GitHub Actions (OIDC, no keys), then SAM/CloudFormation |

Nothing in the data tier has a public endpoint path from the application: Lambda reaches DynamoDB and S3 through gateway endpoints on its private route tables, and the frontend bucket only answers CloudFront.

## 2. Walkthrough 1: a student opens an exam and answers autosave

1. **DNS.** The browser resolves `exams.<university domain>`; Route 53 answers with an alias to the CloudFront distribution.
2. **Edge.** The browser connects to the nearest CloudFront edge over HTTPS (ACM certificate). WAF inspects the request (managed rules, per-IP rate limit) before anything else happens.
3. **Frontend.** CloudFront returns `index.html` and the JavaScript from its cache, or fetches them from the private S3 frontend bucket, signing the request with Origin Access Control.
4. **Sign-in.** The app redirects to Cognito, which federates to the university IdP. Cognito returns a JWT whose `cognito:groups` claim says `students`.
5. **Open the exam.** The browser calls `GET /api/exams/{id}` with the JWT. CloudFront forwards `/api/*` to API Gateway, whose JWT authorizer rejects bad or expired tokens before any code runs.
6. **Exam logic.** API Gateway invokes the exam Lambda, which runs in the private app subnet of AZ-a or AZ-b. It checks the group and that the exam is open (opened by an EventBridge schedule), then reads through the DynamoDB gateway endpoint: the exam paper (never the answer key, which is a separate item) and any saved attempt. On the first open it records a server-side start time and deadline.
7. **Autosave, every 30 seconds.** If anything changed, the browser sends `PUT /api/attempts/{id}/autosave` along the same path (CloudFront, WAF, API Gateway, Lambda). The Lambda makes a **conditional write** to the attempt's single `ANSWERS` item: it succeeds only while the attempt is open and before the deadline. DynamoDB stores the write in multiple AZs before confirming it.
8. **Confirmation.** The Lambda returns `savedAt`; the page shows "All changes saved at hh:mm:ss". If the save fails, the page keeps the answers marked unsaved and retries on the next 30-second tick.
9. **Telemetry.** Each invocation writes a structured log line to CloudWatch Logs and a trace to X-Ray; alarms watch the error rate and latency.
10. **Submit.** On submit, the Lambda saves the final answers and places a marking job on the SQS marking queue; the marking worker scores the MCQs against the answer key and writes the result. Results stay hidden until the tutor releases them, and SES then emails each student.

**What the demo deployment proves:** steps 3, 5–8 and the submit, without Cognito or WAF. Evidence: `evidence/aws/05-smoke-test-run-1.txt` (autosave, resume, marking), `09-autosave.png` and `10-resume.png` (browser).

## 3. Walkthrough 2: a student uploads a 40 MB assignment and the tutor is notified

1. **Choose the file.** The signed-in student selects a 40 MB PDF. The page checks the type (PDF or ZIP) and size (at most 50 MB) for fast feedback; the real limits are enforced by S3 in step 3.
2. **Ask for an upload URL.** The browser calls `POST /api/assignments/{id}/upload-url` with its JWT, through CloudFront and API Gateway. The Lambda checks that the student is enrolled and the deadline has not passed, then returns a **presigned POST** valid for 5 minutes. It is signed for one key (`submissions/{course}/{assignment}/{student}/{uuid}.pdf`), one content type, a `content-length-range` of at most 50 MB, and SSE-KMS.
3. **Upload straight to S3.** The browser sends the 40 MB file directly to the submissions bucket over HTTPS. The file never passes through API Gateway (10 MB payload limit) or Lambda (6 MB limit). S3 rejects anything over 50 MB, of the wrong type, or after the URL expires.
4. **Stored and protected.** S3 encrypts the object with KMS, versions it and applies Object Lock; the lifecycle rules start its 5-year clock. GuardDuty Malware Protection scans it and tags the result.
5. **Event.** S3 publishes an `ObjectCreated` event for the `submissions/` prefix to the SQS upload queue. The queue policy accepts messages only from this bucket in this account.
6. **Notifier.** Lambda polls the queue and runs the notifier function in the private app subnets. It writes a submission record to DynamoDB (student, file, size, upload time: the proof of an on-time submission) and looks up the course tutor.
7. **Notify.** The notifier publishes to the SNS tutor topic, which emails the tutor "New upload from {student}"; SES sends the student a receipt.
8. **Failure handling.** If the notifier fails, SQS makes the message visible again and retries it; after 3 failures it moves to the dead-letter queue, and a CloudWatch alarm on the DLQ alerts staff. Nothing is lost silently.
9. **Tutor opens it.** From the tutor view, `GET /api/submissions/{id}/download-url` returns a 5-minute presigned GET for that one object.

**What the demo deployment proves:** steps 2–3 and 5–8 (SNS email to one address; no GuardDuty, Object Lock or SES). Evidence: `evidence/aws/05-smoke-test-run-1.txt` (presigned POST, `204` from S3, queue, notifier log, DynamoDB record), `06` and `13` (emails), `07-dlq-empty.txt`, `11-upload.png`.

## 4. Exam peak and loss of one Availability Zone (295 words)

**Exam-week peak.** 3,000 students starting within 5 minutes is about 10 exam loads per second, with bursts above that; once everyone is writing, autosave adds 3,000 ÷ 30 s = 100 writes per second. The app and the exam paper are cached by CloudFront, so the start burst mostly hits the edge. API Gateway and Lambda scale per request: at about 50 ms per autosave, 100 requests per second needs only 5–10 concurrent functions, but we raise the account's Lambda quota before exam week (the course account's limit is 10) and schedule provisioned concurrency for exam windows, so no student waits for a cold start. DynamoDB on-demand absorbs the writes without capacity planning, and each autosave overwrites one item, so load grows with students, not with answers. Final submissions at the deadline go onto SQS, so marking and emails run at a controlled rate and failures retry, then wait in a dead-letter queue. WAF rate-limits per IP, and CloudWatch alarms on errors, throttles and latency.

**Loss of one Availability Zone.** Every tier either spans both AZs or is a service AWS already runs across several. CloudFront, Route 53 and WAF are global; API Gateway, Lambda, Cognito, SQS, SNS, S3 and DynamoDB are regional and route around a failed AZ automatically. Lambda is attached to private subnets in both AZs, and each AZ has its own NAT gateway and endpoint interfaces, so AZ-b keeps working alone. DynamoDB confirms a write only after storing it in multiple AZs, so saved answers survive: the most a student can lose is the last unsaved 30 seconds, well inside the 5-minute RPO. Nothing has to fail over, so service continues within seconds; for data corruption or a regional outage, point-in-time recovery and AWS Backup copies restore within the 1-hour RTO.

## 5. How each target is met

| Target | How the design meets it | Shown in the demo |
|---|---|---|
| 99.9% availability during exams (about 43 minutes of downtime a month) | Only managed, multi-AZ services; no single server; alarms page staff; a protected GitHub environment blocks deploys during exam weeks unless approved | Serverless stack with no instances; `evidence/aws/02-health-api.txt` |
| Survives the loss of one AZ | Compute in both AZs, one NAT gateway and endpoint interface per AZ, regional data services | DynamoDB, S3, SQS, Lambda and API Gateway are all regional; AZ failure simulated in the Cloud Architecture Lab (`evidence/`) |
| RPO at most 5 minutes | Autosave every 30 s; DynamoDB writes stored in multiple AZs before confirming; PITR to the second; S3 versioning | PITR enabled: `evidence/aws/03-dynamodb-table-pitr.txt` |
| RTO at most 1 hour | AZ loss needs no failover; corruption: PITR restore to a new table, then redeploy from code in about 10 minutes | Whole stack redeploys from code by pipeline: `evidence/cicd/` |
| Records kept 5 years | S3 lifecycle expiry at 1,825 days with Object Lock; AWS Backup monthly copies of DynamoDB kept 5 years in cold storage | Lifecycle rules: `evidence/aws/04-submissions-bucket-config.txt` |
| Encryption in transit | HTTPS only everywhere: CloudFront redirect-to-HTTPS with TLS 1.2+, API Gateway HTTPS-only, bucket policies deny non-TLS requests | Deny-non-TLS policies on both buckets (in `template.yaml`), HTTPS URLs throughout |
| Encryption at rest | KMS customer-managed keys for S3, DynamoDB, SQS, SNS and logs | SSE-S3 on both buckets, DynamoDB default encryption, SQS-managed encryption: `evidence/aws/04-…` |
