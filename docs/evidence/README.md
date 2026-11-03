# Deployment Evidence

Proof that the solution was **deployed and operated** inside the simulated customer environment. Capture each item after completing [runbook RB-INSTALL](../runbook.md#rb-install--first-time-installation-about-30-minutes) and save it in this folder with the file name shown.

> **Before committing:** check that no screenshot or text shows a secret value, an API key, or your AWS access keys. Account IDs and ARNs are fine to show.

| # | Evidence | How to capture | File |
|---|---|---|---|
| 1 | Terraform apply completed | Last lines of `terraform apply` ("Apply complete! Resources: N added") | `01-terraform-apply.txt` |
| 2 | Security tests pass | `cd infra/modules/secure-agent-platform && terraform test` | `02-terraform-test.txt` |
| 3 | Service healthy | `scripts/status.sh` output | `03-status.txt` |
| 4 | End-to-end smoke test from inside the network | `scripts/smoke-test.sh` output (5/5 PASS) | `04-smoke-test.txt` |
| 5 | ALB is internal | Console → EC2 → Load Balancers → scheme **internal** | `05-alb-internal.png` |
| 6 | No public access to the agent | From your laptop: `curl -m 5 http://<alb-dns>/health` times out, and the DNS name resolves only to private 10.40.x.x addresses (`nslookup <alb-dns>`) | `06-no-public-access.txt` |
| 7 | Secrets locked to the workload | Run `aws secretsmanager get-secret-value --secret-id <llm-secret-arn>` as the operator role → **AccessDenied** | `07-secret-denied.txt` |
| 8 | Secret resource policy | `aws secretsmanager get-resource-policy --secret-id <arn>` | `08-secret-policy.json` |
| 9 | CloudWatch dashboard with traffic | Console screenshot after running the smoke test a few times | `09-dashboard.png` |
| 10 | Alarms configured | Console → CloudWatch → Alarms (12 alarms, OK state) | `10-alarms.png` |
| 11 | Trace of one request | Logs Insights → saved query `trace-one-request` with a `request_id` from #4 | `11-trace.png` |
| 12 | Rotation works | Output of `scripts/rotate-client-key.sh start` (**redact the key**) and `finish`, followed by a passing smoke test with the new key | `12-rotation.txt` |
| 13 | Rollback works | `scripts/rollback.sh` then `SKIP_BUILD=1 scripts/deploy.sh <tag>` output | `13-rollback.txt` |
| 14 | Teardown | `terraform destroy` summary | `14-destroy.txt` |
