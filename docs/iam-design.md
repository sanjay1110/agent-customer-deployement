# IAM Design

**Deliverable 2 of 6** · Requirement 3 (least-privilege access controls)

Source of truth: [`infra/modules/secure-agent-platform/iam.tf`](../infra/modules/secure-agent-platform/iam.tf), plus resource policies in `data_protection.tf` and `network.tf`. Automated checks: [`tests/security_controls.tftest.hcl`](../infra/modules/secure-agent-platform/tests/security_controls.tftest.hcl) (`run "least_privilege_iam"`).

---

## 1. Principles applied

1. **No long-lived credentials.** Workloads use IAM roles, CI uses GitHub OIDC, and humans use SSO with MFA. No IAM user or access key is created by this design.
2. **One identity per job.** Pulling images, running the agent, releasing, operating, administering and auditing are separate roles, so a compromise of one does not grant the others.
3. **Resource-scoped.** Every write permission names a specific ARN (one repository, one table, two secrets, one service, one log group). `"*"` appears only where AWS does not support resource-level permissions (`ecr:GetAuthorizationToken`, `ecs:RegisterTaskDefinition`) or for read-only `Describe*`/`Get*`/`List*`.
4. **Defence in depth.** Critical permissions are enforced in two places: an IAM policy *and* a resource or endpoint policy. For example, secret values need both the task-role policy and the secret's resource policy, which denies everyone else.
5. **Separation of duties.** Nobody who can change the system can read secret values. Operators can rotate secrets but never read them. Auditors can see everything except secret values and customer data.
6. **Conditions everywhere they help.** `aws:SourceAccount` and `aws:SourceArn` on service trust policies; `kms:ViaService` on KMS grants; `iam:PassedToService` on PassRole; `aws:MultiFactorAuthPresent` on human roles; OIDC `sub` pinned to one repo and environment.

## 2. Identity inventory

| Identity | Type | Assumed by | Purpose | Max session |
|---|---|---|---|---|
| `<name>-ecs-execution` | Service role | ECS agent (`ecs-tasks.amazonaws.com`) | Pull the image, create log streams | 1 h |
| `<name>-agent-task` | Service role (**service account of the app**) | The agent container | Read its 2 secrets, insert tickets | 1 h |
| `<name>-github-deploy` | Federated (OIDC) | GitHub Actions job in environment `production` of one repo | Release new images | 1 h |
| `<name>-platform-admin` | Human role | Customer platform engineers (SSO + MFA) | Apply Terraform | 1 h |
| `<name>-operator` | Human role | Customer ops / on-call (SSO + MFA) | Run, restart, roll back, rotate | 4 h |
| `<name>-auditor` | Human role | Customer security / compliance (SSO + MFA) | Read-only review | 1 h |
| `<name>-vpc-flow-logs` | Service role | `vpc-flow-logs.amazonaws.com` | Write flow logs to one log group | – |
| `<name>-test-client` | Instance role | Test EC2 instance | Register with SSM (`AmazonSSMManagedInstanceCore`) | – |

## 3. Workload roles in detail

### 3.1 Execution role: `<name>-ecs-execution`

Trust: `ecs-tasks.amazonaws.com` with `aws:SourceAccount = <account>` and `aws:SourceArn = arn:aws:ecs:<region>:<account>:*` (blocks confused-deputy use from other accounts).

| Sid | Actions | Resource | Why |
|---|---|---|---|
| EcrAuthTokenIsAccountWide | `ecr:GetAuthorizationToken` | `*` | AWS does not support resource scoping for this action. |
| PullOnlyThisRepository | `ecr:BatchCheckLayerAvailability`, `GetDownloadUrlForLayer`, `BatchGetImage` | the agent's ECR repo | Pull only this image. |
| WriteOnlyThisLogGroup | `logs:CreateLogStream`, `logs:PutLogEvents` | `/ecs/<name>:*` | Ship container stdout. |

