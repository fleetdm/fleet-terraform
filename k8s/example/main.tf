module "fleet" {
    source = "git::https://github.com/fleetdm/fleet-terraform//k8s?depth=1&ref=tf-mod-k8s-v1.1.3"

    namespace = "fleet"
    hostname = "fleet.localhost.local"
    replicas = "3"
    image_repository = "fleetdm/fleet"
    image_tag = "v4.72.0"
    /*
        Example:
        image_pull_secrets = [
            { name = "docker_pull_secret" },
            { name = "docker_pull_secret_two"}
        ]
    */
    image_pull_secrets = []
    pod_annotations = {}
    service_annotations = {}
    service_account_annotations = {}
    resources = {
        limits = {
            cpu = "1"
            memory = "4Gi"
        }
        requests = {
            cpu = "0.1"
            memory = "50Mi"
        }
    }

    vuln_processing = {
        ttl_seconds_after_finished = 100
        restart_policy = "Never"
        dedicated = false
        schedule = "0 * * * *"
        resources = {
            limits = {
                cpu = "1"
                memory = "4Gi"
            }
            requests = {
                cpu = "0.1"
                memory = "50Mi"
            }
        }
    }

    node_selector = {}
    /*
        EXAMPLE: 
        tolerations = [
            { key = "", operator = "", value = "", effect = "" }
        ]
    */
    tolerations = []

    /*
        affinity_rules = {
            required_during_scheduling_ignored_during_execution = [
                label_selector = {
                    match_expressions = [
                        {
                            key = "disktype"
                            operator = "In"
                            values = ["ssd"]
                        }
                    ]
                }
                topology_key = "kubernetes.io/hostname"
                }
            ]
            preferred_during_scheduling_ignored_during_execution = [
                {
                    weight = 1
                    preference = {
                        label_selector = {
                            match_expressions = [
                                {
                                    key = "another-label"
                                    operator = "In"
                                    values = ["value1", "value2"]
                                }
                            ]
                        }
                        topology_key = "kubernetes.io/hostname"
                    }
                }
            ]
        }
        anti_affinity_rules = {
            required_during_scheduling_ignored_during_execution = [
                label_selector = {
                    match_expressions = [
                        {
                            key = "disktype"
                            operator = "In"
                            values = ["ssd"]
                        }
                    ]
                }
                topology_key = "kubernetes.io/hostname"
                }
            ]
            preferred_during_scheduling_ignored_during_execution = [
                {
                    weight = 1
                    preference = {
                        label_selector = {
                            match_expressions = [
                                {
                                    key = "another-label"
                                    operator = "In"
                                    values = ["value1", "value2"]
                                }
                            ]
                        }
                        topology_key = "kubernetes.io/hostname"
                    }
                }
            ]
        }
    */
    affinity_rules = {}
    anti_affinity_rules = {}
    
    ingress = {
        enabled = false
        class_name = ""
        annotations = {}
        labels = {}
        hosts = [{
            name = "fleet.localhost.local"
            paths = [{
                path = "/"
                path_type = "ImplementationSpecific"
            }]
        }]
        /*
          # Example
          tls = {
              secret_name = "chart-example-tls"
              hosts = [
                  "fleet.localhost.local"
              ]
          }
        */
        tls = {}
    }

    fleet = {
        listen_port = "8080"
        secret_name = "fleet"
        migrations = {
            auto_apply_sql_migrations = true
            migration_job_annotations = {}
            parallelism = 1
            completions = 1
            active_deadline_seconds = 900
            backoff_limit = 6
            manual_selector = false
            restart_policy = "Never"
        }
        tls = {
            enabled = false
            unique_tls_secret = false
            secret_name = "fleet-tls"
            compatibility = "modern"
            cert_secret_key = "server.cert"
            key_secret_key = "server.key"
        }
        auth = {
            b_crypto_cost = "12"
            salt_key_size = "24"
        }
        app = {
            token_key_size = "24"
            invite_token_validity_period = "120h"
        }
        session = {
            key_size = 64
            duration = "2160h"
        }
        logging = {
            debug = false
            json = false
            disable_banner = false
        }
        carving = {
            s3 = {
                bucket_name = ""
                prefix = ""
                access_key_id = ""
                secret_key = "s3-bucket"
                sts_assume_role_arn = ""
            }
        }
        license = {
            secret_name = ""
            license_key = "license-key"
        }
        extra_volumes = []
        extra_volume_mounts = []
        /*
           If you're not providing an id for run_as_user or run_as_group, 
           and you're not running on Openshift (Openshift will set the userid/groupid, if left blank),
           you might encounter an issue with Fleet pods starting up, where
           k8s is not able to determine whether the fleet user, in the
           Fleet container image, is running as root. 
           
           Examples:
           1. Openshift example (without id's):
                security_context = {
                    run_as_non_root = true
                }

           2. Openshift example (with id's):
                security_context = {
                    run_as_user = 1000653333
                    run_as_group = 1000653333
                    run_as_non_root = true
                }

           3. Non-Openshift (without id's):
                security_context = {
                    run_as_non_root = false
                }
                
           4. Non-Openshift (with id's):
                security_context = {
                    run_as_user = 3333
                    run_as_group = 3333
                    run_as_non_root = true
                }
        */
        security_context = {
            run_as_user = 3333
            run_as_group = 3333
            run_as_non_root = true
        }
    }

    osquery = {
        secret_name = "osquery"
        node_key_size = 24
        label_update_interval = "30m"
        detail_update_interval = "30m"

        logging = {
            status_plugin = "filesystem"
            result_plugin = "filesystem"

            filesystem = {
                status_log_file = "osquery_status"
                result_log_file = "osquery_result"
                enable_rotation = false
                enable_compression = false
                volume_size = "20Gi"
            }

            firehose = {
                region = ""
                access_key_id = ""
                secret_key = "firehose"
                sts_assume_role_arn = ""
                status_stream = ""
                result_stream = ""
            }

            kinesis = {
                region = ""
                access_key_id = ""
                secret_key = "kinesis"
                sts_assume_role_arn = ""
                status_stream = ""
                result_stream = ""
            }

            lambda = {
                region = ""
                access_key_id = ""
                secret_key = "lambda"
                sts_assume_role_arn = ""
                status_function = ""
                result_function = ""
            }

            pubsub = {
                project = ""
                status_topic = ""
                result_topic = ""
            }
        }
    }

    database = {
        enabled = false
        secret_name = "mysql"
        address = "fleet-database-mysql:3306"
        database = "fleet"
        username = "fleet"
        password_key = "password"
        max_open_conns = 50
        max_idle_conns = 50
        conn_max_lifetime = 0

        tls = {
            enabled = false
            config = ""
            server_name = ""
            ca_cert_key = ""
            cert_key = ""
            key_key = ""
        }
    }

    /*
        database_read_replica - optional and be configured to enable Fleet to use read replica for
            MySQL SELECT statements.
        

        database_read_replica = {
            enabled = false
            address = "fleet-database-mysql-read-replica:3306"
            database = "fleet"
            username = "fleet-ro"
            secret_name = "mysql"
            password_key = "ro-password"
            password_path = ""
            max_open_conns = 50
            max_idle_conns = 50
            conn_max_lifetime = 0

            tls = {
                enabled = false
                config = ""
                server_name = ""
                ca_cert_key = ""
                cert_key = ""
                key_key = ""
            }   
        }
    */
    database_read_replica = {}

    cache = {
        enabled = false
        address = "fleet-cache-redis-master:6379"
        database = "0"
        use_password = true
        secret_name = "redis"
        password_key = "password"
    }

    gke = {
        cloud_sql = {
            enable_proxy = false
            image_repository = "gcr.io/cloudsql-docker/gce-proxy"
            image_tag = "1.17-alpine"
            verbose = true
            instance_name = ""
        }
        ingress = {
            use_managed_certificate = false
            use_gke_ingress = false
            node_port = 0
            hostnames = ["example.com","example2.com"]
        }
        workload_identity_email = ""
    }

    environment_variables = [
        { name = "FLEET_SERVER_PRIVATE_KEY", value = "" }
    ]
    /*
        EXAMPLE: 
        environment_from_config_maps = [
            { name = "CONFIG_MAP_NAME" }
        ]
    */
    environment_from_config_maps = []

    /*
        EXAMPLE: 
        environment_from_secrets = [
            { name = "K8S_SECRET_NAME" }
        ]
    */
    environment_from_secrets = []
}
