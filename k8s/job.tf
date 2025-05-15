resource "kubernetes_job" "migration" {
    metadata{
        name = "fleet-migration"
        namespace = data.kubernetes_namespace.fleet.metadata[0].name
        labels = {
            app = "fleet"
        }
        annotations = local.pod_annotations
    }
    spec {
        parallelism = local.fleet.migrations.parallelism
        completions = local.fleet.migrations.completions
        active_deadline_seconds = local.fleet.migrations.active_deadline_seconds
        backoff_limit = local.fleet.migrations.backoff_limit

        manual_selector = local.fleet.migrations.manual_selector

        template {
            metadata {
                name = "fleet-migration"
                labels = {
                    app = "fleet"
                }
                annotations = local.pod_annotations
            }

            spec {
                service_account_name = resource.kubernetes_service_account.fleet-sa.metadata[0].name
                share_process_namespace = "true"
                restart_policy = local.fleet.migrations.restart_policy

                container {
                    name = "fleet-migration"
                    image = "${local.image_repository}:${local.image_tag}"

                    command = ["/bin/sh", "-c"]
                    args = local.gke.cloud_sql.enable_proxy ? [
                        "/usr/bin/fleet prepare db --no-prompt; sql_proxy_pid=$(pgrep cloud_sql_proxy) && kill -INT $sql_proxy_pid;"
                    ] : [
                        "/usr/bin/fleet prepare db --no-prompt;"
                    ]

                    dynamic "env" {
                        for_each = [ 
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

                    security_context {
                        run_as_user = local.fleet.security_context.run_as_user
                        run_as_group = local.fleet.security_context.run_as_group
                        run_as_non_root = "true"
                        read_only_root_filesystem = "true"
                        privileged = "false"
                        allow_privilege_escalation = "false"

                        dynamic "capabilities" {
                            for_each = local.gke.cloud_sql.enable_proxy ? [
                                { name = "add", values = ["SYS_PTRACE"] }
                            ] : [
                                { name = "drop", values = ["ALL"] }
                            ]

                            content {
                                add = capabilities.value.name == "add" ? capabilities.value.values : []
                                drop = capabilities.value.name == "drop" ? capabilities.value.values : []
                            }
                        }
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
                }
                
                dynamic "container" {
                    for_each = local.gke.cloud_sql.enable_proxy ? [
                        {
                            name = "cloudql-proxy",
                            image = "${local.gke.cloud_sql.image_repository}:${local.gke.cloud_sql.image_tag}",
                            command = ["/cloud_sql_proxy", "-verbose=${local.gke.cloud_sql.verbose}", "-instances=${local.gke.cloud_sql.instance_name}=tcp:3306"]
                            resources = {
                                limits = {
                                    cpu = "0.5",
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

                dynamic "toleration" {
                    for_each = local.tolerations

                    content {
                        key = toleration.env.key
                        operator = toleration.env.operator
                        value = toleration.env.value
                        effect = toleration.env.effect
                    }
                }

                node_selector = local.node_selector

                dynamic "image_pull_secrets" {
                    for_each = var.image_pull_secrets

                    content {
                        name = image_pull_secrets.value["name"]
                    }
                }
            }
        }
    }
    wait_for_completion = true
    timeouts {
        create = "30m"
    }
}