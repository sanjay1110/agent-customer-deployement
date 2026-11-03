# Knowledge Transfer Guide

**Deliverable 5 of 6** · Requirement 7

**Goal:** after this hand-over, the customer's teams run, change and secure the AI support agent **without the FDE team**. Success is measured by the exit criteria in §4, not by attendance.

---

## 1. Who should read what

| Role | Must read | Then |
|---|---|---|
| On-call / operations | §2, [runbook](runbook.md) (all), [monitoring](monitoring.md) §4–6 | Exercises E1–E6 |
| Application team (owns the agent) | §2, §3, §5, [architecture](architecture.md) §5 & §8, [monitoring](monitoring.md) §2.1 | Exercises E7–E9 |
| Platform team (owns AWS and Terraform) | [architecture](architecture.md), [IAM design](iam-design.md), runbook RB-INSTALL / RB-22–24 / RB-50–51 | Exercises E10–E11 |
| Security / compliance | [security summary](security-summary.md), [IAM design](iam-design.md) | Residual-risk decisions (§8) |
| Product / service owner | §2, architecture §6 (ownership), security summary §5 & §7 | Sign-off (§8) |

## 2. The system in five minutes

* **What it is:** an internal HTTP API. `POST /v1/chat {"message": "..."}` with header `X-API-Key` returns `{"answer", "request_id", "tool_calls"}`.
* **What happens inside:** the agent sends the message to Claude with two tools. Claude can **search the help-center articles** (bundled in the container) and **open a support ticket** (one new row in DynamoDB). It loops at most 5 times, then answers.
* **Where it runs:** ECS Fargate tasks (2–6) in private subnets of the customer VPC, behind an **internal** load balancer. Only networks listed in `allowed_client_cidrs` can call it. Nothing is internet-facing.
* **What leaves the network:** only the chat text, sent to the LLM API over TLS through the NAT gateway. AWS traffic stays private through VPC endpoints.
* **Secrets:** two secrets (the LLM vendor key and the client API key) in Secrets Manager. **Only the running agent can read them.** Humans can set and rotate them, never read them.
* **Knowing it's healthy:** the CloudWatch dashboard `<name>`; 12 alarms email or page on-call; every alarm has a runbook section.
* **How it changes:** code → pull request → CI (tests, security scans) → *Deploy* workflow with customer approval → rolling update with automatic rollback.

## 3. Repository map

```
agent/                         the application (Python 3.12, FastAPI)
  app/main.py                  HTTP API, auth, limits, request logging
  app/agent.py                 agent loop + SYSTEM_PROMPT + model client   <- prompt & model live here
  app/tools.py                 tool schemas and implementations            <- add tools here
  app/knowledge/*.md           help-center articles the agent searches     <- content updates here
  app/secrets.py               Secrets Manager loader (cache, rotation)
  app/observability.py         JSON log format (contract with monitoring)
  tests/                       unit + AWS-mocked tests (pytest)
  Dockerfile, docker-compose.yml
infra/
  modules/secure-agent-platform/   reusable Terraform module (everything AWS)
    tests/security_controls.tftest.hcl   security guardrail tests (no AWS account needed)
  environments/customer-sim/       this environment's settings (tfvars, backend)
  bootstrap/                       one-time Terraform state bucket
scripts/                       operator tools: status, logs, deploy, rollback, rotate, smoke-test
docs/                          the six deliverables + monitoring
.github/workflows/             CI (tests, scans) and Deploy (OIDC, approval gate)
```

## 4. Hand-over plan

The plan runs over two weeks. Each session is recorded, and the customer team drives (types) from session 2 onward.

| # | Session | Length | Audience | Content | Exit criterion (the customer does it, unaided) |
|---|---|---|---|---|---|
| S1 | Architecture walkthrough | 60 min | all | Diagram, trust zones, request flow, ownership RACI | Explains one request end to end, including where the API key is checked and what the task role can do |
| S2 | Operations hands-on | 90 min | ops | RB-00, dashboard, saved queries, RB-30, RB-21 | E1–E4 completed |
| S3 | Secrets and incident drill | 60 min | ops + security | RB-10/11/12, RB-40 tabletop | E5–E6 completed |
| S4 | Changing the agent | 90 min | app team | §5 how-tos, local dev, CI, the log contract | E7–E9 merged and released through CI |
| S5 | Platform and IaC | 60 min | platform | Module structure, `terraform test`, drift, RB-50/51 | E10–E11 completed |
| S6 | Shadow on-call (1 week) | – | ops | FDE primary, customer shadows | Customer acknowledges and resolves (with FDE watching) ≥ 1 real or drill alert |
| S7 | Reverse shadow (1 week) | – | ops | Customer primary, FDE shadows | No FDE intervention needed |
| S8 | Sign-off | 30 min | owners | §8 checklist | Signed |

