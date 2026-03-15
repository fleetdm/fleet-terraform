#!/usr/bin/env bash
set -euo pipefail

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

LOG_GROUP_NAME="${1:-}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
DELETE_OLD_STREAMS="${DELETE_OLD_STREAMS:-true}"

if [[ -z "$LOG_GROUP_NAME" || -z "$REGION" ]]; then
  echo "Usage: $0 <log-group-name> <region>" >&2
  echo "Example: $0 fleet-application-logs us-east-2" >&2
  echo "Example: $0 /aws/ecs/aws-ec2 us-east-2" >&2
  exit 1
fi

LOG_GROUP_JSON="$(aws logs describe-log-groups \
  --region "$REGION" \
  --log-group-name-prefix "$LOG_GROUP_NAME" \
  --output json)"

NEW_KMS_KEY_ARN="$(jq -r --arg lg "$LOG_GROUP_NAME" '
  .logGroups[]
  | select(.logGroupName == $lg)
  | .kmsKeyId // empty
' <<<"$LOG_GROUP_JSON")"

if [[ -z "$NEW_KMS_KEY_ARN" ]]; then
  echo "ERROR: log group not found or has no kmsKeyId: $LOG_GROUP_NAME" >&2
  exit 1
fi

CLOUDTRAIL_JSON='{"Events":[]}'
CLOUDTRAIL_NEXT_TOKEN=''
while :; do
  if [[ -n "$CLOUDTRAIL_NEXT_TOKEN" ]]; then
    CLOUDTRAIL_PAGE_JSON="$(aws cloudtrail lookup-events \
      --region "$REGION" \
      --lookup-attributes AttributeKey=EventName,AttributeValue=AssociateKmsKey \
      --starting-token "$CLOUDTRAIL_NEXT_TOKEN" \
      --output json)"
  else
    CLOUDTRAIL_PAGE_JSON="$(aws cloudtrail lookup-events \
      --region "$REGION" \
      --lookup-attributes AttributeKey=EventName,AttributeValue=AssociateKmsKey \
      --output json)"
  fi

  CLOUDTRAIL_JSON="$(jq -c --argjson page "$CLOUDTRAIL_PAGE_JSON" '
    {
      Events: ((.Events // []) + ($page.Events // []))
    }
  ' <<<"$CLOUDTRAIL_JSON")"

  CLOUDTRAIL_NEXT_TOKEN="$(jq -r '.NextToken // empty' <<<"$CLOUDTRAIL_PAGE_JSON")"
  if [[ -z "$CLOUDTRAIL_NEXT_TOKEN" ]]; then
    break
  fi
done

CUTOFF_ISO="$(jq -r --arg lg "$LOG_GROUP_NAME" --arg kms "$NEW_KMS_KEY_ARN" '
  [
    .Events[]
    | .CloudTrailEvent
    | fromjson
    | select((.requestParameters.logGroupName // "") == $lg)
    | select((.requestParameters.kmsKeyId // "") == $kms)
    | .eventTime
  ]
  | sort
  | last // empty
' <<<"$CLOUDTRAIL_JSON")"

if [[ -z "$CUTOFF_ISO" ]]; then
  echo "ERROR: could not find AssociateKmsKey event for log group=$LOG_GROUP_NAME and key=$NEW_KMS_KEY_ARN" >&2
  echo "CloudTrail retention may be too short for this migration check." >&2
  exit 1
fi

CUTOFF_MS="$(jq -nr --arg t "$CUTOFF_ISO" '($t | fromdateiso8601 * 1000 | floor)')"

# Explicit pagination to ensure all streams are processed.
ALL_STREAMS_JSON='[]'
NEXT_TOKEN=''
while :; do
  if [[ -n "$NEXT_TOKEN" ]]; then
    STREAMS_PAGE_JSON="$(aws logs describe-log-streams \
      --region "$REGION" \
      --log-group-name "$LOG_GROUP_NAME" \
      --next-token "$NEXT_TOKEN" \
      --output json)"
  else
    STREAMS_PAGE_JSON="$(aws logs describe-log-streams \
      --region "$REGION" \
      --log-group-name "$LOG_GROUP_NAME" \
      --output json)"
  fi

  PAGE_STREAMS_JSON="$(jq '.logStreams // []' <<<"$STREAMS_PAGE_JSON")"
  ALL_STREAMS_JSON="$(jq -c --argjson page "$PAGE_STREAMS_JSON" '. + $page' <<<"$ALL_STREAMS_JSON")"

  NEXT_TOKEN="$(jq -r '.nextToken // empty' <<<"$STREAMS_PAGE_JSON")"
  if [[ -z "$NEXT_TOKEN" ]]; then
    break
  fi
done

OLD_STREAMS_JSON="$(jq --argjson cutoff "$CUTOFF_MS" '
  [
    .[]
    | select((.creationTime // 0) > 0)
    | select(.creationTime < $cutoff)
    | {
        logStreamName,
        creationTime,
        lastEventTimestamp
      }
  ]
' <<<"$ALL_STREAMS_JSON")"

OLD_COUNT="$(jq 'length' <<<"$OLD_STREAMS_JSON")"

echo "region:            $REGION"
echo "log_group_name:    $LOG_GROUP_NAME"
echo "new_kms_key_arn:   $NEW_KMS_KEY_ARN"
echo "associate_kms_at:  $CUTOFF_ISO"
echo "old_stream_count:  $OLD_COUNT"
echo
echo "Streams created before associate_kms_at (creationTime < associate_kms_at):"
jq '.' <<<"$OLD_STREAMS_JSON"
echo

if [[ "$OLD_COUNT" -eq 0 ]]; then
  echo "No old streams detected."
  exit 0
fi

if [[ "$DELETE_OLD_STREAMS" != "true" ]]; then
  echo "Dry run only. Set DELETE_OLD_STREAMS=true to delete old streams."
  exit 0
fi

echo "Deleting old streams..."
jq -r '.[].logStreamName' <<<"$OLD_STREAMS_JSON" | while IFS= read -r stream; do
  aws logs delete-log-stream \
    --region "$REGION" \
    --log-group-name "$LOG_GROUP_NAME" \
    --log-stream-name "$stream"
  echo "deleted: $stream"
done

echo "Done."
