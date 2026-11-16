#!/bin/bash
set -e
export AWS_PAGER=""

# List every task that still belongs to a service and has not reached STOPPED yet.
# ECS defaults ListTasks to desiredStatus=RUNNING, which hides tasks that ECS has already
# decided to stop (desiredStatus=STOPPED) but that are still executing while they drain
# from the load balancer, so both desired statuses are listed and filtered on lastStatus.
function list_live_service_tasks(){
	local SERVICE_NAME TASK_ARNS DESIRED_STATUS
	SERVICE_NAME="${1:?}"
	TASK_ARNS="$(
		for DESIRED_STATUS in RUNNING STOPPED; do
			aws ecs list-tasks --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --service-name "${SERVICE_NAME:?}" --desired-status "${DESIRED_STATUS}" --query 'taskArns' --output text
		done | tr '[:space:]' '\n' | grep -vE '^(None)?$' | sort -u
	)"
	[ -n "${TASK_ARNS}" ] || return 0
	# describe-tasks accepts at most 100 tasks per call, and --tasks has to come last so
	# xargs can append the batch to it.
	echo "${TASK_ARNS}" | xargs -n 100 aws ecs describe-tasks --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --query "tasks[?lastStatus!='STOPPED'].taskArn" --output text --tasks | tr '[:space:]' '\n' | grep -vE '^(None)?$' | sort -u | tr '\n' ' '
}

# Wait until a scaled-down service has no task left alive.  "aws ecs wait services-stable"
# is not enough on its own: a service's runningCount only counts tasks in the RUNNING
# state, so it reaches 0 as soon as the tasks enter DEACTIVATING, while the containers
# keep running for the target group's deregistration delay (300s by default) plus the
# container stop timeout.  Migrations must not start while those containers are alive.
function wait_for_service_tasks_stopped(){
	local SERVICE_NAME ELAPSED LIVE_TASK_ARNS
	SERVICE_NAME="${1:?}"
	ELAPSED=0
	while [ "${ELAPSED}" -lt "${SCALE_DOWN_TIMEOUT_SECONDS:-900}" ]; do
		LIVE_TASK_ARNS="$(list_live_service_tasks "${SERVICE_NAME:?}")"
		if [ -z "${LIVE_TASK_ARNS// /}" ]; then
			return 0
		fi
		echo "Waiting for ${SERVICE_NAME} tasks to stop: ${LIVE_TASK_ARNS}" >&2
		sleep 10
		ELAPSED=$((ELAPSED + 10))
	done

	echo "ERROR: tasks for service ${SERVICE_NAME} were still running after ${SCALE_DOWN_TIMEOUT_SECONDS:-900} seconds." >&2
	echo "Refusing to continue: running migrations against live Fleet containers corrupts cron runs." >&2
	echo "Still alive: ${LIVE_TASK_ARNS}" >&2
	return 1
}

function scale_services(){
	UP_DOWN="${1:?}"
	# Take service name as an argument.  Accept a service ARN too and reduce it to the
	# name, because list-tasks only filters on the name.
	SERVICE_NAME="${2:?}"
	SERVICE_NAME="${SERVICE_NAME##*/}"
	ADJUST_AUTOSCALING="${3:-}"
	COUNT="${4:-1}"

	# Set the minimum capacity and desired count in the cluster to 0 to scale down or to the original size to scale back to normal.

	# This is a bit hacky, but the update-service has to happen first when scaling up and second when scaling down.
	# Assume scaling down unless "up".
	CAPACITY=0
	CAPACITY_MAX=0
	if [ "${UP_DOWN:?}" = "up" ]; then
		aws ecs update-service --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --service "${SERVICE_NAME:?}" --desired-count "${COUNT:?}"
		CAPACITY="${MIN_CAPACITY:?}"
		CAPACITY_MAX="${MAX_CAPACITY:?}"
	fi

	# Registering a scalable target whose bounds exclude the current capacity makes
	# Application Auto Scaling move the service into those bounds, so this already starts
	# the scale-down to 0 on its own.
	if [ -n "${ADJUST_AUTOSCALING}" ]; then
		aws application-autoscaling register-scalable-target --region "${REGION:?}" --service-namespace ecs --resource-id "service/${ECS_CLUSTER:?}/${SERVICE_NAME:?}" --scalable-dimension "ecs:service:DesiredCount" --min-capacity "${CAPACITY:?}" --max-capacity "${CAPACITY_MAX:?}"
	fi

	# We are scaling down, make it 0
	if [ "${UP_DOWN:?}" != "up" ]; then
		aws ecs update-service --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --service "${SERVICE_NAME:?}" --desired-count 0
	fi
	# The first task definition might never get stable because it never had initial migrations so don't wait before continuing
	if [ "${TASK_DEFINITION_REVISION}" != "1" ]; then
		# Wait for scale-down to succeed
		aws ecs wait services-stable --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --services "${SERVICE_NAME:?}"
	fi

	if [ "${UP_DOWN:?}" != "up" ]; then
		wait_for_service_tasks_stopped "${SERVICE_NAME:?}"
	fi
}

