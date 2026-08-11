// Glue tables over the raw newline-delimited JSON that Fleet's Firehose logger writes. Fleet appends
// a newline to every record (server/logging/firehose.go) precisely because Firehose does not
// delimit records itself, so the objects are valid NDJSON and nothing has to transform them.
//
// These tables are deliberately shape-faithful: they describe what osquery and Fleet emit, with no
// normalisation. All normalisation lives in the views.

locals {
  # osquery result logs arrive in four shapes, all of which are represented here so no delivery is
  # silently dropped:
  #   - event/differential ...... top-level `columns`, action = added | removed
  #   - snapshot ................ top-level `snapshot` array, action = snapshot
  #   - snapshot-as-events ...... top-level `columns`, action = snapshot
  #                               (--logger_snapshot_event_type=true)
  #   - batch ................... top-level `diffResults` (log_result_events=false)
  osquery_results_columns = [
    {
      name    = "name"
      type    = "string"
      comment = "pack<delim>{Global|team-<id>}<delim><query name>. The query name may itself contain the delimiter."
    },
    {
      name    = "hostidentifier"
      type    = "string"
      comment = "The osquery host identifier. Always present in result logs, but its meaning is deployment-defined (uuid|instance|hostname|provided)."
    },
    {
      name    = "calendartime"
      type    = "string"
      comment = "Human-readable event time, e.g. 'Wed Jan 29 22:17:17 2025 UTC'. Not ISO 8601; prefer unixtime."
    },
    {
      name    = "unixtime"
      type    = "bigint"
      comment = "Authoritative event time, seconds since epoch."
    },
    {
      name    = "epoch"
      type    = "bigint"
      comment = "osquery epoch counter, incremented when the results database is reset."
    },
    {
      name    = "counter"
      type    = "bigint"
      comment = "Per-query execution counter for this host."
    },
    {
      name    = "numerics"
      type    = "boolean"
      comment = "Whether osquery emitted numeric column values unquoted. False under Fleet's defaults."
    },
    {
      name    = "decorations"
      type    = "map<string,string>"
      comment = "Deployment-defined decorator output. Keys vary per environment and the field may be absent entirely (disable_decorators)."
    },
    {
      name    = "action"
      type    = "string"
      comment = "added | removed | snapshot."
    },
    {
      name    = "columns"
      type    = "map<string,string>"
      comment = "One result row, event format. Null on snapshot-array and batch records."
    },
    {
      name    = "snapshot"
      type    = "array<map<string,string>>"
      comment = "A complete result set for one query execution, snapshot format. Null on event-format records."
    },
    {
      name    = "diffresults"
      type    = "struct<added:array<map<string,string>>,removed:array<map<string,string>>>"
      comment = "Batch format, emitted when log_result_events is false. Usually null."
    },
  ]

  # Status logs are written through untouched by Fleet (server/service/osquery.go SubmitStatusLogs),
  # so every field is a JSON string, including severity and line. There is no hostIdentifier: host
  # correlation for status logs is only possible via decorations.
  osquery_status_columns = [
    {
      name    = "severity"
      type    = "string"
      comment = "glog severity as a quoted string: 0 = INFO, 1 = WARNING, 2 = ERROR."
    },
    {
      name    = "filename"
      type    = "string"
      comment = "osquery source file that emitted the line."
    },
    {
      name    = "line"
      type    = "string"
      comment = "Source line number, as a quoted string."
    },
    {
      name    = "message"
      type    = "string"
      comment = "Log message."
    },
    {
      name    = "version"
      type    = "string"
      comment = "osquery version."
    },
    {
      name    = "decorations"
      type    = "map<string,string>"
      comment = "Deployment-defined decorator output. The ONLY available host correlation for status logs."
    },
    {
      name    = "calendartime"
      type    = "string"
      comment = "Human-readable event time. May be absent depending on osquery version."
    },
    {
      name    = "unixtime"
      type    = "string"
      comment = "Event time as a quoted string. May be absent depending on osquery version."
    },
  ]
}

