#!/bin/bash
set -e
export AWS_PAGER=""

# ECS defaults ListTasks to desiredStatus=RUNNING, which hides tasks it has already decided
# to stop but that are still draining from the load balancer, so both statuses are listed
# and filtered on lastStatus.  Each lookup runs on its own and is checked: inside a pipeline
# the aws exit status is lost, and the empty output of a failed lookup would read as "drained".
function list_live_service_tasks(){
	local SERVICE_NAME DESIRED_STATUS LISTED TASK_ARNS REMAINING BATCH ROWS REQUESTED DESCRIBED LIVE
	SERVICE_NAME="${1:?}"

	LISTED=""
	for DESIRED_STATUS in RUNNING STOPPED; do
		BATCH="$(aws ecs list-tasks --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --service-name "${SERVICE_NAME:?}" --desired-status "${DESIRED_STATUS}" --query 'taskArns' --output text)" || {
			echo "ERROR: ListTasks failed for service ${SERVICE_NAME} (desired-status ${DESIRED_STATUS})." >&2
			return 1
		}
		LISTED="${LISTED}
${BATCH}"
	done

	# grep exits 1 on a legitimately empty listing.
	TASK_ARNS="$(printf '%s' "${LISTED}" | tr '[:space:]' '\n' | grep -vE '^(None)?$' | sort -u || true)"
	if [ -z "${TASK_ARNS}" ]; then
		return 0
	fi

	LIVE=""
	REMAINING="${TASK_ARNS}"
	while [ -n "${REMAINING}" ]; do
		BATCH="$(printf '%s\n' "${REMAINING}" | head -n 100)"
		REMAINING="$(printf '%s\n' "${REMAINING}" | tail -n +101)"

		# Query both arrays so a task missing from "tasks" is never read as stopped.
		# describe-tasks takes at most 100 tasks, --tasks must come last, ${BATCH} word-splits.
		ROWS="$(aws ecs describe-tasks --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --query '[tasks[].[`"task"`,taskArn,lastStatus], failures[].[`"failure"`,arn,reason]][]' --output text --tasks ${BATCH})" || {
			echo "ERROR: DescribeTasks failed for service ${SERVICE_NAME}." >&2
			return 1
		}

		if printf '%s\n' "${ROWS}" | grep -q '^failure'; then
			echo "ERROR: DescribeTasks could not describe some tasks of ${SERVICE_NAME}:" >&2
			printf '%s\n' "${ROWS}" | grep '^failure' >&2
			return 1
		fi

		REQUESTED="$(printf '%s\n' "${BATCH}" | grep -c . || true)"
		DESCRIBED="$(printf '%s\n' "${ROWS}" | grep -c '^task' || true)"
		if [ "${DESCRIBED:--1}" -ne "${REQUESTED:--2}" ]; then
			echo "ERROR: DescribeTasks described ${DESCRIBED} of ${REQUESTED} tasks for ${SERVICE_NAME}; their state is unknown." >&2
			return 1
		fi

		LIVE="${LIVE}$(printf '%s\n' "${ROWS}" | awk '$1 == "task" && $3 != "STOPPED" { printf "%s ", $2 }')"
	done

	printf '%s' "${LIVE}"
}

# "aws ecs wait services-stable" is not enough on its own: runningCount only counts tasks in
# the RUNNING state, so it reaches 0 as soon as they enter DEACTIVATING, while the containers
# keep running for the target group's deregistration delay (300s by default).
function wait_for_service_tasks_stopped(){
	local SERVICE_NAME ELAPSED LIVE_TASK_ARNS
	SERVICE_NAME="${1:?}"
	ELAPSED=0
	while [ "${ELAPSED}" -lt "${SCALE_DOWN_TIMEOUT_SECONDS:-900}" ]; do
		LIVE_TASK_ARNS="$(list_live_service_tasks "${SERVICE_NAME:?}")" || {
			echo "ERROR: could not establish the task state of service ${SERVICE_NAME}." >&2
			echo "Refusing to continue: migrating against live Fleet containers corrupts cron runs." >&2
			return 1
		}
		if [ -z "${LIVE_TASK_ARNS// /}" ]; then
			return 0
		fi
		echo "Waiting for ${SERVICE_NAME} tasks to stop: ${LIVE_TASK_ARNS}" >&2
		sleep 10
		ELAPSED=$((ELAPSED + 10))
	done

	echo "ERROR: tasks for service ${SERVICE_NAME} were still running after ${SCALE_DOWN_TIMEOUT_SECONDS:-900} seconds." >&2
	echo "Refusing to continue: migrating against live Fleet containers corrupts cron runs." >&2
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

# STOPPED does not mean the migration succeeded, so check the exit code before restoring.
TASK_EXIT_CODE="$(aws ecs describe-tasks --region "${REGION:?}" --cluster "${ECS_CLUSTER:?}" --tasks "${TASK_ARN:?}" --query "tasks[0].containers[?name=='fleet'].exitCode" --output text)" || {
    echo "ERROR: could not read the migration task's exit code; its result is unknown." >&2
    echo "Task ARN: ${TASK_ARN}" >&2
    exit 1
}

if [ -z "${TASK_EXIT_CODE}" ] || [ "${TASK_EXIT_CODE}" = "None" ]; then
    echo "ERROR: the migration task stopped without reporting an exit code." >&2
    echo "Task ARN: ${TASK_ARN}" >&2
    echo "  aws ecs describe-tasks --region ${REGION} --cluster ${ECS_CLUSTER} --tasks ${TASK_ARN}" >&2
    exit 1
fi

if [ "${TASK_EXIT_CODE}" -ne 0 ]; then
    echo "ERROR: the migration task exited with code ${TASK_EXIT_CODE}." >&2
    echo "Task ARN: ${TASK_ARN}" >&2
    echo "Leaving ${ECS_SERVICE} scaled down: starting Fleet against a partially migrated" >&2
    echo "database would crash-loop, and scaling up would hide the failed migration." >&2
    echo "  aws ecs describe-tasks --region ${REGION} --cluster ${ECS_CLUSTER} --tasks ${TASK_ARN}" >&2
    exit "${TASK_EXIT_CODE}"
fi

scale_services up "${ECS_SERVICE:?}" true "${DESIRED_COUNT}"

if [ -n "${VULN_SERVICE}" ]; then
  scale_services up "${VULN_SERVICE:?}"
fi

exit 0
