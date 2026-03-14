#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  rds_storage_kms_migration.sh --storage-kms-key-arn <arn> [options]
  rds_storage_kms_migration.sh --storage-kms-alias <alias> [options]

This helper automates an Aurora storage KMS migration for the byo-vpc module by:
1. Editing the caller's inline rds_config object.
2. Pre-creating a wrapper-managed storage CMK when an alias is requested.
3. Creating a source snapshot and an encrypted copy with the target CMK.
4. Removing the current Aurora resources from Terraform state.
5. Applying Terraform to restore a new Aurora cluster from the encrypted snapshot.
6. Deleting the old Aurora resources from AWS after the new cluster is managed.

Required options:
  --storage-kms-key-arn <arn>   Use an existing CMK ARN in rds_config.storage_kms.kms_key_arn.
  --storage-kms-alias <alias>   Have byo-vpc create/manage the target CMK with this alias.

Options:
  --terraform-dir <dir>         Terraform working directory. Default: .
  --config-file <path>          Terraform file that contains the inline rds_config object.
                                Default: main.tf (relative to --terraform-dir if not absolute)
  --manifest <path>             Existing manifest.json to use with --cleanup-only.
  --module-address <addr>       Full Terraform address for the byo-vpc module instance.
                                Auto-detected when exactly one match exists.
  --region <region>             AWS region. Default: AWS_REGION / AWS_DEFAULT_REGION
  --restored-name <name>        New Aurora cluster identifier/name. Default: <current>-kms-<timestamp>
  --source-snapshot-id <id>     Manual DB cluster snapshot identifier to create.
  --copied-snapshot-id <id>     Encrypted DB cluster snapshot copy identifier to create.
  --old-final-snapshot-id <id>  Final snapshot identifier when deleting the old cluster.
  --skip-old-final-snapshot     Delete the old cluster without a final snapshot.
  --include-performance-insights
                                Also enable Performance Insights CMK configuration during restore.
  --performance-insights-kms-alias <alias>
                                Set rds_config.observability.kms.kms_alias during restore.
  --keep-old-resources          Leave the old Aurora resources in AWS after cutover.
  --cleanup-only                Skip migration steps and only run AWS cleanup from --manifest.
  --confirm                     Prompt before each AWS cleanup command executes.
  --dry-run                     Show the planned actions without mutating Terraform, state, or AWS.
  --help                        Show this help text.

Notes:
* This assumes the caller passes rds_config as a direct inline object literal in the config file.
* The helper intentionally leaves rds_config.snapshot_identifier pinned to the copied snapshot.
  Clearing it later would force Terraform to replace the restored cluster.
* --include-performance-insights updates rds_config.observability during restore so the
  recreated cluster can adopt Performance Insights CMK settings at creation time.
* --performance-insights-kms-alias controls the alias written to
  rds_config.observability.kms.kms_alias during restore.
* Run this during a maintenance window. The snapshot/copy/restore path is not an in-place re-key.
EOF
}

log() {
  printf '[rds-storage-kms-migration] %s\n' "$*" >&2
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
  if [[ -z "$value" ]]; then
    value="fleet"
  fi
  value="${value:0:$max_length}"
  value="$(printf '%s' "$value" | sed -E 's/-+$//')"
  if [[ ! "$value" =~ ^[a-z] ]]; then
    value="f${value}"
    value="${value:0:$max_length}"
    value="$(printf '%s' "$value" | sed -E 's/-+$//')"
  fi
  printf '%s\n' "$value"
}

join_by() {
  local separator="$1"
  shift
  local first=1
  for value in "$@"; do
    if [[ "$first" -eq 1 ]]; then
      printf '%s' "$value"
      first=0
    else
      printf '%s%s' "$separator" "$value"
    fi
  done
}

