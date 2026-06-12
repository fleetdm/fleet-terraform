# Fleet Database Restore on AWS

`db-restore.sh` automates the restoration of a Fleet-managed Aurora database cluster using Terraform and AWS RDS APIs. It supports point-in-time recovery (PITR), RDS snapshot restoration, dry-runs, ECS scale-down handling, optional Fleet image rollback, RDS master username updates, and delayed cleanup of old DB resources.

This script is designed for self-hosted Fleet deployments provisioned via `fleet-terraform`.

## Prerequisites

- `terraform`, `aws` CLI, `jq`, `perl`, and `python3` on your `PATH`
- AWS credentials configured with permissions to manage RDS, ECS, IAM, Secrets Manager, and EC2 security groups in the target region
- The target `fleet-terraform` environment directory checked out locally

## Quick Start

The script does not need to live in your environment directory. It defaults to `$PWD` for Terraform state and config, so just `cd` into your environment directory and run the script from there. Alternatively, use `--env-dir` to point at the environment directory from anywhere.

1. **Run from inside the environment directory:**
   ```bash
   cd fleet-terraform/example
   AWS_PROFILE=<profile> /path/to/db-restore.sh --list
   ```
   Or use `--env-dir` to target it from anywhere:
   ```bash
   AWS_PROFILE=<profile> /path/to/db-restore.sh --list \
     --env-dir /path/to/fleet-terraform/example
   ```
2. **Dry-run a point-in-time restore:**
   ```bash
   AWS_PROFILE=<profile> /path/to/db-restore.sh \
     --restore-time 2026-05-05T11:00:00Z \
     --dry-run
   ```
3. **Execute the restore:**
   ```bash
   AWS_PROFILE=<profile> /path/to/db-restore.sh \
     --restore-time 2026-05-05T11:00:00Z \
     --confirm
   ```

## Supported Terraform Layouts

The script works with `fleet-terraform` layouts by auto-detecting the parent module address from Terraform state. It searches for `module.rds.aws_rds_cluster.this` and uses the path preceding it as the base.

| Layout | Environment Directory | Auto-detected `MODULE_ADDRESS` |
|---|---|---|
| Standard | `fleet-terraform/example` | `module.fleet.module.byo-vpc` |
| BYO-VPC | `fleet-terraform/byo-vpc/example` | `module.byo-vpc.module.byo-db` |

If auto-detection fails, pass `--module-address <path>` explicitly (e.g. `--module-address module.fleet.module.byo-vpc`). Underneath the provided address, the script expects the following child modules:

- `<MODULE_ADDRESS>.module.rds` — Aurora cluster and instances
- `<MODULE_ADDRESS>.module.secrets-manager-1` — database password secret
- `<MODULE_ADDRESS>.module.byo-ecs` or `<MODULE_ADDRESS>.module.byo-db.module.ecs` — ECS service and task definitions

## Execution Path

When running a standard restore with migrations enabled, the script performs the following steps:

1. Captures a full copy of Terraform state and resource metadata into `.db-restore-<timestamp>/`.
2. Optionally updates `fleet_config.image` if `--rollback` and `--fleet-image` are provided. Supports literal values and `local.*` references whose definitions are literals in the same file. `var.*` expressions are rejected.
3. Optionally adds/updates `rds_config.master_username` if `--master-username` is provided.
4. Updates the `rds_config` block to point to the restored database.
5. Scales Fleet ECS services to `0` so no tasks connect during the restore.
6. Removes old RDS resources from Terraform state.
7. Creates a new Aurora cluster from the chosen restore point.
8. Restores the original `rds_config` and re-applies monitoring/observability settings.
9. Applies ECS services and runs database migrations (`module.migrations`).
10. Scales ECS services back up.
11. Keeps old DB resources intact for safe cleanup later.

## Configuration & Flags