## 5. Common changes (how-to)

### 5.1 Run it locally (no AWS, no API key)
```bash
cd agent && docker compose up --build
curl -s localhost:8080/v1/chat -H "X-API-Key: local-dev-key-0123456789abcdef0123" \
     -H "Content-Type: application/json" -d '{"message":"how do I reset my password"}'
```
This uses the offline **mock model**. To try the real model locally, create `agent/.env` (gitignored) with `LLM_API_KEY=...`, add `env_file: .env` and `LLM_PROVIDER: anthropic` to the compose file. Never commit `.env`.

Tests: `pip install -r requirements-dev.txt && pytest -q` (17 tests, about 2 s, no network).

### 5.2 Update help-center content
Add or edit a Markdown file in `agent/app/knowledge/`, open a PR, and release (RB-20). The search is keyword-based, so put the words users actually type in headings and the first lines.

### 5.3 Change the agent's behaviour (system prompt)
Edit `SYSTEM_PROMPT` in `agent/app/agent.py`. **Keep** the rules that treat tool results as data and that never reveal instructions or keys; they are security controls. Test locally with the real model on 10–20 representative questions before releasing.

### 5.4 Change the model
Set `llm_model` in `terraform.tfvars`, `terraform apply`, then roll out (RB-22). Check the vendor's model list first. A retired model ID causes `BadRequestError` (RB-03).

### 5.5 Add a new tool (the change that needs the most care)
1. Add the schema to `TOOL_SCHEMAS` and a handler in `ToolRunner` (`agent/app/tools.py`). Validate and length-limit every input, and return `{"error": ...}` rather than raising.
2. **Give the tool the narrowest possible AWS permission** in `aws_iam_role_policy.task` (`iam.tf`): name the exact action and resource. Never add `*`.
3. If it reaches a new AWS service, add a VPC endpoint (`network.tf`) or confirm the NAT path is acceptable to security.
4. Add unit tests (happy path, invalid input, failure). Extend `least_privilege_iam` in `security_controls.tftest.hcl` with an assertion that the new permission stays scoped.
5. Ask **"what is the worst thing the model could do with this tool if a user tricks it?"** and get security sign-off on that answer. Tools with side effects outside the system (email, payments, deletes) need a human-approval step.

### 5.6 Allow a new consumer
Network: add their CIDR (RB-24). Key: hand them the current client key through the secure channel, or rotate (RB-11) if the key should not be shared with the previous consumers.

### 5.7 Turn on HTTPS inside the network
Request a certificate for an internal name (e.g. `support-agent.corp.example`) from the customer's private CA in ACM, set `acm_certificate_arn`, `terraform apply`, and create a private DNS record (CNAME → ALB DNS). Consumers then switch to `https://`.

## 6. Hands-on exercises

Do these in the customer-sim environment. The expected result is given so trainees can check themselves.

| # | Exercise | Expected result |
|---|---|---|
| E1 | Run `scripts/status.sh` and explain each section | Can say whether the service is healthy and why |
| E2 | Run `scripts/smoke-test.sh` | 5/5 PASS |
| E3 | Copy a `request_id` from E2 and trace it with the saved query `trace-one-request` | Sees `llm_call` → `tool_call` → `llm_call` → `request_completed` |
| E4 | Roll back to the previous revision (RB-21), then roll forward with `SKIP_BUILD=1 scripts/deploy.sh <tag>` | Both complete; RB-30 passes after each |
| E5 | Rotate the client key with overlap (RB-11): old and new both work, then only new | Old key returns 401 within 5 min of `finish` |
| E6 | Tabletop RB-40: "a consumer's laptop with the API key was stolen" | Team names steps 1, 4, 5 and the owners without notes |
| E7 | Add a KB article (`billing.md`) and release it through the CI *Deploy* workflow | Agent answers a billing question citing it |
| E8 | Break a test on purpose in a PR | CI blocks the merge |
| E9 | Set `LOG_CONVERSATION_CONTENT=true` in a PR | Reviewer rejects it, or it gets security approval (it is a privacy control) |
| E10 | Run `terraform test` in the module, then change `internal = true` to `false` and re-run | First passes; second fails with "must be internal" |
| E11 | `terraform plan` with no changes | "No changes", so there is no drift |