json_array_from_lines() {
  jq -Rsc 'split("\n") | map(select(length > 0))'
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

terraform_cmd() {
  terraform -chdir="$TERRAFORM_DIR" "$@"
}

aws_cmd() {
  if [[ -n "$AWS_REGION_ARG" ]]; then
    aws --region "$AWS_REGION_ARG" "$@"
  else
    aws "$@"
  fi
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

confirm_cleanup_command() {
  local command_display="$1"
  local reply=""

  [[ "$CONFIRM_CLEANUP" == "true" ]] || return 0
  [[ -r /dev/tty ]] || die "--confirm requires an interactive terminal"

  printf '[rds-storage-kms-migration] about to run: %s\n' "$command_display" >&2
  printf '[rds-storage-kms-migration] continue? [y/N] ' >/dev/tty
  read -r reply </dev/tty
  case "$reply" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      die "cleanup aborted at user request"
      ;;
  esac
}

aws_cleanup_cmd() {
  local display=""
  display="$(print_shell_command aws ${AWS_REGION_ARG:+--region "$AWS_REGION_ARG"} "$@")"
  confirm_cleanup_command "$display"
  aws_cmd "$@"
}

auto_detect_module_address() {
  local matches_text=""
  local matches=()

  matches_text="$(terraform_cmd state list | grep -E '\.module\.rds\.aws_rds_cluster\.this\[0\]$' | sed 's/\.module\.rds\.aws_rds_cluster\.this\[0\]$//' || true)"
  array_from_newline_text matches "$matches_text"
  if [[ "${#matches[@]}" -eq 0 ]]; then
    die "could not auto-detect the byo-vpc module address from Terraform state; pass --module-address"
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    die "multiple byo-vpc module addresses found: $(join_by ', ' "${matches[@]}"); pass --module-address"
  fi
  MODULE_ADDRESS="${matches[0]}"
}

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
  jq -r --arg addr "$address" ".[] | select(.address == \$addr) | ${jq_filter}" "$STATE_RESOURCES_FILE"
}

resolve_target_storage_kms_id() {
  if [[ -n "$TARGET_STORAGE_KMS_KEY_ARN" ]]; then
    RESOLVED_TARGET_STORAGE_KMS_ID="$TARGET_STORAGE_KMS_KEY_ARN"
    return
  fi

  local key_address="${MODULE_ADDRESS}.aws_kms_key.rds_storage[0]"
  RESOLVED_TARGET_STORAGE_KMS_ID="$(state_value "$key_address" '.values.arn')"
  RESOLVED_TARGET_STORAGE_KMS_ID="${RESOLVED_TARGET_STORAGE_KMS_ID//$'\r'/}"
  if [[ -z "$RESOLVED_TARGET_STORAGE_KMS_ID" || "$RESOLVED_TARGET_STORAGE_KMS_ID" == "null" ]]; then
    die "could not determine the created storage CMK ARN from ${key_address}"
  fi
}

collect_state_addresses_for_removal() {
  local pattern
  local matches_text=""
  pattern="^${MODULE_ADDRESS//./\\.}\\.(module\\.rds\\.|module\\.secrets-manager-1\\.|random_id\\.rds_final_snapshot_identifier(\\[0\\])?$|aws_db_parameter_group\\.main(\\[0\\])?$|aws_rds_cluster_parameter_group\\.main(\\[0\\])?$)"
  matches_text="$(terraform_cmd state list | grep -E "$pattern" | sort || true)"
  array_from_newline_text STATE_REMOVE_ADDRESSES "$matches_text"
  if [[ "${#STATE_REMOVE_ADDRESSES[@]}" -eq 0 ]]; then
    die "did not find any RDS-related Terraform addresses to remove under ${MODULE_ADDRESS}"
  fi
}

write_manifest() {
  jq -n \
    --arg module_address "$MODULE_ADDRESS" \
    --arg config_file "$CONFIG_FILE" \
    --arg current_cluster_identifier "$CURRENT_CLUSTER_IDENTIFIER" \
    --arg restored_name "$RESTORED_NAME" \
    --arg source_snapshot_id "$SOURCE_SNAPSHOT_ID" \
    --arg copied_snapshot_id "$COPIED_SNAPSHOT_ID" \
    --arg old_final_snapshot_id "$OLD_FINAL_SNAPSHOT_ID" \
    --arg storage_kms_key_arn "$TARGET_STORAGE_KMS_KEY_ARN" \
    --arg storage_kms_alias "$TARGET_STORAGE_KMS_ALIAS" \
    --arg performance_insights_kms_alias "$PERFORMANCE_INSIGHTS_KMS_ALIAS" \
    --argjson include_performance_insights "$INCLUDE_PERFORMANCE_INSIGHTS_JSON" \
    --argjson old_instance_identifiers "$OLD_INSTANCE_IDENTIFIERS_JSON" \
    --argjson old_security_group_ids "$OLD_SECURITY_GROUP_IDS_JSON" \
    --argjson old_secrets "$OLD_SECRETS_JSON" \
    --argjson old_monitoring_roles "$OLD_MONITORING_ROLES_JSON" \
    --argjson old_parameter_groups "$OLD_PARAMETER_GROUPS_JSON" \
    --argjson old_db_subnet_groups "$OLD_DB_SUBNET_GROUPS_JSON" \
    --argjson state_remove_addresses "$STATE_REMOVE_ADDRESSES_JSON" \
    '{
      module_address: $module_address,
      config_file: $config_file,
      current_cluster_identifier: $current_cluster_identifier,
      restored_name: $restored_name,
      source_snapshot_id: $source_snapshot_id,
      copied_snapshot_id: $copied_snapshot_id,
      old_final_snapshot_id: ($old_final_snapshot_id | if length > 0 then . else null end),
      storage_kms_key_arn: ($storage_kms_key_arn | if length > 0 then . else null end),
      storage_kms_alias: ($storage_kms_alias | if length > 0 then . else null end),
      performance_insights_kms_alias: ($performance_insights_kms_alias | if length > 0 then . else null end),
      include_performance_insights: $include_performance_insights,
      old_instance_identifiers: $old_instance_identifiers,
      old_security_group_ids: $old_security_group_ids,
      old_secrets: $old_secrets,
      old_monitoring_roles: $old_monitoring_roles,
      old_parameter_groups: $old_parameter_groups,
      old_db_subnet_groups: $old_db_subnet_groups,
      state_remove_addresses: $state_remove_addresses
    } | with_entries(select(.value != null))' >"$ARTIFACT_DIR/manifest.json"
}

