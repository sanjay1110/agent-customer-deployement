#!/usr/bin/env bash
# RB-00: one-screen health summary for on-call.
source "$(dirname "$0")/lib.sh"
load_env
require CLUSTER SERVICE
echo "== Service"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount,taskDef:taskDefinition}' --output table
echo "== Deployments"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].deployments[].{status:status,rollout:rolloutState,taskDef:taskDefinition,running:runningCount,updated:updatedAt}' --output table
echo "== Recent service events"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].events[:8].[createdAt,message]' --output text
echo "== Alarms currently firing"
aws cloudwatch describe-alarms --alarm-name-prefix "$SERVICE-" --state-value ALARM --query 'MetricAlarms[].[AlarmName,StateReason]' --output text | sed 's/^/  /' || true
echo "== Stopped tasks (last hour) and why"
for t in $(aws ecs list-tasks --cluster "$CLUSTER" --desired-status STOPPED --query 'taskArns[:5]' --output text); do
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$t" --query 'tasks[0].[stoppedAt,stoppedReason,containers[0].exitCode]' --output text
done