**Deliberately absent:** `secretsmanager:*`. The execution role is only needed when ECS injects secrets, which this design does not do, so a compromised ECS agent context cannot read secrets.

### 3.2 Task role: `<name>-agent-task` (the application's service account)

| Sid | Actions | Resource | Condition | Why |
|---|---|---|---|---|
| ReadOnlyItsOwnTwoSecrets | `secretsmanager:GetSecretValue` | the 2 secret ARNs | – | Fetch the LLM key and client key at runtime. |
| DecryptSecretsViaSecretsManagerOnly | `kms:Decrypt` | the CMK | `kms:ViaService = secretsmanager.<region>.amazonaws.com` | The key can only be used *through* Secrets Manager, not to decrypt arbitrary ciphertext. |
| InsertTicketsOnlyNoReadUpdateDelete | `dynamodb:PutItem` | the tickets table | – | The only tool side effect. The app also sends `attribute_not_exists(ticket_id)`, so even PutItem cannot overwrite. |
| TableEncryptionViaDynamoDbOnly | `kms:Decrypt`, `GenerateDataKey`, `DescribeKey` | the CMK | `kms:ViaService = dynamodb.<region>.amazonaws.com` | Required for a CMK-encrypted table. |

**Why this matters for an AI agent:** the model chooses which tools to call, and a prompt-injection attack might try to make it misuse them. The blast radius is fixed by this policy, not by the prompt. Even a fully compromised agent process can only insert tickets. It cannot read or delete customer data, read other secrets, or touch any other resource.

### 3.3 CI deploy role: `<name>-github-deploy`

Trust (federated):

```json
"Principal": {"Federated": "arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com"},
"Action": "sts:AssumeRoleWithWebIdentity",
"Condition": {"StringEquals": {
  "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
  "token.actions.githubusercontent.com:sub": "repo:<owner>/<repo>:environment:production"
}}
```

Only workflow jobs that run in the **protected `production` environment** of this one repository can assume the role. Configure *Required reviewers* on that environment so every release needs a named customer approver.

| Sid | Actions | Resource |
|---|---|---|
| EcrLogin | `ecr:GetAuthorizationToken` | `*` (not resource-scopable) |
| PushToThisRepositoryOnly | ECR layer upload / `PutImage` / describe / scan findings | agent repo |
| TaskDefinitionsCannotBeResourceScoped | `ecs:RegisterTaskDefinition`, `DescribeTaskDefinition` | `*` (AWS limitation) |
| RollThisServiceOnly | `ecs:UpdateService`, `DescribeServices` | `service/<name>/<name>` |
| PassOnlyTheAgentRolesToEcs | `iam:PassRole` | execution and task role ARNs, with `iam:PassedToService = ecs-tasks.amazonaws.com` |

**Known gap:** because `RegisterTaskDefinition` cannot be resource-scoped, the CI role could register a task definition in another family. It cannot *run* it, though: it has `UpdateService` on this service only, and can pass only these two roles. See R-6 in the security summary.

## 4. Human roles in detail

All three trust the customer account (or specific SSO role ARNs via `human_role_trusted_principals`) and require `aws:MultiFactorAuthPresent = true`. With IAM Identity Center, map each to a permission set, or have the permission set allow `sts:AssumeRole` on it.

### 4.1 Platform admin

* `PowerUserAccess` (AWS managed: everything except IAM and Organizations), plus
* `iam-scoped-to-deployment`: IAM writes **only** on `role/<name>-*`, `instance-profile/<name>-*`, `policy/<name>-*` and the GitHub OIDC provider; read-only `iam:Get*`/`List*` (needed for `terraform plan`); `iam:CreateServiceLinkedRole` restricted to ECS, ELB and Application Auto Scaling.
* **Cannot read secret values** (denied by the secret resource policy).

### 4.2 Operator (day-to-day operations and on-call)