update_rds_config_file() {
  local file="$1"
  local mode="$2"

  CONFIG_EDIT_MODE="$mode" \
  CONFIG_EDIT_RESTORED_NAME="${RESTORED_NAME:-}" \
  CONFIG_EDIT_SOURCE_SNAPSHOT_ID="${COPIED_SNAPSHOT_ID:-}" \
  CONFIG_EDIT_TARGET_STORAGE_KMS_KEY_ARN="${TARGET_STORAGE_KMS_KEY_ARN:-}" \
  CONFIG_EDIT_TARGET_STORAGE_KMS_ALIAS="${TARGET_STORAGE_KMS_ALIAS:-}" \
  CONFIG_EDIT_INCLUDE_PERFORMANCE_INSIGHTS="${INCLUDE_PERFORMANCE_INSIGHTS:-false}" \
  CONFIG_EDIT_PERFORMANCE_INSIGHTS_KMS_ALIAS="${PERFORMANCE_INSIGHTS_KMS_ALIAS:-}" \
  perl -i -0pe '
use strict;
use warnings;

my $mode = $ENV{CONFIG_EDIT_MODE} // "";
my $restored_name = $ENV{CONFIG_EDIT_RESTORED_NAME} // "";
my $snapshot_id = $ENV{CONFIG_EDIT_SOURCE_SNAPSHOT_ID} // "";
my $kms_key_arn = $ENV{CONFIG_EDIT_TARGET_STORAGE_KMS_KEY_ARN} // "";
my $kms_alias = $ENV{CONFIG_EDIT_TARGET_STORAGE_KMS_ALIAS} // "";
my $include_performance_insights = $ENV{CONFIG_EDIT_INCLUDE_PERFORMANCE_INSIGHTS} // "false";
my $performance_insights_kms_alias = $ENV{CONFIG_EDIT_PERFORMANCE_INSIGHTS_KMS_ALIAS} // "";

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

    if ($in_line_comment) {
      if ($char eq "\n") {
        $in_line_comment = 0;
      }
      next;
    }

    if ($in_block_comment) {
      if ($char eq "*" && $next eq "/") {
        $in_block_comment = 0;
        $i++;
      }
      next;
    }

    if ($in_string) {
      if ($escaped) {
        $escaped = 0;
        next;
      }
      if ($char eq "\\") {
        $escaped = 1;
        next;
      }
      if ($char eq "\"") {
        $in_string = 0;
      }
      next;
    }

    if ($char eq "/" && $next eq "/") {
      $in_line_comment = 1;
      $i++;
      next;
    }

    if ($char eq "#") {
      $in_line_comment = 1;
      next;
    }

    if ($char eq "/" && $next eq "*") {
      $in_block_comment = 1;
      $i++;
      next;
    }

    if ($char eq "\"") {
      $in_string = 1;
      next;
    }

    if ($char eq "{") {
      $depth++;
      next;
    }

    if ($char eq "}") {
      $depth--;
      if ($depth == 0) {
        return $i;
      }
    }
  }

  die "failed to find matching closing brace for rds_config\n";
}

