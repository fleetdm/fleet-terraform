// Athena views, created natively as Glue VIRTUAL_VIEW tables. An Athena view is a Glue table whose
// definition is a base64-encoded document in view_original_text, so Terraform can manage one
// directly -- no compute, no invocation-on-apply, and terraform destroy removes them cleanly.
//
// The catch with declaring views this way is that a view carries its output schema in two spellings:
// Trino types inside the encoded definition, and Hive types in the storage descriptor. If either
// disagrees with what the SQL actually produces, the failure surfaces at query time for the
// consumer rather than at apply time here. So each view is defined by ONE projection list holding
// the SQL expression alongside both type spellings, and the SELECT text and both schemas are all
// generated from it. They cannot drift.
//
// Every projection is explicitly CAST where the result type would otherwise be inferred -- a bare
// 'event' literal is varchar(5), not varchar, and UNION ALL of differently-sized varchars coerces to
// the widest. Casting makes the declared type exact.
//
// The three views over result logs read only from the result-log table, the status view only from
// the status table, and the audit view only from the audit table. Nothing is unioned or joined
// across the three log sources.

locals {
  view_names = {
    results      = "${var.table_prefix}osquery_results"
    snapshots    = "${var.table_prefix}osquery_snapshots"
    differential = "${var.table_prefix}osquery_differential"
    status       = "${var.table_prefix}osquery_status"
    audit        = "${var.table_prefix}fleet_audit"
  }

  results_enabled = contains(keys(local.enabled_sources), "osquery_results")
  status_enabled  = contains(keys(local.enabled_sources), "osquery_status")
  audit_enabled   = contains(keys(local.enabled_sources), "fleet_audit")

  quoted_database = "\"${local.database_name}\""

  # Partition columns pass through unchanged into every view so consumers can still write a
  # partition predicate. A view that hides them turns every query into a full-bucket scan.
  # Quoted because `hour` is a keyword in Trino's grammar. Every generated identifier is quoted for
  # the same reason -- an osquery-derived or partition column name should never collide with SQL.
  partition_projection = [
    for c in local.partition_columns : {
      name    = c
      expr    = "\"${c}\""
      trino   = "varchar"
      hive    = "string"
      comment = "Firehose delivery partition. ARRIVAL time, not event time."
    }
  ]

  # Projected as decoration_<key>: decoration keys can collide with real osquery column names, and
  # `hostname` is both a common decorator and an actual column in several osquery tables. element_at
  # rather than subscript, so a key this environment does not emit yields NULL instead of raising
  # "Key not present in map".
  decoration_projection = [
    for k in var.decoration_columns : {
      name    = "decoration_${lower(k)}"
      expr    = "element_at(decorations, '${k}')"
      trino   = "varchar"
      hive    = "string"
      comment = "Decoration '${k}'. NULL when this environment does not emit it."
    }
  ]
}

# ── osquery results ──────────────────────────────────────────────────────────