| Capability | Actions | Scope |
|---|---|---|
| Triage | `ecs:Describe*/List*`, `elasticloadbalancing:Describe*`, `cloudwatch:Get*/Describe*/List*`, `logs:Describe*`, ECR scan findings, `dynamodb:DescribeTable` | read-only |
| Restart / scale / roll back | `ecs:UpdateService` | this service only |
| Kill a bad task | `ecs:StopTask` | tasks in this cluster |
| Read logs | `logs:GetLogEvents`, `FilterLogEvents`, `StartQuery`, `StartLiveTail` | app and flow-log groups only |
| Maintenance windows, fire drills | `cloudwatch:Disable/EnableAlarmActions`, `SetAlarmState` | alarms named `<name>-*` |
| **Rotate secrets without reading them** | `secretsmanager:PutSecretValue`, `UpdateSecretVersionStage`, `DescribeSecret`, `ListSecretVersionIds` + `kms:GenerateDataKey/Encrypt` via Secrets Manager | the 2 secrets |
| Reach the internal endpoint | `ssm:StartSession` | the test-client instance + `AWS-StartPortForwardingSessionToRemoteHost` document only |

Not granted: `GetSecretValue`, any DynamoDB data access, any IAM, any change to networking, `RegisterTaskDefinition` (releases go through CI).

### 4.3 Auditor

* `SecurityAudit` (AWS managed: read-only configuration metadata across services), plus read access to the app and flow-log groups.
* **Explicit deny** on `secretsmanager:GetSecretValue` and DynamoDB item reads (`GetItem`, `Query`, `Scan`, `BatchGetItem`). Auditors verify the controls, not the data.

## 5. Resource and endpoint policies (second lock)

| Resource | Policy | Effect |
|---|---|---|
| Both secrets | `Deny secretsmanager:GetSecretValue` unless `aws:PrincipalArn = <task role>` | Even an account admin with `*:*` is denied by this resource policy until they change it, and that change shows up in CloudTrail. |
| KMS key | Account root administers via IAM; CloudWatch Logs scoped by `kms:EncryptionContext:aws:logs:arn` to this account's log groups; CloudWatch alarms may publish to the encrypted SNS topic | No cross-account use. |
| S3 gateway endpoint | `s3:GetObject` only on the ECR layer bucket and Amazon Linux repos | The VPC cannot be used to upload data to arbitrary buckets. |
| DynamoDB gateway endpoint | `PutItem` and `DescribeTable` on the tickets table only | Same idea for DynamoDB. |
| ALB log bucket | Only the regional ELB log-delivery account may `PutObject`; TLS-only | – |
| State bucket (bootstrap) | TLS-only; public access blocked; owner-enforced | – |

## 6. Access matrix (who can do what)

| Action | Task | Exec | CI | Admin | Operator | Auditor |
|---|---|---|---|---|---|---|
| Read secret values | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Write / rotate secret values | ❌ | ❌ | ❌ | ✅* | ✅ | ❌ |
| Insert ticket | ✅ | ❌ | ❌ | ✅* | ❌ | ❌ |
| Read tickets | ❌ | ❌ | ❌ | ✅* | ❌ | ❌ |
| Push image | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ |
| Deploy / roll back | ❌ | ❌ | ✅ | ✅ | ✅ (rollback / restart) | ❌ |
| Change infrastructure | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |
| Read logs and metrics | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| Reach internal endpoint | – | – | ❌ | ✅ | ✅ (via SSM) | ❌ |

\* via `PowerUserAccess`. Reading tickets is a customer-data access that should go through the customer's normal data-access process. Tighten with an SCP or a permission boundary if required.

## 7. Review and maintenance

* **Quarterly access review:** auditor runs IAM Access Analyzer *unused access* findings on these roles and removes unused actions.
* **Before any IAM change:** run `terraform test`. The `least_privilege_iam` run fails if the task role gains wildcards or read/delete on the table, if the execution role gains secrets access, or if operators gain `GetSecretValue`.
* **Break-glass:** if the task role must be changed in an emergency, the platform admin edits `iam.tf` and applies it. There is no standing human path to secret values by design. To recover from a lost key, **write a new value** rather than reading the old one.
