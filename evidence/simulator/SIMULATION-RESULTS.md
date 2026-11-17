# Cloud Architecture Lab - verified results

Checked with the simulator's own validator and simulation engine before upload.

| File | Start | Result | Path taken |
|---|---|---|---|
| exam-platform-walkthrough1.json | Student - opens an exam | **200** - processed across all tiers | Student > Route 53 > CloudFront > AWS WAF > API Gateway > Exam API Lambda (AZ-A) > Gateway endpoints (regional) > DynamoDB |
| exam-platform-walkthrough2.json | Student - uploads a 40 MB assignment | **202** - queue accepted; workers in AZ-A and AZ-B **processed** | Student > S3 submissions (presigned POST) > SQS upload queue > worker Lambdas |
| exam-platform-az-failure.json | walkthrough 1, AZ-A failed | **200** - 4 AZ-A resources failed (NAT, 2 Lambda ENIs, interface-endpoint ENI); API Gateway and both queues survived via redundancy | ... > API Gateway > Exam API Lambda (**AZ-B**) > Gateway endpoints (regional) > DynamoDB |
| exam-platform-az-failure-walkthrough2.json | walkthrough 2, AZ-A failed | **202** - AZ-A worker *failing and retrying*, AZ-B worker **processed** | Student > S3 > SQS > worker (**AZ-B**) - SQS redelivers, nothing lost |

Validator: 0 findings. Stray components: 0 (11 configuration-level services marked referenceOnly).
Diagram: 38 services, 19 boundaries (region, VPC 10.0.0.0/16, AZ-A/AZ-B, public / private app / private endpoint subnets, lambda-sg), 33 links.
Gateway endpoints (DynamoDB, S3) are drawn once, inside the VPC but outside the subnets: they are route-table targets, regional, with no ENI, so an AZ failure does not affect them. Only interface endpoints (ENIs) sit in the endpoint subnets.
The header's $206.20/mo is the estimate for the full production design (NAT gateways, WAF, endpoints...), compared with well under a dollar for the lean demo deployment.
