// Optional read-only role for a third-party data modelling or BI application to assume as its
// Athena data connector. Athena writes query results with the caller's identity, so the role needs
// write access to the query-results bucket and its key -- but only read access to log data.

data "aws_iam_policy_document" "consumer_assume_role" {
  count = local.create_consumer_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.consumer_role.trusted_principals
    }

    dynamic "condition" {
      for_each = var.consumer_role.external_id != null ? [var.consumer_role.external_id] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [condition.value]
      }
    }
  }
}

data "aws_iam_policy_document" "consumer" {
  count = local.create_consumer_role ? 1 : 0

  statement {
    sid = "RunQueries"
    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetQueryResultsStream",
      "athena:GetWorkGroup",
      "athena:ListQueryExecutions",
      "athena:ListNamedQueries",
      "athena:GetNamedQuery",
      "athena:BatchGetNamedQuery",
      "athena:GetTableMetadata",
      "athena:ListTableMetadata",
      "athena:GetDatabase",
      "athena:ListDatabases",
    ]
    resources = [aws_athena_workgroup.fleet_logs.arn]
  }

  # Driver-level discovery calls that are not scoped to a workgroup.
  statement {
    sid = "DiscoverCatalogs"
    actions = [
      "athena:ListWorkGroups",
      "athena:ListDataCatalogs",
      "athena:ListEngineVersions",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ReadDataCatalog"
    actions = [
      "athena:GetDataCatalog",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:athena:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:datacatalog/AwsDataCatalog",
    ]
  }

  statement {
    sid = "ReadGlueMetadata"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:database/${aws_athena_database.fleet_logs.name}",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${aws_athena_database.fleet_logs.name}/*",
    ]
  }

  statement {
    sid = "ReadLogData"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:GetObject",
    ]
    resources = concat(
      local.source_bucket_arns,
      [for arn in local.source_bucket_arns : "${arn}/*"],
    )
  }

  statement {
    sid = "WriteQueryResults"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = [
      module.query_results_bucket.s3_bucket_arn,
      "${module.query_results_bucket.s3_bucket_arn}/*",
    ]
  }

  statement {
    sid = "UseQueryResultsKey"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [local.kms_key_arn]
  }

  # Only needed when the source log buckets are encrypted with a CMK. Grant the role usage on that
  # key too -- for logging-destination-firehose, pass this role's ARN through its kms_extra_policies.
  dynamic "statement" {
    for_each = length(var.source_kms_key_arns) > 0 ? [1] : []
    content {
      sid = "DecryptLogData"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      resources = var.source_kms_key_arns
    }
  }
}

resource "aws_iam_role" "consumer" {
  count = local.create_consumer_role ? 1 : 0

  name                 = local.consumer_role_name
  description          = "Read-only Athena access to Fleet log data for a third-party data modelling application."
  assume_role_policy   = data.aws_iam_policy_document.consumer_assume_role[0].json
  max_session_duration = coalesce(var.consumer_role.max_session_hours, 1) * 3600
}

resource "aws_iam_role_policy" "consumer" {
  count = local.create_consumer_role ? 1 : 0

  name_prefix = "${var.prefix}-athena-consumer-"
  role        = aws_iam_role.consumer[0].id
  policy      = data.aws_iam_policy_document.consumer[0].json
}

resource "aws_iam_role_policy_attachment" "consumer_extra" {
  for_each = local.create_consumer_role ? toset(coalesce(var.consumer_role.extra_policy_arns, [])) : toset([])

  role       = aws_iam_role.consumer[0].name
  policy_arn = each.value
}
