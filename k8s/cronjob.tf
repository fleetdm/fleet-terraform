resource "kubernetes_cron_job_v1" "fleet_vuln_processing_cron_job" {
    metadata {
        name = "fleet-vulnprocessing"
        namespace = data.kubernetes_namespace.fleet.metadata[0].name
    }
    spec {
        schedule = local.vuln_processing.schedule
        concurrency_policy = "Forbid"

        job_template {
            metadata {
                labels = {
                    app = "fleet"
                }
            }

            spec {
                ttl_seconds_after_finished = local.vuln_processing.ttl_seconds_after_finished
                template {
                    metadata {
                        labels = {
                            app = "fleet"
                        }
                        annotations = local.pod_annotations
                    }
                    spec {
                        share_process_namespace = "true"
                        restart_policy = local.vuln_processing.restart_policy
                        service_account_name = resource.kubernetes_service_account.fleet-sa.metadata[0].name

                        container {
                            name = "fleet-vulnprocessing"
                            image = "${local.image_repository}:${local.image_tag}"

                            command = ["/bin/sh", "-c"]
                            args = local.gke.cloud_sql.enable_proxy ? [
                                "/usr/bin/fleet vuln_processing; sql_proxy_pid=$(pgrep cloud_sql_proxy) && kill -INT $sql_proxy_pid;"
                            ] : [
                                "/usr/bin/fleet vuln_processing;"
                            ]

                            dynamic "env" {
                                for_each = [ 
                                    { name = "FLEET_VULNERABILITIES_DATABASES_PATH", value = "/tmp/vuln" },
                                    { name = "FLEET_LOGGING_DEBUG", value = local.fleet.logging.debug },
                                    { name = "FLEET_LOGGING_JSON", value = local.fleet.logging.json },
                                    { name = "FLEET_LOGGING_DISABLE_BANNER", value = local.fleet.logging.disable_banner }
                                ]

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
                                        key = local.database.secret_name
                                        name = local.database.password_key
                                    }
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

                            resources {
                                limits = {
                                    cpu = local.vuln_processing.resources.limits.cpu
                                    memory = local.vuln_processing.resources.limits.memory
                                }
                                requests = {
                                    cpu = local.vuln_processing.resources.requests.cpu
                                    memory = local.vuln_processing.resources.requests.memory
                                }
                            }
                        
                            volume_mount {
                                name = "tmp"
                                mount_path = "/tmp"
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

                        volume {
                            name = "tmp"
                            empty_dir {}
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
        }
    }
    depends_on = [ 
        resource.kubernetes_job.migration, // Include when migration is enabled
        resource.kubernetes_service_account.fleet-sa
    ]
}