locals {
  # Columns each union branch carries straight out of the raw table.
  results_branch_passthrough = [
    for c in concat(local.partition_columns, [
      "name",
      "hostidentifier",
      "calendartime",
      "unixtime",
      "epoch",
      "counter",
      "numerics",
      "decorations",
    ]) : "\"${c}\""
  ]

  # osquery delivers result logs in four wire shapes depending on agent options, and which one
  # arrives can differ between hosts in the same fleet. Only the serialisation is normalised here:
  # `action` keeps the snapshot-vs-differential semantics verbatim, and `result_format` records the
  # shape each row arrived in.
  results_union_branches = [
    {
      comment      = "Event format: one result row per record. Differentials (action = added | removed), plus snapshots when --logger_snapshot_event_type = true (action = snapshot)."
      action       = "action"
      format       = "event"
      row_columns  = "columns"
      row_num      = "CAST(NULL AS bigint)"
      row_count    = "CAST(NULL AS bigint)"
      join_clause  = ""
      where_clause = "WHERE columns IS NOT NULL"
    },
    {
      comment      = "Snapshot format: one record carries the complete result set for a query execution. WITH ORDINALITY preserves the delivered row order, and snapshot_row_count lets a consumer confirm the set arrived whole without a self-join."
      action       = "action"
      format       = "snapshot_array"
      row_columns  = "s"
      row_num      = "n"
      row_count    = "CAST(cardinality(snapshot) AS bigint)"
      join_clause  = "CROSS JOIN UNNEST(snapshot) WITH ORDINALITY AS t (s, n)"
      where_clause = "WHERE snapshot IS NOT NULL"
    },
    {
      comment      = "Batch format (log_result_events = false), added rows."
      action       = "CAST('added' AS varchar)"
      format       = "batch"
      row_columns  = "s"
      row_num      = "n"
      row_count    = "CAST(cardinality(diffresults.added) AS bigint)"
      join_clause  = "CROSS JOIN UNNEST(diffresults.added) WITH ORDINALITY AS t (s, n)"
      where_clause = ""
    },
    {
      comment      = "Batch format (log_result_events = false), removed rows."
      action       = "CAST('removed' AS varchar)"
      format       = "batch"
      row_columns  = "s"
      row_num      = "n"
      row_count    = "CAST(cardinality(diffresults.removed) AS bigint)"
      join_clause  = "CROSS JOIN UNNEST(diffresults.removed) WITH ORDINALITY AS t (s, n)"
      where_clause = ""
    },
  ]

  results_view_projection = concat(local.partition_projection, [
    {
      name    = "event_time"
      expr    = "CAST(from_unixtime(unixtime) AS timestamp(3))"
      trino   = "timestamp(3)"
      hive    = "timestamp"
      comment = "Authoritative event time, from unixTime. Filter on this, and widen the partition predicate by a day on each side."
    },
    {
      name    = "calendar_time"
      expr    = "calendartime"
      trino   = "varchar"
      hive    = "string"
      comment = "osquery's human-readable time string. Not ISO 8601; prefer event_time."
    },
    {
      name    = "query_path"
      expr    = "name"
      trino   = "varchar"
      hive    = "string"
      comment = "The raw osquery query name, pack<delim>{Global|team-<id>}<delim><query name>."
    },
    {
      name    = "pack_scope"
      expr    = "regexp_extract(name, '^pack${var.pack_delimiter}([^${var.pack_delimiter}]+)${var.pack_delimiter}', 1)"
      trino   = "varchar"
      hive    = "string"
      comment = "Global, or team-<team_id>."
    },
    {
      name    = "query_name"
      expr    = "regexp_replace(name, '^pack${var.pack_delimiter}[^${var.pack_delimiter}]+${var.pack_delimiter}', '')"
      trino   = "varchar"
      hive    = "string"
      comment = "Query name with the pack prefix stripped. Extracted by regex, not split, because a query name may itself contain the delimiter."
    },
    {
      name    = "team_id"
      expr    = "TRY_CAST(regexp_extract(name, '^pack${var.pack_delimiter}team-(\\d+)${var.pack_delimiter}', 1) AS integer)"
      trino   = "integer"
      hive    = "int"
      comment = "Team ID for team-scheduled queries; NULL for Global."
    },
    {
      name    = "host_identifier"
      expr    = "hostidentifier"
      trino   = "varchar"
      hive    = "string"
      comment = "Always populated, but its meaning follows the server's host identifier setting (uuid | instance | hostname | provided). Not necessarily a UUID."
    },
    {
      name    = "action"
      expr    = "action"
      trino   = "varchar"
      hive    = "string"
      comment = "added | removed | snapshot. The semantic distinction between change events and point-in-time state."
    },
    {
      name    = "result_format"
      expr    = "result_format"
      trino   = "varchar"
      hive    = "string"
      comment = "Wire shape this row arrived in: event | snapshot_array | batch. Provenance only; carries no analytic meaning."
    },
    {
      name    = "epoch"
      expr    = "epoch"
      trino   = "bigint"
      hive    = "bigint"
      comment = "osquery epoch counter, incremented when the results database is reset."
    },
    {
      name    = "counter"
      expr    = "counter"
      trino   = "bigint"
      hive    = "bigint"
      comment = "Per-query execution counter for this host."
    },
    {
      name    = "numerics"
      expr    = "numerics"
      trino   = "boolean"
      hive    = "boolean"
      comment = "Whether osquery emitted numeric values unquoted. False under Fleet's defaults."
    },
    {
      name    = "snapshot_row_num"
      expr    = "snapshot_row_num"
      trino   = "bigint"
      hive    = "bigint"
      comment = "Position within the delivered snapshot, 1-based. NULL for event-format rows."
    },
    {
      name    = "snapshot_row_count"
      expr    = "snapshot_row_count"
      trino   = "bigint"
      hive    = "bigint"
      comment = "Total rows in the delivered snapshot. NULL for event-format rows."
    },
    {
      name    = "row_columns"
      expr    = "row_columns"
      trino   = "map(varchar, varchar)"
      hive    = "map<string,string>"
      comment = "The result row. Read with element_at(row_columns, 'col') -- subscript raises \"Key not present in map\" for rows from a query lacking that column."
    },
    {
      name    = "row_columns_json"
      expr    = "json_format(CAST(row_columns AS JSON))"
      trino   = "varchar"
      hive    = "string"
      comment = "row_columns as JSON text, for clients that cannot read a map over JDBC/ODBC."
    },
    {
      name    = "decorations"
      expr    = "decorations"
      trino   = "map(varchar, varchar)"
      hive    = "map<string,string>"
      comment = "Deployment-defined decorator output. Keys vary per environment; may be absent entirely."
    },
    {
      name    = "decorations_json"
      expr    = "json_format(CAST(decorations AS JSON))"
      trino   = "varchar"
      hive    = "string"
      comment = "decorations as JSON text, for clients that cannot read a map over JDBC/ODBC."
    },
  ], local.decoration_projection)

  results_branch_sql = [
    for b in local.results_union_branches : join("\n", concat(
      ["  -- ${b.comment}"],
      ["  SELECT"],
      [for c in local.results_branch_passthrough : "    ${c},"],
      [
        "    ${b.action} AS \"action\",",
        "    CAST('${b.format}' AS varchar) AS \"result_format\",",
        "    ${b.row_columns} AS \"row_columns\",",
        "    ${b.row_num} AS \"snapshot_row_num\",",
        "    ${b.row_count} AS \"snapshot_row_count\"",
        "  FROM ${local.quoted_database}.\"${local.raw_table_names.results}\"",
      ],
      b.join_clause == "" ? [] : ["  ${b.join_clause}"],
      b.where_clause == "" ? [] : ["  ${b.where_clause}"],
    ))
  ]

  results_view_sql = join("\n", [
    "WITH shaped AS (",
    join("\n\n  UNION ALL\n\n", local.results_branch_sql),
    ")",
    "SELECT",
    join(",\n", [for c in local.results_view_projection : "  ${c.expr} AS \"${c.name}\""]),
    "FROM shaped",
  ])

  # The snapshot and differential views select from the results view, so their output schema is the
  # results projection with every expression reduced to a plain column reference.
  derived_view_projection = [
    for c in local.results_view_projection : {
      name    = c.name
      expr    = "\"${c.name}\""
      trino   = c.trino
      hive    = c.hive
      comment = c.comment
    }
  ]

  snapshots_view_sql = join("\n", [
    "SELECT",
    join(",\n", [for c in local.derived_view_projection : "  \"${c.name}\""]),
    "FROM ${local.quoted_database}.\"${local.view_names.results}\"",
    "WHERE action = 'snapshot'",
  ])

  differential_view_sql = join("\n", [
    "SELECT",
    join(",\n", [for c in local.derived_view_projection : "  \"${c.name}\""]),
    "FROM ${local.quoted_database}.\"${local.view_names.results}\"",
    "WHERE action IN ('added', 'removed')",
  ])
}