| Flag | Required | Description |
|---|---|---|
| `--cleanup-only` | No | Cleanup mode. Requires `--manifest`. Deletes old DB resources from a previous restore. |
| `--cleanup-old-resources` | No | Delete old DB resources immediately after restore. Default keeps them for safe later cleanup. |
| `--confirm` | No | Skips the interactive typed confirmation prompt. Without it, you will be prompted to type the environment name. |
| `--config-file <path>` | No | Terraform file containing `rds_config`. Default: `<env-dir>/main.tf`. |
| `--destination-name <name>` | No | Override restored DB name. Default increments from current cluster name. |
| `--dry-run` | No | Print the execution path and planned mutations. Creates a manifest without applying changes. |
| `--env-dir <path>` | No | Root directory containing the environment. Default: `$PWD`. |
| `--fleet-image <uri-or-tag>` | No | Specifies the Fleet image version when using `--rollback`. |
| `--help` | No | Show help text. |
| `--master-username <name>` | No | Set `rds_config.master_username`. Adds if absent, updates if present. Requires fleet-terraform root module tag >= `tf-mod-root-v1.28.0` or byo-vpc tag >= `tf-mod-byo-vpc-v1.29.0`. |
| `--manifest <path>` | Yes (with `--cleanup-only`) | Manifest file path for `--cleanup-only`. |
| `--module-address <addr>` | No | Terraform address of the parent module. Auto-detected when possible. |
| `--no-ecs-apply` | No | Do not apply ECS targets or scale services back up. Services remain at `0` for manual validation. |
| `--old-final-snapshot-id <id>` | No | Final snapshot ID for old cluster deletion. Auto-generated if omitted. |
| `--region <region>` | No | AWS region. Default: `AWS_REGION` / `AWS_DEFAULT_REGION` / `us-east-2`. |
| `--restore-snapshot <id\|arn>` | No | Restore from an RDS DB cluster snapshot identifier or ARN. |
| `--restore-time <time>` | No | Restore to a point in time. Requires UTC ISO-8601 format (e.g. `2026-05-05T11:00:00Z`). |
| `--rollback` | No | Update `fleet_config.image` before ECS is applied. Requires `--fleet-image`. Supports literal values and `local.*` references whose definitions are literals in the same file. `var.*` expressions are rejected. |
| `--skip-migrations` | No | Do not run `module.migrations`. ECS can still be targeted and scaled back up. |
| `--skip-old-final-snapshot` | No | Delete old cluster without taking a final snapshot. |

## Usage Examples

### List available restore points
```bash
cd fleet-terraform/example
AWS_PROFILE=<profile> ./db-restore.sh --list
```

### Dry-run a PITR restore
```bash
AWS_PROFILE=<profile> ./db-restore.sh \
  --restore-time 2026-05-05T11:00:00Z \
  --dry-run
```

### Restore from a snapshot
```bash
AWS_PROFILE=<profile> ./db-restore.sh \
  --restore-snapshot rds:<cluster>-2026-04-06-02-08 \
  --confirm
```

### Restore without bringing ECS services back up
Useful for inspecting the database manually before reconnecting the application.
```bash
AWS_PROFILE=<profile> ./db-restore.sh \
  --restore-time 2026-05-05T11:00:00Z \
  --no-ecs-apply \
  --confirm
```

### Restore with Fleet image rollback
Combines database recovery with rolling back the Fleet application image.
```bash
AWS_PROFILE=<profile> ./db-restore.sh \
  --restore-time 2026-05-05T10:45:00Z \
  --rollback \
  --fleet-image v4.84.0 \
  --confirm
```

### Restore with master username change
Sets `rds_config.master_username` before the restore begins.
```bash
AWS_PROFILE=<profile> ./db-restore.sh \
  --restore-time 2026-05-05T11:00:00Z \
  --master-username fleetadmin \
  --confirm
```

### Clean up old resources after validation
```bash
AWS_PROFILE=<profile> ./db-restore.sh \
  --cleanup-only \
  --manifest .db-restore-<timestamp>/manifest.json \
  --confirm
```


