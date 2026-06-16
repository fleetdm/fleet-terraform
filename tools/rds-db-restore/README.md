# Fleet database restore on AWS

`db-restore.sh` automates the restoration of a Fleet-managed Aurora database cluster using Terraform and AWS RDS APIs. It supports point-in-time recovery (PITR), RDS snapshot restoration, dry-runs, ECS scale-down handling, optional Fleet image rollback, RDS master username updates, and delayed cleanup of old DB resources.

This script is designed for self-hosted Fleet deployments provisioned via `fleet-terraform`.

> **Note:** Fleet built and tested `db-restore.sh` against the [`fleet-terraform/example`](https://github.com/fleetdm/fleet-terraform/tree/main/example) (Standard) deployment layout. If your Fleet deployment is not based on `fleet-terraform/example`, contact Fleet customer support before running this script.

## Prerequisites

- `terraform`, `aws` CLI, `jq`, `perl`, and `python3` on your `PATH`
- AWS credentials configured with permissions to manage RDS, ECS, IAM, Secrets Manager, and EC2 security groups in the target region
- The target `fleet-terraform` environment directory checked out locally

## Quick start

The script does not need to live in your environment directory, but you should run it from there. It defaults to `$PWD` for Terraform state and config. `cd` into your environment directory before running it, whether the script lives inside that directory or somewhere else on disk.

Every restore command needs exactly one restore source. Use `--restore-time <iso-8601>` for point-in-time recovery (PITR), or `--restore-snapshot <id|arn>` to restore from an RDS DB cluster snapshot. Each step below shows both forms.

1. **Run from inside the environment directory:**
   ```bash
   cd fleet-terraform/example
   AWS_PROFILE=<profile> /path/to/db-restore.sh --list
   ```
2. **Dry-run the restore:**

   PITR:
   ```bash
   AWS_PROFILE=<profile> /path/to/db-restore.sh \
     --restore-time 2026-05-05T11:00:00Z \
     --dry-run
   ```
   Snapshot:
   ```bash
   AWS_PROFILE=<profile> /path/to/db-restore.sh \
     --restore-snapshot arn:aws:rds:us-east-2:123456789012:cluster-snapshot:fleet-prod-manual-2026-04-06 \
     --dry-run
   ```
3. **Execute the restore:**

   PITR:
   ```bash
   AWS_PROFILE=<profile> /path/to/db-restore.sh \
     --restore-time 2026-05-05T11:00:00Z \
     --confirm
   ```
   Snapshot:
   ```bash
   AWS_PROFILE=<profile> /path/to/db-restore.sh \
     --restore-snapshot arn:aws:rds:us-east-2:123456789012:cluster-snapshot:fleet-prod-manual-2026-04-06 \
     --confirm
   ```

## Supported Terraform layouts

The script works with `fleet-terraform` layouts by auto-detecting the parent module address from Terraform state. It searches for `module.rds.aws_rds_cluster.this` and uses the path preceding it as the base.

| Layout | Environment Directory | Auto-detected `MODULE_ADDRESS` |
|---|---|---|
| Standard | `fleet-terraform/example` | `module.fleet.module.byo-vpc` |
| BYO-VPC *(not verified; contact Fleet customer support before use)* | `fleet-terraform/byo-vpc/example` | `module.byo-vpc.module.byo-db` |

## Execution path

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

## Configuration & flags

| Flag | Required | Description |
|---|---|---|
| `--cleanup-only` | No | Cleanup mode. Requires `--manifest` pointing to the `manifest.json` written under `.db-restore-<timestamp>/` by a previous run. Deletes old DB resources from that restore. |
| `--cleanup-old-resources` | No | Delete old DB resources immediately after restore. Default keeps them for safe later cleanup. |
| `--confirm` | No | Skips the interactive typed confirmation prompt. Without it, you will be prompted to type the environment name. |
| `--config-file <path>` | No | Terraform file containing `rds_config`. Default: `<env-dir>/main.tf`. |
| `--destination-name <name>` | No | Override restored DB name. Default increments from current cluster name. |
| `--dry-run` | No | Print the execution path and planned mutations. Creates a manifest without applying changes. |
| `--env-dir <path>` | No | Root directory containing the environment. Default: `$PWD`. |
| `--fleet-image <uri-or-tag>` | No | Specifies the Fleet image version when using `--rollback`. |
| `--help` | No | Show help text. |
| `--master-username <name>` | No | Set `rds_config.master_username`. Adds if absent, updates if present. Requires fleet-terraform root module tag >= `tf-mod-root-v1.28.0` or byo-vpc tag >= `tf-mod-byo-vpc-v1.29.0`. |
| `--manifest <path>` | Yes (with `--cleanup-only`) | Path to the `manifest.json` JSON file produced by a prior restore (written under `.db-restore-<timestamp>/`). Accepts an absolute or relative path; absolute is convenient when invoking the script from outside the environment directory. Used by `--cleanup-only`. |
| `--module-address <addr>` | No | Terraform address of the parent module. Auto-detected when possible. |
| `--no-ecs-apply` | No | Do not apply ECS targets or scale services back up. Services remain at `0` for manual validation. |
| `--old-final-snapshot-id <id>` | No | Final snapshot ID for old cluster deletion. Auto-generated if omitted, in the form `<current-cluster>-pre-restore-retirement-<timestamp>`. |
| `--region <region>` | No | AWS region. Default: `AWS_REGION` / `AWS_DEFAULT_REGION` / `us-east-2`. |
| `--restore-snapshot <id\|arn>` | No | Restore from an RDS DB cluster snapshot identifier or ARN. |
| `--restore-time <time>` | No | Restore to a point in time. Requires UTC ISO-8601 format (e.g. `2026-05-05T11:00:00Z`). |
| `--rollback` | No | Update `fleet_config.image` before ECS is applied. Requires `--fleet-image`. Supports literal values and `local.*` references whose definitions are literals in the same file. `var.*` expressions are rejected. |
| `--skip-migrations` | No | Do not run `module.migrations`. ECS can still be targeted and scaled back up. |
| `--skip-old-final-snapshot` | No | Delete old cluster without taking a final snapshot. |

## Usage examples

Every restore command needs exactly one **restore source** flag:

- `--restore-time <iso-8601>`: point-in-time recovery (PITR) within the cluster's PITR window. UTC ISO-8601 (e.g. `2026-05-05T11:00:00Z`).
- `--restore-snapshot <id|arn>`: restore from an RDS DB cluster snapshot identifier or its full ARN.

The two flags are mutually exclusive but interchangeable: every example below that uses `--restore-time` works the same way if you swap in `--restore-snapshot <id|arn>`, and vice versa. The remaining flags (`--no-ecs-apply`, `--rollback`, `--dry-run`, etc.) apply to both restore sources.

### List available restore points
```bash
cd fleet-terraform/example
AWS_PROFILE=<profile> /path/to/db-restore.sh --list
```

### Dry-run a restore
PITR:
```bash
AWS_PROFILE=<profile> /path/to/db-restore.sh \
  --restore-time 2026-05-05T11:00:00Z \
  --dry-run
```

Snapshot:
```bash
AWS_PROFILE=<profile> /path/to/db-restore.sh \
  --restore-snapshot arn:aws:rds:us-east-2:123456789012:cluster-snapshot:fleet-prod-manual-2026-04-06 \
  --dry-run
```

### Restore from a snapshot
`--restore-snapshot` accepts either a DB cluster snapshot identifier or its full ARN.

Using a snapshot identifier:
```bash
AWS_PROFILE=<profile> /path/to/db-restore.sh \
  --restore-snapshot fleet-prod-manual-2026-04-06 \
  --confirm
```

Using a snapshot ARN:
```bash
AWS_PROFILE=<profile> /path/to/db-restore.sh \
  --restore-snapshot arn:aws:rds:us-east-2:123456789012:cluster-snapshot:fleet-prod-manual-2026-04-06 \
  --confirm
```

### Restore without bringing ECS services back up
Useful for inspecting the database manually before reconnecting the application. Swap the restore source as needed.

PITR:
```bash
AWS_PROFILE=<profile> /path/to/db-restore.sh \
  --restore-time 2026-05-05T11:00:00Z \
  --no-ecs-apply \
  --confirm
```

Snapshot:
```bash
AWS_PROFILE=<profile> /path/to/db-restore.sh \
  --restore-snapshot arn:aws:rds:us-east-2:123456789012:cluster-snapshot:fleet-prod-manual-2026-04-06 \
  --no-ecs-apply \
  --confirm
```

### Restore with Fleet image rollback
Combines database recovery with rolling back the Fleet application image. Swap the restore source as needed.

PITR:
```bash
AWS_PROFILE=<profile> /path/to/db-restore.sh \
  --restore-time 2026-05-05T10:45:00Z \
  --rollback \
  --fleet-image v4.84.0 \
  --confirm
```

Snapshot:
```bash
AWS_PROFILE=<profile> /path/to/db-restore.sh \
  --restore-snapshot arn:aws:rds:us-east-2:123456789012:cluster-snapshot:fleet-prod-manual-2026-04-06 \
  --rollback \
  --fleet-image v4.84.0 \
  --confirm
```

**Manual alternative.** If your `fleet_config.image` source isn't expressible via the script's literal-or-`local.*` rules (e.g. it's a `var.*` reference), edit `fleet_config.image` in `main.tf` to the rollback target by hand, then run the restore without `--rollback`/`--fleet-image`. The restore picks up your manual edit.

### Clean up old resources after validation
```bash
AWS_PROFILE=<profile> /path/to/db-restore.sh \
  --cleanup-only \
  --manifest .db-restore-<timestamp>/manifest.json \
  --confirm
```

## Troubleshooting

**Rollback fails before any AWS calls**

`--rollback --fleet-image` requires `fleet_config.image` to already be present in `main.tf` and to resolve from a source the script can rewrite. The expected behavior:

| `fleet_config.image` state | `--rollback --fleet-image` outcome |
|---|---|
| Not defined in `main.tf` | Fails. Define `fleet_config.image` before retrying. |
| Set to `var.<name>` | Fails. `var.*` references are rejected. Use the manual alternative described in the "Restore with Fleet image rollback" section. |
| Set to `local.<name>` where the local is a literal in the same file | Succeeds. |
| Set to a literal string | Succeeds. |

**Auto-detect fails for module address**

Pass `--module-address` explicitly. For the `fleet-terraform/example` (Standard) layout the value is `module.fleet.module.byo-vpc`.

**Snapshot not found or fails to restore**

Run `--list` to verify the snapshot identifier or ARN. Snapshots must exist in the same AWS region and account as your environment.

**PITR timestamp outside restore window**

Run `--list` to see the valid PITR window. Choose a timestamp 5-10 minutes before the incident occurred.

**Timestamp format is invalid**

Use UTC ISO-8601 format. The script accepts `2026-05-05T11:00:00Z` or `2026-05-05T11:00:00.000Z`.

**Missing script options**

Run `/path/to/db-restore.sh --help` to print the full list of flags.
