# Monitoring & Observability Requirements

Requirement 5. Implemented in [`monitoring.tf`](../infra/modules/secure-agent-platform/monitoring.tf). Alarm responses are in the [runbook](runbook.md).

---

## 1. What "healthy" means (SLIs and proposed SLOs)

| SLI | Definition | Proposed SLO | Source |
|---|---|---|---|
| Availability | Share of `/v1/chat` requests that do not return 5xx | ≥ 99.5% per month | ALB `HTTPCode_Target_5XX_Count` / `RequestCount` |
| Latency | p95 of `TargetResponseTime` | ≤ 20 s (agent loops call the LLM several times) | ALB |
| LLM success | `1 − LLMErrors / LLMCalls` | ≥ 99% | Log metric filters |
| Tool success | `1 − ToolErrors / ToolCalls` | ≥ 99.5% | Log metric filters |
| Cost | Tokens per hour | Under `hourly_token_budget` (default 500k) | Log metric filters |

The SLOs are proposals for the customer to confirm during hand-over. An error budget of 0.5% is about 3.6 hours of failed requests a month.

## 2. Signals collected

| Layer | Signal | Collected by | Retention |
|---|---|---|---|
| Edge | Requests, 4xx/5xx, latency percentiles, healthy hosts | ALB metrics (built in) | 15 months |
| Edge | Every request (client IP, path, status, timing) | ALB access logs → S3 | 365 days |
| Compute | CPU, memory, running task count | ECS + Container Insights | 15 months |
| Application | Structured JSON events (below) | stdout → CloudWatch Logs (`/ecs/<name>`) | 365 days (CMK) |
| AI / app metrics | 13 metrics derived from the logs | CloudWatch metric filters, namespace `AIAgent/<name>` | 15 months |
| Network | Accepted and rejected flows | VPC flow logs → CloudWatch | 365 days |
| Control plane | API calls (who changed what) | CloudTrail (customer organisation trail) | Per customer policy |
| Deploys | Deployment status, rollbacks, stopped-task reasons | ECS service events | `scripts/status.sh` |

### 2.1 Application log contract

Every line is a single JSON object with `ts`, `level`, `service`, `event` and `request_id`. These events and fields are a **contract**: the metric filters depend on them, so renaming one requires updating `monitoring.tf` in the same pull request.

| `event` | Extra fields | Emitted when |
|---|---|---|
| `request_completed` | `method`, `path`, `status`, `latency_ms` | Every request except `/health` |
| `llm_call` | `outcome` (`ok`/`error`), `model`, `latency_ms`, `input_tokens`, `output_tokens`, `error` | Every model round-trip |
| `tool_call` | `tool`, `outcome` (`ok`/`invalid_input`/`error`/`rejected_unknown_tool`) | Every tool invocation |
| `chat_completed` | `tool_calls`, `input_tokens`, `output_tokens` | End of each successful chat |
| `auth_failed` | `reason` (`missing_key`/`invalid_key`) | Rejected API key |
| `auth_unavailable` | – | Client key cannot be loaded |
| `capacity_exceeded` | `limit` | Request rejected with 429 |
| `agent_iteration_limit_reached` | `limit` | Agent stopped after 5 tool loops |
| `secret_refresh_failed_serving_cached` | `stage`, `error` | Secrets Manager refresh failed |

**Privacy:** message text and answers are **not** logged (`LOG_CONVERSATION_CONTENT=false`). Use `request_id`, returned to callers and sent in the `x-request-id` response header, to correlate a user's complaint with the logs.

## 3. Metrics derived from logs

`LLMCalls`, `LLMErrors`, `LLMLatencyMs`, `LLMInputTokens`, `LLMOutputTokens`, `ToolCalls`, `ToolErrors`, `ToolRejected`, `AuthFailures`, `CapacityRejections`, `IterationLimitHits`, `SecretRefreshFailures`, `AppErrors`. All are in namespace `AIAgent/<name>`.

## 4. Alarms

All alarms notify the encrypted SNS topic `<name>-alarms` (email by default; add PagerDuty or Opsgenie as another subscription) on both ALARM and OK.

| Alarm | Condition | Severity | Meaning | Runbook |
|---|---|---|---|---|
| `P1-no-healthy-targets` | HealthyHostCount < 1 for 2 min | **P1** | Service down | RB-01 |
| `P1-running-tasks-below-min` | RunningTaskCount < min for 3 min | **P1** | Tasks crashing or not starting | RB-01 |
| `P1-alb-5xx` | > 10 target 5xx in 5 min | **P1** | Users getting errors | RB-02 |
| `P1-llm-errors` | ≥ 5 LLM errors in 5 min | **P1** | Vendor outage, revoked key, or quota | RB-03 |
| `P1-secret-access-failures` | ≥ 1 in 5 min | **P1** | App can't refresh secrets (endpoint, KMS, policy) | RB-04 |
| `P2-latency-p95` | p95 > 20 s for 15 min | P2 | Slow model or saturation | RB-05 |
| `P2-cpu-high` / `P2-memory-high` | > 85% for 15 min | P2 | Undersized or at max scale | RB-05 |
| `P2-token-budget` | input+output tokens/hour > budget | P2 | Cost spike, loop or abuse | RB-06 |
| `P2-auth-failures` | > 25 in 5 min | P2 | Client not updated after rotation, or key guessing | RB-07 |
| `P2-tool-errors` | ≥ 3 in 5 min | P2 | Ticket writes failing | RB-08 |
| `P2-rejected-tool-calls` | ≥ 1 in 5 min | P2 | Model asked for a non-existent tool (possible prompt injection) | RB-09 |

**P1:** page on-call 24×7, acknowledge within 15 min. **P2:** handle in business hours, acknowledge within 4 business hours.

## 5. Dashboard

CloudWatch dashboard `<name>` (Console → CloudWatch → Dashboards):

* **Row 1, "is it up?":** healthy targets and running tasks; requests, 4xx and 5xx; latency p50 and p95.
* **Row 2, "is the AI healthy?":** LLM calls vs errors; LLM latency p50 and p95; tool calls, errors, rejected tools and iteration-limit hits.
* **Row 3, "cost and abuse":** tokens per hour; auth failures, capacity rejections and secret failures; CPU and memory.
* **Row 4:** live status of every alarm.

## 6. Saved Logs Insights queries

Console → CloudWatch → Logs Insights → *Saved queries*:

| Query | Use it to |
|---|---|
| `<name>/recent-errors` | See the last 100 errors and 5xx responses |
| `<name>/trace-one-request (edit the id)` | Follow one `request_id` through LLM and tool calls |
| `<name>/slowest-requests` | Find the 25 slowest requests |
| `<name>/token-usage-by-hour` | Track cost and model latency trends |
| `<name>/auth-failures` | Separate a misconfigured client from a brute-force attempt |

## 7. Health endpoints

| Endpoint | Checks | Used by |
|---|---|---|
| `GET /health` | Process is serving (no dependencies) | ALB target health; container `HEALTHCHECK`. Kept dependency-free so a Secrets Manager blip does not mark every task unhealthy. |
| `GET /ready` | Both secrets can be loaded and are non-empty | Smoke tests, runbook triage |

## 8. Monitoring review cadence

* **Weekly (ops):** dashboard review; alarms that fired; token trend vs budget.
* **Monthly (app team + ops):** SLO report; tune thresholds that were noisy or silent; review `IterationLimitHits` and `ToolRejected` samples for prompt-quality or abuse issues.
* **Quarterly (security):** confirm the log contract is intact (alarms still have data), review retention against policy, and run an alarm fire-drill (runbook §9).
