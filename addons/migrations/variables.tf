variable "ecs_cluster" {
  type     = string
  nullable = false
}

variable "ecs_service" {
  type     = string
  nullable = false
}

variable "min_capacity" {
  type     = number
  nullable = false
}

variable "desired_count" {
  type     = number
  nullable = false
}

variable "task_definition" {
  type     = string
  nullable = false
}

variable "task_definition_revision" {
  type     = number
  nullable = false
}

variable "subnets" {
  type     = list(string)
  nullable = false
}

variable "security_groups" {
  type     = list(string)
  nullable = false
}

variable "vuln_service" {
  default = ""
}
variable "assume_role_arn" {
  description = "ARN of the IAM role to assume for ECS permissions"
  type        = string
  default     = ""
}

variable "assume_role_session_name" {
  description = "Session name to use when assuming the IAM role"
  type        = string
  default     = ""
}

