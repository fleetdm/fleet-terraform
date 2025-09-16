resource "aws_kms_key" "enroll_secret" {
  count                   = var.enroll_secret_arn == null ? 1 : 0
  deletion_window_in_days = 10
  enable_key_rotation     = true
}

resource "aws_kms_alias" "enroll_secret" {
  count         = var.enroll_secret_arn == null ? 1 : 0
  name_prefix   = "alias/${var.customer_prefix}-enroll-secret-key"
  target_key_id = aws_kms_key.enroll_secret[0].key_id
}

resource "aws_secretsmanager_secret" "enroll_secret" {
  count       = var.enroll_secret_arn == null ? 1 : 0
  name_prefix = "${var.customer_prefix}-enroll-secret"
  kms_key_id  = aws_kms_key.enroll_secret[0].arn
}

resource "aws_secretsmanager_secret_version" "enroll_secret" {
  count         = var.enroll_secret == null || var.enroll_secret_arn != null ? 0 : 1 # Passing in ARN takes priority
  secret_id     = aws_secretsmanager_secret.enroll_secret[0].id
  secret_string = var.enroll_secret
}

data "aws_secretsmanager_secret_version" "enroll_secret" {
  secret_id = var.enroll_secret_arn == null ? aws_secretsmanager_secret.enroll_secret[0].id : var.enroll_secret_arn
}

resource "aws_ecs_task_definition" "osquery_perf" {
  family                   = "${var.customer_prefix}-osquery-perf"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = var.ecs_execution_iam_role_arn
  task_role_arn            = var.ecs_iam_role_arn
  cpu                      = 256
  memory                   = 1024
  container_definitions = jsonencode(
    [
      {
        name        = "osquery-perf"
        image       = var.osquery_perf_image
        cpu         = 256
        memory      = 512
        mountPoints = []
        volumesFrom = []
        essential   = true
        ulimits = [
          {
            softLimit = 9999,
            hardLimit = 9999,
            name      = "nofile"
          }
        ]
        networkMode = "awsvpc"
        logConfiguration = {
          logDriver = "awslogs"
          options   = var.logging_options
        }
        workingDirectory = "/go",
        command = concat([
          "/go/osquery-perf",
          "-enroll_secret", data.aws_secretsmanager_secret_version.enroll_secret.secret_string,
          "-host_count", "500",
          "-server_url", var.server_url,
          "--policy_pass_prob", "0.5",
          "--start_period", "5m",
        ], var.extra_flags)
      }
  ])
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ecs_service" "osquery_perf" {
  name                               = "osquery_perf"
  launch_type                        = "FARGATE"
  cluster                            = var.ecs_cluster
  task_definition                    = aws_ecs_task_definition.osquery_perf.arn
  desired_count                      = var.loadtest_containers
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets         = var.subnets
    security_groups = var.security_groups
  }
}
