resource "kubernetes_deployment" "fleet" {
    /* 
        if local.jobmigration = true
        don't run this block
        if local.jobmigration = false
        run this block 
    */
    metadata {
        name = "fleet"
        namespace = data.kubernetes_namespace.fleet.metadata[0].name
        labels = {
            app = "fleet"
        }
    }

    spec {
        replicas = local.replicas
        
        selector {
            match_labels = {
                app = "fleet"
            }
        }

        strategy {
            type = "RollingUpdate"
            rolling_update {
                max_unavailable = "25%"
                max_surge = "25%"
            }
        }

        template {
            metadata {
                labels = {
                    app = "fleet"
                }
                annotations = local.pod_annotations
            }
            
            spec {
                service_account_name = resource.kubernetes_service_account.fleet-sa.metadata[0].name
                container {
                    name = "fleet"
                    image = "${local.image_repository}:${local.image_tag}"

                    command = ["/usr/bin/fleet"]
                    args = ["serve"]

                    dynamic "env" {
                        for_each = [ 
                            { name = "FLEET_VULNERABILITIES_DATABASES_PATH", value = "/tmp/vuln" },
                            { name = "FLEET_SERVER_ADDRESS", value = "0.0.0.0:${local.fleet.listen_port}" },
                            { name = "FLEET_AUTH_BCRYPT_COST", value = local.fleet.auth.b_crypto_cost },
                            { name = "FLEET_AUTH_SALT_KEY_SIZE", value = local.fleet.auth.salt_key_size },
                            { name = "FLEET_APP_TOKEN_KEY_SIZE", value = local.fleet.app.token_key_size },
                            { name = "FLEET_APP_TOKEN_VALIDITY_PERIOD", value = local.fleet.app.invite_token_validity_period },
                            { name = "FLEET_SESSION_KEY_SIZE", value = local.fleet.session.key_size },
                            { name = "FLEET_SESSION_DURATION", value = local.fleet.session.duration },
                            { name = "FLEET_LOGGING_DEBUG", value = local.fleet.logging.debug },
                            { name = "FLEET_LOGGING_JSON", value = local.fleet.logging.json },
                            { name = "FLEET_LOGGING_DISABLE_BANNER", value = local.fleet.logging.disable_banner },
                            { name = "FLEET_SERVER_TLS", value = local.fleet.tls.enabled }
                        ]

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.fleet.tls.enabled ? [ 
                            { name = "FLEET_SERVER_TLS_COMPATIBILITY", value = local.fleet.tls.compatibility },
                            { name = "FLEET_SERVER_CERT", value = local.fleet.tls.cert_secret_key },
                            { name = "FLEET_SERVER_KEY", value = local.fleet.tls.key_secret_key }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.fleet.carving.s3.bucket_name != "" ? [ 
                            { name = "FLEET_S3_BUCKET", value = local.fleet.carving.s3.bucket_name },
                            { name = "FLEET_S3_PREFIX", value = local.fleet.carving.s3.prefix }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.fleet.carving.s3.access_key_id != "" ? [ 
                            { 
                                name = "FLEET_S3_SECRET_ACCESS_KEY", 
                                value_from = {
                                    secret_key_ref = {
                                        name = local.fleet.secret_name
                                        key =  local.fleet.carving.s3.secret_key
                                    }
                                }
                            }
                        ] : []

                        content {
                            name = env.value.name
                            value_from {
                                secret_key_ref {
                                    name = env.value.value_from.secret_key_ref.name
                                    key = env.value.value_from.secret_key_ref.key
                                }
                            }
                        }
                    }

                    dynamic "env" {
                        for_each = local.fleet.carving.s3.access_key_id == "" ? [ 
                            { name = "FLEET_S3_STS_ASSUME_ROLE_ARN", value = local.fleet.carving.s3.secret_key }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.fleet.license.secret_name != "" ? [
                            { 
                                name = "FLEET_LICENSE_KEY", 
                                value_from = {
                                    secret_key_ref = {
                                        name = local.fleet.license.secret_name
                                        key =  local.fleet.license.license_key
                                    }
                                }
                            }
                        ] : []

                        content {
                            name = env.value.name
                            value_from {
                                secret_key_ref {
                                    name = env.value.value_from.secret_key_ref.name
                                    key = env.value.value_from.secret_key_ref.key
                                }
                            }
                        }
                    }

                    dynamic "env" {
                        for_each = [ 
                            { name = "FLEET_MYSQL_ADDRESS", value = local.database.address },
                            { name = "FLEET_MYSQL_DATABASE", value = local.database.database },
                            { name = "FLEET_MYSQL_USERNAME", value = local.database.username },
                            { name = "FLEET_MYSQL_MAX_OPEN_CONNS", value = local.database.max_open_conns },
                            { name = "FLEET_MYSQL_MAX_IDLE_CONNS", value = local.database.max_idle_conns },
                            { name = "FLEET_MYSQL_CONN_MAX_LIFETIME", value = local.database.conn_max_lifetime }
                        ]

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    env {
                        name = "FLEET_MYSQL_PASSWORD"
                        value_from {
                            secret_key_ref {
                                name = local.database.secret_name
                                key = local.database.password_key
                            }
                        }
                    }

                    dynamic "env" {
                        for_each = local.database.tls.enabled ? [
                            { name = "FLEET_MYSQL_TLS_CA", value = "/secrets/mysql/${local.database.tls.ca_cert_key}" },
                            { name = "FLEET_MYSQL_TLS_CERT", value = "/secrets/mysql/${local.database.tls.cert_secret_key}" },
                            { name = "FLEET_MYSQL_TLS_KEY", value = "/secrets/mysql/${local.database.tls.key_key}" },
                            { name = "FLEET_MYSQL_TLS_CONFIG", value = local.database.tls.config },
                            { name = "FLEET_MYSQL_TLS_SERVER_NAME", value = local.database.tls.server_name }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = [ 
                            { name = "FLEET_REDIS_ADDRESS", value = local.cache.address },
                            { name = "FLEET_REDIS_DATABASE", value = local.cache.database }
                        ]

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.cache.use_password ? [
                            { 
                                name = "FLEET_REDIS_PASSWORD", 
                                value_from = {
                                    secret_key_ref = {
                                        name = local.cache.secret_name
                                        key =  local.cache.password_key
                                    }
                                }
                            }
                        ] : []

                        content {
                            name = env.value.name
                            value_from {
                                secret_key_ref {
                                    name = env.value.value_from.secret_key_ref.name
                                    key = env.value.value_from.secret_key_ref.key
                                }
                            }
                        }
                    }

                    dynamic "env" {
                        for_each = [ 
                            { name = "FLEET_OSQUERY_NODE_KEY_SIZE", value = local.osquery.node_key_size },
                            { name = "FLEET_OSQUERY_LABEL_UPDATE_INTERVAL", value = local.osquery.label_update_interval },
                            { name = "FLEET_OSQUERY_DETAIL_UPDATE_INTERVAL", value = local.osquery.detail_update_interval },
                            { name = "FLEET_OSQUERY_STATUS_LOG_PLUGIN", value = local.osquery.logging.status_plugin },
                            { name = "FLEET_OSQUERY_RESULT_LOG_PLUGIN", value = local.osquery.logging.result_plugin }
                        ]

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin == "filesystem" ? [ 
                            { name = "FLEET_FILESYSTEM_STATUS_LOG_FILE", value = "/logs/${local.osquery.logging.filesystem.status_log_file}" }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.result_plugin == "filesystem" ? [ 
                            { name = "FLEET_FILESYSTEM_RESULT_LOG_FILE", value = "/logs/${local.osquery.logging.filesystem.result_log_file}" }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin  == "filesystem" || local.osquery.logging.result_plugin  == "filesystem" ? [ 
                            { name = "FLEET_FILESYSTEM_ENABLE_LOG_ROTATION", value = local.osquery.logging.filesystem.enable_rotation },
                            { name = "FLEET_FILESYSTEM_ENABLE_LOG_COMPRESSION", value = local.osquery.logging.filesystem.enable_compression }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin == "firehose" || local.osquery.logging.result_plugin  == "firehose" ? [ 
                            { name = "FLEET_FIREHOSE_REGION", value = local.osquery.logging.firehose.region }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin == "firehose" ? [ 
                            { name = "FLEET_FIREHOSE_STATUS_STREAM", value = local.osquery.logging.firehose.status_stream }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.result_plugin == "firehose" ? [ 
                            { name = "FLEET_FIREHOSE_RESULT_STREAM", value = local.osquery.logging.firehose.result_stream }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.firehose.access_key_id != "" ? [
                            { 
                                name = "FLEET_FIREHOSE_SECRET_ACCESS_KEY", 
                                value_from = {
                                    secret_key_ref = {
                                        name = local.osquery.secret_name
                                        key =  local.osquery.logging.firehose.secret_key
                                    }
                                }
                            }
                        ] : []

                        content {
                            name = env.value.name
                            value_from {
                                secret_key_ref {
                                    name = env.value.value_from.secret_key_ref.name
                                    key = env.value.value_from.secret_key_ref.key
                                }
                            }
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.firehose.access_key_id == "" ? [ 
                            { name = "FLEET_FIREHOSE_STS_ASSUME_ROLE_ARN", value = local.osquery.logging.firehose.sts_assume_role_arn }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin == "kinesis" || local.osquery.logging.result_plugin  == "kinesis" ? [ 
                            { name = "FLEET_KINESIS_REGION", value = local.osquery.logging.kinesis.region }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin  == "kinesis" ? [ 
                            { name = "FLEET_KINESIS_STATUS_STREAM", value = local.osquery.logging.kinesis.status_stream }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.result_plugin  == "kinesis" ? [ 
                            { name = "FLEET_KINESIS_RESULT_STREAM", value = local.osquery.logging.kinesis.result_stream }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.kinesis.access_key_id  != "" ? [ 
                            { name = "FLEET_KINESIS_ACCESS_KEY_ID", value = local.osquery.logging.kinesis.access_key_id }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.kinesis.access_key_id  != "" ? [
                            { 
                                name = "FLEET_KINESIS_SECRET_ACCESS_KEY", 
                                value_from = {
                                    secret_key_ref = {
                                        name = local.osquery.secret_name
                                        key =  local.osquery.logging.kinesis.secret_key
                                    }
                                }
                            }
                        ] : []

                        content {
                            name = env.value.name
                            value_from {
                                secret_key_ref {
                                    name = env.value.value_from.secret_key_ref.name
                                    key = env.value.value_from.secret_key_ref.key
                                }
                            }
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.kinesis.access_key_id  == "" ? [ 
                            { name = "FLEET_KINESIS_STS_ASSUME_ROLE_ARN", value = local.osquery.logging.kinesis.sts_assume_role_arn }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin == "lambda" || local.osquery.logging.result_plugin  == "lambda" ? [ 
                            { name = "FLEET_LAMBDA_REGION", value = local.osquery.logging.lambda.region }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin  == "lambda" ? [ 
                            { name = "FLEET_LAMBDA_STATUS_FUNCTION", value = local.osquery.logging.lambda.status_stream }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.result_plugin  == "lambda" ? [ 
                            { name = "FLEET_LAMBDA_RESULT_FUNCTION", value = local.osquery.logging.lambda.result_stream }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.lambda.access_key_id  != "" ? [ 
                            { name = "FLEET_LAMBDA_ACCESS_KEY_ID", value = local.osquery.logging.lambda.access_key_id }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.lambda.access_key_id  != "" ? [
                            { 
                                name = "FLEET_LAMBDA_SECRET_ACCESS_KEY", 
                                value_from = {
                                    secret_key_ref = {
                                        name = local.osquery.secret_name
                                        key =  local.osquery.logging.lambda.secret_key
                                    }
                                }
                            }
                        ] : []

                        content {
                            name = env.value.name
                            value_from {
                                secret_key_ref {
                                    name = env.value.value_from.secret_key_ref.name
                                    key = env.value.value_from.secret_key_ref.key
                                }
                            }
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.lambda.access_key_id  == "" ? [ 
                            { name = "FLEET_LAMBDA_STS_ASSUME_ROLE_ARN", value = local.osquery.logging.lambda.sts_assume_role_arn }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin == "pubsub" || local.osquery.logging.result_plugin  == "pubsub" ? [ 
                            { name = "FLEET_PUBSUB_PROJECT", value = local.osquery.logging.pubsub.project }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.status_plugin  == "pubsub" ? [ 
                            { name = "FLEET_PUBSUB_STATUS_TOPIC", value = local.osquery.logging.pubsub.status_topic }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.osquery.logging.result_plugin  == "pubsub" ? [ 
                            { name = "FLEET_PUBSUB_RESULT_TOPIC", value = local.osquery.logging.pubsub.result_topic }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env" {
                        for_each = local.vuln_processing.dedicated ? [ 
                            { name = "FLEET_VULNERABILITIES_DISABLE_SCHEDULE", value = local.vuln_processing.dedicated }
                        ] : []

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }

                    dynamic "env"{
                        for_each = local.environment_variables

                        content {
                            name = env.value.name
                            value = env.value.value
                        }
                    }


                    dynamic "env_from" {
                        for_each = local.environment_from_config_maps

                        content {
                            config_map_ref {
                                name = env_from.value.name
                            }
                        }
                    }

                    dynamic "env_from" {
                        for_each = local.environment_from_secrets

                        content {
                            secret_ref {
                                name = env_from.value.name
                            }
                        }
                    }

                    security_context {
                        run_as_user = local.fleet.security_context.run_as_user
                        run_as_group = local.fleet.security_context.run_as_group
                        run_as_non_root = "true"
                        read_only_root_filesystem = "true"
                        privileged = "false"
                        allow_privilege_escalation = "false"
                        capabilities {
                            drop = ["ALL"]
                        }
                    }

                    port {
                        name = "fleet"
                        container_port = local.fleet.listen_port
                        protocol = "TCP"
                    }

                    liveness_probe {
                        http_get {
                            path = "healthz"
                            port = local.fleet.listen_port
                            scheme = local.fleet.tls.enabled ? "HTTPS" : "HTTP"
                        }
                        failure_threshold = "3"
                        period_seconds = "3"
                        success_threshold = "1"
                        timeout_seconds = "1"
                    }

                    readiness_probe {
                        http_get {
                            path = "healthz"
                            port = local.fleet.listen_port
                            scheme = local.fleet.tls.enabled ? "HTTPS" : "HTTP"
                        }
                        failure_threshold = "3"
                        period_seconds = "10"
                        success_threshold = "1"
                        timeout_seconds = "1"
                    }

                    resources {
                        limits = {
                            cpu = local.resources.limits.cpu
                            memory = local.resources.limits.memory
                        }
                        requests = {
                            cpu = local.resources.requests.cpu
                            memory = local.resources.requests.memory
                        }
                    }
                
                    volume_mount {
                        name = "tmp"
                        mount_path = "/tmp"
                    }

                    dynamic "volume_mount" {
                        for_each = local.fleet.tls.enabled ? [ 
                            { name = "fleet-tls", read_only = true, mount_path = "/secrets/tls" }
                        ] : []

                        content {
                            name = volume_mount.value.name
                            read_only = volume_mount.value.read_only
                            mount_path = volume_mount.value.mount_path
                        }
                    }

                    dynamic "volume_mount" {
                        for_each = local.database.tls.enabled ? [ 
                            { name = "mysql-tls", read_only = true, mount_path = "/secrets/mysql" }
                        ] : []

                        content {
                            name = volume_mount.value.name
                            read_only = volume_mount.value.read_only
                            mount_path = volume_mount.value.mount_path
                        }
                    }

                    dynamic "volume_mount" {
                        for_each = local.osquery.logging.status_plugin == "filesystem" || local.osquery.logging.result_plugin == "filesystem" ? [ 
                            { name = "osquery-logs", mount_path = "/logs" }
                        ] : []

                        content {
                            name = volume_mount.value.name
                            mount_path = volume_mount.value.mount_path
                        }
                    }
                }
                
                dynamic "container" {
                    for_each = local.gke.cloud_sql.enable_proxy ? [
                        {
                            name = "cloudql-proxy",
                            image = "${local.gke.cloud_sql.image_repository}:${local.gke.cloud_sql.image_tag}",
                            command = ["/cloud_sql_proxy", "-verbose=${local.gke.cloud_sql.verbose}", "-instances=${local.gke.cloud_sql.instance_name}=tcp:3306"]
                            resources = {
                                limits = {
                                    cpu = "0.1",
                                    memory = "150Mi"
                                },
                                requests = {
                                    cpu = "0.1",
                                    memory = "50Mi"
                                }
                            }
                            security_context = {
                                allow_privilege_escalation = false,
                                capabilities = {
                                    drop = ["ALL"]
                                },
                                privileged = false,
                                read_only_root_filesystem = true,
                                run_as_group = local.fleet.security_context.run_as_group,
                                run_as_user = local.fleet.security_context.run_as_user,
                                run_as_non_root = true
                            }
                        }
                    ] : []

                    content {
                        name = container.value.name
                        image = container.value.image
                        command = container.value.command
                        resources { 
                            limits = {
                                cpu = container.value.resources.limits.cpu
                                memory = container.value.resources.limits.memory
                            }
                            requests = {
                                cpu = container.value.resources.requests.cpu
                                memory = container.value.resources.requests.memory
                            }
                        }
                        security_context {
                            allow_privilege_escalation = container.value.security_context.allow_privilege_escalation
                            capabilities {
                                drop = container.value.security_context.capabilities.drop
                            }
                            privileged = container.value.security_context.privileged
                            read_only_root_filesystem = container.value.security_context.read_only_root_filesystem
                            run_as_group = container.value.security_context.run_as_group
                            run_as_user = container.value.security_context.run_as_user
                            run_as_non_root = container.value.security_context.run_as_non_root
                        }
                    }
                }

                host_pid = false
                host_network = false
                host_ipc = false

                volume {
                    name = "tmp"
                    empty_dir {}
                }

                dynamic "volume" {
                    for_each = local.fleet.tls.enabled ? [
                        {
                            name = "fleet-tls",
                            secret_name = local.fleet.tls.unique_tls_secret ? local.fleet.tls.secretName : local.fleet.secret_name
                        }
                    ] : []

                    content {
                        name = volume.value.name
                        secret {
                            secret_name = volume.value.secret_name
                        }
                    }
                }

                dynamic "volume" {
                    for_each = local.database.tls.enabled ? [
                        {
                            name = "mysql-tls",
                            secret_name = local.database.tls.secret_name
                        }
                    ] : []

                    content {
                        name = volume.value.name
                        secret {
                            secret_name = volume.value.secret_name
                        }
                    }
                }

                dynamic "volume" {
                    for_each = local.osquery.logging.status_plugin == "filesystem" || local.osquery.logging.result_plugin == "filesystem" ? [
                        {
                            name = "osquery-logs",
                            size_limit = local.osquery.logging.filesystem.volume_size
                        }
                    ] : []

                    content {
                        name = volume.value.name
                        empty_dir {
                            size_limit = volume.value.size_limit
                        }
                    }
                }

                dynamic "affinity" {
                    for_each = local.affinity_rules.required_during_scheduling_ignored_during_execution != null ? local.affinity_rules.required_during_scheduling_ignored_during_execution : null

                    content {
                        pod_affinity {
                            required_during_scheduling_ignored_during_execution {
                                label_selector {
                                    match_expressions {
                                        key = affinity.value.label_selector.match_expressions[*].key
                                        operator = affinity.value.label_selector.match_expressions[*].operator
                                        values = affinity.value.label_selector.match_expressions[*].values
                                    }
                                }
                                topology_key = affinity.value.topology_key
                            }
                        }
                    }
                }
            
                dynamic "affinity" {
                    for_each = local.affinity_rules.preferred_during_scheduling_ignored_during_execution != null ? local.affinity_rules.preferred_during_scheduling_ignored_during_execution : null
                    
                    content {
                        pod_affinity {
                            preferred_during_scheduling_ignored_during_execution {
                                pod_affinity_term {
                                    preference = affinity.value.preference
                                }
                                topology_key = affinity.value.topology_key
                            }
                        }
                    }
                }


                dynamic "affinity" {
                    for_each = local.anti_affinity_rules.required_during_scheduling_ignored_during_execution != null ? local.affinity_rules.required_during_scheduling_ignored_during_execution : null

                    content {
                        pod_anti_affinity {
                            required_during_scheduling_ignored_during_execution {
                                label_selector {
                                    match_expressions {
                                        key = affinity.value.label_selector.match_expressions[*].key
                                        operator = affinity.value.label_selector.match_expressions[*].operator
                                        values = affinity.value.label_selector.match_expressions[*].values
                                    }
                                }
                                topology_key = affinity.value.topology_key
                            }
                        }
                    }
                }

                dynamic "affinity" {
                    for_each = local.anti_affinity_rules.preferred_during_scheduling_ignored_during_execution != null ? local.affinity_rules.preferred_during_scheduling_ignored_during_execution : null
                    
                    content {
                        pod_anti_affinity {
                            preferred_during_scheduling_ignored_during_execution {
                                pod_affinity_term {
                                    label_selector = affinity.value.label_selector.label_selector
                                }
                                topology_key = affinity.value.topology_key
                            }
                        }
                    }
                }

                dynamic "image_pull_secrets" {
                    for_each = var.image_pull_secrets

                    content {
                        name = image_pull_secrets.value["name"]
                    }
                }
            }
        }
    }
    depends_on = [ 
        resource.kubernetes_job.migration // dependency should only be here if migration is enabled
    ]
}