# ── osquery status ───────────────────────────────────────────────────────────

locals {
  status_view_projection = concat(local.partition_projection, [
    {
      name    = "event_time"
      expr    = "CAST(from_unixtime(TRY_CAST(NULLIF(unixtime, '') AS bigint)) AS timestamp(3))"
      trino   = "timestamp(3)"
      hive    = "timestamp"
      comment = "Event time. NULL when the osquery version in use omits unixTime from status logs."
    },
    {
      name    = "calendar_time"
      expr    = "calendartime"
      trino   = "varchar"
      hive    = "string"
      comment = "osquery's human-readable time string. May be absent depending on osquery version."
    },
    {
      name    = "severity"
      expr    = "TRY_CAST(NULLIF(severity, '') AS integer)"
      trino   = "integer"
      hive    = "int"
      comment = "glog severity: 0 = INFO, 1 = WARNING, 2 = ERROR. Arrives as a quoted string."
    },
    {
      name    = "severity_label"
      expr    = "CAST(CASE TRY_CAST(NULLIF(severity, '') AS integer) WHEN 0 THEN 'INFO' WHEN 1 THEN 'WARNING' WHEN 2 THEN 'ERROR' ELSE NULL END AS varchar)"
      trino   = "varchar"
      hive    = "string"
      comment = "Human-readable severity."
    },
    {
      name    = "filename"
      expr    = "filename"
      trino   = "varchar"
      hive    = "string"
      comment = "osquery source file that emitted the line."
    },
    {
      name    = "line"
      expr    = "TRY_CAST(NULLIF(line, '') AS integer)"
      trino   = "integer"
      hive    = "int"
      comment = "Source line number. Arrives as a quoted string."
    },
    {
      name    = "message"
      expr    = "message"
      trino   = "varchar"
      hive    = "string"
      comment = "Log message."
    },
    {
      name    = "version"
      expr    = "version"
      trino   = "varchar"
      hive    = "string"
      comment = "osquery version."
    },
    {
      name    = "decorations"
      expr    = "decorations"
      trino   = "map(varchar, varchar)"
      hive    = "map<string,string>"
      comment = "Deployment-defined decorator output. The ONLY possible host correlation for status logs -- osquery does not include hostIdentifier in them and Fleet writes them through untouched."
    },
    {
      name    = "decorations_json"
      expr    = "json_format(CAST(decorations AS JSON))"
      trino   = "varchar"
      hive    = "string"
      comment = "decorations as JSON text, for clients that cannot read a map over JDBC/ODBC."
    },
  ], local.decoration_projection)

  status_view_sql = join("\n", [
    "SELECT",
    join(",\n", [for c in local.status_view_projection : "  ${c.expr} AS \"${c.name}\""]),
    "FROM ${local.quoted_database}.\"${local.raw_table_names.status}\"",
  ])
}

