"""Daily sweep Lambda that finds SSE-S3 objects and submits an S3 Batch Operations job to re-encrypt them."""

import csv
import io
import os
import uuid
from datetime import datetime, timedelta, timezone

import boto3

s3 = boto3.client("s3")
s3control = boto3.client("s3control")

BUCKET = os.environ["BUCKET"]
KMS_KEY_ARN = os.environ["KMS_KEY_ARN"]
LOG_PREFIX = os.environ["LOG_PREFIX"]
ACCOUNT_ID = os.environ["ACCOUNT_ID"]
REGION = os.environ["REGION"]
BATCH_ROLE_ARN = os.environ["BATCH_ROLE_ARN"]


def _build_prefixes():
    """Build ALB log prefixes for the last 2 days."""
    base = f"{LOG_PREFIX}/AWSLogs/{ACCOUNT_ID}/elasticloadbalancing/{REGION}"
    prefixes = []
    now = datetime.now(timezone.utc)
    for days_ago in range(2):
        d = now - timedelta(days=days_ago)
        prefixes.append(f"{base}/{d.strftime('%Y/%m/%d')}/")
    return prefixes


def _find_sse_s3_objects(prefixes):
    """List objects under the given prefixes and return keys still using SSE-S3."""
    sse_s3_keys = []
    for prefix in prefixes:
        paginator = s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=BUCKET, Prefix=prefix):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                head = s3.head_object(Bucket=BUCKET, Key=key)
                if head.get("ServerSideEncryption") != "aws:kms":
                    sse_s3_keys.append(key)
    return sse_s3_keys


def handler(event, context):
    prefixes = _build_prefixes()
    print(f"Scanning prefixes: {prefixes}")

    sse_s3_keys = _find_sse_s3_objects(prefixes)

    if not sse_s3_keys:
        print("No SSE-S3 objects found. Nothing to do.")
        return {"status": "no-op", "objects": 0}

    print(f"Found {len(sse_s3_keys)} SSE-S3 objects. Submitting batch job.")

    # Build CSV manifest
    manifest_buf = io.StringIO()
    writer = csv.writer(manifest_buf)
    for key in sse_s3_keys:
        writer.writerow([BUCKET, key])
    manifest_bytes = manifest_buf.getvalue().encode("utf-8")

    # Upload manifest
    token = str(uuid.uuid4())
    manifest_key = f"_sweep-reencrypt/manifest-{token}.csv"
    put_resp = s3.put_object(Bucket=BUCKET, Key=manifest_key, Body=manifest_bytes)
    manifest_etag = put_resp["ETag"]

    # Submit S3 Batch Operations job
    bucket_arn = f"arn:aws:s3:::{BUCKET}"
    job = s3control.create_job(
        AccountId=ACCOUNT_ID,
        Operation={
            "S3PutObjectCopy": {
                "TargetResource": bucket_arn,
                "NewObjectMetadata": {
                    "SSEAlgorithm": "KMS",
                },
                "SSEAwsKmsKeyId": KMS_KEY_ARN,
                "MetadataDirective": "COPY",
                "BucketKeyEnabled": True,
            }
        },
        Manifest={
            "Spec": {
                "Format": "S3BatchOperations_CSV_20180820",
                "Fields": ["Bucket", "Key"],
            },
            "Location": {
                "ObjectArn": f"{bucket_arn}/{manifest_key}",
                "ETag": manifest_etag,
            },
        },
        Report={
            "Bucket": bucket_arn,
            "Prefix": "_sweep-reencrypt/reports",
            "Format": "Report_CSV_20180820",
            "Enabled": True,
            "ReportScope": "FailedTasksOnly",
        },
        Priority=10,
        RoleArn=BATCH_ROLE_ARN,
        Description=f"Sweep re-encrypt {len(sse_s3_keys)} SSE-S3 objects",
        ClientRequestToken=token,
        ConfirmationRequired=False,
    )

    job_id = job["JobId"]
    print(f"Submitted batch job {job_id} for {len(sse_s3_keys)} objects")

    return {"status": "submitted", "jobId": job_id, "objects": len(sse_s3_keys)}