sub find_rds_config_span {
  my ($text) = @_;
  my @matches = ($text =~ /(^[ \t]*rds_config[ \t]*=[ \t]*\{)/mg);
  my @positions;
  while ($text =~ /(^[ \t]*rds_config[ \t]*=[ \t]*\{)/mg) {
    push @positions, pos($text) - 1;
  }
  die "did not find an inline rds_config object\n" if @positions == 0;
  die "found multiple inline rds_config objects; pass a narrower --config-file\n" if @positions > 1;

  my $line_start = rindex($text, "\n", $positions[0]);
  $line_start = $line_start == -1 ? 0 : $line_start + 1;
  my $brace_index = index($text, "{", $positions[0]);
  my $end_index = find_matching_brace($text, $brace_index);
  return ($line_start, $end_index);
}

sub object_indent {
  my ($text) = @_;
  if ($text =~ /\{\n([ \t]+)\S/m) {
    return $1;
  }
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

sub upsert_storage_kms_block {
  my ($object_text, $kms_key_arn, $kms_alias) = @_;
  my $indent = object_indent($object_text);
  my $nested_indent = $indent . "  ";

  my $replacement = "${indent}storage_kms = {\n";
  $replacement .= "${nested_indent}cmk_enabled = true\n";
  if (length($kms_key_arn)) {
    $replacement .= "${nested_indent}kms_key_arn = " . quote_hcl($kms_key_arn) . "\n";
  } else {
    $replacement .= "${nested_indent}kms_key_arn = null\n";
  }
  if (length($kms_alias)) {
    $replacement .= "${nested_indent}kms_alias = " . quote_hcl($kms_alias) . "\n";
  }
  $replacement .= "${indent}}";

  if ($object_text =~ /^([ \t]*)storage_kms[ \t]*=[ \t]*\{/m) {
    my $storage_start = $-[0];
    my $storage_brace = index($object_text, "{", $storage_start);
    my $storage_end = find_matching_brace($object_text, $storage_brace);
    substr($object_text, $storage_start, $storage_end - $storage_start + 1, $replacement);
    return $object_text;
  }

  $object_text =~ s/\n([ \t]*)\}$/\n$replacement\n$1}/s;
  return $object_text;
}

sub upsert_observability_kms_block {
  my ($observability_text, $kms_alias) = @_;
  my $indent = object_indent($observability_text);
  my $nested_indent = $indent . "  ";

  my $replacement = "${indent}kms = {\n";
  $replacement .= "${nested_indent}cmk_enabled = true\n";
  if (length($kms_alias)) {
    $replacement .= "${nested_indent}kms_alias = " . quote_hcl($kms_alias) . "\n";
  }
  $replacement .= "${indent}}";

  if ($observability_text =~ /^([ \t]*)kms[ \t]*=[ \t]*\{/m) {
    my $kms_start = $-[0];
    my $kms_brace = index($observability_text, "{", $kms_start);
    my $kms_end = find_matching_brace($observability_text, $kms_brace);
    my $existing = substr($observability_text, $kms_start, $kms_end - $kms_start + 1);
    $existing = upsert_simple_attribute($existing, "cmk_enabled", "true");
    if (length($kms_alias)) {
      $existing = upsert_simple_attribute($existing, "kms_alias", quote_hcl($kms_alias));
    }
    substr($observability_text, $kms_start, $kms_end - $kms_start + 1, $existing);
    return $observability_text;
  }

  $observability_text =~ s/\n([ \t]*)\}$/\n$replacement\n$1}/s;
  return $observability_text;
}

sub upsert_observability_block {
  my ($object_text, $kms_alias) = @_;
  my $indent = object_indent($object_text);
  my $nested_indent = $indent . "  ";

  if ($object_text =~ /^([ \t]*)observability[ \t]*=[ \t]*\{/m) {
    my $observability_start = $-[0];
    my $observability_brace = index($object_text, "{", $observability_start);
    my $observability_end = find_matching_brace($object_text, $observability_brace);
    my $existing = substr($object_text, $observability_start, $observability_end - $observability_start + 1);
    $existing = upsert_simple_attribute($existing, "performance_insights_enabled", "true");
    $existing = upsert_observability_kms_block($existing, $kms_alias);
    substr($object_text, $observability_start, $observability_end - $observability_start + 1, $existing);
    return $object_text;
  }

  my $replacement = "${indent}observability = {\n";
  $replacement .= "${nested_indent}performance_insights_enabled = true\n";
  $replacement .= "${nested_indent}kms = {\n";
  $replacement .= "${nested_indent}  cmk_enabled = true\n";
  if (length($kms_alias)) {
    $replacement .= "${nested_indent}  kms_alias = " . quote_hcl($kms_alias) . "\n";
  }
  $replacement .= "${nested_indent}}\n";
  $replacement .= "${indent}}";

  $object_text =~ s/\n([ \t]*)\}$/\n$replacement\n$1}/s;
  return $object_text;
}

sub replace_optional_mysql_password_secret_name {
  my ($text, $restored_name) = @_;
  my $replacement = quote_hcl($restored_name . "-database-password");
  $text =~ s/^([ \t]*mysql_password_secret_name[ \t]*=[ \t]*).*$/$1$replacement/mg;
  return $text;
}

my ($start_index, $end_index) = find_rds_config_span($_);
my $object_text = substr($_, $start_index, $end_index - $start_index + 1);

if ($mode eq "kms-bootstrap") {
  $object_text = upsert_storage_kms_block($object_text, $kms_key_arn, $kms_alias);
} elsif ($mode eq "restore") {
  die "restore mode requires CONFIG_EDIT_RESTORED_NAME\n" if !length($restored_name);
  die "restore mode requires CONFIG_EDIT_SOURCE_SNAPSHOT_ID\n" if !length($snapshot_id);
  $object_text = upsert_simple_attribute($object_text, "name", quote_hcl($restored_name));
  $object_text = upsert_simple_attribute($object_text, "snapshot_identifier", quote_hcl($snapshot_id));
  $object_text = upsert_simple_attribute($object_text, "restore_to_point_in_time", "{}");
  $object_text = upsert_storage_kms_block($object_text, $kms_key_arn, $kms_alias);
  if ($include_performance_insights eq "true") {
    $object_text = upsert_observability_block($object_text, $performance_insights_kms_alias);
  }
} else {
  die "unexpected CONFIG_EDIT_MODE=$mode\n";
}

substr($_, $start_index, $end_index - $start_index + 1, $object_text);
if ($mode eq "restore") {
  $_ = replace_optional_mysql_password_secret_name($_, $restored_name);
}
  ' "$file"
}

create_source_snapshot() {
  log "creating source DB cluster snapshot ${SOURCE_SNAPSHOT_ID}"
  aws_cmd rds create-db-cluster-snapshot \
    --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" \
    --db-cluster-snapshot-identifier "$SOURCE_SNAPSHOT_ID" \
    >/dev/null
  aws_cmd rds wait db-cluster-snapshot-available \
    --db-cluster-snapshot-identifier "$SOURCE_SNAPSHOT_ID"
}

copy_snapshot_with_target_kms() {
  local kms_id="$RESOLVED_TARGET_STORAGE_KMS_ID"

  log "copying snapshot ${SOURCE_SNAPSHOT_ID} to ${COPIED_SNAPSHOT_ID} with ${kms_id}"
  aws_cmd rds copy-db-cluster-snapshot \
    --source-db-cluster-snapshot-identifier "$SOURCE_SNAPSHOT_ID" \
    --target-db-cluster-snapshot-identifier "$COPIED_SNAPSHOT_ID" \
    --kms-key-id "$kms_id" \
    --copy-tags \
    >/dev/null
  aws_cmd rds wait db-cluster-snapshot-available \
    --db-cluster-snapshot-identifier "$COPIED_SNAPSHOT_ID"
}

terraform_apply_storage_kms_only() {
  local targets=(
    "-target=${MODULE_ADDRESS}.aws_kms_key.rds_storage[0]"
    "-target=${MODULE_ADDRESS}.aws_kms_alias.rds_storage[0]"
  )

  log "running targeted terraform apply to pre-create the storage CMK"
  terraform_cmd apply -auto-approve "${targets[@]}"
}

