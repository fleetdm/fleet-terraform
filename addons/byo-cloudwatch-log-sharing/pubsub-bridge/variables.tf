variable "subscription" {
  description = "CloudWatch Logs subscription settings for sending Fleet log events to the Pub/Sub bridge Lambda."
  type = object({
    log_group_name = string
    log_group_arn  = optional(string)
    filter_name    = optional(string, "fleet-log-pubsub-bridge")
    filter_pattern = optional(string, "")
  })

  validation {
    condition     = length(trimspace(var.subscription.log_group_name)) > 0
    error_message = "subscription.log_group_name must not be empty."
  }

  validation {
    condition = (
      !can(var.subscription.log_group_arn) ||
      var.subscription.log_group_arn == null ||
      startswith(var.subscription.log_group_arn, "arn:")
    )
    error_message = "subscription.log_group_arn must be a valid ARN when provided."
  }
}

variable "lambda" {
  description = "Go-based Lambda bridge configuration."
  type = object({
    function_name                  = optional(string, "fleet-cloudwatch-pubsub-bridge")
    role_name                      = optional(string, "fleet-cloudwatch-pubsub-bridge-role")
    policy_name                    = optional(string)
    runtime                        = optional(string, "provided.al2")
    architecture                   = optional(string, "x86_64")
    memory_size                    = optional(number, 256)
    timeout                        = optional(number, 60)
    log_retention_in_days          = optional(number, 30)
    reserved_concurrent_executions = optional(number, -1)
    batch_size                     = optional(number, 1000)
  })
  default = {}

  validation {
    condition     = contains(["provided.al2", "provided.al2023"], var.lambda.runtime)
    error_message = "lambda.runtime must be one of: provided.al2, provided.al2023."
  }

  validation {
    condition     = contains(["x86_64", "arm64"], var.lambda.architecture)
    error_message = "lambda.architecture must be one of: x86_64, arm64."
  }

  validation {
    condition     = var.lambda.memory_size >= 128 && var.lambda.memory_size <= 10240
    error_message = "lambda.memory_size must be between 128 and 10240 MB."
  }

  validation {
    condition     = var.lambda.timeout >= 1 && var.lambda.timeout <= 900
    error_message = "lambda.timeout must be between 1 and 900 seconds."
  }

  validation {
    condition     = var.lambda.batch_size >= 1 && var.lambda.batch_size <= 1000
    error_message = "lambda.batch_size must be between 1 and 1000."
  }

  validation {
    condition = (
      var.lambda.reserved_concurrent_executions == -1 ||
      var.lambda.reserved_concurrent_executions >= 1
    )
    error_message = "lambda.reserved_concurrent_executions must be -1 (unreserved) or >= 1."
  }
}

variable "gcp_pubsub" {
  description = "GCP Pub/Sub settings and credentials secret reference for cloud.google.com/go/pubsub/v2. The secret must contain a Google service-account key JSON, or a JSON object with a service_account_json field containing that key JSON."
  type = object({
    project_id             = string
    topic_id               = string
    credentials_secret_arn = string
    secret_kms_key_arn     = optional(string, "")
  })

  validation {
    condition     = length(trimspace(var.gcp_pubsub.project_id)) > 0
    error_message = "gcp_pubsub.project_id must not be empty."
  }

  validation {
    condition     = length(trimspace(var.gcp_pubsub.topic_id)) > 0
    error_message = "gcp_pubsub.topic_id must not be empty."
  }

  validation {
    condition     = startswith(var.gcp_pubsub.credentials_secret_arn, "arn:")
    error_message = "gcp_pubsub.credentials_secret_arn must be a Secrets Manager ARN."
  }

  validation {
    condition = (
      var.gcp_pubsub.secret_kms_key_arn == "" ||
      startswith(var.gcp_pubsub.secret_kms_key_arn, "arn:")
    )
    error_message = "gcp_pubsub.secret_kms_key_arn must be empty or a valid KMS key ARN."
  }
}

variable "dlq" {
  description = "Asynchronous Lambda failure handling via SQS dead-letter queue."
  type = object({
    enabled                      = optional(bool, true)
    queue_name                   = optional(string)
    maximum_retry_attempts       = optional(number, 2)
    maximum_event_age_in_seconds = optional(number, 3600)
    message_retention_seconds    = optional(number, 1209600)
    visibility_timeout_seconds   = optional(number, 60)
    sqs_managed_sse_enabled      = optional(bool, true)
    kms_master_key_id            = optional(string, "")
  })
  default = {}

  validation {
    condition = (
      !can(var.dlq.queue_name) ||
      var.dlq.queue_name == null ||
      length(trimspace(var.dlq.queue_name)) > 0
    )
    error_message = "dlq.queue_name must not be empty when provided."
  }

  validation {
    condition     = var.dlq.maximum_retry_attempts >= 0 && var.dlq.maximum_retry_attempts <= 2
    error_message = "dlq.maximum_retry_attempts must be between 0 and 2."
  }

  validation {
    condition     = var.dlq.maximum_event_age_in_seconds >= 60 && var.dlq.maximum_event_age_in_seconds <= 21600
    error_message = "dlq.maximum_event_age_in_seconds must be between 60 and 21600."
  }

  validation {
    condition     = var.dlq.message_retention_seconds >= 60 && var.dlq.message_retention_seconds <= 1209600
    error_message = "dlq.message_retention_seconds must be between 60 and 1209600."
  }

  validation {
    condition     = var.dlq.visibility_timeout_seconds >= 0 && var.dlq.visibility_timeout_seconds <= 43200
    error_message = "dlq.visibility_timeout_seconds must be between 0 and 43200."
  }

  validation {
    condition = (
      var.dlq.kms_master_key_id == "" ||
      startswith(var.dlq.kms_master_key_id, "arn:") ||
      startswith(var.dlq.kms_master_key_id, "alias/")
    )
    error_message = "dlq.kms_master_key_id must be empty, an ARN, or an alias/ value."
  }
}

