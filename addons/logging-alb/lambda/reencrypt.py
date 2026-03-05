"""Lambda that re-encrypts newly created S3 objects in-place from SSE-S3 to SSE-KMS."""

import os
import urllib.parse

import boto3

s3 = boto3.client("s3")

KMS_KEY_ARN = os.environ["KMS_KEY_ARN"]


def handler(event, context):
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        # Safety belt: skip if already encrypted with KMS
        head = s3.head_object(Bucket=bucket, Key=key)
        if head.get("ServerSideEncryption") == "aws:kms":
            print(f"Skipping {key}: already SSE-KMS")
            continue

        s3.copy_object(
            Bucket=bucket,
            Key=key,
            CopySource={"Bucket": bucket, "Key": key},
            ServerSideEncryption="aws:kms",
            SSEKMSKeyId=KMS_KEY_ARN,
            BucketKeyEnabled=True,
            MetadataDirective="REPLACE",
            Metadata=head.get("Metadata", {}),
        )
        print(f"Re-encrypted {key} to SSE-KMS")