# ── Fleet audit ──────────────────────────────────────────────────────────────

locals {
  # `details` differs in shape per activity type, so it stays JSON text rather than being forced into
  # a schema. Most Activity fields are omitempty in Fleet, so absent fields read as NULL.
  audit_view_projection = concat(local.partition_projection, [
    {
      name = "created_at"
      # Converted through UTC explicitly: from_iso8601_timestamp returns a timestamp WITH time zone,
      # and casting that straight to timestamp(3) would resolve against the client's session zone.
      expr    = "CAST(from_iso8601_timestamp(json_extract_scalar(raw_json, '$.created_at')) AT TIME ZONE 'UTC' AS timestamp(3))"
      trino   = "timestamp(3)"
      hive    = "timestamp"
      comment = "Activity timestamp in UTC. Marshalled from a Go time.Time, RFC 3339 with optional fractional seconds."
    },
    {
      name    = "activity_id"
      expr    = "TRY_CAST(json_extract_scalar(raw_json, '$.id') AS bigint)"
      trino   = "bigint"
      hive    = "bigint"
      comment = "Fleet activity ID."
    },
    {
      name    = "activity_uuid"
      expr    = "json_extract_scalar(raw_json, '$.uuid')"
      trino   = "varchar"
      hive    = "string"
      comment = "Fleet activity UUID."
    },
    {
      name    = "activity_type"
      expr    = "json_extract_scalar(raw_json, '$.type')"
      trino   = "varchar"
      hive    = "string"
      comment = "Activity type, e.g. ran_script. Determines the shape of details_json."
    },
    {
      name    = "actor_id"
      expr    = "TRY_CAST(json_extract_scalar(raw_json, '$.actor_id') AS bigint)"
      trino   = "bigint"
      hive    = "bigint"
      comment = "Fleet user ID of the actor. NULL for Fleet-initiated activity."
    },
    {
      name    = "actor_full_name"
      expr    = "json_extract_scalar(raw_json, '$.actor_full_name')"
      trino   = "varchar"
      hive    = "string"
      comment = "Actor display name."
    },
    {
      name    = "actor_email"
      expr    = "json_extract_scalar(raw_json, '$.actor_email')"
      trino   = "varchar"
      hive    = "string"
      comment = "Actor email."
    },
    {
      name    = "actor_gravatar"
      expr    = "json_extract_scalar(raw_json, '$.actor_gravatar')"
      trino   = "varchar"
      hive    = "string"
      comment = "Actor gravatar URL."
    },
    {
      name    = "actor_api_only"
      expr    = "json_extract_scalar(raw_json, '$.actor_api_only') = 'true'"
      trino   = "boolean"
      hive    = "boolean"
      comment = "Whether the actor is an API-only user."
    },
    {
      name    = "fleet_initiated"
      expr    = "json_extract_scalar(raw_json, '$.fleet_initiated') = 'true'"
      trino   = "boolean"
      hive    = "boolean"
      comment = "Whether Fleet performed the action rather than a user."
    },
    {
      name    = "details_json"
      expr    = "json_format(json_extract(raw_json, '$.details'))"
      trino   = "varchar"
      hive    = "string"
      comment = "Activity details as JSON text. Shape depends on activity_type; extract with json_extract_scalar."
    },
    {
      name    = "raw_json"
      expr    = "raw_json"
      trino   = "varchar"
      hive    = "string"
      comment = "The complete record as delivered, for fields this view does not project."
    },
  ])

  audit_view_sql = join("\n", [
    "SELECT",
    join(",\n", [for c in local.audit_view_projection : "  ${c.expr} AS \"${c.name}\""]),
    "FROM ${local.quoted_database}.\"${local.raw_table_names.audit}\"",
  ])
}

