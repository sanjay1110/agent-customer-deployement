# Reusable Asset Proposal

**Deliverable 6 of 6** · Requirement 8

## Summary

| | |
|---|---|
| **Proposed asset** | **Secure Agent Platform**: a versioned Terraform module (`infra/modules/secure-agent-platform`) with its built-in security test suite, which deploys *any* containerised AI agent into a customer AWS account with private networking, least-privilege IAM, runtime secrets and day-one monitoring. |
| **Companion assets** | (a) `agent-secrets`: the Python Secrets Manager loader with stage-based rotation (`agent/app/secrets.py`). (b) The operator script kit (`scripts/`) and the runbook/KT templates. |
| **Problem solved** | Every FDE engagement rebuilds the same VPC, IAM, secrets and alarms from scratch: 1–2 weeks of work, uneven security quality, and a new review by each customer's security team. |
| **Expected impact** | Time from "agent works on my laptop" to "running in the customer VPC with monitoring" goes from **~2 weeks to < 1 day**. Security review effort drops because the controls are pre-documented and **proven by tests**. |
| **Ask** | 2 engineer-weeks to generalise and publish v1.0, plus a named owner for maintenance (~2 days/month). |

---

## 1. Why this component

Each piece of the deployment was assessed for reuse potential:

| Component | Engagement-specific? | Reuse potential | Verdict |
|---|---|---|---|
| Agent code (prompt, tools, KB) | Yes, entirely | Low | Stays per-customer |
| **Terraform module** (network, IAM, secrets, ECS, monitoring) | No. Only `name`, CIDRs and image vary. | **Very high**: every agent we deploy needs exactly this | **Primary asset** |
| **Security test suite** (`terraform test`, mocked AWS) | No | **High**: turns the security design into executable guarantees | Ships inside the module |
| `SecretStore` loader | No | High: every Python agent needs runtime secrets with rotation | Companion library |
| Ops scripts + runbook/KT templates | Mostly no (names and alarms are generated) | Medium-high | Companion templates |

**Evidence that it is already reusable:** the environment root that uses the module (`infra/environments/customer-sim/main.tf`) is about 30 lines of variables. Nothing in the module refers to "support" or to this agent's tools except the tickets table, which v1.0 generalises (§3).

## 2. What the asset provides out of the box

* **Private network:** VPC across 2–3 AZs, NAT-only public subnets, 7 interface + 2 gateway endpoints with restrictive endpoint policies, flow logs, emptied default SG.
* **Ingress:** internal ALB with optional HTTPS (customer private CA), access logs, client-CIDR allow-list.
* **Compute:** ECS Fargate service with a hardened container definition (non-root, read-only FS, capabilities dropped, no ECS Exec), autoscaling, circuit-breaker rollback.
* **Identity:** execution, task, OIDC-deploy, admin, operator and auditor roles, with MFA, conditions and resource scoping.
* **Secrets:** Secrets Manager containers with a CMK and a "workload-only read" resource policy; values never in Terraform state.
* **Observability:** a log-contract-based metric set for LLM agents (LLM errors, latency, tokens, tool errors, rejected tools, auth failures), 12 alarms, dashboard and saved queries.
* **Governance:** 9 plan-time test runs that fail CI if a control regresses; Checkov clean with documented exceptions.

## 3. Generalisation needed for v1.0

| Change | Why | Effort |
|---|---|---|
| Replace the hard-coded tickets table with `data_stores = [{ name, hash_key, actions = ["dynamodb:PutItem"] }]` | Each agent has different side-effect stores; keep IAM generated from that declaration | 2 d |
| `secrets = { name = description }` map instead of two fixed secrets | Agents need different credentials | 1 d |
| `llm_backend = "anthropic_api" \| "bedrock"` | Bedrock mode adds a `bedrock-runtime` endpoint, removes the NAT, and adds `bedrock:InvokeModel` on the chosen model ARN. Closes residual risks R-1 and R-7 for strict customers. | 2 d |
| `egress_allowlist_domains` (optional AWS Network Firewall) | Domain-level egress for regulated customers | 2 d |
| `client_auth = "api_key" \| "oidc"` (ALB OIDC listener rule) | Per-user identity (R-3) | 1 d |
| Publish the log contract as a 30-line schema + reference emitters (Python, TypeScript) | Any agent stack gets the dashboards for free | 1 d |
| Extract `SecretStore` into a pip package `agent-secrets` with its tests | Shared across Python agents | 1 d |

