# Security Design Summary

**Deliverable 3 of 6** · Requirement 4 (Secrets Management) and security controls across all requirements

---

## 1. Scope and assets

| Asset | Sensitivity | Where it lives |
|---|---|---|
| LLM provider API key | **Secret.** Misuse costs money and could expose data. | Secrets Manager (CMK) |
| Client API key | **Secret.** Grants use of the agent. | Secrets Manager (CMK) |
| Customer chat messages | Confidential, may contain PII | In memory only. Not logged by default. Sent to the LLM vendor over TLS. |
| Support tickets | Confidential, may contain PII | DynamoDB (CMK, PITR) |
| Application logs | Internal, metadata only | CloudWatch Logs (CMK, 365 days) |
| Container image | Internal, integrity-critical | ECR (immutable tags, scanned, CMK) |
| Terraform state | Sensitive (resource IDs; **no secret values by design**) | S3 (KMS, versioned, TLS-only) |

## 2. Threat model (summary)

| # | Threat | Likely vector | Primary controls | Residual |
|---|---|---|---|---|
| T-1 | Unauthorised use of the agent | Network reachability + guessed or leaked key | Internal ALB + SG allow-list; 48-char random key; constant-time compare; `AuthFailures` alarm | Low |
| T-2 | **Prompt injection makes the agent misuse tools** | Malicious user text or KB content | Tool allow-list; validated, length-limited inputs; task role = PutItem only; max 5 iterations; system prompt treats tool output as data | Medium (inherent to LLMs, R-5) |
| T-3 | Secret theft | Logs, env vars, Terraform state, over-privileged humans | Runtime fetch; never in env/state/logs; resource policy (task role only); operators rotate without reading | Low |
| T-4 | Data exfiltration from the VPC | Compromised container uploading data | No inbound; egress 443 only; S3/DynamoDB endpoint policies; flow logs | Medium until domain egress filtering (R-1) |
| T-5 | Supply-chain compromise | Malicious dependency or base image | Pinned deps; Dependabot; Trivy in CI; ECR scan on push; deploy gate on CRITICAL findings; immutable tags | Low-Medium |
| T-6 | Unauthorised release | Stolen CI credentials, rogue workflow | OIDC (no keys); `sub` pinned to repo + protected environment; required reviewers; scoped deploy role | Low |
| T-7 | Cost exhaustion / denial of wallet | Loops, abuse, huge inputs | Input cap 4,000 chars; `max_tokens` 1024; 5 iterations; 20 concurrent per task; autoscaling max 6; token-budget alarm | Low |
| T-8 | Container breakout / lateral movement | Exploited app bug | Fargate isolation; non-root UID 10001; read-only root FS; all caps dropped; no ECS Exec; task SG accepts ALB only | Low |
| T-9 | Tampering that hides activity | Admin deletes logs or changes policies | Log groups encrypted, 365-day retention; CloudTrail (customer org trail); auditor role; Terraform drift visible | Low |

### OWASP Top 10 for LLM Applications (2025) mapping

| OWASP item | How it is addressed here |
|---|---|
| LLM01 Prompt Injection | Least-privilege tools (T-2). Instructions in tool results are ignored by the system prompt. Iteration limit. `ToolRejected` and `IterationLimitHits` metrics. |
| LLM02 Sensitive Information Disclosure | No conversation content in logs (`LOG_CONVERSATION_CONTENT=false`); generic error messages (no stack traces or vendor errors to callers, which is tested); the agent cannot read tickets. |
| LLM03 Supply Chain | Pinned Python deps, Dependabot, Trivy, ECR scanning, a deploy gate, a vendor-pinned model ID (`LLM_MODEL`). |
| LLM05 Improper Output Handling | Output is returned as JSON text only. The app never executes, renders or evaluates model output. Tool inputs are schema-validated server-side. |
| LLM06 Excessive Agency | Two tools only. Ticket creation is insert-only and IAM-enforced. No delete, update, email or payment tools. |
| LLM07 System Prompt Leakage | The prompt contains no secrets. Keys are never placed in the prompt or context. |
| LLM09 Misinformation | Answers are grounded in KB search ("base your answer only on what it returns"); escalation to a human via ticket. |
| LLM10 Unbounded Consumption | T-7 controls plus the `P2-token-budget` alarm. |
| LLM04 / LLM08 (poisoning, embeddings) | KB articles ship inside the signed, immutable image and change only through code review. No vector store. |