# ── View resources ───────────────────────────────────────────────────────────

locals {
  view_definitions = merge(
    local.results_enabled ? {
      (local.view_names.results) = {
        description = "osquery result rows with all four osquery serialisations normalised. action distinguishes snapshot from differential; result_format records the wire shape."
        sql         = local.results_view_sql
        projection  = local.results_view_projection
      }
      (local.view_names.snapshots) = {
        description = "Point-in-time state rows only (action = snapshot). Kept separate from the differential view because mixing state with change rows makes aggregates meaningless."
        sql         = local.snapshots_view_sql
        projection  = local.derived_view_projection
      }
      (local.view_names.differential) = {
        description = "Change rows only (action = added | removed). Queries logging as differential_ignore_removals produce added rows only."
        sql         = local.differential_view_sql
        projection  = local.derived_view_projection
      }
    } : {},
    local.status_enabled ? {
      (local.view_names.status) = {
        description = "osquery status logs with severity, line, and timestamps typed. No host identifier exists in this data; correlation is only possible via decorations."
        sql         = local.status_view_sql
        projection  = local.status_view_projection
      }
    } : {},
    local.audit_enabled ? {
      (local.view_names.audit) = {
        description = "Fleet activity audit records with scalars typed and details left as JSON text."
        sql         = local.audit_view_sql
        projection  = local.audit_view_projection
      }
    } : {},
  )
}