## 4. Interface (v1.0 sketch)

```hcl
module "agent" {
  source  = "git::https://github.com/<org>/secure-agent-platform.git?ref=v1.0.0"

  name                 = "contoso-claims-agent"
  image_tag            = var.image_tag
  allowed_client_cidrs = ["10.20.0.0/16"]           # customer VPN
  llm_backend          = "bedrock"                  # or "anthropic_api"
  llm_model            = "<model-id>"

  secrets = {
    crm-api-token = "Token for the CRM read API"
  }
  data_stores = [{
    name     = "claims-notes"
    hash_key = "claim_id"
    actions  = ["dynamodb:PutItem"]                 # IAM is generated from this
  }]

  alarm_email       = "ops@contoso.example"
  github_repository = "contoso/claims-agent"
  lab_mode          = false
}
```

Outputs: `alb_dns_name`, `ecr_repository_url`, `role_arns`, `secret_arns`, `dashboard_name`, and everything the operator scripts need.

## 5. Quality bar and governance

* **Versioning:** SemVer git tags. A breaking change to any variable or the log contract requires a major version, and the changelog lists required migrations.
* **CI on the asset repo:** `fmt`, `validate`, `tflint`, Checkov, the `terraform test` suite, plus a **nightly real deploy and destroy** in a sandbox account (catches AWS API drift that mocks cannot).
* **Security sign-off:** the security summary and IAM design are maintained in the asset repo. Each minor release gets a short review; engagements inherit it, so customer security reviews only the deltas.
* **Ownership:** one named maintainer (FDE platform guild) with backup. Engagements contribute fixes through PRs, which must keep the test suite green.
* **Support policy:** latest two minor versions supported; Dependabot keeps provider and action versions current.

## 6. Adoption plan

| Phase | When | What | Success measure |
|---|---|---|---|
| 0. Harvest | Week 1 | Copy the module into its own repo; add README, examples, CI | Repo published internally |
| 1. Generalise | Weeks 2–3 | §3 changes, v1.0.0 | Two different sample agents deploy from the same tag |
| 2. Pilot | Next 2 engagements | Use v1.0 instead of hand-built infra; collect friction notes | Each reaches a deployed environment in ≤ 1 day |
| 3. Default | Quarter after | Becomes the standard starting point in the FDE playbook | ≥ 80% of new agent deployments use it |

## 7. Measuring value

| Metric | Baseline (hand-built) | Target with asset |
|---|---|---|
| Time to first deployed environment | 1–2 weeks | < 1 day |
| Customer security review cycle | 2–4 weeks | 1 week (pre-documented controls + test evidence) |
| High/critical findings from customer security reviews | variable | 0 known regressions (tests enforce controls) |
| Monitoring present at go-live | inconsistent | 100% (built in) |

## 8. Risks

| Risk | Mitigation |
|---|---|
| Module becomes a "kitchen sink" with too many flags | Strict scope: one containerised agent behind an internal ALB on AWS. Other shapes (EKS, GCP) get sibling modules sharing the log contract and test approach. |
| Customers with mandated landing zones (existing VPC, shared endpoints) | v1.1: `existing_vpc_id` / `existing_subnet_ids` mode that skips network creation |
| Stale versions in old engagements | Pinned tags make upgrades deliberate; changelog with migration notes; Dependabot on consumers |
| Mocked tests give false confidence | Nightly real deploy/destroy in a sandbox (§5) |