variable "alerting" {
  description = "CloudWatch alarm and SNS notification settings for bridge failures."
  type = object({
    enabled                        = optional(bool, true)
    sns_topic_arns                 = optional(list(string), [])
    enable_ok_notifications        = optional(bool, true)
    period_seconds                 = optional(number, 300)
    evaluation_periods             = optional(number, 1)
    datapoints_to_alarm            = optional(number, 1)
    lambda_errors_threshold        = optional(number, 1)
    dlq_visible_messages_threshold = optional(number, 1)
  })
  default = {}

  validation {
    condition     = var.alerting.period_seconds >= 10
    error_message = "alerting.period_seconds must be at least 10."
  }

  validation {
    condition     = var.alerting.evaluation_periods >= 1
    error_message = "alerting.evaluation_periods must be at least 1."
  }

  validation {
    condition = (
      var.alerting.datapoints_to_alarm >= 1 &&
      var.alerting.datapoints_to_alarm <= var.alerting.evaluation_periods
    )
    error_message = "alerting.datapoints_to_alarm must be between 1 and alerting.evaluation_periods."
  }

  validation {
    condition     = var.alerting.lambda_errors_threshold >= 1
    error_message = "alerting.lambda_errors_threshold must be at least 1."
  }

  validation {
    condition     = var.alerting.dlq_visible_messages_threshold >= 1
    error_message = "alerting.dlq_visible_messages_threshold must be at least 1."
  }
}

variable "replayer" {
  description = "SQS DLQ replayer settings. Replays failed bridge events back to the main bridge Lambda."
  type = object({
    enabled                            = optional(bool, true)
    function_name                      = optional(string)
    role_name                          = optional(string)
    policy_name                        = optional(string)
    runtime                            = optional(string)
    architecture                       = optional(string)
    memory_size                        = optional(number, 256)
    timeout                            = optional(number, 60)
    log_retention_in_days              = optional(number, 30)
    reserved_concurrent_executions     = optional(number, -1)
    batch_size                         = optional(number, 10)
    maximum_batching_window_in_seconds = optional(number, 5)
    maximum_concurrency                = optional(number, 2)
  })
  default = {}

  validation {
    condition     = !var.replayer.enabled || var.dlq.enabled
    error_message = "replayer.enabled requires dlq.enabled to be true."
  }

  validation {
    condition = (
      !can(var.replayer.function_name) ||
      var.replayer.function_name == null ||
      length(trimspace(var.replayer.function_name)) > 0
    )
    error_message = "replayer.function_name must not be empty when provided."
  }

  validation {
    condition = (
      !can(var.replayer.role_name) ||
      var.replayer.role_name == null ||
      length(trimspace(var.replayer.role_name)) > 0
    )
    error_message = "replayer.role_name must not be empty when provided."
  }

  validation {
    condition = (
      !can(var.replayer.policy_name) ||
      var.replayer.policy_name == null ||
      length(trimspace(var.replayer.policy_name)) > 0
    )
    error_message = "replayer.policy_name must not be empty when provided."
  }

  validation {
    condition = (
      !can(var.replayer.runtime) ||
      var.replayer.runtime == null ||
      contains(["provided.al2", "provided.al2023"], var.replayer.runtime)
    )
    error_message = "replayer.runtime must be one of: provided.al2, provided.al2023."
  }

  validation {
    condition = (
      !can(var.replayer.architecture) ||
      var.replayer.architecture == null ||
      contains(["x86_64", "arm64"], var.replayer.architecture)
    )
    error_message = "replayer.architecture must be one of: x86_64, arm64."
  }

  validation {
    condition     = var.replayer.memory_size >= 128 && var.replayer.memory_size <= 10240
    error_message = "replayer.memory_size must be between 128 and 10240 MB."
  }

  validation {
    condition     = var.replayer.timeout >= 1 && var.replayer.timeout <= 900
    error_message = "replayer.timeout must be between 1 and 900 seconds."
  }

  validation {
    condition = (
      var.replayer.reserved_concurrent_executions == -1 ||
      var.replayer.reserved_concurrent_executions >= 1
    )
    error_message = "replayer.reserved_concurrent_executions must be -1 (unreserved) or >= 1."
  }

  validation {
    condition     = var.replayer.batch_size >= 1 && var.replayer.batch_size <= 10000
    error_message = "replayer.batch_size must be between 1 and 10000."
  }

  validation {
    condition     = var.replayer.maximum_batching_window_in_seconds >= 0 && var.replayer.maximum_batching_window_in_seconds <= 300
    error_message = "replayer.maximum_batching_window_in_seconds must be between 0 and 300."
  }

  validation {
    condition = (
      var.replayer.maximum_concurrency == 0 ||
      (var.replayer.maximum_concurrency >= 2 && var.replayer.maximum_concurrency <= 1000)
    )
    error_message = "replayer.maximum_concurrency must be 0 (disabled) or between 2 and 1000."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to created resources that support tags."
  default     = {}
}
