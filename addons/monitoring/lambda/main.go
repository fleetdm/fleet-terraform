/*
This script is intended to be used with AWS Lambda to monitor the various
crons that live inside of Fleet.

We will check to see if there are recent updates from the crons in the
following table:

    - cron_stats

If we have an old/incomplete run in cron_stats or if we are missing a
cron entry entirely, throw an alert to an SNS topic.

Currently tested crons:

    - cleanups_then_aggregation
    - vulnerabilities

*/

package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/secretsmanager"
	"github.com/aws/aws-sdk-go/service/sns"
	"github.com/aws/aws-secretsmanager-caching-go/secretcache"
	"github.com/go-sql-driver/mysql"
	flags "github.com/jessevdk/go-flags"
)

type (
	NullEvent       struct{}
	SNSTopicArnsMap map[string]string
)

type OptionsStruct struct {
	LambdaRuntimeAPI           string `long:"lambda-runtime-api" env:"AWS_LAMBDA_RUNTIME_API"`
	SNSCronSystemTopicArns     string `long:"sns-cron-system-topic-arn" env:"CRON_SYSTEM_MONITOR_SNS_TOPIC_ARNS" required:"true"`
	SNSCronJobFailureTopicArns string `long:"sns-cron-job-failure-topic-arn" env:"CRON_JOB_FAILURE_MONITOR_SNS_TOPIC_ARNS"`
	MySQLHost                  string `long:"mysql-host" env:"MYSQL_HOST" required:"true"`
	MySQLUser                  string `long:"mysql-user" env:"MYSQL_USER" required:"true"`
	MySQLSMSecret              string `long:"mysql-secretsmanager-secret" env:"MYSQL_SECRETSMANAGER_SECRET" required:"true"`
	MySQLDatabase              string `long:"mysql-database" env:"MYSQL_DATABASE" required:"true"`
	FleetEnv                   string `long:"fleet-environment" env:"FLEET_ENV" required:"true"`
	AWSRegion                  string `long:"aws-region" env:"AWS_REGION" required:"true"`
	CronDelayTolerance         string `long:"cron-delay-tolerance" env:"CRON_DELAY_TOLERANCE" default:"2h"`
	CronMonitorInterval        string `long:"monitor-run-interval" env:"CRON_MONITOR_RUN_INTERVAL" default:"1 hour"`
	AwsEndpointUrl             string `long:"aws-endpoint-url" env:"AWS_ENDPOINT_URL"`
}

var (
	options   = OptionsStruct{}
	snsTopics = make(SNSTopicArnsMap)
)

func sendSNSMessage(msg string, topic string, sess *session.Session) {
	topicArns, ok := snsTopics[topic]
	if !ok {
		log.Printf("No SNS topic ARNs available for topic '%s'", topic)
		return
	}

	log.Printf("Sending SNS Message")
	fullMsg := fmt.Sprintf("Environment: %s\nMessage: %s", options.FleetEnv, msg)
	svc := sns.New(sess)
	for _, SNSTopicArn := range strings.Split(topicArns, ",") {
		log.Printf("Sending '%s' to '%s'", fullMsg, SNSTopicArn)
		result, err := svc.Publish(&sns.PublishInput{
			Message:  &fullMsg,
			TopicArn: &SNSTopicArn,
		})
		if err != nil {
			log.Printf(err.Error())
		}
		log.Printf(result.GoString())
	}
}

func parseLambdaIntervalToDuration(intervalString string) (duration time.Duration, err error) {
	var number int
	var unit string

	_, err = fmt.Sscanf(intervalString, "%d %s", &number, &unit)
	if err != nil {
		return 0, err
	}

	switch unit {
	case "hour", "hours":
		unit = "h"
	case "minute", "minutes":
		unit = "m"
	case "day", "days":
		unit = "h"
		number *= 24
	}

	return time.ParseDuration(strconv.Itoa(number) + unit)
}

type CronStatsRow struct {
	name       string
	status     string
	errors     string
	created_at time.Time
	updated_at time.Time
}

