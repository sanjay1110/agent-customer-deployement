# -----------------------------------------------------------------------------
# Monitoring & observability (requirements in docs/monitoring.md)
#
#  Signals:
#    Platform  : ALB (5xx, latency, healthy hosts), ECS (running tasks, CPU, memory)
#    App/AI    : metric filters over the app's JSON logs (LLM errors/latency/tokens,
#                tool errors, auth failures, secret refresh failures, app errors)
#    Network   : VPC flow logs
#  Every alarm -> encrypted SNS topic -> email (and any on-call integration the customer adds).
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name              = "${local.name}-alarms"
  kms_master_key_id = aws_kms_key.this.arn
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ----------------------------------------------------------------- log-derived metrics
# CONTRACT: event names/fields come from agent/app/*.py log calls.
locals {
  log_metrics = {
    LLMCalls              = { pattern = "{ $.event = \"llm_call\" }", value = "1", unit = "Count" }
    LLMErrors             = { pattern = "{ $.event = \"llm_call\" && $.outcome = \"error\" }", value = "1", unit = "Count" }
    LLMLatencyMs          = { pattern = "{ $.event = \"llm_call\" && $.outcome = \"ok\" }", value = "$.latency_ms", unit = "Milliseconds" }
    LLMInputTokens        = { pattern = "{ $.event = \"llm_call\" && $.outcome = \"ok\" }", value = "$.input_tokens", unit = "Count" }
    LLMOutputTokens       = { pattern = "{ $.event = \"llm_call\" && $.outcome = \"ok\" }", value = "$.output_tokens", unit = "Count" }
    ToolCalls             = { pattern = "{ $.event = \"tool_call\" }", value = "1", unit = "Count" }
    ToolErrors            = { pattern = "{ $.event = \"tool_call\" && $.outcome = \"error\" }", value = "1", unit = "Count" }
    ToolRejected          = { pattern = "{ $.event = \"tool_call\" && $.outcome = \"rejected_unknown_tool\" }", value = "1", unit = "Count" }
    AuthFailures          = { pattern = "{ $.event = \"auth_failed\" }", value = "1", unit = "Count" }
    CapacityRejections    = { pattern = "{ $.event = \"capacity_exceeded\" }", value = "1", unit = "Count" }
    IterationLimitHits    = { pattern = "{ $.event = \"agent_iteration_limit_reached\" }", value = "1", unit = "Count" }
    SecretRefreshFailures = { pattern = "{ $.event = \"secret_refresh_failed_serving_cached\" || $.event = \"auth_unavailable\" }", value = "1", unit = "Count" }
    AppErrors             = { pattern = "{ $.level = \"ERROR\" }", value = "1", unit = "Count" }
  }
}

resource "aws_cloudwatch_log_metric_filter" "app" {
  for_each       = local.log_metrics
  name           = "${local.name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = each.value.pattern
  metric_transformation {
    name      = each.key
    namespace = local.metrics_ns
    value     = each.value.value
    unit      = each.value.unit
  }
}

