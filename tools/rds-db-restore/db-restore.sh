#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_BASE_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  db-restore.sh --list [options]
  db-restore.sh --restore-time <UTC-ISO-time> [options]
  db-restore.sh --restore-snapshot <snapshot-id-or-arn> [options]
  db-restore.sh --cleanup-only --manifest <path> [options]

Restore a Terraform-managed Fleet Aurora database by replacing the RDS resources
in Terraform state and pointing rds_config at a new restored cluster.

Modes:
  --list                         List same-region restore choices. PITR and
                                 RDS automated/manual cluster snapshots are
                                 targetable by this script. AWS Backup recovery
                                 points are shown as inventory-only because
                                 they require AWS Backup restore adoption.
  --restore-time <UTC-ISO-time>  Restore to a point in time. The timestamp must
                                 be UTC ISO-8601, for example:
                                   2026-05-05T15:30:00Z
                                   2026-05-05T15:30:00.000Z
  --restore-snapshot <id|arn>    Restore from an RDS DB cluster snapshot
                                 identifier or ARN. AWS Backup recovery point
                                 ARNs are detected and rejected with a clear
                                 explanation because they require AWS Backup
                                 StartRestoreJob, not Terraform's
                                 snapshot_identifier flow.
  --cleanup-only                 Only delete old resources from --manifest.

Options:
  --region <region>              AWS region. Default: AWS_REGION /
                                 AWS_DEFAULT_REGION / us-east-2.
  --env-dir <path>               Root directory containing the environment.
                                    Default: $PWD. Use when running from
                                    outside the environment directory.
  --module-address <addr>        Terraform address of the byo-db module.
                                  Auto-detected from state when possible.
  --config-file <path>           Terraform file containing inline rds_config.
                                 Default: <customer-env>/main.tf.
  --destination-name <name>      Override restored DB name. Default increments
                                 <customer>, <customer>-1, <customer>-2, ...
 --fleet-image <image-or-tag>   Required with --rollback. For template-style
                                  local.fleet_image, a tag like v4.84.0 updates
                                  the existing repo expression; a full image URI
                                  replaces the whole value.
  --master-username <name>       Set rds_config.master_username to the provided
                                  value. Adds it if absent, updates if present.
                                  Omit to leave the config unchanged.
  --rollback                     Update local.fleet_image before ECS is applied.
                                 Requires --fleet-image.
  --skip-migrations              Do not run module.migrations. ECS can still be
                                 targeted/applied and scaled back up.
  --no-ecs-apply                 Do not apply ECS task/service updates and do
                                 not scale services back up. Services remain at
                                 desired count 0 for manual validation.
  --cleanup-old-resources        Delete old DB resources after restore. Default
                                 is to keep old DB resources and write a
                                 manifest for later cleanup.
  --old-final-snapshot-id <id>   Final snapshot id for old cluster deletion.
  --skip-old-final-snapshot      Delete old cluster without final snapshot.
  --dry-run                      Print the execution path and planned mutations.
  --confirm                      Required for non-dry-run restore and cleanup.
                                 Without it, an interactive confirmation prompt
                                 is shown.
  --manifest <path>              Manifest for --cleanup-only.
  --help                         Show this help text.

Timestamp recommendations:
* For an operator mistake, pick a UTC timestamp just before the mistake, with a
  small safety buffer such as 5-10 minutes.
* For a failed deployment rollback, pick a timestamp before the first new app
  task reached healthy/running, then use --rollback --fleet-image <known-good>.

Execution summary:
* The script always captures state and metadata under .db-restore-<timestamp>/.
* Restore defaults to keeping old DB resources.
* Fleet and vuln-processing ECS services are scaled to 0 before restore.
* Database restore is applied with RDS/secret/parameter-group targets only.
  The initial restore temporarily disables restore-incompatible Performance
  Insights, Database Insights, and Enhanced Monitoring settings, then a second
  RDS-only reconcile re-applies the original config against the restored DB.
* ECS task/service updates and migrations happen only after DB restore unless
  --no-ecs-apply or --skip-migrations changes that path.
EOF
}

log() {
  printf '[db-restore] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sanitize_identifier() {
  local value="$1"
  local max_length="${2:-63}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  [[ -n "$value" ]] || value="fleet"
  value="${value:0:$max_length}"
  value="$(printf '%s' "$value" | sed -E 's/-+$//')"
  if [[ ! "$value" =~ ^[a-z] ]]; then
    value="f${value}"
    value="${value:0:$max_length}"
    value="$(printf '%s' "$value" | sed -E 's/-+$//')"
  fi
  printf '%s\n' "$value"
}

append_array_value() {
  local array_name="$1"
  local value="$2"
  local quoted_value=""
  printf -v quoted_value '%q' "$value"
  eval "$array_name+=( $quoted_value )"
}

array_from_newline_text() {
  local array_name="$1"
  local text="$2"
  local line=""

  eval "$array_name=()"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    append_array_value "$array_name" "$line"
  done <<EOF
$text
EOF
}

json_array_from_lines() {
  jq -Rsc 'split("\n") | map(select(length > 0))'
}

terraform_cmd() {
  terraform -chdir="$TERRAFORM_DIR" "$@"
}

aws_cmd() {
  aws --region "$AWS_REGION_ARG" "$@"
}

print_shell_command() {
  local first=1
  local arg=""
  for arg in "$@"; do
    if [[ "$first" -eq 1 ]]; then
      printf '%q' "$arg"
      first=0
    else
      printf ' %q' "$arg"
    fi
  done
  printf '\n'
}

confirm_or_die() {
  local action="$1"
  local reply=""
  [[ "$DRY_RUN" == "true" ]] && return 0
  [[ "$CONFIRM" == "true" ]] && return 0
  [[ -r /dev/tty ]] || die "non-dry-run ${action} requires --confirm when no interactive terminal is available"

  printf '[db-restore] About to %s for %s in %s.\n' "$action" "${ENV_NAME:-cleanup-only}" "$AWS_REGION_ARG" >/dev/tty
  printf '[db-restore] Type the environment name to continue: ' >/dev/tty
  read -r reply </dev/tty
  [[ "$reply" == "${ENV_NAME:-cleanup-only}" ]] || die "confirmation did not match"
}

is_utc_iso() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]
}

epoch_from_utc_iso() {
  python3 - "$1" <<'PY'
import datetime
import sys

value = sys.argv[1]
if value.endswith("Z"):
    value = value[:-1] + "+00:00"
try:
    parsed = datetime.datetime.fromisoformat(value)
except ValueError:
    sys.exit(1)
if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=datetime.timezone.utc)
print(int(parsed.timestamp()))
PY
}