type CronStatsDigestRow struct {
	CronStatsRow
	num_occurences    int
	num_errors        int
	last_updated_at   time.Time
	most_recent_error sql.NullString
}

func setupDB(sess *session.Session) (db *sql.DB, err error) {
	secretCache, err := secretcache.New()
	if err != nil {
		log.Printf(err.Error())
		sendSNSMessage("Unable to initialise SecretsManager helper.  Cron status is unknown.", "cronSystem", sess)
		return db, err
	}

	secretCache.Client = secretsmanager.New(sess)
	MySQLPassword, err := secretCache.GetSecretString(options.MySQLSMSecret)
	if err != nil {
		log.Printf(err.Error())
		sendSNSMessage("Unable to retrieve SecretsManager secret.  Cron status is unknown.", "cronSystem", sess)
		return db, err
	}

	cfg := mysql.Config{
		User:                 options.MySQLUser,
		Passwd:               MySQLPassword,
		Net:                  "tcp",
		Addr:                 options.MySQLHost,
		DBName:               options.MySQLDatabase,
		AllowNativePasswords: true,
		ParseTime:            true,
	}

	db, err = sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		log.Printf(err.Error())
		sendSNSMessage("Unable to connect to database. Cron status unknown.", "cronSystem", sess)
		return db, err
	}
	if err = db.Ping(); err != nil {
		log.Printf(err.Error())
		sendSNSMessage("Unable to connect to database. Cron status unknown.", "cronSystem", sess)
		return db, err
	}

	log.Printf("Connected to database!")

	return db, err
}

// Check that the cron stats table is reachable, and that no cron jobs have been stuck for > 1 run time.
func checkDB(db *sql.DB, sess *session.Session) (err error) {
	rows, err := db.Query("SELECT b.name,IFNULL(status, 'missing cron'),IFNULL(updated_at, FROM_UNIXTIME(0)) AS updated_at FROM (SELECT 'vulnerabilities' AS name UNION ALL SELECT 'cleanups_then_aggregation') b LEFT JOIN (SELECT name, status, updated_at FROM cron_stats WHERE id IN (SELECT MAX(id) FROM cron_stats WHERE status = 'completed' GROUP BY name)) a ON a.name = b.name;")
	defer rows.Close()
	if err != nil {
		log.Printf(err.Error())
		sendSNSMessage("Unable to SELECT cron_stats table.  Unable to continue.", "cronSystem", sess)
		return err
	}
	cronDelayDuration, err := time.ParseDuration(options.CronDelayTolerance)
	if err != nil {
		log.Printf(err.Error())
		sendSNSMessage("Unable to parse cron-delay-tolerance. Check lambda settings.", "cronSystem", sess)
		return err
	}
	cronAlertTimestamp := time.Now().Add(-1 * cronDelayDuration)
	for rows.Next() {
		var row CronStatsRow
		if err := rows.Scan(&row.name, &row.status, &row.updated_at); err != nil {
			log.Printf(err.Error())
			sendSNSMessage("Error scanning row in cron_stats table.  Unable to continue.", "cronSystem", sess)
			return err
		}
		log.Printf("Row %s last updated at %s", row.name, row.updated_at.String())
		if row.updated_at.Before(cronAlertTimestamp) {
			log.Printf("*** %s hasn't updated in more than %s, alerting! (status %s)", options.CronDelayTolerance, row.name, row.status)
			// Fire on the first match and return.  We only need to alert that the crons need looked at, not each cron.
			sendSNSMessage(fmt.Sprintf("Fleet cron '%s' hasn't updated in more than %s. Last status was '%s' at %s.", row.name, options.CronDelayTolerance, row.status, row.updated_at.String()), "cronSystem", sess)
			return nil
		}
	}

	return nil
}