terraform_apply_byo_vpc_only() {
  log "running targeted terraform apply for ${MODULE_ADDRESS}"
  terraform_cmd apply -auto-approve "-target=${MODULE_ADDRESS}"
}

terraform_reconcile_restored_byo_vpc() {
  log "running a second targeted terraform apply for ${MODULE_ADDRESS} to reconcile post-restore in-place updates"
  terraform_cmd apply -auto-approve "-target=${MODULE_ADDRESS}"
}

remove_old_rds_state() {
  log "removing old Aurora resources from Terraform state"
  terraform_cmd state rm "${STATE_REMOVE_ADDRESSES[@]}"
}

load_cleanup_manifest() {
  [[ -f "$MANIFEST_FILE" ]] || die "manifest file does not exist: $MANIFEST_FILE"

  CURRENT_CLUSTER_IDENTIFIER="$(jq -r '.current_cluster_identifier // empty' "$MANIFEST_FILE")"
  CURRENT_CLUSTER_IDENTIFIER="${CURRENT_CLUSTER_IDENTIFIER//$'\r'/}"
  [[ -n "$CURRENT_CLUSTER_IDENTIFIER" ]] || die "manifest is missing current_cluster_identifier"

  OLD_FINAL_SNAPSHOT_ID="$(jq -r '.old_final_snapshot_id // empty' "$MANIFEST_FILE")"

  array_from_newline_text OLD_INSTANCE_IDENTIFIERS "$(jq -r '.old_instance_identifiers[]? // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_SECURITY_GROUP_IDS "$(jq -r '.old_security_group_ids[]? // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_SECRET_IDS "$(jq -r '.old_secrets[]? | .arn // .name // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_DB_PARAMETER_GROUP_NAMES "$(jq -r '.old_parameter_groups.db_parameter_groups[]? // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_DB_CLUSTER_PARAMETER_GROUP_NAMES "$(jq -r '.old_parameter_groups.db_cluster_parameter_groups[]? // empty' "$MANIFEST_FILE")"
  array_from_newline_text OLD_DB_SUBNET_GROUP_NAMES "$(jq -r '.old_db_subnet_groups[]? // empty' "$MANIFEST_FILE")"
  OLD_MONITORING_ROLES_JSON="$(jq -c '.old_monitoring_roles // []' "$MANIFEST_FILE")"
}

delete_old_cluster_resources() {
  if [[ "$KEEP_OLD_RESOURCES" == "true" ]]; then
    log "keeping the old Aurora resources in AWS because --keep-old-resources was set"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would delete old Aurora instances, cluster, secret, enhanced monitoring IAM role, parameter groups, subnet groups, and security groups"
    return
  fi

  local instance_id
  for instance_id in "${OLD_INSTANCE_IDENTIFIERS[@]}"; do
    log "deleting old Aurora instance ${instance_id}"
    aws_cleanup_cmd rds delete-db-instance \
      --db-instance-identifier "$instance_id" \
      --skip-final-snapshot \
      >/dev/null || true
  done

  for instance_id in "${OLD_INSTANCE_IDENTIFIERS[@]}"; do
    log "waiting for old Aurora instance ${instance_id} to be deleted"
    aws_cleanup_cmd rds wait db-instance-deleted --db-instance-identifier "$instance_id" || true
  done

  if [[ "$SKIP_OLD_FINAL_SNAPSHOT" == "true" ]]; then
    log "deleting old Aurora cluster ${CURRENT_CLUSTER_IDENTIFIER} without a final snapshot"
    aws_cleanup_cmd rds delete-db-cluster \
      --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" \
      --skip-final-snapshot \
      >/dev/null || true
  else
    log "deleting old Aurora cluster ${CURRENT_CLUSTER_IDENTIFIER} with final snapshot ${OLD_FINAL_SNAPSHOT_ID}"
    aws_cleanup_cmd rds delete-db-cluster \
      --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" \
      --final-db-snapshot-identifier "$OLD_FINAL_SNAPSHOT_ID" \
      >/dev/null || true
  fi

  log "waiting for old Aurora cluster ${CURRENT_CLUSTER_IDENTIFIER} to be deleted"
  aws_cleanup_cmd rds wait db-cluster-deleted --db-cluster-identifier "$CURRENT_CLUSTER_IDENTIFIER" || true

  local secret_id
  for secret_id in "${OLD_SECRET_IDS[@]}"; do
    log "deleting old secret ${secret_id}"
    aws_cleanup_cmd secretsmanager delete-secret \
      --secret-id "$secret_id" \
      --force-delete-without-recovery \
      >/dev/null || true
  done

  local role_name
  local policy_arn
  while IFS= read -r role_name; do
    [[ -n "$role_name" ]] || continue

    while IFS= read -r policy_arn; do
      [[ -n "$policy_arn" ]] || continue
      log "detaching managed policy ${policy_arn} from IAM role ${role_name}"
      aws_cleanup_cmd iam detach-role-policy \
        --role-name "$role_name" \
        --policy-arn "$policy_arn" \
        >/dev/null || true
    done < <(jq -r --arg role_name "$role_name" '.[] | select(.name == $role_name) | .attached_policy_arns[]?' <<<"$OLD_MONITORING_ROLES_JSON")

    log "deleting old enhanced monitoring IAM role ${role_name}"
    aws_cleanup_cmd iam delete-role --role-name "$role_name" >/dev/null || true
  done < <(jq -r '.[].name // empty' <<<"$OLD_MONITORING_ROLES_JSON")

  local group_name
  for group_name in "${OLD_DB_PARAMETER_GROUP_NAMES[@]}"; do
    log "deleting old DB parameter group ${group_name}"
    aws_cleanup_cmd rds delete-db-parameter-group --db-parameter-group-name "$group_name" >/dev/null || true
  done

  for group_name in "${OLD_DB_CLUSTER_PARAMETER_GROUP_NAMES[@]}"; do
    log "deleting old DB cluster parameter group ${group_name}"
    aws_cleanup_cmd rds delete-db-cluster-parameter-group --db-cluster-parameter-group-name "$group_name" >/dev/null || true
  done

  for group_name in "${OLD_DB_SUBNET_GROUP_NAMES[@]}"; do
    log "deleting old DB subnet group ${group_name}"
    aws_cleanup_cmd rds delete-db-subnet-group --db-subnet-group-name "$group_name" >/dev/null || true
  done

  local sg_id
  for sg_id in "${OLD_SECURITY_GROUP_IDS[@]}"; do
    log "deleting old security group ${sg_id}"
    aws_cleanup_cmd ec2 delete-security-group --group-id "$sg_id" >/dev/null || true
  done
}

copy_file() {
  local src="$1"
  local dest="$2"
  cp "$src" "$dest"
}

CONFIG_FILE=""
MANIFEST_FILE=""
TERRAFORM_DIR="."
MODULE_ADDRESS=""
AWS_REGION_ARG="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
TARGET_STORAGE_KMS_KEY_ARN=""
TARGET_STORAGE_KMS_ALIAS=""
PERFORMANCE_INSIGHTS_KMS_ALIAS=""
RESOLVED_TARGET_STORAGE_KMS_ID=""
RESTORED_NAME=""
SOURCE_SNAPSHOT_ID=""
COPIED_SNAPSHOT_ID=""
OLD_FINAL_SNAPSHOT_ID=""
SKIP_OLD_FINAL_SNAPSHOT="false"
INCLUDE_PERFORMANCE_INSIGHTS="false"
KEEP_OLD_RESOURCES="false"
CONFIRM_CLEANUP="false"
CLEANUP_ONLY="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir)
      TERRAFORM_DIR="$2"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --manifest)
      MANIFEST_FILE="$2"
      shift 2
      ;;
    --module-address)
      MODULE_ADDRESS="$2"
      shift 2
      ;;
    --region)
      AWS_REGION_ARG="$2"
      shift 2
      ;;
    --storage-kms-key-arn)
      TARGET_STORAGE_KMS_KEY_ARN="$2"
      shift 2
      ;;
    --storage-kms-alias)
      TARGET_STORAGE_KMS_ALIAS="${2#alias/}"
      shift 2
      ;;
    --restored-name)
      RESTORED_NAME="$2"
      shift 2
      ;;
    --source-snapshot-id)
      SOURCE_SNAPSHOT_ID="$2"
      shift 2
      ;;
    --copied-snapshot-id)
      COPIED_SNAPSHOT_ID="$2"
      shift 2
      ;;
    --old-final-snapshot-id)
      OLD_FINAL_SNAPSHOT_ID="$2"
      shift 2
      ;;
    --skip-old-final-snapshot)
      SKIP_OLD_FINAL_SNAPSHOT="true"
      shift
      ;;
    --include-performance-insights)
      INCLUDE_PERFORMANCE_INSIGHTS="true"
      shift
      ;;
    --performance-insights-kms-alias)
      PERFORMANCE_INSIGHTS_KMS_ALIAS="${2#alias/}"
      shift 2
      ;;
    --keep-old-resources)
      KEEP_OLD_RESOURCES="true"
      shift
      ;;
    --confirm)
      CONFIRM_CLEANUP="true"
      shift
      ;;
    --cleanup-only)
      CLEANUP_ONLY="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
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
if [[ "$CLEANUP_ONLY" != "true" ]]; then
  require_cmd perl
  require_cmd terraform