for ARGUMENT in "$@"
do
   KEY=$(echo $ARGUMENT | cut -f1 -d=)
   KEY_LENGTH=${#KEY}
   VALUE="${ARGUMENT:$KEY_LENGTH+1}"
   export "$KEY"="$VALUE"
done

# If an IAM role ARN is provided, assume it and export AWS temporary credentials
if [ -n "${ASSUME_ROLE_ARN:-}" ]; then
  SESSION_NAME="${ASSUME_ROLE_SESSION_NAME:-migrate-$(date +%s)}"
  echo "Assuming role ${ASSUME_ROLE_ARN} with session name ${SESSION_NAME}" >&2
  # Retrieve temporary credentials via AWS STS
  read AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< "$(
    aws sts assume-role \
      --role-arn "${ASSUME_ROLE_ARN}" \
      --role-session-name "${SESSION_NAME}" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text
  )"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
fi

scale_services down "${ECS_SERVICE:?}" true "${DESIRED_COUNT}"

if [ -n "${VULN_SERVICE}" ]; then
  scale_services down "${VULN_SERVICE:?}"
fi

# Call aws ecs run-task
TASK_ARN="$(aws ecs run-task --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --task-definition "${TASK_DEFINITION:?}":"${TASK_DEFINITION_REVISION:?}" --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets="${SUBNETS:?}",securityGroups="${SECURITY_GROUPS:?}"}" --query 'tasks[].taskArn' --overrides '{"containerOverrides": [{"name": "fleet", "command": ["fleet", "prepare", "db"]}]}' --output text | rev | cut -d'/' -f1 | rev)"

# Wait for completion with configurable timeout
ELAPSED=0
while [ "$ELAPSED" -lt "${TIMEOUT_SECONDS:-600}" ]; do
    sleep 30
    ELAPSED=$((ELAPSED + 30))
    TASK_STATUS=$(aws ecs describe-tasks --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --tasks "${TASK_ARN:?}" --query "tasks[0].lastStatus" --output text)
    if [ "$TASK_STATUS" = "STOPPED" ]; then
        break
    fi
    echo "Migration task status: ${TASK_STATUS} (elapsed: ${ELAPSED}s / ${TIMEOUT_SECONDS:-600}s)" >&2
done

if [ "$TASK_STATUS" != "STOPPED" ]; then
    echo "ERROR: Migration task timed out after ${TIMEOUT_SECONDS:-600} seconds." >&2
    echo "Task ARN: ${TASK_ARN}" >&2
    echo "Task Status: ${TASK_STATUS}" >&2
    echo "Check the task manually:" >&2
    echo "  aws ecs describe-tasks --region ${REGION} --cluster ${ECS_CLUSTER} --tasks ${TASK_ARN}" >&2
    echo "If the task completed successfully, re-running terraform apply will detect this and continue." >&2
    exit 1
fi

scale_services up "${ECS_SERVICE:?}" true "${DESIRED_COUNT}"

if [ -n "${VULN_SERVICE}" ]; then
  scale_services up "${VULN_SERVICE:?}"
fi

# Exit with task's exit code
TASK_EXIT_CODE=$(aws ecs describe-tasks --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --tasks "${TASK_ARN:?}" --query "tasks[0].containers[?name=='fleet'].exitCode" --output text)
exit "${TASK_EXIT_CODE}"