resource "aws_glue_catalog_table" "osquery_results" {
  count = contains(keys(local.enabled_sources), "osquery_results") ? 1 : 0

  name          = local.raw_table_names.results
  database_name = aws_athena_database.fleet_logs.name
  table_type    = "EXTERNAL_TABLE"
  description   = "Raw osquery result logs as delivered by Firehose. Query the ${local.view_names.results} view instead unless you need the untouched record shapes."

  storage_descriptor {
    location      = "s3://${var.osquery_results.bucket_name}/${local.static_prefixes["osquery_results"]}"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "openx-json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters            = local.openx_serde_parameters
    }

    dynamic "columns" {
      for_each = local.osquery_results_columns
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }

  dynamic "partition_keys" {
    for_each = local.partition_keys
    content {
      name    = partition_keys.value.name
      type    = partition_keys.value.type
      comment = partition_keys.value.comment
    }
  }

  parameters = merge(local.projection_parameters, {
    "storage.location.template" = "s3://${var.osquery_results.bucket_name}/${local.static_prefixes["osquery_results"]}${local.location_partition_template}"
  })

  depends_on = [terraform_data.validate_source_prefixes]
}

resource "aws_glue_catalog_table" "osquery_status" {
  count = contains(keys(local.enabled_sources), "osquery_status") ? 1 : 0

  name          = local.raw_table_names.status
  database_name = aws_athena_database.fleet_logs.name
  table_type    = "EXTERNAL_TABLE"
  description   = "Raw osquery status logs as delivered by Firehose. Query the ${local.view_names.status} view instead."

  storage_descriptor {
    location      = "s3://${var.osquery_status.bucket_name}/${local.static_prefixes["osquery_status"]}"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "openx-json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters            = local.openx_serde_parameters
    }

    dynamic "columns" {
      for_each = local.osquery_status_columns
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }

  dynamic "partition_keys" {
    for_each = local.partition_keys
    content {
      name    = partition_keys.value.name
      type    = partition_keys.value.type
      comment = partition_keys.value.comment
    }
  }

  parameters = merge(local.projection_parameters, {
    "storage.location.template" = "s3://${var.osquery_status.bucket_name}/${local.static_prefixes["osquery_status"]}${local.location_partition_template}"
  })

  depends_on = [terraform_data.validate_source_prefixes]
}

# Fleet audit records are the marshalled Activity struct, whose `details` field is a raw JSON
# document with a different shape per activity type. Rather than force a schema onto it, this table
# exposes one column holding the whole record and the view extracts fields with json_extract_scalar.
# LazySimpleSerDe's default field delimiter is \001, which never occurs in JSON, so each line lands
# in raw_json intact.
resource "aws_glue_catalog_table" "fleet_audit" {
  count = contains(keys(local.enabled_sources), "fleet_audit") ? 1 : 0

  name          = local.raw_table_names.audit
  database_name = aws_athena_database.fleet_logs.name
  table_type    = "EXTERNAL_TABLE"
  description   = "Raw Fleet activity audit records, one JSON document per row. Query the ${local.view_names.audit} view instead."

  storage_descriptor {
    location      = "s3://${var.fleet_audit.bucket_name}/${local.static_prefixes["fleet_audit"]}"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "raw-line-serde"
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name    = "raw_json"
      type    = "string"
      comment = "The complete Fleet activity record as delivered. Extract fields with json_extract_scalar."
    }
  }

  dynamic "partition_keys" {
    for_each = local.partition_keys
    content {
      name    = partition_keys.value.name
      type    = partition_keys.value.type
      comment = partition_keys.value.comment
    }
  }

  parameters = merge(local.projection_parameters, {
    "storage.location.template" = "s3://${var.fleet_audit.bucket_name}/${local.static_prefixes["fleet_audit"]}${local.location_partition_template}"
  })

  depends_on = [terraform_data.validate_source_prefixes]
}