fi

if [[ "$CLEANUP_ONLY" == "true" ]]; then
  [[ -n "$MANIFEST_FILE" ]] || die "--cleanup-only requires --manifest"
else
  if [[ -z "$TARGET_STORAGE_KMS_KEY_ARN" && -z "$TARGET_STORAGE_KMS_ALIAS" ]]; then
    die "set either --storage-kms-key-arn or --storage-kms-alias"
  fi

  if [[ -n "$TARGET_STORAGE_KMS_KEY_ARN" && -n "$TARGET_STORAGE_KMS_ALIAS" ]]; then
    die "use either --storage-kms-key-arn or --storage-kms-alias, not both"
  fi
fi

if [[ -z "$AWS_REGION_ARG" ]]; then
  die "set --region or AWS_REGION/AWS_DEFAULT_REGION"
fi

if [[ ! -d "$TERRAFORM_DIR" ]]; then
  die "terraform directory does not exist: $TERRAFORM_DIR"
fi

if [[ -n "$PERFORMANCE_INSIGHTS_KMS_ALIAS" && "$INCLUDE_PERFORMANCE_INSIGHTS" != "true" ]]; then
  die "--performance-insights-kms-alias requires --include-performance-insights"
fi

INCLUDE_PERFORMANCE_INSIGHTS_JSON="false"
if [[ "$INCLUDE_PERFORMANCE_INSIGHTS" == "true" ]]; then
  INCLUDE_PERFORMANCE_INSIGHTS_JSON="true"