# ----------------------------------------------------------------- alarms
locals {
  tg_dim  = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = aws_lb_target_group.agent.arn_suffix }
  svc_dim = { ClusterName = aws_ecs_cluster.this.name, ServiceName = aws_ecs_service.agent.name }

  # severity: P1 = page now, P2 = business hours. Runbook section per alarm.
  alarms = {
    "P1-no-healthy-targets" = {
      ns   = "AWS/ApplicationELB", metric = "HealthyHostCount", stat = "Minimum", dims = local.tg_dim,
      op   = "LessThanThreshold", threshold = 1, periods = 2, period = 60, missing = "breaching",
      desc = "No healthy agent tasks behind the ALB. Service is DOWN. Runbook: RB-01"
    }
    "P1-running-tasks-below-min" = {
      ns   = "ECS/ContainerInsights", metric = "RunningTaskCount", stat = "Minimum", dims = local.svc_dim,
      op   = "LessThanThreshold", threshold = var.min_tasks, periods = 3, period = 60, missing = "breaching",
      desc = "Fewer running tasks than the minimum. Runbook: RB-01"
    }
    "P1-alb-5xx" = {
      ns   = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", stat = "Sum", dims = local.tg_dim,
      op   = "GreaterThanThreshold", threshold = 10, periods = 1, period = 300, missing = "notBreaching",
      desc = "More than 10 server errors in 5 minutes. Runbook: RB-02"
    }
    "P1-llm-errors" = {
      ns   = local.metrics_ns, metric = "LLMErrors", stat = "Sum", dims = {},
      op   = "GreaterThanOrEqualToThreshold", threshold = 5, periods = 1, period = 300, missing = "notBreaching",
      desc = "LLM provider calls failing (outage, bad/revoked key, quota). Runbook: RB-03"
    }
    "P1-secret-access-failures" = {
      ns   = local.metrics_ns, metric = "SecretRefreshFailures", stat = "Sum", dims = {},
      op   = "GreaterThanOrEqualToThreshold", threshold = 1, periods = 1, period = 300, missing = "notBreaching",
      desc = "App cannot refresh secrets from Secrets Manager. Runbook: RB-04"
    }
    "P2-latency-p95" = {
      ns   = "AWS/ApplicationELB", metric = "TargetResponseTime", stat = "p95", dims = local.tg_dim,
      op   = "GreaterThanThreshold", threshold = 20, periods = 3, period = 300, missing = "notBreaching",
      desc = "p95 response time above 20s for 15 minutes. Runbook: RB-05"
    }
    "P2-auth-failures" = {
      ns   = local.metrics_ns, metric = "AuthFailures", stat = "Sum", dims = {},
      op   = "GreaterThanThreshold", threshold = 25, periods = 1, period = 300, missing = "notBreaching",
      desc = "Many rejected API keys: misconfigured client after rotation, or key guessing. Runbook: RB-07"
    }
    "P2-tool-errors" = {
      ns   = local.metrics_ns, metric = "ToolErrors", stat = "Sum", dims = {},
      op   = "GreaterThanOrEqualToThreshold", threshold = 3, periods = 1, period = 300, missing = "notBreaching",
      desc = "Agent tools failing (e.g. DynamoDB ticket writes). Runbook: RB-08"
    }
    "P2-rejected-tool-calls" = {
      ns   = local.metrics_ns, metric = "ToolRejected", stat = "Sum", dims = {},
      op   = "GreaterThanOrEqualToThreshold", threshold = 1, periods = 1, period = 300, missing = "notBreaching",
      desc = "The model requested a tool that does not exist: possible prompt-injection attempt. Runbook: RB-09"
    }
    "P2-cpu-high" = {
      ns   = "AWS/ECS", metric = "CPUUtilization", stat = "Average", dims = local.svc_dim,
      op   = "GreaterThanThreshold", threshold = 85, periods = 3, period = 300, missing = "notBreaching",
      desc = "CPU above 85% for 15 minutes even with autoscaling. Runbook: RB-05"
    }
    "P2-memory-high" = {
      ns   = "AWS/ECS", metric = "MemoryUtilization", stat = "Average", dims = local.svc_dim,
      op   = "GreaterThanThreshold", threshold = 85, periods = 3, period = 300, missing = "notBreaching",
      desc = "Memory above 85% for 15 minutes (risk of OOM kills). Runbook: RB-05"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each            = local.alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.desc
  namespace           = each.value.ns
  metric_name         = each.value.metric
  dimensions          = length(each.value.dims) > 0 ? each.value.dims : null
  statistic           = startswith(each.value.stat, "p") ? null : each.value.stat
  extended_statistic  = startswith(each.value.stat, "p") ? each.value.stat : null
  comparison_operator = each.value.op
  threshold           = each.value.threshold
  evaluation_periods  = each.value.periods
  period              = each.value.period
  treat_missing_data  = each.value.missing
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  depends_on          = [aws_cloudwatch_log_metric_filter.app]
}

# Cost guardrail: input + output tokens in one hour (metric math).
resource "aws_cloudwatch_metric_alarm" "token_budget" {
  alarm_name          = "${local.name}-P2-token-budget"
  alarm_description   = "Input+output tokens in the last hour above budget (cost spike, loop or abuse). Runbook: RB-06"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.hourly_token_budget
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  metric_query {
    id          = "total"
    expression  = "FILL(inp, 0) + FILL(out, 0)"
    label       = "Tokens per hour"
    return_data = true
  }
  metric_query {
    id = "inp"
    metric {
      namespace   = local.metrics_ns
      metric_name = "LLMInputTokens"
      period      = 3600
      stat        = "Sum"
    }
  }
  metric_query {
    id = "out"
    metric {
      namespace   = local.metrics_ns
      metric_name = "LLMOutputTokens"
      period      = 3600
      stat        = "Sum"
    }
  }
  depends_on = [aws_cloudwatch_log_metric_filter.app]
}

# ----------------------------------------------------------------- saved Logs Insights queries (used by the runbook)
resource "aws_cloudwatch_query_definition" "errors" {
  name            = "${local.name}/recent-errors"
  log_group_names = [aws_cloudwatch_log_group.app.name]
  query_string    = <<-EOT
    fields ts, event, request_id, error, path, status
    | filter level = "ERROR" or status >= 500
    | sort @timestamp desc
    | limit 100
  EOT
}

resource "aws_cloudwatch_query_definition" "trace_request" {
  name            = "${local.name}/trace-one-request (edit the id)"
  log_group_names = [aws_cloudwatch_log_group.app.name]
  query_string    = <<-EOT
    fields ts, level, event, tool, outcome, latency_ms, input_tokens, output_tokens, status
    | filter request_id = "PASTE-REQUEST-ID"
    | sort @timestamp asc
  EOT
}

resource "aws_cloudwatch_query_definition" "slowest" {
  name            = "${local.name}/slowest-requests"
  log_group_names = [aws_cloudwatch_log_group.app.name]
  query_string    = <<-EOT
    fields ts, request_id, path, status, latency_ms
    | filter event = "request_completed"
    | sort latency_ms desc
    | limit 25
  EOT
}

resource "aws_cloudwatch_query_definition" "token_usage" {
  name            = "${local.name}/token-usage-by-hour"
  log_group_names = [aws_cloudwatch_log_group.app.name]
  query_string    = <<-EOT
    filter event = "llm_call" and outcome = "ok"
    | stats sum(input_tokens) as input, sum(output_tokens) as output, count(*) as calls, avg(latency_ms) as avg_ms by bin(1h)
  EOT
}

resource "aws_cloudwatch_query_definition" "auth_failures" {
  name            = "${local.name}/auth-failures"
  log_group_names = [aws_cloudwatch_log_group.app.name]
  query_string    = <<-EOT
    filter event = "auth_failed"
    | stats count(*) as failures by reason, bin(5m)
  EOT
}

# ----------------------------------------------------------------- dashboard
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2
        properties = { markdown = "## ${local.name} — AI agent (customer environment)\nRow 1: is it up? Row 2: is the AI healthy? Row 3: cost & abuse. Alarms are listed in docs/runbook.md." }
      },
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6
        properties = {
          title = "Healthy targets / running tasks", region = local.region, view = "timeSeries", stat = "Minimum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.agent.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix],
            ["ECS/ContainerInsights", "RunningTaskCount", "ServiceName", aws_ecs_service.agent.name, "ClusterName", aws_ecs_cluster.this.name],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6
        properties = {
          title = "Requests and 5xx", region = local.region, view = "timeSeries", stat = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.agent.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "TargetGroup", aws_lb_target_group.agent.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "TargetGroup", aws_lb_target_group.agent.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6
        properties = {
          title = "Response time p50 / p95 (s)", region = local.region, view = "timeSeries", period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", aws_lb_target_group.agent.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", aws_lb_target_group.agent.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 8, height = 6
        properties = {
          title   = "LLM calls vs errors", region = local.region, view = "timeSeries", stat = "Sum", period = 60
          metrics = [[local.metrics_ns, "LLMCalls"], [local.metrics_ns, "LLMErrors"]]
        }
      },
      {
        type = "metric", x = 8, y = 8, width = 8, height = 6
        properties = {
          title   = "LLM latency p50 / p95 (ms)", region = local.region, view = "timeSeries", period = 60
          metrics = [[local.metrics_ns, "LLMLatencyMs", { stat = "p50" }], [local.metrics_ns, "LLMLatencyMs", { stat = "p95" }]]
        }
      },
      {
        type = "metric", x = 16, y = 8, width = 8, height = 6
        properties = {
          title   = "Tool calls / errors / rejected", region = local.region, view = "timeSeries", stat = "Sum", period = 300
          metrics = [[local.metrics_ns, "ToolCalls"], [local.metrics_ns, "ToolErrors"], [local.metrics_ns, "ToolRejected"], [local.metrics_ns, "IterationLimitHits"]]
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 8, height = 6
        properties = {
          title   = "Tokens per hour", region = local.region, view = "timeSeries", stat = "Sum", period = 3600
          metrics = [[local.metrics_ns, "LLMInputTokens"], [local.metrics_ns, "LLMOutputTokens"]]
        }
      },
      {
        type = "metric", x = 8, y = 14, width = 8, height = 6
        properties = {
          title   = "Auth failures / capacity rejections / secret failures", region = local.region, view = "timeSeries", stat = "Sum", period = 300
          metrics = [[local.metrics_ns, "AuthFailures"], [local.metrics_ns, "CapacityRejections"], [local.metrics_ns, "SecretRefreshFailures"]]
        }
      },
      {
        type = "metric", x = 16, y = 14, width = 8, height = 6
        properties = {
          title = "CPU / memory %", region = local.region, view = "timeSeries", stat = "Average", period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ServiceName", aws_ecs_service.agent.name, "ClusterName", aws_ecs_cluster.this.name],
            ["AWS/ECS", "MemoryUtilization", "ServiceName", aws_ecs_service.agent.name, "ClusterName", aws_ecs_cluster.this.name],
          ]
        }
      },
      {
        type       = "alarm", x = 0, y = 20, width = 24, height = 4
        properties = { title = "Alarm status", alarms = concat([for a in aws_cloudwatch_metric_alarm.this : a.arn], [aws_cloudwatch_metric_alarm.token_budget.arn]) }
      },
    ]
  })
}
