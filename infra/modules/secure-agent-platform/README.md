# secure-agent-platform (Terraform module)

Deploys a containerised AI agent into a customer AWS account: private VPC, internal ALB, ECS Fargate, least-privilege IAM, Secrets Manager + KMS, and CloudWatch monitoring. This is the asset proposed in [docs/reusable-asset-proposal.md](../../../docs/reusable-asset-proposal.md).

## Usage

```hcl
module "platform" {
  source               = "../../modules/secure-agent-platform"
  name                 = "acme-support-agent"
  image_tag            = "v1"
  allowed_client_cidrs = ["10.0.0.0/8"]
  alarm_email          = "ops@example.com"
  lab_mode             = false
}
```

## Files

| File | Contents |
|---|---|
| `network.tf` | VPC, subnets, NAT, flow logs, VPC endpoints (with endpoint policies) |
| `compute.tf` | Internal ALB + access-log bucket, ECS cluster/service/task definition, autoscaling, SSM test client |
| `data_protection.tf` | KMS key, Secrets Manager secrets + resource policies, DynamoDB table, ECR |
| `iam.tf` | Execution, task, GitHub-deploy, platform-admin, operator, auditor roles |
| `monitoring.tf` | SNS, log metric filters, alarms, saved queries, dashboard |
| `tests/security_controls.tftest.hcl` | Plan-time security guardrails (mocked AWS provider) |

## Test

```bash
terraform init && terraform test      # no AWS credentials needed
```

## Important inputs

| Variable | Default | Notes |
|---|---|---|
| `name` | – | Prefix for all resources |
| `vpc_cidr` | `10.40.0.0/16` | Must not overlap networks it will connect to |
| `allowed_client_cidrs` | VPC CIDR | Networks allowed to call the ALB |
| `acm_certificate_arn` | `""` | Set to switch the ALB to HTTPS 443 |
| `llm_provider` | `anthropic` | `mock` for zero-cost smoke tests |
| `lab_mode` | `false` | `true` = no deletion protection, immediate secret deletion (use only for labs) |
| `single_nat_gateway` | `true` | `false` = one NAT per AZ (production) |
| `github_repository` | `""` | `owner/repo` to create the OIDC deploy role |
| `hourly_token_budget` | `500000` | Cost alarm threshold |
