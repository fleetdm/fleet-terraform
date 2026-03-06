#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  start-batch-replication-migration.sh --source-bucket BUCKET [options]
  start-batch-replication-migration.sh --cleanup-role --source-bucket BUCKET [options]

Submits an S3 Batch Operations job that re-encrypts existing ALB log objects
in-place from SSE-S3 to SSE-KMS using S3PutObjectCopy.

The KMS key is automatically detected by deriving a prefix from the bucket
name (stripping the -alb-logs suffix) and looking up a KMS alias matching
alias/<prefix>-logs. Use --kms-key-arn to override.

Required:
  --source-bucket BUCKET         Bucket containing ALB logs.

Optional:
  --kms-key-arn ARN              KMS key ARN override. By default the key is
                                 resolved from a KMS alias derived from the
                                 bucket name (see above).
  --account-id ID                AWS account ID. Defaults to the current caller account.
  --region REGION                Source bucket region. Defaults to the source bucket location.
  --report-bucket BUCKET         Bucket for the manifest and completion report.
                                 Defaults to the source bucket.
  --report-prefix PREFIX         Prefix for manifest and reports.
                                 Default: _batch-copy-migration/
  --report-kms-key-arn ARN       KMS key for the report bucket if it uses SSE-KMS.
  --batch-role-arn ARN           Existing IAM role ARN for S3 Batch Operations.
  --batch-role-name NAME         IAM role name to create/update if --batch-role-arn is omitted.
  --prefix PREFIX                Only copy objects under this key prefix.
  --priority N                   Batch job priority. Default: 10
  --cleanup-role                 Delete the inline policy and (if script-created) the IAM role.

Examples:
  # In-place re-encryption (auto-detect KMS key from alias)
  ./scripts/start-batch-replication-migration.sh \
    --source-bucket fleet-alb-logs

  # Explicit KMS key override
  ./scripts/start-batch-replication-migration.sh \
    --source-bucket fleet-alb-logs \
    --kms-key-arn arn:aws:kms:us-east-1:123456789012:key/abcd-1234

  ./scripts/start-batch-replication-migration.sh \
    --cleanup-role \
    --source-bucket fleet-alb-logs
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

sanitize_role_name() {
  printf '%s' "$1" | tr -cs '[:alnum:]+=,.@_-' '-'
}

source_bucket=""
kms_key_arn=""
account_id=""
region=""
report_bucket=""
report_prefix="_batch-copy-migration/"
report_kms_key_arn=""
batch_role_arn=""
batch_role_name=""
prefix=""
priority="10"
cleanup_role="false"
managed_policy_name=""
role_provided_explicitly="false"

script_manager_tag_key="ManagedBy"
script_manager_tag_value="fleet-logging-alb-batch-copy-script"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-bucket)
      source_bucket="${2:?missing value for --source-bucket}"
      shift 2
      ;;
    --kms-key-arn)
      kms_key_arn="${2:?missing value for --kms-key-arn}"
      shift 2
      ;;
    --account-id)
      account_id="${2:?missing value for --account-id}"
      shift 2
      ;;
    --region)
      region="${2:?missing value for --region}"
      shift 2
      ;;
    --report-bucket)
      report_bucket="${2:?missing value for --report-bucket}"
      shift 2
      ;;
    --report-prefix)
      report_prefix="${2:?missing value for --report-prefix}"
      shift 2
      ;;
    --report-kms-key-arn)
      report_kms_key_arn="${2:?missing value for --report-kms-key-arn}"
      shift 2
      ;;
    --batch-role-arn)
      batch_role_arn="${2:?missing value for --batch-role-arn}"
      role_provided_explicitly="true"
      shift 2
      ;;
    --batch-role-name)
      batch_role_name="${2:?missing value for --batch-role-name}"
      role_provided_explicitly="true"
      shift 2
      ;;
    --prefix)
      prefix="${2:?missing value for --prefix}"
      shift 2
      ;;
    --priority)
      priority="${2:?missing value for --priority}"
      shift 2
      ;;
    --cleanup-role)
      cleanup_role="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$cleanup_role" != "true" ]]; then
  if [[ -z "$source_bucket" ]]; then
    echo "Error: --source-bucket is required." >&2
    usage
    exit 1
  fi
elif [[ -z "$source_bucket" && -z "$batch_role_name" && -z "$batch_role_arn" ]]; then
  echo "Error: --source-bucket or --batch-role-name/--batch-role-arn is required for --cleanup-role." >&2
  usage
  exit 1
fi

require_command aws
require_command jq
require_command uuidgen

if [[ -z "$account_id" ]]; then
  account_id="$(aws sts get-caller-identity --query 'Account' --output text)"
fi