# shellcheck disable=SC2016
state_resources_query='
  def instance_address($resource; $instance):
    (($resource.module // "") + (if ($resource.module // "") != "" then "." else "" end)) +
    (if $resource.mode == "data" then "data." else "" end) +
    $resource.type + "." + $resource.name +
    (
      if ($instance.index_key? == null) then ""
      elif (($instance.index_key | type) == "number") then "[\($instance.index_key)]"
      else "[\($instance.index_key | tojson)]"
      end
    );

  [
    .resources[]
    | . as $resource
    | .instances[]?
    | {
        address: instance_address($resource; .),
        module: ($resource.module // ""),
        mode: $resource.mode,
        type: $resource.type,
        name: $resource.name,
        index_key: (.index_key // null),
        values: ((.attributes // {}) + (.attributes_flat // {}))
      }
  ]
'

load_state_snapshot() {
  STATE_JSON_FILE="$ARTIFACT_DIR/terraform-state.json"
  STATE_RESOURCES_FILE="$ARTIFACT_DIR/terraform-state-resources.json"
  terraform_cmd state pull >"$STATE_JSON_FILE"
  jq "$state_resources_query" "$STATE_JSON_FILE" >"$STATE_RESOURCES_FILE"
}

state_value() {
  local address="$1"
  local jq_filter="$2"
  jq -r --arg addr "$address" ".[] | select(.address == \$addr) | ${jq_filter}" "$STATE_RESOURCES_FILE" | sed '/^null$/d' | head -1
}

auto_detect_module_address() {
  local matches_text=""
  local matches=()

  matches_text="$(terraform_cmd state list | grep -E '\.module\.rds\.aws_rds_cluster\.this(\[0\])?$' | sed -E 's/\.module\.rds\.aws_rds_cluster\.this(\[0\])?$//' || true)"
  array_from_newline_text matches "$matches_text"
  if [[ "${#matches[@]}" -eq 0 ]]; then
    die "could not auto-detect the byo-vpc module address from Terraform state; pass --module-address"
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    die "multiple byo-vpc module addresses found: $(printf '%s ' "${matches[@]}"); pass --module-address"
  fi
  MODULE_ADDRESS="${matches[0]}"
}

collect_state_addresses_for_removal() {
  local escaped_addr=""
  local pattern=""
  local matches_text=""
  escaped_addr="$(printf '%s' "$MODULE_ADDRESS" | sed 's/\./\\./g')"
  pattern="^${escaped_addr}\\.(module\\.rds\\.|module\\.secrets-manager-1\\.|random_id\\.rds_final_snapshot_identifier|aws_db_parameter_group\\.|aws_rds_cluster_parameter_group\\.)"
  matches_text="$(terraform_cmd state list | grep -E "$pattern" | sort || true)"
  array_from_newline_text STATE_REMOVE_ADDRESSES "$matches_text"
  if [[ "${#STATE_REMOVE_ADDRESSES[@]}" -eq 0 ]]; then
    die "did not find RDS-related Terraform addresses to remove under ${MODULE_ADDRESS}"
  fi
  STATE_REMOVE_ADDRESSES_JSON="$(printf '%s\n' "${STATE_REMOVE_ADDRESSES[@]}" | json_array_from_lines)"
}

collect_old_resource_metadata() {
  array_from_newline_text OLD_INSTANCE_IDENTIFIERS "$(jq -r --arg prefix "${MODULE_ADDRESS}.module.rds.aws_rds_cluster_instance." '
    .[] | select(.address | startswith($prefix)) | .values.identifier // empty
  ' "$STATE_RESOURCES_FILE")"
  OLD_INSTANCE_IDENTIFIERS_JSON="$(printf '%s\n' "${OLD_INSTANCE_IDENTIFIERS[@]:-}" | json_array_from_lines)"

  array_from_newline_text OLD_SECURITY_GROUP_IDS "$(jq -r --arg prefix "${MODULE_ADDRESS}.module.rds.aws_security_group." '
    .[] | select(.address | startswith($prefix)) | .values.id // empty
  ' "$STATE_RESOURCES_FILE")"
  OLD_SECURITY_GROUP_IDS_JSON="$(printf '%s\n' "${OLD_SECURITY_GROUP_IDS[@]:-}" | json_array_from_lines)"

  OLD_SECRETS_JSON="$(jq -c --arg prefix "${MODULE_ADDRESS}.module.secrets-manager-1." '
    [
      .[]
      | select(.address | startswith($prefix))
      | select(.type == "aws_secretsmanager_secret")
      | {name: .values.name, arn: .values.arn}
    ]
  ' "$STATE_RESOURCES_FILE")"
  array_from_newline_text OLD_SECRET_IDS "$(jq -r '.[] | .arn // .name // empty' <<<"$OLD_SECRETS_JSON")"

  OLD_MONITORING_ROLES_JSON="$(jq -c --arg role_prefix "${MODULE_ADDRESS}.module.rds.aws_iam_role.rds_enhanced_monitoring" --arg attachment_prefix "${MODULE_ADDRESS}.module.rds.aws_iam_role_policy_attachment.rds_enhanced_monitoring" '
    . as $all
    | [
        $all[] as $resource
        | select($resource.address | startswith($role_prefix))
        | {
            name: $resource.values.name,
            attached_policy_arns: [
              $all[]
              | select(.address | startswith($attachment_prefix))
              | select(.values.role == $resource.values.name)
              | .values.policy_arn
            ]
          }
      ]
  ' "$STATE_RESOURCES_FILE")"

  OLD_PARAMETER_GROUPS_JSON="$(jq -c --arg rds_prefix "${MODULE_ADDRESS}.module.rds." --arg top_db "${MODULE_ADDRESS}.aws_db_parameter_group.main" --arg top_cluster "${MODULE_ADDRESS}.aws_rds_cluster_parameter_group.main" '
    {
      db_parameter_groups: [
        .[]
        | select(.type == "aws_db_parameter_group")
        | select(.address | startswith($rds_prefix) or startswith($top_db))
        | .values.name
      ],
      db_cluster_parameter_groups: [
        .[]
        | select(.type == "aws_rds_cluster_parameter_group")
        | select(.address | startswith($rds_prefix) or startswith($top_cluster))
        | .values.name
      ]
    }
  ' "$STATE_RESOURCES_FILE")"
  array_from_newline_text OLD_DB_PARAMETER_GROUP_NAMES "$(jq -r '.db_parameter_groups[]?' <<<"$OLD_PARAMETER_GROUPS_JSON")"
  array_from_newline_text OLD_DB_CLUSTER_PARAMETER_GROUP_NAMES "$(jq -r '.db_cluster_parameter_groups[]?' <<<"$OLD_PARAMETER_GROUPS_JSON")"

  OLD_DB_SUBNET_GROUPS_JSON="$(jq -c --arg prefix "${MODULE_ADDRESS}.module.rds.aws_db_subnet_group." '
    [.[] | select(.address | startswith($prefix)) | .values.name]
  ' "$STATE_RESOURCES_FILE")"
  array_from_newline_text OLD_DB_SUBNET_GROUP_NAMES "$(jq -r '.[]?' <<<"$OLD_DB_SUBNET_GROUPS_JSON")"
}

collect_ecs_metadata() {
 local ecs_prefix=""

  for ecs_prefix in "${MODULE_ADDRESS}.module.byo-ecs." "${MODULE_ADDRESS}.byo-ecs." "${MODULE_ADDRESS}.module.byo-db.module.ecs."; do
    FLEET_ECS_JSON="$(jq -c --arg prefix "$ecs_prefix" '
      [
        .[]
        | select(.address | startswith($prefix))
        | select(.type == "aws_ecs_service")
        | select((.values.name // .values.service_name // "") | test("vuln-processing") | not)
        | {
            address: .address,
            module: .module,
            cluster: .values.cluster,
            name: (.values.name // .values.service_name),
            desired_count: (.values.desired_count // 1)
          }
      ] | first // {}
    ' "$STATE_RESOURCES_FILE")"
    if [[ "$FLEET_ECS_JSON" != "{}" && "$FLEET_ECS_JSON" != "null" ]]; then
      break
    fi
  done

  if [[ "$FLEET_ECS_JSON" == "{}" || "$FLEET_ECS_JSON" == "null" ]]; then
    die "could not find Fleet ECS service in Terraform state under ${MODULE_ADDRESS}"
  fi

  FLEET_ECS_MODULE="$(jq -r '.module // empty' <<<"$FLEET_ECS_JSON")"
  [[ -n "$FLEET_ECS_MODULE" ]] || die "Fleet ECS service state entry is missing module path"

  array_from_newline_text FLEET_ECS_TARGET_ADDRESSES "$(jq -r --arg prefix "${FLEET_ECS_MODULE}." '
    .[]
    | select(.address | startswith($prefix))
    | select(.type == "aws_ecs_task_definition" or .type == "aws_ecs_service" or .type == "aws_appautoscaling_target")
    | .address
  ' "$STATE_RESOURCES_FILE")"

  FLEET_ECS_CLUSTER="$(jq -r '.cluster' <<<"$FLEET_ECS_JSON")"
  FLEET_ECS_SERVICE="$(jq -r '.name' <<<"$FLEET_ECS_JSON")"
  FLEET_ECS_DESIRED_COUNT="$(jq -r '.desired_count' <<<"$FLEET_ECS_JSON")"
  FLEET_ECS_MIN_CAPACITY="$(jq -r --arg prefix "${FLEET_ECS_MODULE}." '
    [
      .[]
      | select(.address | startswith($prefix))
      | select(.type == "aws_appautoscaling_target")
      | .values.min_capacity
    ] | first // 1
  ' "$STATE_RESOURCES_FILE")"

  VULN_ECS_JSON="$(jq -c '
    [
      .[]
      | select(.type == "aws_ecs_service")
      | select((.module // "") | contains("vuln-processing"))
      | {
          address: .address,
          cluster: .values.cluster,
          name: (.values.name // .values.service_name),
          desired_count: (.values.desired_count // 1)
        }
    ] | first // {}
  ' "$STATE_RESOURCES_FILE")"
  if [[ "$VULN_ECS_JSON" == "{}" || "$VULN_ECS_JSON" == "null" ]]; then
    log "vuln processing doesn't exist, skipping"
    VULN_ECS_JSON="{}"
  fi
}

copy_file() {
  cp "$1" "$2"
}

update_config_file() {
  local file="$1"
  local edit_phase="$2"
  CONFIG_EDIT_RESTORED_NAME="$RESTORED_NAME" \
  CONFIG_EDIT_PHASE="$edit_phase" \
  CONFIG_EDIT_RESTORE_MODE="$RESTORE_MODE" \
  CONFIG_EDIT_RESTORE_TIME="${RESTORE_TIME:-}" \
  CONFIG_EDIT_SOURCE_CLUSTER="$CURRENT_CLUSTER_IDENTIFIER" \
  CONFIG_EDIT_SNAPSHOT_ID="${RESTORE_SNAPSHOT:-}" \
  perl -i -0pe '
use strict;
use warnings;

my $restored_name = $ENV{CONFIG_EDIT_RESTORED_NAME} // "";
my $edit_phase = $ENV{CONFIG_EDIT_PHASE} // "";
my $restore_mode = $ENV{CONFIG_EDIT_RESTORE_MODE} // "";
my $restore_time = $ENV{CONFIG_EDIT_RESTORE_TIME} // "";
my $source_cluster = $ENV{CONFIG_EDIT_SOURCE_CLUSTER} // "";
my $snapshot_id = $ENV{CONFIG_EDIT_SNAPSHOT_ID} // "";

sub quote_hcl {
  my ($value) = @_;
  $value =~ s/\\/\\\\/g;
  $value =~ s/"/\\"/g;
  return qq("$value");
}

sub find_matching_brace {
  my ($text, $start_index) = @_;
  my $depth = 0;
  my $in_string = 0;
  my $in_line_comment = 0;
  my $in_block_comment = 0;
  my $escaped = 0;

  for (my $i = $start_index; $i < length($text); $i++) {
    my $char = substr($text, $i, 1);
    my $next = $i + 1 < length($text) ? substr($text, $i + 1, 1) : "";
    if ($in_line_comment) { if ($char eq "\n") { $in_line_comment = 0; } next; }
    if ($in_block_comment) { if ($char eq "*" && $next eq "/") { $in_block_comment = 0; $i++; } next; }
    if ($in_string) {
      if ($escaped) { $escaped = 0; next; }
      if ($char eq "\\") { $escaped = 1; next; }
      if ($char eq "\"") { $in_string = 0; }
      next;
    }
    if ($char eq "/" && $next eq "/") { $in_line_comment = 1; $i++; next; }
    if ($char eq "#") { $in_line_comment = 1; next; }
    if ($char eq "/" && $next eq "*") { $in_block_comment = 1; $i++; next; }
    if ($char eq "\"") { $in_string = 1; next; }
    if ($char eq "{") { $depth++; next; }
    if ($char eq "}") {
      $depth--;
      if ($depth == 0) { return $i; }
    }
  }
  die "failed to find matching closing brace\n";
}

sub find_rds_config_span {
  my ($text) = @_;
  my @positions;
  while ($text =~ /(^[ \t]*rds_config[ \t]*=[ \t]*\{)/mg) {
    push @positions, pos($text) - 1;
  }
  die "did not find an inline rds_config object\n" if @positions == 0;
  die "found multiple inline rds_config objects; pass --config-file for a file with one object\n" if @positions > 1;
  my $line_start = rindex($text, "\n", $positions[0]);
  $line_start = $line_start == -1 ? 0 : $line_start + 1;
  my $brace_index = index($text, "{", $positions[0]);
  my $end_index = find_matching_brace($text, $brace_index);
  return ($line_start, $end_index);
}

sub object_indent {
  my ($text) = @_;
  if ($text =~ /\{\n([ \t]+)\S/m) { return $1; }
  return "  ";
}

sub upsert_simple_attribute {
  my ($object_text, $key, $value_text) = @_;
  if ($object_text =~ /^([ \t]*)\Q$key\E[ \t]*=.*$/m) {
    $object_text =~ s/^([ \t]*)\Q$key\E[ \t]*=.*$/$1$key = $value_text/m;
    return $object_text;
  }
  my $indent = object_indent($object_text);
  $object_text =~ s/\n([ \t]*)\}$/\n$indent$key = $value_text\n$1}/s;
  return $object_text;
}

sub remove_attribute_or_block {
  my ($object_text, $key) = @_;
  if ($object_text =~ /^([ \t]*)\Q$key\E[ \t]*=[ \t]*\{/m) {
    my $start = $-[0];
    my $brace = index($object_text, "{", $start);
    my $end = find_matching_brace($object_text, $brace);
    substr($object_text, $start, $end - $start + 1, "");
    $object_text =~ s/\n{3,}/\n\n/s;
    return $object_text;
  }
  $object_text =~ s/^[ \t]*\Q$key\E[ \t]*=.*\n?//mg;
  return $object_text;
}

sub upsert_restore_to_point_in_time {
  my ($object_text, $source_cluster, $restore_time) = @_;
  my $indent = object_indent($object_text);
  my $nested = $indent . "  ";
  my $replacement = "${indent}restore_to_point_in_time = {\n";
  $replacement .= "${nested}source_cluster_identifier = " . quote_hcl($source_cluster) . "\n";
  $replacement .= "${nested}restore_to_time           = " . quote_hcl($restore_time) . "\n";
  $replacement .= "${nested}restore_type              = " . quote_hcl("full-copy") . "\n";
  $replacement .= "${indent}}";
  $object_text = remove_attribute_or_block($object_text, "restore_to_point_in_time");
  $object_text =~ s/\n([ \t]*)\}$/\n$replacement\n$1}/s;
  return $object_text;
}

sub disable_observability_for_restore {
  my ($object_text) = @_;
  my $indent = object_indent($object_text);
  my $nested = $indent . "  ";
  my $replacement = "${indent}observability = {\n";
  $replacement .= "${nested}performance_insights_enabled = false\n";
  $replacement .= "${nested}database_insights_mode       = null\n";
  $replacement .= "${nested}kms = {\n";
  $replacement .= "${nested}  cmk_enabled = false\n";
  $replacement .= "${nested}}\n";
  $replacement .= "${indent}}";

  if ($object_text =~ /^([ \t]*)observability[ \t]*=[ \t]*\{/m) {
    my $start = $-[0];
    my $brace = index($object_text, "{", $start);
    my $end = find_matching_brace($object_text, $brace);
    substr($object_text, $start, $end - $start + 1, $replacement);
    return $object_text;
  }

  $object_text =~ s/\n([ \t]*)\}$/\n$replacement\n$1}/s;
  return $object_text;
}

die "restore edit requires restored name\n" if !length($restored_name);
die "restore edit phase must be initial or post-restore\n" if $edit_phase ne "initial" && $edit_phase ne "post-restore";
my ($start_index, $end_index) = find_rds_config_span($_);
my $object_text = substr($_, $start_index, $end_index - $start_index + 1);

$object_text = upsert_simple_attribute($object_text, "name", quote_hcl($restored_name));
if ($restore_mode eq "pitr") {
  die "PITR edit requires source cluster and restore time\n" if !length($source_cluster) || !length($restore_time);
  $object_text = remove_attribute_or_block($object_text, "snapshot_identifier");
  $object_text = upsert_restore_to_point_in_time($object_text, $source_cluster, $restore_time);
} elsif ($restore_mode eq "snapshot") {
  die "snapshot edit requires snapshot id/arn\n" if !length($snapshot_id);
  $object_text = remove_attribute_or_block($object_text, "restore_to_point_in_time");
  $object_text = upsert_simple_attribute($object_text, "snapshot_identifier", quote_hcl($snapshot_id));
} else {
  die "unexpected restore mode: $restore_mode\n";
}

if ($edit_phase eq "initial") {
  $object_text = upsert_simple_attribute($object_text, "monitoring_interval", "0");
  $object_text = disable_observability_for_restore($object_text);
}

substr($_, $start_index, $end_index - $start_index + 1, $object_text);
$_ =~ s/^([ \t]*mysql_password_secret_name[ \t]*=[ \t]*).*$/$1 . quote_hcl($restored_name . "-database-password")/mge;
  ' "$file"
}

update_fleet_image() {
  local file="$1"
  [[ "$ROLLBACK" == "true" ]] || return 0
  [[ -n "$FLEET_IMAGE" ]] || die "--rollback requires --fleet-image"
  FLEET_IMAGE_EDIT_VALUE="$FLEET_IMAGE" perl -i -0pe '
use strict;
use warnings;
my $value = $ENV{FLEET_IMAGE_EDIT_VALUE} // "";
die "--fleet-image value is empty\n" if !length($value);

sub quote_hcl {
  my ($v) = @_;
  $v =~ s/\\/\\\\/g;
  $v =~ s/"/\\"/g;
  return qq("$v");
}

my $matched = 0;

sub replace_fleet_image {
  my ($prefix, $rhs, $suffix) = @_;
  die "image uses a variable expression ($rhs); restore rollback requires a template-style literal repo/tag expression or full image URI\n"
    if $rhs =~ m{(var|local)\.};
  my $new_rhs;
  my $has_repo = ($value =~ m{[/:]}) || (substr($value, 0, 2) eq "\${");
  if ($has_repo) {
    $new_rhs = quote_hcl($value);
  } elsif ($rhs =~ m/^"(.+):[^:}"]+"$/) {
    $new_rhs = quote_hcl($1 . ":" . $value);
  } else {
    die "could not update image tag in $rhs; pass a full image URI to --fleet-image\n";
  }
  return $prefix . $new_rhs . ($suffix // "");
}

sub replace_fleet_config_image {
  my ($block_start, $image_prefix, $rhs, $suffix) = @_;
  $matched = 1;
  return $block_start . $image_prefix . replace_fleet_image("", $rhs, $suffix);
}

s/(fleet_config\s*=\s*\{.*?)(\s*image\s*=\s*)("[^"]*"|[^\n#]+)(.*)$/replace_fleet_config_image($1, $2, $3, $4)/sge;
if (!$matched) {
  warn "[db-restore] could not find image or fleet_config.image to update; skipping image rollback\n";
}
  ' "$file"
}

validate_pitr_window() {
  [[ "$RESTORE_MODE" == "pitr" ]] || return 0
  is_utc_iso "$RESTORE_TIME" || die "--restore-time must be UTC ISO-8601, for example 2026-05-05T15:30:00Z"

  local cluster_json=""
  local earliest=""
  local latest=""
  local target_epoch=""
  local earliest_epoch=""
  local latest_epoch=""
  cluster_json="$(aws_cmd rds describe-db-clusters --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" --output json)"
  printf '%s\n' "$cluster_json" >"$ARTIFACT_DIR/current-db-cluster.json"
  earliest="$(jq -r '.DBClusters[0].EarliestRestorableTime // empty' <<<"$cluster_json")"
  latest="$(jq -r '.DBClusters[0].LatestRestorableTime // empty' <<<"$cluster_json")"
  [[ -n "$earliest" && -n "$latest" ]] || die "could not determine PITR window from AWS for ${CURRENT_CLUSTER_IDENTIFIER}"

  target_epoch="$(epoch_from_utc_iso "$RESTORE_TIME")" || die "could not parse --restore-time: $RESTORE_TIME"
  earliest_epoch="$(epoch_from_utc_iso "$earliest")" || die "could not parse AWS EarliestRestorableTime: $earliest"
  latest_epoch="$(epoch_from_utc_iso "$latest")" || die "could not parse AWS LatestRestorableTime: $latest"

  if (( target_epoch < earliest_epoch || target_epoch > latest_epoch )); then
    die "--restore-time ${RESTORE_TIME} is outside PITR window ${earliest} to ${latest}"
  fi
}

detect_snapshot_source() {
  [[ "$RESTORE_MODE" == "snapshot" ]] || return 0
  if [[ "$RESTORE_SNAPSHOT" =~ ^arn:aws[^:]*:backup: ]]; then
    die "AWS Backup recovery point ARN was supplied to --restore-snapshot. AWS Backup Aurora restore requires StartRestoreJob and does not fit Terraform snapshot_identifier adoption safely yet. Use an RDS DB cluster snapshot identifier/ARN for this restore path."
  fi

  local snapshot_json=""
  local status=""
  snapshot_json="$(aws_cmd rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "$RESTORE_SNAPSHOT" --output json)"
  printf '%s\n' "$snapshot_json" >"$ARTIFACT_DIR/selected-db-cluster-snapshot.json"
  status="$(jq -r '.DBClusterSnapshots[0].Status // empty' <<<"$snapshot_json")"
  [[ "$status" == "available" ]] || die "snapshot ${RESTORE_SNAPSHOT} is not available; current status: ${status:-unknown}"
}

next_destination_name() {
  local base="$1"
  local config_name="$2"
  local highest=0
  local names_text=""
  local name=""
  local truebase="$base"

  # Strip all trailing -N suffixes to find the true base name
  while [[ "$truebase" =~ ^(.+)-([0-9]+)$ ]]; do
    truebase="${BASH_REMATCH[1]}"
  done

  names_text="$(printf '%s\n' "$config_name"; terraform_cmd state list 2>/dev/null | grep -E '\.module\.rds\.aws_rds_cluster\.this' | while read -r addr; do state_value "$addr" '.values.cluster_identifier // .values.id'; done || true)"
  names_text="$names_text"$'\n'"$(aws_cmd rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text 2>/dev/null | tr '\t' '\n' || true)"

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == "$truebase" ]]; then
      (( highest < 0 )) && highest=0
    elif [[ "$name" =~ ^${truebase}-([0-9]+)$ ]]; then
      local n="${BASH_REMATCH[1]}"
      (( n > highest )) && highest="$n"
    fi
  done <<<"$names_text"

  printf '%s\n' "$(sanitize_identifier "${truebase}-$((highest + 1))")"
}

ensure_destination_available() {
  if aws_cmd rds describe-db-clusters --db-cluster-identifier "$RESTORED_NAME" >/dev/null 2>&1; then
    die "destination DB cluster name already exists in AWS: ${RESTORED_NAME}; pass --destination-name"
  fi
}

list_restore_points() {
  local cluster_json=""
  local cluster_arn=""
  local earliest=""
  local latest=""
  local recommended=""
  local snapshots_json=""
  local snapshot_type=""
  local err_file=""
  cluster_json="$(aws_cmd rds describe-db-clusters --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" --output json)"
  cluster_arn="$(jq -r '.DBClusters[0].DBClusterArn' <<<"$cluster_json")"
  earliest="$(jq -r '.DBClusters[0].EarliestRestorableTime // empty' <<<"$cluster_json")"
  latest="$(jq -r '.DBClusters[0].LatestRestorableTime // empty' <<<"$cluster_json")"
  recommended="$(date -u -j -v-10M -f "%Y-%m-%dT%H:%M:%S.000Z" "$latest" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"

  printf 'Environment: %s\n' "$ENV_NAME"
  printf 'Region: %s\n' "$AWS_REGION_ARG"
  printf 'Current cluster: %s\n' "$CURRENT_CLUSTER_IDENTIFIER"
  printf '\nPITR window:\n'
  printf '  earliest: %s\n' "${earliest:-unknown}"
  printf '  latest:   %s\n' "${latest:-unknown}"
  [[ -n "$recommended" ]] && printf '  suggested restore-time: %s  (10 minutes before latest)\n' "$recommended"

  printf '\nRDS DB cluster snapshots:\n'
  for snapshot_type in automated manual; do
    err_file="$ARTIFACT_DIR/rds-${snapshot_type}-snapshots.err"
    if snapshots_json="$(aws_cmd rds describe-db-cluster-snapshots \
      --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" \
      --snapshot-type "$snapshot_type" \
      --output json 2>"$err_file")"; then
      printf '%s\n' "$snapshots_json" >"$ARTIFACT_DIR/rds-${snapshot_type}-snapshots.json"
      jq -r --arg snapshot_type "$snapshot_type" '.DBClusterSnapshots[]? | [.SnapshotCreateTime, $snapshot_type, .Status, .DBClusterSnapshotIdentifier, .DBClusterSnapshotArn] | @tsv' <<<"$snapshots_json"
    else
      log "warning: failed to list ${snapshot_type} RDS DB cluster snapshots for ${CURRENT_CLUSTER_IDENTIFIER}: $(tr '\n' ' ' <"$err_file")"
    fi
  done

  printf '\nAWS Backup recovery points (same region, inventory-only; not currently targetable by this script):\n'
  printf '  These require aws backup start-restore-job and post-restore Terraform adoption.\n'
  local vault=""
  while IFS= read -r vault; do
    [[ -n "$vault" ]] || continue
    aws_cmd backup list-recovery-points-by-backup-vault \
      --backup-vault-name "$vault" \
      --by-resource-arn "$cluster_arn" \
      --output json 2>/dev/null |
      jq -r --arg vault "$vault" '.RecoveryPoints[]? | [.CreationDate, "aws-backup-inventory-only", .Status, $vault, .RecoveryPointArn] | @tsv' || true
  done < <(aws_cmd backup list-backup-vaults --output json 2>/dev/null | jq -r '.BackupVaultList[]?.BackupVaultName' || true)
}

write_manifest() {
  jq -n \
    --arg env_name "$ENV_NAME" \
    --arg region "$AWS_REGION_ARG" \
    --arg terraform_dir "$TERRAFORM_DIR" \
    --arg config_file "$CONFIG_FILE" \
    --arg module_address "$MODULE_ADDRESS" \
    --arg current_cluster_identifier "$CURRENT_CLUSTER_IDENTIFIER" \
    --arg restored_name "$RESTORED_NAME" \
    --arg restore_mode "$RESTORE_MODE" \
    --arg restore_time "${RESTORE_TIME:-}" \
    --arg restore_snapshot "${RESTORE_SNAPSHOT:-}" \
    --arg old_final_snapshot_id "${OLD_FINAL_SNAPSHOT_ID:-}" \
    --argjson old_instance_identifiers "$OLD_INSTANCE_IDENTIFIERS_JSON" \
    --argjson old_security_group_ids "$OLD_SECURITY_GROUP_IDS_JSON" \
    --argjson old_secrets "$OLD_SECRETS_JSON" \
    --argjson old_monitoring_roles "$OLD_MONITORING_ROLES_JSON" \
    --argjson old_parameter_groups "$OLD_PARAMETER_GROUPS_JSON" \
    --argjson old_db_subnet_groups "$OLD_DB_SUBNET_GROUPS_JSON" \
    --argjson state_remove_addresses "$STATE_REMOVE_ADDRESSES_JSON" \
    --argjson fleet_ecs "$FLEET_ECS_JSON" \
    --argjson vuln_ecs "$VULN_ECS_JSON" \
    '{
      env_name: $env_name,
      region: $region,
      terraform_dir: $terraform_dir,
      config_file: $config_file,
      module_address: $module_address,
      current_cluster_identifier: $current_cluster_identifier,
      restored_name: $restored_name,
      restore_mode: $restore_mode,
      restore_time: ($restore_time | if length > 0 then . else null end),
      restore_snapshot: ($restore_snapshot | if length > 0 then . else null end),
      old_final_snapshot_id: ($old_final_snapshot_id | if length > 0 then . else null end),
      old_instance_identifiers: $old_instance_identifiers,
      old_security_group_ids: $old_security_group_ids,
      old_secrets: $old_secrets,
      old_monitoring_roles: $old_monitoring_roles,
      old_parameter_groups: $old_parameter_groups,
      old_db_subnet_groups: $old_db_subnet_groups,
      state_remove_addresses: $state_remove_addresses,
      fleet_ecs: $fleet_ecs,
      vuln_ecs: $vuln_ecs
    } | with_entries(select(.value != null))' >"$ARTIFACT_DIR/manifest.json"
}

terraform_restore_targets() {
  local targets=()
  local have_rds="false"
  local have_secrets="false"
  local address=""

  for address in "${STATE_REMOVE_ADDRESSES[@]}"; do
    case "$address" in
      "${MODULE_ADDRESS}.module.rds."*)
        if [[ "$have_rds" == "false" ]]; then
          targets+=("-target=${MODULE_ADDRESS}.module.rds")
          have_rds="true"
        fi
        ;;
      "${MODULE_ADDRESS}.module.secrets-manager-1."*)
        if [[ "$have_secrets" == "false" ]]; then
          targets+=("-target=${MODULE_ADDRESS}.module.secrets-manager-1")
          have_secrets="true"
        fi
        ;;
      *)
        targets+=("-target=${address}")
        ;;
    esac
  done

  [[ "${#targets[@]}" -gt 0 ]] || die "no restore targets were derived from Terraform state"
  terraform_cmd apply -auto-approve "${targets[@]}"
}

terraform_apply_ecs_targets() {
  local targets=()
  local address=""

  for address in "${FLEET_ECS_TARGET_ADDRESSES[@]}"; do
    targets+=("-target=${address}")
  done

  [[ "${#targets[@]}" -gt 0 ]] || die "no Fleet ECS apply targets were derived from Terraform state"
  terraform_cmd apply -auto-approve "${targets[@]}"
}

terraform_apply_migrations() {
  if terraform_cmd state list | grep -q '^module\.migrations\.'; then
    terraform_cmd apply -auto-approve -target=module.migrations
  elif grep -q 'module "migrations"' "$CONFIG_FILE"; then
    terraform_cmd apply -auto-approve -target=module.migrations
  else
    log "module.migrations doesn't exist, skipping"
  fi
}

scale_service() {
  local direction="$1"
  local cluster="$2"
  local service="$3"
  local desired="${4:-1}"
  local min_capacity="${5:-}"
  local adjust_autoscaling="${6:-false}"

  [[ -n "$cluster" && -n "$service" ]] || return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would scale ${service} ${direction}"
    return
  fi

  if [[ "$direction" == "up" ]]; then
    aws_cmd ecs update-service --cluster "$cluster" --service "$service" --desired-count "$desired" >/dev/null
    if [[ "$adjust_autoscaling" == "true" && -n "$min_capacity" ]]; then
      aws_cmd application-autoscaling register-scalable-target \
        --service-namespace ecs \
        --resource-id "service/${cluster}/${service}" \
        --scalable-dimension "ecs:service:DesiredCount" \
        --min-capacity "$min_capacity" >/dev/null
    fi
  else
    if [[ "$adjust_autoscaling" == "true" ]]; then
      aws_cmd application-autoscaling register-scalable-target \
        --service-namespace ecs \
        --resource-id "service/${cluster}/${service}" \
        --scalable-dimension "ecs:service:DesiredCount" \
        --min-capacity 0 >/dev/null
    fi
    aws_cmd ecs update-service --cluster "$cluster" --service "$service" --desired-count 0 >/dev/null
  fi
  aws_cmd ecs wait services-stable --cluster "$cluster" --services "$service" || true
}

scale_down_services() {
  log "scaling Fleet ECS service to 0"
  scale_service down "$FLEET_ECS_CLUSTER" "$FLEET_ECS_SERVICE" "$FLEET_ECS_DESIRED_COUNT" "$FLEET_ECS_MIN_CAPACITY" true
  if [[ "$VULN_ECS_JSON" != "{}" ]]; then
    log "scaling vuln-processing ECS service to 0"
    scale_service down "$(jq -r '.cluster' <<<"$VULN_ECS_JSON")" "$(jq -r '.name' <<<"$VULN_ECS_JSON")" "$(jq -r '.desired_count' <<<"$VULN_ECS_JSON")" "" false
  fi
}

scale_up_services() {
  log "scaling Fleet ECS service back to ${FLEET_ECS_DESIRED_COUNT}"
  scale_service up "$FLEET_ECS_CLUSTER" "$FLEET_ECS_SERVICE" "$FLEET_ECS_DESIRED_COUNT" "$FLEET_ECS_MIN_CAPACITY" true
  if [[ "$VULN_ECS_JSON" != "{}" ]]; then
    log "scaling vuln-processing ECS service back to $(jq -r '.desired_count' <<<"$VULN_ECS_JSON")"
    scale_service up "$(jq -r '.cluster' <<<"$VULN_ECS_JSON")" "$(jq -r '.name' <<<"$VULN_ECS_JSON")" "$(jq -r '.desired_count' <<<"$VULN_ECS_JSON")" "" false
  fi
}

remove_old_rds_state() {
  log "removing old RDS resources from Terraform state"
  terraform_cmd state rm "${STATE_REMOVE_ADDRESSES[@]}"
}

load_cleanup_manifest() {
  [[ -f "$MANIFEST_FILE" ]] || die "manifest file does not exist: $MANIFEST_FILE"
  ENV_NAME="$(jq -r '.env_name // "cleanup-only"' "$MANIFEST_FILE")"
  AWS_REGION_ARG="$(jq -r '.region // env.AWS_REGION // env.AWS_DEFAULT_REGION // "us-east-2"' "$MANIFEST_FILE")"
  CURRENT_CLUSTER_IDENTIFIER="$(jq -r '.current_cluster_identifier // empty' "$MANIFEST_FILE")"
  OLD_FINAL_SNAPSHOT_ID="$(jq -r '.old_final_snapshot_id // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_INSTANCE_IDENTIFIERS "$(jq -r '.old_instance_identifiers[]? // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_SECURITY_GROUP_IDS "$(jq -r '.old_security_group_ids[]? // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_SECRET_IDS "$(jq -r '.old_secrets[]? | .arn // .name // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_DB_PARAMETER_GROUP_NAMES "$(jq -r '.old_parameter_groups.db_parameter_groups[]? // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_DB_CLUSTER_PARAMETER_GROUP_NAMES "$(jq -r '.old_parameter_groups.db_cluster_parameter_groups[]? // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_DB_SUBNET_GROUP_NAMES "$(jq -r '.old_db_subnet_groups[]? // empty' "$MANIFEST_FILE")"
  OLD_MONITORING_ROLES_JSON="$(jq -c '.old_monitoring_roles // []' "$MANIFEST_FILE")"
}

aws_cleanup_cmd() {
  local display=""
  display="$(print_shell_command aws --region "$AWS_REGION_ARG" "$@")"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would run ${display}"
    return 0
  fi
  aws_cmd "$@"
}

delete_old_cluster_resources() {
  local instance_id=""
  local secret_id=""
  local role_name=""
  local policy_arn=""
  local group_name=""
  local sg_id=""

  for instance_id in "${OLD_INSTANCE_IDENTIFIERS[@]:-}"; do
    log "deleting old Aurora instance ${instance_id}"
    aws_cleanup_cmd rds delete-db-instance --db-instance-identifier "$instance_id" --skip-final-snapshot >/dev/null || true
  done
  for instance_id in "${OLD_INSTANCE_IDENTIFIERS[@]:-}"; do
    aws_cleanup_cmd rds wait db-instance-deleted --db-instance-identifier "$instance_id" || true
  done

  if [[ "$SKIP_OLD_FINAL_SNAPSHOT" == "true" ]]; then
    log "deleting old Aurora cluster ${CURRENT_CLUSTER_IDENTIFIER} without final snapshot"
    aws_cleanup_cmd rds delete-db-cluster --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" --skip-final-snapshot >/dev/null || true
  else
    [[ -n "$OLD_FINAL_SNAPSHOT_ID" ]] || die "old final snapshot id is required unless --skip-old-final-snapshot is set"
    log "deleting old Aurora cluster ${CURRENT_CLUSTER_IDENTIFIER} with final snapshot ${OLD_FINAL_SNAPSHOT_ID}"
    aws_cleanup_cmd rds delete-db-cluster --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" --final-db-snapshot-identifier "$OLD_FINAL_SNAPSHOT_ID" >/dev/null || true
  fi
  aws_cleanup_cmd rds wait db-cluster-deleted --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" || true

  for secret_id in "${OLD_SECRET_IDS[@]:-}"; do
    log "deleting old secret ${secret_id}"
    aws_cleanup_cmd secretsmanager delete-secret --secret-id "$secret_id" --force-delete-without-recovery >/dev/null || true
  done

  while IFS= read -r role_name; do
    [[ -n "$role_name" ]] || continue
    while IFS= read -r policy_arn; do
      [[ -n "$policy_arn" ]] || continue
      aws_cleanup_cmd iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" >/dev/null || true
    done < <(jq -r --arg role_name "$role_name" '.[] | select(.name == $role_name) | .attached_policy_arns[]?' <<<"$OLD_MONITORING_ROLES_JSON")
    aws_cleanup_cmd iam delete-role --role-name "$role_name" >/dev/null || true
  done < <(jq -r '.[].name // empty' <<<"$OLD_MONITORING_ROLES_JSON")

  for group_name in "${OLD_DB_PARAMETER_GROUP_NAMES[@]:-}"; do
    aws_cleanup_cmd rds delete-db-parameter-group --db-parameter-group-name "$group_name" >/dev/null || true
  done
  for group_name in "${OLD_DB_CLUSTER_PARAMETER_GROUP_NAMES[@]:-}"; do
    aws_cleanup_cmd rds delete-db-cluster-parameter-group --db-cluster-parameter-group-name "$group_name" >/dev/null || true
  done
  for group_name in "${OLD_DB_SUBNET_GROUP_NAMES[@]:-}"; do
    aws_cleanup_cmd rds delete-db-subnet-group --db-subnet-group-name "$group_name" >/dev/null || true
  done
  for sg_id in "${OLD_SECURITY_GROUP_IDS[@]:-}"; do
    aws_cleanup_cmd ec2 delete-security-group --group-id "$sg_id" >/dev/null || true
  done
}

ENV_NAME=""
ENV_DIR_ARG=""
MODE=""
RESTORE_MODE=""
RESTORE_TIME=""
RESTORE_SNAPSHOT=""
TERRAFORM_DIR=""
CONFIG_FILE=""
MODULE_ADDRESS=""
AWS_REGION_ARG="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
DESTINATION_NAME=""
RESTORED_NAME=""
ROLLBACK="false"
FLEET_IMAGE=""
MASTER_USERNAME=""
SKIP_MIGRATIONS="false"
NO_ECS_APPLY="false"
CLEANUP_OLD_RESOURCES="false"
MANIFEST_FILE=""
OLD_FINAL_SNAPSHOT_ID=""
SKIP_OLD_FINAL_SNAPSHOT="false"
DRY_RUN="false"
CONFIRM="false"

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      MODE="list"
      shift
      ;;
    --restore-time)
      MODE="restore"
      RESTORE_MODE="pitr"
      RESTORE_TIME="$2"
      shift 2
      ;;
    --restore-snapshot)
      MODE="restore"
      RESTORE_MODE="snapshot"
      RESTORE_SNAPSHOT="$2"
      shift 2
      ;;
    --cleanup-only)
      MODE="cleanup"
      shift
      ;;
    --manifest)
      MANIFEST_FILE="$2"
      shift 2
      ;;
    --region)
      AWS_REGION_ARG="$2"
      shift 2
      ;;
    --env-dir)
      ENV_DIR_ARG="$2"
      shift 2
      ;;
    --module-address)
      MODULE_ADDRESS="$2"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --destination-name)
      DESTINATION_NAME="$2"
      shift 2
      ;;
    --fleet-image)
      FLEET_IMAGE="$2"
      shift 2
      ;;
    --master-username)
      MASTER_USERNAME="$2"
      shift 2
      ;;
    --rollback)
      ROLLBACK="true"
      shift
      ;;
    --skip-migrations)
      SKIP_MIGRATIONS="true"
      shift
      ;;
    --no-ecs-apply)
      NO_ECS_APPLY="true"
      shift
      ;;
    --cleanup-old-resources)
      CLEANUP_OLD_RESOURCES="true"
      shift
      ;;
    --old-final-snapshot-id)
      OLD_FINAL_SNAPSHOT_ID="$2"
      shift 2
      ;;
    --skip-old-final-snapshot)
      SKIP_OLD_FINAL_SNAPSHOT="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --confirm)
      CONFIRM="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_cmd aws
