# Fleet Database Restore on AWS

`db-restore.sh` automates the restoration of a Fleet-managed Aurora database cluster using Terraform and AWS RDS APIs. It supports point-in-time recovery (PITR), RDS snapshot restoration, dry-runs, ECS scale-down handling, optional Fleet image rollback, and delayed cleanup of old DB resources.

This script is designed for self-hosted Fleet deployments provisioned via `fleet-terraform`.

## Prerequisites

- `terraform`, `aws` CLI, `jq`, `perl`, and `python3` on your `PATH`
- AWS credentials configured with permissions to manage RDS, ECS, IAM, Secrets Manager, and EC2 security groups in the target region
- The target `fleet-terraform` environment directory checked out locally

## Quick Start

1. **List available restore points:**
   ```bash
   AWS_PROFILE=<profile> ./db-restore.sh example --env-dir fleet-terraform/example --list
   ```
2. **Dry-run a point-in-time restore:**
   ```bash
   AWS_PROFILE=<profile> ./db-restore.sh example \
     --env-dir fleet-terraform/example \
     --restore-time 2026-05-05T11:00:00Z \
     --dry-run
   ```
3. **Execute the restore:**
   ```bash
   AWS_PROFILE=<profile> ./db-restore.sh example \
     --env-dir fleet-terraform/example \
     --restore-time 2026-05-05T11:00:00Z \
     --confirm
   ```

> These examples use the standard `fleet-terraform/example` layout. Update the environment name and `--env-dir` path to match your deployment.

## Supported Terraform Layouts

The script works with `fleet-terraform` layouts by auto-detecting the parent module address from Terraform state. It searches for `module.rds.aws_rds_cluster.this` and uses the path preceding it as the base.

| Layout | Environment Directory | Auto-detected `MODULE_ADDRESS` |
|---|---|---|
| Standard | `fleet-terraform/example` | `module.fleet.module.byo-vpc` |
| BYO-VPC | `fleet-terraform/byo-vpc/example` | `module.byo-vpc.module.byo-db` |

If auto-detection fails, pass `--module-address <path>` explicitly. The script expects child modules named `module.rds`, `module.secrets-manager-1`, and either `module.byo-ecs`, `byo-ecs`, or `module.byo-db.module.ecs` underneath the provided address.

## Execution Path

When running a standard restore with migrations enabled, the script performs the following steps:

1. Captures a full copy of Terraform state and resource metadata into `.db-restore-<timestamp>/`.
2. Ensures `fleet_image` is explicitly defined in `main.tf` (extracted from ECS state if missing).
3. Updates the `rds_config` block to point to the restored database.
4. Scales Fleet ECS services to `0` so no tasks connect during the restore.
5. Removes old RDS resources from Terraform state.
6. Creates a new Aurora cluster from the chosen restore point.
7. Restores the original `rds_config` and re-applies monitoring/observability settings.
8. Applies ECS services and runs database migrations (`module.migrations`).
9. Scales ECS services back up.
10. Keeps old DB resources intact for safe cleanup later.

## Configuration & Flags

| Flag | Required | Description |
|---|---|---|
| `--cleanup-old-resources` | No | Delete old DB resources immediately after restore. |
| `--confirm` | No | Skips the interactive typed confirmation prompt. Without it, you will be prompted to type the environment name. |
| `--config-file <path>` | No | Terraform file containing `rds_config`. Default: `<env-dir>/main.tf`. |
| `--destination-name <name>` | No | Override restored DB name. Default increments from current state name. |
| `--dry-run` | No | Print the execution path and planned mutations. Creates a manifest without applying changes. |
| `--env-dir <path>` | No | Root directory containing the environment. Default: parent of this script. |
| `--fleet-image <uri-or-tag>` | No | Specifies the Fleet image version when using `--rollback`. Updates the existing repo expression or replaces it. |
| `--manifest <path>` | Yes (with `--cleanup-only`) | Manifest file path for `--cleanup-only`. |
| `--module-address <addr>` | No | Terraform address of the parent module. Auto-detected when possible. |
| `--no-ecs-apply` | No | Do not apply ECS targets or scale services back up. Services remain at `0` for manual validation. |
| `--region <region>` | No | AWS region. Default: `AWS_REGION` / `AWS_DEFAULT_REGION` / `us-east-2`. |
| `--rollback` | No | Update `fleet_image` before ECS is applied. Requires `--fleet-image`. |
| `--skip-migrations` | No | Do not run `module.migrations`. ECS can still be targeted and scaled back up. |

## Testing Checklist

Before running a production restore:
1. Run `--list` and confirm the PITR window or snapshot exists.
2. Run the intended command with `--dry-run`.
3. Confirm the destination name is correct.
4. Confirm the restore mode is correct: `--restore-time` or `--restore-snapshot`.
5. Decide whether ECS should stay down (`--no-ecs-apply`).
6. Decide whether migrations should run or be skipped.
7. Decide whether Fleet image rollback is needed.
8. Keep old DB resources unless immediate cleanup is intentionally required.

## Usage Examples

### List available restore points
```bash
AWS_PROFILE=<profile> ./db-restore.sh example \
  --env-dir fleet-terraform/example \
  --list
```

### Dry-run a PITR restore
```bash
AWS_PROFILE=<profile> ./db-restore.sh example \
  --env-dir fleet-terraform/example \
  --restore-time 2026-05-05T11:00:00Z \
  --dry-run
```

### Restore from a snapshot
```bash
AWS_PROFILE=<profile> ./db-restore.sh example \
  --env-dir fleet-terraform/example \
  --restore-snapshot rds:<cluster>-2026-04-06-02-08 \
  --confirm
```

### Restore without bringing ECS services back up
Useful for inspecting the database manually before reconnecting the application.
```bash
AWS_PROFILE=<profile> ./db-restore.sh example \
  --env-dir fleet-terraform/example \
  --restore-time 2026-05-05T11:00:00Z \
  --no-ecs-apply \
  --confirm
```

### Restore with Fleet image rollback
Combines database recovery with rolling back the Fleet application image.
```bash
AWS_PROFILE=<profile> ./db-restore.sh example \
  --env-dir fleet-terraform/example \
  --restore-time 2026-05-05T10:45:00Z \
  --rollback \
  --fleet-image v4.84.0 \
  --confirm
```

### Clean up old resources after validation
```bash
AWS_PROFILE=<profile> ./db-restore.sh \
  --cleanup-only \
  --manifest fleet-terraform/example/.db-restore-<timestamp>/manifest.json \
  --confirm
```