fi

STAMP="$(date +%Y%m%d%H%M%S)"
if [[ "$CLEANUP_ONLY" != "true" ]]; then
  ARTIFACT_DIR="${TERRAFORM_DIR%/}/.rds-storage-kms-migration-${STAMP}"
  mkdir -p "$ARTIFACT_DIR"
  if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="main.tf"
  fi

  if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${TERRAFORM_DIR%/}/$CONFIG_FILE"
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    die "config file does not exist: $CONFIG_FILE"
  fi

  terraform_cmd init -no-color >/dev/null

  if [[ -z "$MODULE_ADDRESS" ]]; then
    auto_detect_module_address
  fi

  copy_file "$CONFIG_FILE" "$ARTIFACT_DIR/$(basename "$CONFIG_FILE").original"
  load_state_snapshot

  CURRENT_CLUSTER_ADDRESS="${MODULE_ADDRESS}.module.rds.aws_rds_cluster.this[0]"
  CURRENT_CLUSTER_IDENTIFIER="$(state_value "$CURRENT_CLUSTER_ADDRESS" '.values.cluster_identifier // .values.id')"
  CURRENT_CLUSTER_IDENTIFIER="${CURRENT_CLUSTER_IDENTIFIER//$'\r'/}"
  if [[ -z "$CURRENT_CLUSTER_IDENTIFIER" || "$CURRENT_CLUSTER_IDENTIFIER" == "null" ]]; then
    die "could not determine the current Aurora cluster identifier from ${CURRENT_CLUSTER_ADDRESS}"
  fi

  if [[ -z "$RESTORED_NAME" ]]; then
    RESTORED_NAME="$(sanitize_identifier "${CURRENT_CLUSTER_IDENTIFIER}-kms-${STAMP}" 63)"
  fi
  if [[ -z "$SOURCE_SNAPSHOT_ID" ]]; then
    SOURCE_SNAPSHOT_ID="$(sanitize_identifier "${CURRENT_CLUSTER_IDENTIFIER}-kms-source-${STAMP}" 63)"
  fi
  if [[ -z "$COPIED_SNAPSHOT_ID" ]]; then
    COPIED_SNAPSHOT_ID="$(sanitize_identifier "${CURRENT_CLUSTER_IDENTIFIER}-kms-copy-${STAMP}" 63)"
  fi
  if [[ -z "$OLD_FINAL_SNAPSHOT_ID" && "$SKIP_OLD_FINAL_SNAPSHOT" != "true" ]]; then
    OLD_FINAL_SNAPSHOT_ID="$(sanitize_identifier "${CURRENT_CLUSTER_IDENTIFIER}-pre-kms-retirement-${STAMP}" 63)"
  fi

  array_from_newline_text OLD_INSTANCE_IDENTIFIERS "$(jq -r --arg prefix "${MODULE_ADDRESS}.module.rds.aws_rds_cluster_instance." '
  .[]
  | select(.address | startswith($prefix))
  | .values.identifier
' "$STATE_RESOURCES_FILE" | sed '/^null$/d')"
  OLD_INSTANCE_IDENTIFIERS_JSON="$(printf '%s\n' "${OLD_INSTANCE_IDENTIFIERS[@]:-}" | json_array_from_lines)"

  array_from_newline_text OLD_SECURITY_GROUP_IDS "$(jq -r --arg prefix "${MODULE_ADDRESS}.module.rds.aws_security_group." '
  .[]
  | select(.address | startswith($prefix))
  | .values.id
' "$STATE_RESOURCES_FILE" | sed '/^null$/d')"
  OLD_SECURITY_GROUP_IDS_JSON="$(printf '%s\n' "${OLD_SECURITY_GROUP_IDS[@]:-}" | json_array_from_lines)"

  OLD_SECRETS_JSON="$(jq -c --arg prefix "${MODULE_ADDRESS}.module.secrets-manager-1." '
  [
    .[]
    | select(.address | startswith($prefix))
    | select(.type == "aws_secretsmanager_secret")
    | {name: .values.name, arn: .values.arn}
  ]
' "$STATE_RESOURCES_FILE")"
  array_from_newline_text OLD_SECRET_IDS "$(jq -r '.[] | .arn // .name' <<<"$OLD_SECRETS_JSON")"

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

  OLD_PARAMETER_GROUPS_JSON="$(jq -c --arg db_addr "${MODULE_ADDRESS}.aws_db_parameter_group.main[0]" --arg cluster_addr "${MODULE_ADDRESS}.aws_rds_cluster_parameter_group.main[0]" '
  {
    db_parameter_groups: [
      .[]
      | select(.address == $db_addr)
      | .values.name
    ],
    db_cluster_parameter_groups: [
      .[]
      | select(.address == $cluster_addr)
      | .values.name
    ]
  }