require_cmd jq
require_cmd python3

if [[ "$MODE" == "cleanup" ]]; then
  [[ -n "$MANIFEST_FILE" ]] || die "--cleanup-only requires --manifest"
  load_cleanup_manifest
  confirm_or_die "clean up old DB resources"
  delete_old_cluster_resources
  log "cleanup complete"
  exit 0
fi

require_cmd terraform
require_cmd perl

[[ -n "$MODE" ]] || die "choose exactly one of --list, --restore-time, --restore-snapshot, or --cleanup-only"
if [[ -n "$ENV_DIR_ARG" ]]; then
  ENV_DIR="${ENV_DIR_ARG}"
else
  ENV_DIR="$PWD"
fi
[[ -d "$ENV_DIR" ]] || die "environment directory not found: $ENV_DIR; use --env-dir to specify a custom path"
ENV_NAME="$(basename "$ENV_DIR")"
TERRAFORM_DIR="$ENV_DIR"
[[ -n "$CONFIG_FILE" ]] || CONFIG_FILE="${ENV_DIR}/main.tf"
[[ "$CONFIG_FILE" == /* ]] || CONFIG_FILE="${ENV_DIR}/${CONFIG_FILE}"
[[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"

if [[ "$ROLLBACK" == "true" && -z "$FLEET_IMAGE" ]]; then
  die "--rollback requires --fleet-image"
fi
if [[ "$MODE" == "restore" && "$RESTORE_MODE" == "pitr" ]]; then
  is_utc_iso "$RESTORE_TIME" || die "--restore-time must be UTC ISO-8601, for example 2026-05-05T15:30:00Z"
fi
if [[ "$MODE" == "list" && ( "$ROLLBACK" == "true" || "$NO_ECS_APPLY" == "true" || "$SKIP_MIGRATIONS" == "true" ) ]]; then
  die "--list cannot be combined with restore execution flags"
fi

STAMP="$(date +%Y%m%d%H%M%S)"
ARTIFACT_DIR="${ENV_DIR}/.db-restore-${STAMP}"
mkdir -p "$ARTIFACT_DIR"

terraform_cmd init -no-color >/dev/null
if [[ -z "$MODULE_ADDRESS" ]]; then
  auto_detect_module_address
fi
load_state_snapshot

CURRENT_CLUSTER_ADDRESS="${MODULE_ADDRESS}.module.rds.aws_rds_cluster.this[0]"
CURRENT_CLUSTER_IDENTIFIER="$(state_value "$CURRENT_CLUSTER_ADDRESS" '.values.cluster_identifier // .values.id')"
if [[ -z "$CURRENT_CLUSTER_IDENTIFIER" ]]; then
  CURRENT_CLUSTER_ADDRESS="${MODULE_ADDRESS}.module.rds.aws_rds_cluster.this"
  CURRENT_CLUSTER_IDENTIFIER="$(state_value "$CURRENT_CLUSTER_ADDRESS" '.values.cluster_identifier // .values.id')"
fi
[[ -n "$CURRENT_CLUSTER_IDENTIFIER" ]] || die "could not determine current Aurora cluster identifier from Terraform state"

if [[ "$MODE" == "list" ]]; then
  list_restore_points
  log "list complete"
  exit 0
fi

detect_snapshot_source
collect_old_resource_metadata
collect_ecs_metadata
collect_state_addresses_for_removal
validate_pitr_window

if [[ -n "$DESTINATION_NAME" ]]; then
  RESTORED_NAME="$(sanitize_identifier "$DESTINATION_NAME")"
else
  RESTORED_NAME="$(next_destination_name "$CURRENT_CLUSTER_IDENTIFIER" "$CURRENT_CLUSTER_IDENTIFIER")"
fi
ensure_destination_available

if [[ -z "$OLD_FINAL_SNAPSHOT_ID" && "$SKIP_OLD_FINAL_SNAPSHOT" != "true" ]]; then
  OLD_FINAL_SNAPSHOT_ID="$(sanitize_identifier "${CURRENT_CLUSTER_IDENTIFIER}-pre-restore-retirement-${STAMP}")"
fi

copy_file "$CONFIG_FILE" "$ARTIFACT_DIR/$(basename "$CONFIG_FILE").original"
write_manifest

log "artifact directory: $ARTIFACT_DIR"
log "module address: $MODULE_ADDRESS"
log "current cluster: $CURRENT_CLUSTER_IDENTIFIER"
log "restored cluster: $RESTORED_NAME"
log "restore mode: $RESTORE_MODE"
[[ "$RESTORE_MODE" == "pitr" ]] && log "restore time: $RESTORE_TIME"
[[ "$RESTORE_MODE" == "snapshot" ]] && log "restore snapshot: $RESTORE_SNAPSHOT"
if [[ "$NO_ECS_APPLY" == "true" ]]; then
  log "execution path: DB restore plus post-restore RDS reconcile only; ECS services remain scaled to 0"
elif [[ "$SKIP_MIGRATIONS" == "true" ]]; then
  log "execution path: DB restore, post-restore RDS reconcile, ECS targeted apply, no migrations, scale services back up"
else
  log "execution path: DB restore, post-restore RDS reconcile, ECS targeted apply, migrations, scale services back up"
fi
if [[ "$CLEANUP_OLD_RESOURCES" == "true" ]]; then
  log "old DB resources will be cleaned up after restore"
else
  log "old DB resources will be kept; run --cleanup-only --manifest ${ARTIFACT_DIR}/manifest.json later"
fi

# Extract the current fleet image from the ECS task definition in state
extract_fleet_image_from_state() {
  jq -r --arg prefix "$FLEET_ECS_MODULE" '
    [
      .[]
      | select(.address | startswith($prefix))
      | select(.type == "aws_ecs_task_definition")
      | select(.values.container_definitions != null)
      | (.values.container_definitions // "[]")
      | fromjson
      | .[]
      | select(.name == "fleet")
      | .image // empty
    ] | first // empty
  ' "$STATE_RESOURCES_FILE"
}

# Ensure image is explicitly defined in the config
ensure_fleet_image_in_config() {
  # Check if image is a direct child of fleet_config (not nested inside containers, etc.)
  if perl -ne '
    BEGIN { $f = 0 }
    if (/fleet_config\s*=\s*[{]/) { $in=1; $depth=1 }
    elsif ($in) {
      my @ob = /\{/g; my @cb = /\}/g;
      $depth += scalar @ob - scalar @cb;
      if ($depth == 1 && /^\s*image\s*=\s*"/ && !/^\s*#/) { $f = 1; last }
      if ($depth <= 0) { $in = 0 }
    }
    END { exit !$f }
  ' "$CONFIG_FILE" 2>/dev/null; then
    return 0
  fi
  # Extract image from state
  local image=""
  image="$(extract_fleet_image_from_state)"
  if [[ -z "$image" ]]; then
    log "could not extract fleet image from state; skipping image addition"
    return 0
  fi
  # If fleet_config block exists, add image inside it; otherwise add top-level image
  if grep -q 'fleet_config\s*=' "$CONFIG_FILE" 2>/dev/null; then
    log "adding fleet_config.image = \"${image}\" to ${CONFIG_FILE}"
    perl -i -0pe '
      BEGIN { $image = $ENV{ENSURE_IMAGE} // ""; }
      s{(fleet_config\s*=\s*\{)}{$1\n    image = "'"$image"'"};
    ' "$CONFIG_FILE"
  else
    log "adding image = \"${image}\" to ${CONFIG_FILE}"
    perl -i -pe '
      BEGIN { $image = $ENV{ENSURE_IMAGE} // ""; $done = 0; }
      if (!$done && /^\s*rds_config\s*=\s*\{/) {
        print "  image = \"" . $image . "\"\n";
        $done = 1;
      }
    ' "$CONFIG_FILE"
  fi
}

# Ensure master_username is set in rds_config if user provided --master-username
ensure_master_username_in_config() {
  if [[ -z "$MASTER_USERNAME" ]]; then
    return 0
  fi
  # Check if master_username already exists as a direct child of rds_config
  if perl -ne '
    BEGIN { $f = 0 }
    if (/rds_config\s*=\s*[{]/) { $in=1; $depth=1 }
    elsif ($in) {
      my @ob = /\{/g; my @cb = /\}/g;
      $depth += scalar @ob - scalar @cb;
      if ($depth == 1 && /^\s*master_username\s*=/ && !/^\s*#/) { $f = 1; last }
      if ($depth <= 0) { $in = 0 }
    }
    END { exit !$f }
  ' "$CONFIG_FILE" 2>/dev/null; then
    # Update existing master_username
    log "updating rds_config.master_username to \"${MASTER_USERNAME}\" in ${CONFIG_FILE}"
    MASTER_USERNAME="$MASTER_USERNAME" perl -i -ne '
      BEGIN { $in = 0; $depth = 0 }
      if (/^\s*rds_config\s*=\s*\{/) { $in=1; $depth=1; print; next }
      if ($in) {
        my @ob = /\{/g; my @cb = /\}/g;
        $depth += scalar @ob - scalar @cb;
        if ($depth == 1 && /^\s*master_username\s*=/) {
          s/^([ \t]*)master_username\s*=.*/$1 . q{master_username = "} . $ENV{MASTER_USERNAME} . q{"}/e;
        }
        if ($depth <= 0) { $in = 0 }
        print; next;
      }
      print;
    ' "$CONFIG_FILE"
  else
    # Add master_username inside rds_config
    log "adding rds_config.master_username = \"${MASTER_USERNAME}\" to ${CONFIG_FILE}"
    MASTER_USERNAME="$MASTER_USERNAME" perl -i -ne '
      if (/^\s*rds_config\s*=\s*\{/) {
        print;
        print "    master_username = \"" . $ENV{MASTER_USERNAME} . "\"\n";
      } else {
        print;
      }
    ' "$CONFIG_FILE"
  fi
}