if [[ -z "$region" && -n "$source_bucket" ]]; then
  region="$(aws s3api get-bucket-location --bucket "$source_bucket" --query 'LocationConstraint' --output text)"
  if [[ "$region" == "None" ]]; then
    region="us-east-1"
  fi
fi

if [[ -z "$report_bucket" ]]; then
  report_bucket="$source_bucket"
fi

# Auto-detect KMS key from KMS alias derived from bucket name
if [[ -z "$kms_key_arn" && -n "$source_bucket" ]]; then
  # Derive prefix by stripping -alb-logs suffix from the bucket name
  kms_prefix="${source_bucket%-alb-logs}"
  alias_prefix="alias/${kms_prefix}-logs"

  echo "Detecting KMS key from alias matching ${alias_prefix} ..."

  matching_aliases="$(aws kms list-aliases \
    --query "Aliases[?starts_with(AliasName, \`${alias_prefix}\`)].{AliasName:AliasName,TargetKeyId:TargetKeyId}" \
    --output json)"

  alias_count="$(echo "$matching_aliases" | jq 'length')"

  if [[ "$alias_count" -eq 1 ]]; then
    target_key_id="$(echo "$matching_aliases" | jq -r '.[0].TargetKeyId')"
    # Resolve full key ARN
    kms_key_arn="$(aws kms describe-key --key-id "$target_key_id" --query 'KeyMetadata.Arn' --output text)"
    echo "  Detected KMS key: ${kms_key_arn}"
  elif [[ "$alias_count" -eq 0 ]]; then
    echo "Error: no KMS alias found matching ${alias_prefix}." >&2
    echo "       Pass --kms-key-arn explicitly." >&2
    exit 1
  else
    echo "Error: found ${alias_count} KMS aliases matching ${alias_prefix}:" >&2
    echo "$matching_aliases" | jq -r '.[].AliasName' | sed 's/^/  /' >&2
    echo "       Pass --kms-key-arn explicitly to disambiguate." >&2
    exit 1
  fi
fi

if [[ -z "$batch_role_arn" ]]; then
  if [[ -z "$batch_role_name" ]]; then
    batch_role_name="$(sanitize_role_name "${source_bucket}-s3-batch-copy")"
  fi
  batch_role_arn="arn:aws:iam::${account_id}:role/${batch_role_name}"
elif [[ -z "$batch_role_name" ]]; then
  batch_role_name="${batch_role_arn##*/}"
fi

managed_policy_name="${batch_role_name}-inline"
role_created_by_script="$(
  aws iam list-role-tags \
    --role-name "$batch_role_name" \
    --query "Tags[?Key=='${script_manager_tag_key}' && Value=='${script_manager_tag_value}'] | length(@)" \
    --output text \
    2>/dev/null || true
)"

# ── Cleanup mode ──────────────────────────────────────────────────────────────

if [[ "$cleanup_role" == "true" ]]; then
  aws iam delete-role-policy \
    --role-name "$batch_role_name" \
    --policy-name "$managed_policy_name" \
    >/dev/null 2>&1 || true

  if [[ "$role_created_by_script" == "1" ]]; then
    aws iam delete-role \
      --role-name "$batch_role_name" \
      >/dev/null
    echo "Deleted IAM role ${batch_role_name} and inline policy ${managed_policy_name}."
  else
    echo "Deleted inline policy ${managed_policy_name} if present."
    echo "Skipped deleting role ${batch_role_name} because it was not tagged as created by this script."
  fi

  exit 0
fi

# ── Build manifest ────────────────────────────────────────────────────────────

source_bucket_arn="arn:aws:s3:::${source_bucket}"
report_bucket_arn="arn:aws:s3:::${report_bucket}"
client_request_token="$(uuidgen | tr '[:upper:]' '[:lower:]')"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Listing objects in s3://${source_bucket}/${prefix} ..."

manifest_file="${tmpdir}/manifest.csv"

# Paginate through all objects and build the CSV manifest
> "$manifest_file"
next_token=""
object_count=0
while true; do
  response="$(aws s3api list-objects-v2 --bucket "$source_bucket" \
    ${prefix:+--prefix "$prefix"} \
    --output json \
    ${next_token:+--starting-token "$next_token"})"

  # Extract keys from this page
  keys="$(echo "$response" | jq -r '.Contents[]?.Key // empty')"

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    echo "${source_bucket},${key}" >> "$manifest_file"
    object_count=$((object_count + 1))
  done <<< "$keys"

  next_token="$(echo "$response" | jq -r '.NextContinuationToken // empty')"

  if [[ -z "$next_token" ]]; then
    break
  fi
done

if [[ "$object_count" -eq 0 ]]; then
  echo "No objects found. Nothing to do."
  exit 0
fi

echo "Found ${object_count} objects. Objects already encrypted with SSE-KMS will be skipped by the batch job."

# Upload manifest to report bucket
manifest_key="${report_prefix}manifest-${client_request_token}.csv"
manifest_etag="$(aws s3api put-object \
  --bucket "$report_bucket" \
  --key "$manifest_key" \
  --body "$manifest_file" \
  ${report_kms_key_arn:+--server-side-encryption aws:kms --ssekms-key-id "$report_kms_key_arn"} \
  --query 'ETag' --output json)"

echo "Uploaded manifest to s3://${report_bucket}/${manifest_key}"

# Get manifest size in bytes
manifest_size="$(wc -c < "$manifest_file" | tr -d ' ')"

# ── Create / update IAM role ─────────────────────────────────────────────────

cat > "${tmpdir}/trust-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "s3.amazonaws.com",
          "batchoperations.s3.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

if ! aws iam get-role --role-name "$batch_role_name" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$batch_role_name" \
    --assume-role-policy-document "file://${tmpdir}/trust-policy.json" \
    --tags "Key=${script_manager_tag_key},Value=${script_manager_tag_value}" \
    >/dev/null
  role_created_by_script="1"
elif [[ "$role_created_by_script" == "1" || "$role_provided_explicitly" != "true" ]]; then
  aws iam update-assume-role-policy \
    --role-name "$batch_role_name" \
    --policy-document "file://${tmpdir}/trust-policy.json" \
    >/dev/null
fi

# Build the role policy — needs read + write on the bucket, KMS, and
# read on the manifest + write on reports.
kms_statements=""
if [[ -n "$kms_key_arn" ]]; then
  kms_statements=',
    {
      "Sid": "UseKmsKey",
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey"
      ],
      "Resource": "'"${kms_key_arn}"'"
    }'
fi

report_kms_statements=""
if [[ -n "$report_kms_key_arn" ]]; then
  report_kms_statements=',
    {
      "Sid": "UseReportBucketKmsKey",
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey"
      ],
      "Resource": "'"${report_kms_key_arn}"'"
    }'
fi

cat > "${tmpdir}/role-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadSourceBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "${source_bucket_arn}/*"
    },
    {
      "Sid": "WriteBucket",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject"
      ],
      "Resource": "${source_bucket_arn}/*"
    },
    {
      "Sid": "ReadManifest",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "${report_bucket_arn}/${report_prefix}*"
    },
    {
      "Sid": "WriteCompletionReports",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject"
      ],
      "Resource": "${report_bucket_arn}/${report_prefix}*"
    }${kms_statements}${report_kms_statements}
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$batch_role_name" \
  --policy-name "$managed_policy_name" \
  --policy-document "file://${tmpdir}/role-policy.json" \
  >/dev/null

aws iam wait role-exists --role-name "$batch_role_name"
echo "Waiting for IAM role propagation..."
sleep 10

# ── Submit batch job ──────────────────────────────────────────────────────────

cat > "${tmpdir}/operation.json" <<EOF
{
  "S3PutObjectCopy": {
    "TargetResource": "${source_bucket_arn}",
    "NewObjectMetadata": {
      "SSEAlgorithm": "KMS"
    },
    "SSEAwsKmsKeyId": "${kms_key_arn}",
    "MetadataDirective": "COPY",
    "BucketKeyEnabled": true
  }
}
EOF

cat > "${tmpdir}/manifest.json" <<EOF
{
  "Spec": {
    "Format": "S3BatchOperations_CSV_20180820",
    "Fields": ["Bucket", "Key"]
  },
  "Location": {
    "ObjectArn": "${report_bucket_arn}/${manifest_key}",
    "ETag": ${manifest_etag}
  }
}
EOF

cat > "${tmpdir}/report.json" <<EOF
{
  "Bucket": "${report_bucket_arn}",
  "Prefix": "${report_prefix}reports",
  "Format": "Report_CSV_20180820",
  "Enabled": true,
  "ReportScope": "FailedTasksOnly"
}
EOF

job_id="$(
  aws --region "$region" s3control create-job \
    --account-id "$account_id" \
    --operation "file://${tmpdir}/operation.json" \
    --manifest "file://${tmpdir}/manifest.json" \
    --report "file://${tmpdir}/report.json" \
    --priority "$priority" \
    --role-arn "$batch_role_arn" \
    --description "Re-encrypt objects in ${source_bucket} in-place with SSE-KMS" \
    --client-request-token "$client_request_token" \
    --no-confirmation-required \
    --query 'JobId' \
    --output text
)"

cat <<EOF
Created S3 Batch Operations re-encryption job.
  Job ID:              ${job_id}
  Region:              ${region}
  Bucket:              ${source_bucket}
  KMS key:             ${kms_key_arn}
  Objects in manifest: ${object_count}
  Report bucket:       ${report_bucket}
  Batch role:          ${batch_role_arn}

Check status with:
  aws --region ${region} s3control describe-job --account-id ${account_id} --job-id ${job_id}
EOF