' "$STATE_RESOURCES_FILE")"
  array_from_newline_text OLD_DB_PARAMETER_GROUP_NAMES "$(jq -r '.db_parameter_groups[]?' <<<"$OLD_PARAMETER_GROUPS_JSON")"
  array_from_newline_text OLD_DB_CLUSTER_PARAMETER_GROUP_NAMES "$(jq -r '.db_cluster_parameter_groups[]?' <<<"$OLD_PARAMETER_GROUPS_JSON")"

  OLD_DB_SUBNET_GROUPS_JSON="$(jq -c --arg prefix "${MODULE_ADDRESS}.module.rds.aws_db_subnet_group." '
  [
    .[]
    | select(.address | startswith($prefix))
    | .values.name
  ]
' "$STATE_RESOURCES_FILE")"
  array_from_newline_text OLD_DB_SUBNET_GROUP_NAMES "$(jq -r '.[]?' <<<"$OLD_DB_SUBNET_GROUPS_JSON")"

  collect_state_addresses_for_removal
  STATE_REMOVE_ADDRESSES_JSON="$(printf '%s\n' "${STATE_REMOVE_ADDRESSES[@]}" | json_array_from_lines)"
  write_manifest

  log "artifact directory: $ARTIFACT_DIR"
  log "module address: $MODULE_ADDRESS"
  log "current cluster identifier: $CURRENT_CLUSTER_IDENTIFIER"
  log "restored cluster name: $RESTORED_NAME"
  log "source snapshot id: $SOURCE_SNAPSHOT_ID"
  log "copied snapshot id: $COPIED_SNAPSHOT_ID"
  if [[ "$SKIP_OLD_FINAL_SNAPSHOT" != "true" ]]; then
    log "old final snapshot id: $OLD_FINAL_SNAPSHOT_ID"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would update ${CONFIG_FILE} in kms-bootstrap mode"
  else
    update_rds_config_file "$CONFIG_FILE" "kms-bootstrap"
    copy_file "$CONFIG_FILE" "$ARTIFACT_DIR/$(basename "$CONFIG_FILE").after-kms-bootstrap"
    terraform fmt "$CONFIG_FILE" >/dev/null
  fi

  if [[ -n "$TARGET_STORAGE_KMS_ALIAS" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log "dry run: would target apply ${MODULE_ADDRESS}.aws_kms_key.rds_storage[0] and ${MODULE_ADDRESS}.aws_kms_alias.rds_storage[0]"
    else
      terraform_apply_storage_kms_only
      load_state_snapshot
      resolve_target_storage_kms_id
    fi
  else
    resolve_target_storage_kms_id
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would create source snapshot ${SOURCE_SNAPSHOT_ID}"
    if [[ -n "$TARGET_STORAGE_KMS_KEY_ARN" ]]; then
      log "dry run: would create encrypted snapshot copy ${COPIED_SNAPSHOT_ID} with ${TARGET_STORAGE_KMS_KEY_ARN}"
    else
      log "dry run: would create encrypted snapshot copy ${COPIED_SNAPSHOT_ID} with the created storage CMK resolved from Terraform state"
    fi
  else
    create_source_snapshot
    copy_snapshot_with_target_kms
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would update ${CONFIG_FILE} in restore mode"
    if [[ "$INCLUDE_PERFORMANCE_INSIGHTS" == "true" ]]; then
      log "dry run: would also enable Performance Insights CMK configuration during restore"
      if [[ -n "$PERFORMANCE_INSIGHTS_KMS_ALIAS" ]]; then
        log "dry run: would set observability.kms.kms_alias to ${PERFORMANCE_INSIGHTS_KMS_ALIAS}"
      fi
    fi
  else
    update_rds_config_file "$CONFIG_FILE" "restore"
    copy_file "$CONFIG_FILE" "$ARTIFACT_DIR/$(basename "$CONFIG_FILE").after-restore"
    terraform fmt "$CONFIG_FILE" >/dev/null
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would remove these Terraform addresses from state:"
    printf '%s\n' "${STATE_REMOVE_ADDRESSES[@]}" >&2
  else
    remove_old_rds_state
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would run a targeted terraform apply for ${MODULE_ADDRESS} to restore the new Aurora cluster from ${COPIED_SNAPSHOT_ID}"
  else
    terraform_apply_byo_vpc_only
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would run a second targeted terraform apply for ${MODULE_ADDRESS} to reconcile any post-restore in-place updates before cleanup"
  else
    terraform_reconcile_restored_byo_vpc
  fi
else
  log "artifact directory: $ARTIFACT_DIR"
  load_cleanup_manifest
  log "cleanup-only mode using manifest: $MANIFEST_FILE"
  log "current cluster identifier: $CURRENT_CLUSTER_IDENTIFIER"
  if [[ "$SKIP_OLD_FINAL_SNAPSHOT" != "true" && -n "$OLD_FINAL_SNAPSHOT_ID" ]]; then
    log "old final snapshot id: $OLD_FINAL_SNAPSHOT_ID"
  fi
fi

delete_old_cluster_resources

if [[ "$CLEANUP_ONLY" == "true" ]]; then
  log "cleanup-only mode complete"
elif [[ "$DRY_RUN" == "true" ]]; then
  log "dry run: would run a full terraform apply after the restored cluster is in place"
else
  log "running final full terraform apply after the restored cluster is in place"
  terraform_cmd apply -auto-approve
fi

if [[ "$CLEANUP_ONLY" == "true" ]]; then
  log "cleanup complete"
else
  log "migration complete"
  log "caller config now points at the restored cluster and keeps snapshot_identifier pinned to ${COPIED_SNAPSHOT_ID}"
  log "artifacts saved under ${ARTIFACT_DIR}"
fi