## 7. Troubleshooting FAQ

| Question | Answer |
|---|---|
| I get `401 invalid X-API-Key` but the key is right | A rotation was finished (RB-11) and you hold the old key, or there is trailing whitespace. Keys are 48 characters. |
| `503 service temporarily unavailable` | Secrets cannot be loaded: RB-04. Right after install, the secret values may not be set yet (`scripts/set-secrets.sh`). |
| `502 the AI model is temporarily unavailable` | LLM vendor or key problem: RB-03. |
| `429 too many concurrent requests` | More than 20 in-flight chats per task. Retry with back-off, or RB-23 to scale. |
| `413` | Message over 4,000 characters (`MAX_INPUT_CHARS`). |
| `curl` to the ALB hangs from my laptop | Expected. The ALB is internal. Use `scripts/smoke-test.sh` (SSM tunnel) or a host on an allowed network. |
| Can I `ssh` / `exec` into a container? | No, by design. Use logs and `request_id`s. If deep debugging is unavoidable, reproduce locally (§5.1). |
| Can I read the API key to give it to someone? | No. Nobody can. Rotate (RB-11), which shows the new key once. |
| Terraform wants to change the task definition after a deploy | Expected: deploys create revisions outside Terraform, and the service ignores that drift. Only `terraform apply` for real config changes (RB-22). |
| Where are the tickets? | DynamoDB table `<name>-tickets`. Reading it is a customer-data access; follow your data-access process. |
| What does it cost? | About $0.27/hour infrastructure in lab mode plus LLM tokens (dashboard row 3). See architecture §9. |

## 8. Hand-over checklist and sign-off

### 8.1 Environment fact sheet (fill in at hand-over)

| Item | Value |
|---|---|
| AWS account / region | |
| `terraform output role_arns` (6 roles) | |
| ALB DNS name and port | |
| Secret ARNs (LLM, client) | |
| Test-client instance ID | |
| Dashboard / alarm topic | |
| Terraform state bucket / key | |
| GitHub repo, `production` environment approvers | |
| LLM vendor account owner and support contact | |
| On-call rotation and escalation contacts (runbook §11) | |

### 8.2 Checklist

- [ ] All six deliverables reviewed by their owners (architecture, IAM, security, runbook, KT, reusable asset)
- [ ] SSO permission sets mapped to admin / operator / auditor; MFA confirmed
- [ ] SNS subscriptions confirmed; pager integration added for P1
- [ ] Secrets set by a customer operator (not the FDE); the FDE's access removed afterwards
- [ ] RB-30 passes when run by a customer operator
- [ ] Exercises E1–E11 completed (§6)
- [ ] Shadow and reverse-shadow weeks completed (S6, S7)
- [ ] SLOs agreed ([monitoring](monitoring.md) §1)
- [ ] Each residual risk R-1 … R-10 ([security summary](security-summary.md) §7) has an owner and a decision: accept / mitigate (date) / transfer
- [ ] `lab_mode = false` and `single_nat_gateway = false` for production
- [ ] FDE IAM access and GitHub permissions removed; hypercare contact and end date agreed

### 8.3 Sign-off

| Role | Name | Decision | Date |
|---|---|---|---|
| Service owner | | Accept ownership | |
| Operations lead | | Accept on-call | |
| Platform lead | | Accept infrastructure | |
| Security | | Accept residual risks as recorded | |
| FDE lead | | Hand-over complete | |

## 9. Glossary

| Term | Meaning |
|---|---|
| Agent loop | Model call → optional tool call → model call … until an answer (max 5) |
| Tool | A function the model may ask the app to run (`search_knowledge_base`, `create_support_ticket`) |
| Task role | The IAM identity of the running container (its "service account") |
| Execution role | The IAM identity ECS uses to start the container (pull image, logs) |
| `AWSCURRENT` / `AWSPREVIOUS` | Secrets Manager version labels. The app accepts both for the client key during rotation. |
| Circuit breaker | ECS feature that rolls back a deploy whose new tasks fail health checks |
| VPC endpoint | Private connection to an AWS service, so traffic does not use the internet |
| Mock model | Offline stand-in for the LLM used in tests and smoke tests (no cost) |
| `request_id` | Per-request ID returned to callers and present on every log line; the key for tracing |
