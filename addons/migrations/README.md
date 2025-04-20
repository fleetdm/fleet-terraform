# Terraform AWS Fleet Database Migration Module

This Terraform module provides a mechanism to trigger database migrations for a Fleet application running on AWS ECS. It is designed to integrate into an infrastructure deployment pipeline, ensuring that database schema changes are applied gracefully, typically during application upgrades.

The core functionality relies on a `null_resource` which executes a local script (`migrate.sh`) when specific triggers change (primarily the `task_definition_revision`). This script is expected to handle the actual migration process, which usually involves:

1.  Scaling down the main Fleet application ECS service.
2.  Running a one-off ECS task using the *new* task definition revision (which contains the updated application code capable of performing the migration). This task executes the necessary Fleet migration command (e.g., `fleetctl prepare db`).
3.  Scaling the main Fleet application ECS service back up once the migration is complete.

## Usage

```hcl
module "fleet_migration" {
  source = "./path/to/this/module" # Or Git source

  ecs_cluster              = "my-fleet-cluster"
  ecs_service              = "my-fleet-service"
  task_definition          = "arn:aws:ecs:us-west-2:123456789012:task-definition/my-fleet-app" # Base ARN without revision
  task_definition_revision = 5 # The *new* revision to migrate *to*
  min_capacity             = 0 # Scale down to this during migration
  desired_count            = 2 # Scale back up to this after migration
  subnets                  = ["subnet-xxxxxxxxxxxxxxxxx", "subnet-yyyyyyyyyyyyyyyyy"]
  security_groups          = ["sg-xxxxxxxxxxxxxxxxx"]

  # Optional: Specify if a separate vulnerability processing service needs coordination
  # vuln_service             = "my-fleet-vuln-service"

  # Optional: Provide an IAM Role ARN for the local-exec script to assume
  # assume_role_arn          = "arn:aws:iam::123456789012:role/MyMigrationRole"
  # assume_role_session_name = "TerraformFleetMigration"

  # Ensure this module depends on the resource that creates/updates the task definition revision
  # For example:
  # depends_on = [aws_ecs_task_definition.fleet_app]
}
```

## Workflow

1.  When `var.task_definition_revision` changes, Terraform triggers the `null_resource`.
2.  The `local-exec` provisioner executes the `migrate.sh` script located within the module's directory.
3.  It passes essential AWS and ECS details (region, cluster, service, task definition, revision, network configuration, scaling parameters, optional role ARN) as command-line arguments or environment variables to the script.
4.  The `migrate.sh` script (which you must provide and maintain) performs the migration steps against the Fleet database, using the provided parameters to interact with AWS ECS.

## Prerequisites

*   **`bash` shell:** Must be available in the environment where Terraform is executed.
*   **AWS CLI:** Must be installed and configured with credentials in the environment where Terraform is executed. The credentials need permissions to perform ECS actions (DescribeServices, UpdateService, RunTask, DescribeTasks) and potentially STS AssumeRole if `assume_role_arn` is provided.
*   **`migrate.sh` script:** A script named `migrate.sh` *must* exist within this module's directory (`path.module`). This script contains the actual logic for scaling services and running the migration task. **This module only triggers the script; it does not contain the migration logic itself.**
*   **Existing Resources:** The specified ECS Cluster, Service, Task Definition (base ARN), Subnets, and Security Groups must exist.

## Important Considerations

*   **`local-exec`:** This provisioner runs commands on the machine executing Terraform. Ensure this machine has the necessary tools (bash, AWS CLI) and network access/credentials to interact with your AWS environment. This might require specific configuration in CI/CD pipelines.
*   **IAM Permissions:** The credentials used by `local-exec` (either default AWS credentials or the assumed role specified by `assume_role_arn`) require sufficient IAM permissions to manage the specified ECS services and tasks.
*   **State:** The `null_resource` uses the `task_definition_revision` in its `triggers` map. This ensures that Terraform re-runs the provisioner if (and only if) the revision number changes between applies.

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |
| <a name="provider_null"></a> [null](#provider\_null) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [null_resource.main](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_assume_role_arn"></a> [assume\_role\_arn](#input\_assume\_role\_arn) | ARN of the IAM role to assume for ECS permissions | `string` | `""` | no |
| <a name="input_assume_role_session_name"></a> [assume\_role\_session\_name](#input\_assume\_role\_session\_name) | Session name to use when assuming the IAM role | `string` | `""` | no |
| <a name="input_desired_count"></a> [desired\_count](#input\_desired\_count) | n/a | `number` | n/a | yes |
| <a name="input_ecs_cluster"></a> [ecs\_cluster](#input\_ecs\_cluster) | n/a | `string` | n/a | yes |
| <a name="input_ecs_service"></a> [ecs\_service](#input\_ecs\_service) | n/a | `string` | n/a | yes |
| <a name="input_min_capacity"></a> [min\_capacity](#input\_min\_capacity) | n/a | `number` | n/a | yes |
| <a name="input_security_groups"></a> [security\_groups](#input\_security\_groups) | n/a | `list(string)` | n/a | yes |
| <a name="input_subnets"></a> [subnets](#input\_subnets) | n/a | `list(string)` | n/a | yes |
| <a name="input_task_definition"></a> [task\_definition](#input\_task\_definition) | n/a | `string` | n/a | yes |
| <a name="input_task_definition_revision"></a> [task\_definition\_revision](#input\_task\_definition\_revision) | n/a | `number` | n/a | yes |
| <a name="input_vuln_service"></a> [vuln\_service](#input\_vuln\_service) | n/a | `string` | `""` | no |

## Outputs

No outputs.
