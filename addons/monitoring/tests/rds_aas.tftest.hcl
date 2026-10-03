// Plan-only checks for the RDS AAS-per-vCPU alarm. Uses mock providers, so no
// AWS credentials are needed and nothing is created. Run from addons/monitoring:
//   terraform init -backend=false && terraform test

mock_provider "aws" {
  // Random mock strings fail plan-time ARN / IAM policy JSON validation in
  // the unrelated cron-monitoring resources, so pin realistic values.
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-2"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}
mock_provider "archive" {}
mock_provider "null" {}

variables {
  customer_prefix        = "fleet"
  mysql_cluster_members  = ["db-1", "db-2"]
  default_sns_topic_arns = ["arn:aws:sns:us-east-2:123456789012:default"]
  // The module's cron-monitoring IAM policy document is evaluated
  // unconditionally, so planning requires a (mocked) cron_monitoring config.
  cron_monitoring = {
    mysql_host                 = "db.example.internal"
    mysql_database             = "fleet"
    mysql_user                 = "fleet"
    mysql_password_secret_name = "fleet-database-password"
    vpc_id                     = "vpc-00000000"
    subnet_ids                 = ["subnet-00000000"]
    rds_security_group_id      = "sg-00000000"
    delay_tolerance            = "4h"
    run_interval               = "1 hour"
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds_aas_too_high) == 2
    error_message = "Expected one AAS alarm per mysql_cluster_members instance."
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].alarm_name == "rds_aas_too_high-fleet-${id}" &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].namespace == "AWS/RDS" &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].metric_name == "DBLoadRelativeToNumVCPUs" &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].statistic == "Average" &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].dimensions["DBInstanceIdentifier"] == id &&
      length(aws_cloudwatch_metric_alarm.rds_aas_too_high[id].dimensions) == 1 &&
      length(aws_cloudwatch_metric_alarm.rds_aas_too_high[id].metric_query) == 0
    )])
    error_message = "AAS alarm must be a direct-metric alarm on AWS/RDS DBLoadRelativeToNumVCPUs Average with only the DBInstanceIdentifier dimension."
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].comparison_operator == "GreaterThanThreshold" &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].threshold == 1 &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].period == 300 &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].evaluation_periods == 1 &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].treat_missing_data == "notBreaching"
    )])
    error_message = "AAS alarm defaults must be strict > 1 over 300s, 1 evaluation period, missing data notBreaching."
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].alarm_actions == toset(["arn:aws:sns:us-east-2:123456789012:default"]) &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].ok_actions == toset(["arn:aws:sns:us-east-2:123456789012:default"])
    )])
    error_message = "AAS alarm must fall back to default_sns_topic_arns for both alarm and OK actions."
  }

  // Existing CPU alarm is unchanged.
  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].alarm_name == "rds_cpu_utilization_too_high-fleet-${id}" &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].metric_name == "CPUUtilization" &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].namespace == "AWS/RDS" &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].statistic == "Average" &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].comparison_operator == "GreaterThanThreshold" &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].threshold == 80 &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].period == 300 &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].evaluation_periods == 1 &&
      // Not set by the module; mock providers plan it as null (the real provider defaults it to "missing").
      coalesce(aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].treat_missing_data, "missing") == "missing" &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].alarm_description == "Average database CPU utilization over last 5 minutes too high" &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].dimensions["DBInstanceIdentifier"] == id &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].alarm_actions == toset(["arn:aws:sns:us-east-2:123456789012:default"]) &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].ok_actions == toset(["arn:aws:sns:us-east-2:123456789012:default"])
    )])
    error_message = "Existing RDS CPU alarm must be unchanged."
  }
}

run "configurable_ratio_period_evaluation_periods" {
  command = plan

  variables {
    alert_thresholds = {
      rds_aas = {
        threshold          = 1.5
        period             = 60
        evaluation_periods = 3
      }
    }
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].threshold == 1.5 &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].period == 60 &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].evaluation_periods == 3 &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].comparison_operator == "GreaterThanThreshold" &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].treat_missing_data == "notBreaching"
    )])
    error_message = "alert_thresholds.rds_aas must override threshold, period, and evaluation_periods."
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].threshold == 80 &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].period == 300 &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].evaluation_periods == 1
    )])
    error_message = "Overriding only rds_aas must keep the rds_cpu defaults."
  }
}