## 3. Secrets management (Requirement 4)

**Tool:** AWS Secrets Manager, encrypted with a customer-managed KMS key.

### 3.1 Lifecycle

```
 create container ──▶ set value ──▶ app reads at runtime ──▶ rotate ──▶ revoke old
 (Terraform:         (scripts/set-   (task role, cached      (scripts/   (vendor console /
  no value, so        secrets.sh:     5 min, stale-on-error)   rotate-*)   rotate-client-key.sh
  never in state)     hidden prompt)                                       finish)
```

| Rule | Implementation | Verified by |
|---|---|---|
| No secret in source control | `.gitignore` (`.env*`, `*.tfvars`, `backend.hcl`), pre-commit gitleaks, CI gitleaks over **full history** | CI `security` job |
| No secret in Terraform state or plan | Terraform creates only `aws_secretsmanager_secret` (no `_version` resource) | Code review; `terraform test` `no_secret_values_in_config` |
| No secret in task definition or env vars | Only secret **ARNs** are passed; the app calls `GetSecretValue` | `terraform test`; unit test `test_secret_store_refuses_env_fallback_in_aws` |
| No secret on the command line or in shell history | Scripts read with `read -s` and pass `file://` from a `0600` temp file, deleted on return | Tested against a local Secrets Manager emulator |
| No secret in logs | Logger never receives values; `boto3`/`anthropic` debug logging suppressed; errors log the exception *type* only | Code review; tests assert no internal error text leaks |
| Only the workload can read values | IAM (task role) **and** a resource policy denying everyone else | `terraform test` |
| Encrypted at rest with the customer's key | `kms_key_id = CMK`; key rotation enabled | `terraform test` `encryption_at_rest` |
| Rotation without downtime | LLM key: new value goes to `AWSCURRENT`; tasks pick it up within 5 min; the old key is revoked in the vendor console after verification (RB-10). Client key: `AWSCURRENT` and `AWSPREVIOUS` are both accepted during overlap, then `AWSPREVIOUS` is removed (RB-11) | Unit test `test_client_key_rotation_overlap_and_revoke`; script tested end to end |
| Resilience | If Secrets Manager is briefly unreachable, the last good value is served and `SecretRefreshFailures` alarms | Code path in `app/secrets.py` |

**Configuration data that is not secret** (model ID, table name, secret ARNs, limits) is passed as plain environment variables in the task definition, version-controlled in Terraform.

**Why not automatic rotation with a Lambda?** The LLM vendor key can only be issued in the vendor's console, so a rotation Lambda cannot mint it. Rotation is a documented, scripted, 10-minute operator procedure on a 90-day calendar (runbook §6). The client key could be auto-rotated with a Lambda, but consumers would then need to fetch it automatically, which is a decision for the customer (noted in the reusable-asset roadmap).

## 4. Control inventory

| Domain | Control | Where |
|---|---|---|
| **Network** | Internal-only ALB; no public IPs; private subnets for all workloads | `compute.tf`, `network.tf` |
| | SG chain (clients → ALB → tasks); default SG emptied; test client has no inbound rules | `compute.tf`, `network.tf` |
| | Task egress TCP 443 only; VPC endpoints with restrictive endpoint policies | `compute.tf`, `network.tf` |
| | VPC flow logs (ALL) and ALB access logs | `network.tf`, `compute.tf` |
| **Identity** | 6 purpose-specific roles; MFA on human roles; OIDC for CI; conditions on all trusts | `iam.tf`, [iam-design.md](iam-design.md) |
| **Data** | One CMK (rotating) for secrets, table, logs, SNS and images; DynamoDB PITR; S3 TLS-only, public access blocked | `data_protection.tf` |
| **Workload** | Non-root, read-only root FS, all Linux capabilities dropped, init process, no ECS Exec, health check, minimal slim image, no build tools in runtime stage | `Dockerfile`, `compute.tf` |
| **Application** | API-key auth (constant-time); input-size limit; concurrency limit; tool allow-list + validation; iteration limit; LLM timeout; no internal error leakage; request IDs | `agent/app/*.py` |
| **Delivery** | Immutable image tags; scan on push; CRITICAL-finding deploy gate; circuit-breaker rollback; approval-gated OIDC releases | `deploy.sh`, `deploy.yml` |
| **Detection** | 12 alarms (incl. auth-failure spikes, rejected tools, token budget, secret failures); saved forensic queries | `monitoring.tf` |
| **Governance** | Plan-time security tests; Checkov (214 passed, 0 failed, 17 justified skips); tflint; gitleaks; Trivy | CI |