// Check for errors in cron runs.
func checkCrons(db *sql.DB, sess *session.Session) (err error) {
	cronMonitorInterval, err := parseLambdaIntervalToDuration(options.CronMonitorInterval)
	if err != nil {
		log.Printf(err.Error())
		sendSNSMessage("Unable to parse cron-delay-tolerance. Check lambda settings.", "cronSystem", sess)
		return err
	}
	cronAlertTimestamp := time.Now().Add(-1 * cronMonitorInterval)

	// Gather stats about how many runs raised errors since the last check.
	rows, err := db.Query(`
		SELECT 
			name, 
			COUNT(*) AS occurences_in_last_hour, 
			COUNT(errors) as errors_in_last_hour, 
			MAX(updated_at) AS last_updated_at, 
			SUBSTRING_INDEX( GROUP_CONCAT(errors ORDER BY updated_at DESC SEPARATOR 0x1e), 0x1e, 1 ) AS most_recent_error 
		FROM 
			cron_stats 
		WHERE 
			created_at > "` + cronAlertTimestamp.Format("20060102150405") + `" 
		GROUP BY 
			name 
	`)
	if err != nil {
		log.Printf(err.Error())
		sendSNSMessage("Unable to SELECT cron_stats table.  Unable to continue.", "cronSystem", sess)
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var row CronStatsDigestRow
		if err := rows.Scan(&row.name, &row.num_occurences, &row.num_errors, &row.last_updated_at, &row.most_recent_error); err != nil {
			log.Printf(err.Error())
			sendSNSMessage("Error scanning row in cron_stats table.  Unable to continue.", "cronSystem", sess)
			return err
		}
		if row.num_errors == 0 {
			continue
		}
		log.Printf("*** %s job had errors (runs: %d, errors: %d), alerting! (errors %s)", row.name, row.num_occurences, row.num_errors, row.most_recent_error.String)
		if row.num_occurences == 1 {
			sendSNSMessage(fmt.Sprintf("Fleet cron '%s' (last updated %s) raised errors during its last run:\n%s", row.name, row.updated_at.String(), row.most_recent_error.String), "cronJobFailure", sess)
		} else {
			sendSNSMessage(fmt.Sprintf("Fleet cron '%s' (last updated %s) raised errors in %d of the previous %d runs; the most recent is:\n%s", row.name, row.last_updated_at.String(), row.num_errors, row.num_occurences, row.most_recent_error.String), "cronJobFailure", sess)
		}
	}

	return nil
}

func handler(ctx context.Context, name NullEvent) error {
	awsConfig := aws.NewConfig()
	awsConfig = awsConfig.WithRegion(options.AWSRegion)
	if options.AwsEndpointUrl != "" {
		awsConfig = awsConfig.WithEndpoint(options.AwsEndpointUrl)
	}
	sess := session.Must(session.NewSessionWithOptions(
		session.Options{
			SharedConfigState: session.SharedConfigEnable,
			Config:            *awsConfig,
		},
	))

	db, err := setupDB(sess)
	defer func() {
		if db != nil {
			db.Close()
		}
	}()

	if err != nil {
		return nil
	}

	checkDB(db, sess)
	checkCrons(db, sess)
	return nil
}

func main() {
	var err error
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	// Get config from environment
	parser := flags.NewParser(&options, flags.Default)
	if _, err = parser.Parse(); err != nil {
		if flagsErr, ok := err.(*flags.Error); ok && flagsErr.Type == flags.ErrHelp {
			return
		} else {
			log.Fatal(err)
		}
	}

	snsTopics["cronSystem"] = options.SNSCronSystemTopicArns
	snsTopics["cronJobFailure"] = options.SNSCronJobFailureTopicArns
	// For backwards compatibility, fall back to sending cron failure alerts
	// to the same SNS topic as cron system alerts.s
	if snsTopics["cronJobFailure"] == "" {
		snsTopics["cronJobFailure"] = options.SNSCronSystemTopicArns
	}

	// When running from Lambda, this should be read from the environment.
	if options.LambdaRuntimeAPI != "" {
		log.Printf("Starting Lambda handler.")
		lambda.Start(handler)
	} else {
		log.Printf("Lambda execution environment not found.  Falling back to local execution.")
		if err = handler(context.Background(), NullEvent{}); err != nil {
			log.Fatal(err)
		}
	}
}