run "partial_override_keeps_rds_aas_defaults" {
  command = plan

  variables {
    alert_thresholds = {
      rds_cpu = {
        threshold          = 90
        period             = 600
        evaluation_periods = 2
      }
    }
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].threshold == 1 &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].period == 300 &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].evaluation_periods == 1
    )])
    error_message = "Overriding only rds_cpu must keep the rds_aas defaults."
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].threshold == 90 &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].period == 600 &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].evaluation_periods == 2
    )])
    error_message = "rds_cpu overrides must still apply."
  }
}

run "explicit_sns_routing_is_independent" {
  command = plan

  variables {
    sns_topic_arns_map = {
      rds_aas_too_high             = ["arn:aws:sns:us-east-2:123456789012:aas"]
      rds_cpu_utilization_too_high = ["arn:aws:sns:us-east-2:123456789012:cpu"]
    }
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].alarm_actions == toset(["arn:aws:sns:us-east-2:123456789012:aas"]) &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].ok_actions == toset(["arn:aws:sns:us-east-2:123456789012:aas"])
    )])
    error_message = "rds_aas_too_high must route both alarm and OK actions."
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].alarm_actions == toset(["arn:aws:sns:us-east-2:123456789012:cpu"]) &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].ok_actions == toset(["arn:aws:sns:us-east-2:123456789012:cpu"])
    )])
    error_message = "CPU alarm routing must be unaffected by rds_aas_too_high."
  }
}

run "cpu_key_and_typo_alias_do_not_route_aas" {
  command = plan

  variables {
    sns_topic_arns_map = {
      rds_cpu_untilizaton_too_high = ["arn:aws:sns:us-east-2:123456789012:cpu-typo"]
    }
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].alarm_actions == toset(["arn:aws:sns:us-east-2:123456789012:cpu-typo"]) &&
      aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].ok_actions == toset(["arn:aws:sns:us-east-2:123456789012:cpu-typo"])
    )])
    error_message = "Deprecated rds_cpu_untilizaton_too_high alias must still route the CPU alarm."
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].alarm_actions == toset(["arn:aws:sns:us-east-2:123456789012:default"]) &&
      aws_cloudwatch_metric_alarm.rds_aas_too_high[id].ok_actions == toset(["arn:aws:sns:us-east-2:123456789012:default"])
    )])
    error_message = "AAS alarm must fall back to default_sns_topic_arns when rds_aas_too_high is absent."
  }
}

run "explicit_empty_sns_override_matches_cpu" {
  command = plan

  variables {
    sns_topic_arns_map = {
      rds_aas_too_high             = []
      rds_cpu_utilization_too_high = []
    }
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      length(aws_cloudwatch_metric_alarm.rds_aas_too_high[id].alarm_actions) == 0 &&
      length(aws_cloudwatch_metric_alarm.rds_aas_too_high[id].ok_actions) == 0
    )])
    error_message = "An explicit empty rds_aas_too_high list must not fall back to default_sns_topic_arns."
  }

  assert {
    condition = alltrue([for id in ["db-1", "db-2"] : (
      length(aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].alarm_actions) == 0 &&
      length(aws_cloudwatch_metric_alarm.cpu_utilization_too_high[id].ok_actions) == 0
    )])
    error_message = "CPU alarm explicit empty override behaves the same way."
  }
}

run "no_instances_no_alarms" {
  command = plan

  variables {
    mysql_cluster_members = []
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds_aas_too_high) == 0
    error_message = "No AAS alarms when mysql_cluster_members is empty."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.cpu_utilization_too_high) == 0
    error_message = "No CPU alarms when mysql_cluster_members is empty."
  }
}

run "alarm_name_uses_customer_prefix_and_instance" {
  command = plan

  variables {
    customer_prefix       = "acme"
    mysql_cluster_members = ["acme-db-writer"]
  }

  assert {
    condition     = keys(aws_cloudwatch_metric_alarm.rds_aas_too_high) == ["acme-db-writer"]
    error_message = "AAS alarms must be keyed by DB instance identifier."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.rds_aas_too_high["acme-db-writer"].alarm_name == "rds_aas_too_high-acme-acme-db-writer"
    error_message = "AAS alarm name must be exactly rds_aas_too_high-<customer_prefix>-<DBInstanceIdentifier>."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.rds_aas_too_high["acme-db-writer"].dimensions["DBInstanceIdentifier"] == "acme-db-writer"
    error_message = "AAS alarm dimension must be the DB instance identifier."
  }
}
