variable "customer_prefix" {
  type        = string
  description = "customer prefix to use to namespace all resources"
  default     = "fleet"
}

variable "task_size" {
  type = object({
    cpu    = optional(number, 256)
    memory = optional(number, 1024)
  })

  default = {
    cpu    = 256
    memory = 1024
  }
}

variable "ecs_cluster" {
  type = string
}

variable "ecs_execution_iam_role_arn" {
  type = string
}

variable "ecs_iam_role_arn" {
  type = string
}

variable "extra_flags" {
  type    = list(string)
  default = []
}

variable "loadtest_containers" {
  type    = number
  default = 1
}

variable "logging_options" {
  type = object({
    awslogs-group         = string
    awslogs-region        = string
    awslogs-stream-prefix = string
  })
}

variable "osquery_perf_image" {
  type = string
}

variable "security_groups" {
  type     = list(string)
  nullable = false
}

variable "server_url" {
  type = string
}

variable "subnets" {
  type     = list(string)
  nullable = false
}

variable "enroll_secret" {
  type        = string
  description = "Value of the enroll secret to be created, if enroll_secret_arn is not passed in"
  default     = null
}

variable "enroll_secret_arn" {
  type        = string
  description = "ARN of the AWS Secret Version containing the enroll secret"
  default     = null
}