resource "aws_glue_catalog_table" "views" {
  for_each = local.view_definitions

  name          = each.key
  database_name = aws_athena_database.fleet_logs.name
  table_type    = "VIRTUAL_VIEW"
  description   = each.value.description

  parameters = {
    presto_view = "true"
    comment     = "Presto View"
  }

  # An Athena view definition: the SELECT statement plus its output schema in Trino types, base64
  # encoded. Athena reads this, not the storage descriptor, when planning a query against the view.
  view_original_text = "/* Presto View: ${base64encode(jsonencode({
    originalSql = each.value.sql
    catalog     = "awsdatacatalog"
    schema      = aws_athena_database.fleet_logs.name
    columns     = [for c in each.value.projection : { name = c.name, type = c.trino }]
  }))} */"

  view_expanded_text = "/* Presto View */"

  # The same schema in Hive types, which is what metadata clients and the Glue console display.
  storage_descriptor {
    dynamic "columns" {
      for_each = each.value.projection
      content {
        name    = columns.value.name
        type    = columns.value.hive
        comment = columns.value.comment
      }
    }
  }

  depends_on = [
    aws_glue_catalog_table.osquery_results,
    aws_glue_catalog_table.osquery_status,
    aws_glue_catalog_table.fleet_audit,
  ]
}

# ── Example named queries ────────────────────────────────────────────────────

resource "aws_athena_named_query" "example_recent_results" {
  count = var.example_named_queries && local.results_enabled ? 1 : 0

  name        = "Example: recent result rows for one query"
  description = "Shows the partition-widening pattern required because Firehose partitions on arrival time, not event time."
  workgroup   = aws_athena_workgroup.fleet_logs.id
  database    = aws_athena_database.fleet_logs.name
  query       = <<-SQL
    -- Replace the query_name filter with one of your scheduled queries.
    -- dt is widened by a day on each side because Firehose partitions on record ARRIVAL time; an
    -- event near midnight can land in the neighbouring partition.
    SELECT
      event_time,
      host_identifier,
      query_name,
      action,
      row_columns
    FROM "${local.database_name}"."${local.view_names.results}"
    WHERE dt BETWEEN date_format(current_date - interval '2' day, '%Y-%m-%d')
                 AND date_format(current_date + interval '1' day, '%Y-%m-%d')
      AND event_time >= current_timestamp - interval '1' day
      AND query_name = 'REPLACE_ME'
    ORDER BY event_time DESC
    LIMIT 100;
  SQL
}

resource "aws_athena_named_query" "example_decoration_discovery" {
  count = var.example_named_queries && local.results_enabled ? 1 : 0

  name        = "Example: which decorations does this environment emit?"
  description = "Run this before choosing values for the addon's decoration_columns variable. Decorations are deployment-defined, so this module projects none by default."
  workgroup   = aws_athena_workgroup.fleet_logs.id
  database    = aws_athena_database.fleet_logs.name
  query       = <<-SQL
    SELECT
      kv.key AS decoration_key,
      count(*) AS records,
      count(DISTINCT kv.value) AS distinct_values
    FROM "${local.database_name}"."${local.view_names.results}"
    CROSS JOIN UNNEST(map_entries(decorations)) AS t (kv)
    WHERE dt >= date_format(current_date - interval '7' day, '%Y-%m-%d')
    GROUP BY kv.key
    ORDER BY records DESC;
  SQL
}

resource "aws_athena_named_query" "example_typed_query_view" {
  count = var.example_named_queries && local.results_enabled ? 1 : 0

  name        = "Template: typed per-query view"
  description = "Starting point for your own view over one scheduled query. Note element_at over subscript, and NULLIF before TRY_CAST because osquery emits empty strings rather than nulls."
  workgroup   = aws_athena_workgroup.fleet_logs.id
  database    = aws_athena_database.fleet_logs.name
  query       = <<-SQL
    CREATE OR REPLACE VIEW example_software_inventory AS
    SELECT
      dt,
      event_time,
      host_identifier,
      team_id,
      element_at(row_columns, 'name') AS software_name,
      element_at(row_columns, 'version') AS software_version,
      element_at(row_columns, 'source') AS source,
      TRY_CAST(NULLIF(element_at(row_columns, 'bundle_size'), '') AS bigint) AS bundle_size_bytes,
      element_at(row_columns, 'is_signed') = '1' AS is_signed,
      from_unixtime(TRY_CAST(NULLIF(element_at(row_columns, 'last_opened_at'), '') AS bigint)) AS last_opened_at
    FROM "${local.database_name}"."${local.view_names.snapshots}"
    WHERE query_name = 'REPLACE_ME';
  SQL
}