confirm_or_die "restore database"

if [[ "$DRY_RUN" == "true" ]]; then
  log "dry run: would edit ${CONFIG_FILE} for initial restore with Performance Insights, Database Insights, and Enhanced Monitoring temporarily disabled"
  [[ -n "$MASTER_USERNAME" ]] && log "dry run: would ensure rds_config.master_username = \"${MASTER_USERNAME}\" in config"
else
  update_config_file "$CONFIG_FILE" "initial"
  ensure_fleet_image_in_config
  update_fleet_image "$CONFIG_FILE"
  ensure_master_username_in_config
  terraform fmt "$CONFIG_FILE" >/dev/null
  copy_file "$CONFIG_FILE" "$ARTIFACT_DIR/$(basename "$CONFIG_FILE").after-initial-restore-edit"
fi

scale_down_services

if [[ "$DRY_RUN" == "true" ]]; then
  log "dry run: would remove these Terraform addresses from state:"
  printf '%s\n' "${STATE_REMOVE_ADDRESSES[@]}" >&2
  log "dry run: would apply RDS-only restore targets"
else
  remove_old_rds_state
  terraform_restore_targets
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "dry run: would restore original config, re-apply restore source, and run a second RDS-only reconcile to restore any configured KMS/Performance Insights/Enhanced Monitoring settings"
else
  copy_file "$ARTIFACT_DIR/$(basename "$CONFIG_FILE").original" "$CONFIG_FILE"
  update_config_file "$CONFIG_FILE" "post-restore"
  ensure_master_username_in_config
  ensure_fleet_image_in_config
  update_fleet_image "$CONFIG_FILE"
  terraform fmt "$CONFIG_FILE" >/dev/null
  copy_file "$CONFIG_FILE" "$ARTIFACT_DIR/$(basename "$CONFIG_FILE").after-post-restore-edit"
  terraform_restore_targets
fi

if [[ "$NO_ECS_APPLY" == "true" ]]; then
  log "leaving ECS services scaled to 0 because --no-ecs-apply was set"
else
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would apply Fleet ECS task/service targets"
    [[ "$SKIP_MIGRATIONS" == "true" ]] || log "dry run: would apply module.migrations"
    log "dry run: would scale Fleet/vuln-processing services back up"
  else
    terraform_apply_ecs_targets
    if [[ "$SKIP_MIGRATIONS" == "true" ]]; then
      log "skipping module.migrations because --skip-migrations was set"
      scale_up_services
    else
      terraform_apply_migrations
    fi
  fi
fi

if [[ "$CLEANUP_OLD_RESOURCES" == "true" ]]; then
  delete_old_cluster_resources
fi

log "restore workflow complete"
log "manifest saved to ${ARTIFACT_DIR}/manifest.json"