## 5. Data flow to the LLM vendor

Only the end-user message, the system prompt, tool schemas and tool results (KB article text, ticket IDs) are sent to the LLM API over TLS 1.2+. Secrets, tickets read back from the DB, logs and AWS metadata are **never** sent. Before go-live the customer should:

1. Confirm the vendor contract covers its data classification (DPA, retention, region).
2. Decide whether PII in chat messages is acceptable, or add a redaction step before the LLM call.
3. Optionally switch to **Amazon Bedrock** in-region. Traffic would then use a VPC endpoint and the NAT gateway could be removed entirely (R-1 and R-7 closed). Only `AnthropicLLM` in `agent/app/agent.py` would change.

## 6. Verification evidence

| Check | Result | How to reproduce |
|---|---|---|
| Unit and integration tests (incl. moto-mocked AWS) | 17 passed | `cd agent && pytest -q` |
| Plan-time security tests (mocked AWS provider) | 9 runs, all passed | `cd infra/modules/secure-agent-platform && terraform test` |
| Regression check | Setting `internal = false` on the ALB makes the tests fail | Demonstrated during build |
| Checkov (Terraform) | 214 passed, 0 failed, 17 skipped with a written justification in the code (`#checkov:skip=...`) | `checkov -d infra` |
| tflint / `terraform validate` / `fmt` | clean | CI `infra` job |
| Secret scripts end to end | set → rotate (overlap) → revoke verified; no temp files left | moto server test |
| shellcheck | clean | CI `security` job |

## 7. Residual risks and recommended upgrades

| ID | Risk | Rating | Recommendation | Effort |
|---|---|---|---|---|
| R-1 | Egress is port-filtered, not domain-filtered: a compromised task could reach any HTTPS host via NAT | Medium | AWS Network Firewall (or the customer's egress proxy) allowing only `api.anthropic.com`; or move to Bedrock via VPC endpoint and delete the NAT | M |
| R-2 | Without `acm_certificate_arn`, client→ALB traffic inside the VPC is HTTP | Medium | Issue a certificate from the customer's private CA (ACM PCA) and set the variable; the module switches to HTTPS 443 with a TLS 1.3 policy | S |
| R-3 | One shared client API key; no per-user identity | Medium | Per-consumer keys, or ALB OIDC authentication with the customer IdP; pass user identity to tickets | M |
| R-4 | No per-client rate limiting or WAF | Low | AWS WAF rate-based rule on the internal ALB | S |
| R-5 | Prompt injection cannot be fully prevented | Medium | Already contained by IAM. Add a red-team prompt suite to CI and human review of tickets flagged by the model | M |
| R-6 | `ecs:RegisterTaskDefinition` cannot be resource-scoped | Low | Mitigated (cannot run other families). Optional SCP or permission boundary | S |
| R-7 | Prompts leave the customer's AWS account | Depends on data class | See §5 (contract, redaction, or Bedrock) | M |
| R-8 | Lab mode uses one NAT gateway (AZ failure removes LLM egress) | Low (lab) | `lab_mode = false` gives one NAT per AZ | S |
| R-9 | CloudTrail is assumed to be the customer's organisation trail | Low | Confirm a trail with data events covers this account, or add one | S |
| R-10 | GitHub Actions are pinned to tags, not commit SHAs | Low | Pin to SHAs (Dependabot keeps them current) | S |

Each residual risk needs a named customer owner and a decision (accept, mitigate or transfer) recorded in the hand-over sign-off ([knowledge-transfer.md](knowledge-transfer.md) §8).
