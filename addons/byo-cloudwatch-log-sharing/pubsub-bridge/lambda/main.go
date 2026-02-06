package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"

	pubsub "cloud.google.com/go/pubsub/v2"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"google.golang.org/api/option"
)

const defaultPubSubBatchMax = 1000

type cloudWatchLogsEvent struct {
	AWSLogs struct {
		Data string `json:"data"`
	} `json:"awslogs"`
}

type cloudWatchPayload struct {
	Owner               string   `json:"owner"`
	LogGroup            string   `json:"logGroup"`
	LogStream           string   `json:"logStream"`
	SubscriptionFilters []string `json:"subscriptionFilters"`
	MessageType         string   `json:"messageType"`
	LogEvents           []struct {
		ID        string `json:"id"`
		Timestamp int64  `json:"timestamp"`
		Message   string `json:"message"`
	} `json:"logEvents"`
}

type outboundMessage struct {
	Data       []byte
	Attributes map[string]string
}

type serviceAccountCredentials struct {
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
}

var (
	cacheMu sync.Mutex

	cachedSecretARN       string
	cachedCredentialsJSON []byte

	cachedProjectID      string
	cachedTopicReference string
	cachedPubSubClient   *pubsub.Client
	cachedPublisher      *pubsub.Publisher

	getPublisherFunc = getPublisher
	publishBatchFunc = publishBatch
)

func mustGetEnv(name string) (string, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return "", fmt.Errorf("missing required environment variable: %s", name)
	}
	return value, nil
}

func parseServiceAccountSecret(secretText string) ([]byte, error) {
	candidatePayload := []byte(secretText)

	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(secretText), &raw); err == nil {
		if nested, ok := raw["service_account_json"]; ok && len(nested) > 0 {
			var nestedString string
			if err := json.Unmarshal(nested, &nestedString); err == nil {
				candidatePayload = []byte(nestedString)
			} else {
				candidatePayload = nested
			}
		}
	}

	var creds serviceAccountCredentials
	if err := json.Unmarshal(candidatePayload, &creds); err != nil {
		return nil, fmt.Errorf("parse service account json: %w", err)
	}

	if strings.TrimSpace(creds.ClientEmail) == "" || strings.TrimSpace(creds.PrivateKey) == "" {
		return nil, errors.New("service account json must include client_email and private_key")
	}

	return candidatePayload, nil
}

func getServiceAccountJSON(ctx context.Context, secretARN string) ([]byte, error) {
	cacheMu.Lock()
	if cachedSecretARN == secretARN && len(cachedCredentialsJSON) > 0 {
		cached := make([]byte, len(cachedCredentialsJSON))
		copy(cached, cachedCredentialsJSON)
		cacheMu.Unlock()
		return cached, nil
	}
	cacheMu.Unlock()

	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load aws sdk config: %w", err)
	}

	smClient := secretsmanager.NewFromConfig(cfg)
	secretValue, err := smClient.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{SecretId: aws.String(secretARN)})
	if err != nil {
		return nil, fmt.Errorf("get secret value: %w", err)
	}

	var secretText string
	switch {
	case secretValue.SecretString != nil:
		secretText = *secretValue.SecretString
	case len(secretValue.SecretBinary) > 0:
		secretText = string(secretValue.SecretBinary)
	default:
		return nil, errors.New("secret has no SecretString or SecretBinary payload")
	}

	credentialsJSON, err := parseServiceAccountSecret(secretText)
	if err != nil {
		return nil, err
	}

	cacheMu.Lock()
	cachedSecretARN = secretARN
	cachedCredentialsJSON = make([]byte, len(credentialsJSON))
	copy(cachedCredentialsJSON, credentialsJSON)
	cacheMu.Unlock()

	return credentialsJSON, nil
}

func getPublisher(ctx context.Context, projectID, topicID, secretARN string) (*pubsub.Publisher, error) {
	topicReference := topicID

	cacheMu.Lock()
	if cachedPublisher != nil && cachedProjectID == projectID && cachedTopicReference == topicReference {
		publisher := cachedPublisher
		cacheMu.Unlock()
		return publisher, nil
	}
	cacheMu.Unlock()

	credentialsJSON, err := getServiceAccountJSON(ctx, secretARN)
	if err != nil {
		return nil, err
	}

	client, err := pubsub.NewClient(ctx, projectID, option.WithAuthCredentialsJSON(option.ServiceAccount, credentialsJSON))
	if err != nil {
		return nil, fmt.Errorf("create pubsub client: %w", err)
	}

	publisher := client.Publisher(topicReference)

	cacheMu.Lock()
	if cachedPublisher != nil {
		cachedPublisher.Stop()
	}
	if cachedPubSubClient != nil {
		_ = cachedPubSubClient.Close()
	}

	cachedProjectID = projectID
	cachedTopicReference = topicReference
	cachedPubSubClient = client
	cachedPublisher = publisher
	cacheMu.Unlock()

	return publisher, nil
}

func decodeCloudWatchPayload(event cloudWatchLogsEvent) (*cloudWatchPayload, error) {
	if strings.TrimSpace(event.AWSLogs.Data) == "" {
		return nil, errors.New("event missing awslogs.data")
	}

	compressed, err := base64.StdEncoding.DecodeString(event.AWSLogs.Data)
	if err != nil {
		return nil, fmt.Errorf("decode awslogs.data: %w", err)
	}

	reader, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		return nil, fmt.Errorf("open gzip payload: %w", err)
	}
	defer reader.Close()

	decoded, err := io.ReadAll(reader)
	if err != nil {
		return nil, fmt.Errorf("read gzip payload: %w", err)
	}

	var payload cloudWatchPayload
	if err := json.Unmarshal(decoded, &payload); err != nil {
		return nil, fmt.Errorf("parse cloudwatch payload: %w", err)
	}

	return &payload, nil
}

func buildOutboundMessages(payload *cloudWatchPayload) ([]outboundMessage, error) {
	if payload.MessageType == "CONTROL_MESSAGE" {
		return nil, nil
	}

	messages := make([]outboundMessage, 0, len(payload.LogEvents))
	for _, event := range payload.LogEvents {
		envelope := map[string]interface{}{
			"owner":               payload.Owner,
			"logGroup":            payload.LogGroup,
			"logStream":           payload.LogStream,
			"subscriptionFilters": payload.SubscriptionFilters,
			"id":                  event.ID,
			"timestamp":           event.Timestamp,
			"message":             event.Message,
		}

		serialized, err := json.Marshal(envelope)
		if err != nil {
			return nil, fmt.Errorf("marshal message payload: %w", err)
		}

		messages = append(messages, outboundMessage{
			Data: serialized,
			Attributes: map[string]string{
				"owner":      payload.Owner,
				"log_group":  payload.LogGroup,
				"log_stream": payload.LogStream,
			},
		})
	}

	return messages, nil
}

func resolveBatchSize() int {
	batchSize := defaultPubSubBatchMax
	raw := strings.TrimSpace(os.Getenv("PUBSUB_BATCH_SIZE"))
	if raw == "" {
		return batchSize
	}

	parsed, err := strconv.Atoi(raw)
	if err != nil || parsed < 1 || parsed > defaultPubSubBatchMax {
		return batchSize
	}

	return parsed
}

func splitBatches(messages []outboundMessage, batchSize int) [][]outboundMessage {
	batches := make([][]outboundMessage, 0, (len(messages)+batchSize-1)/batchSize)
	for i := 0; i < len(messages); i += batchSize {
		end := i + batchSize
		if end > len(messages) {
			end = len(messages)
		}
		batches = append(batches, messages[i:end])
	}
	return batches
}

func publishBatch(ctx context.Context, publisher *pubsub.Publisher, messages []outboundMessage) error {
	results := make([]*pubsub.PublishResult, 0, len(messages))
	for _, message := range messages {
		result := publisher.Publish(ctx, &pubsub.Message{
			Data:       message.Data,
			Attributes: message.Attributes,
		})
		results = append(results, result)
	}

	for _, result := range results {
		if _, err := result.Get(ctx); err != nil {
			return err
		}
	}

	return nil
}

func handler(ctx context.Context, event cloudWatchLogsEvent) (map[string]interface{}, error) {
	projectID, err := mustGetEnv("GCP_PUBSUB_PROJECT_ID")
	if err != nil {
		return nil, err
	}

	topicID, err := mustGetEnv("GCP_PUBSUB_TOPIC_ID")
	if err != nil {
		return nil, err
	}

	secretARN, err := mustGetEnv("GCP_CREDENTIALS_SECRET_ARN")
	if err != nil {
		return nil, err
	}

	payload, err := decodeCloudWatchPayload(event)
	if err != nil {
		return nil, err
	}

	messages, err := buildOutboundMessages(payload)
	if err != nil {
		return nil, err
	}

	messageType := payload.MessageType
	if messageType == "" {
		messageType = "UNKNOWN"
	}

	if len(messages) == 0 {
		return map[string]interface{}{
			"published_message_count": 0,
			"message_type":            messageType,
		}, nil
	}

	publisher, err := getPublisherFunc(ctx, projectID, topicID, secretARN)
	if err != nil {
		return nil, err
	}

	batchSize := resolveBatchSize()
	for _, batch := range splitBatches(messages, batchSize) {
		if err := publishBatchFunc(ctx, publisher, batch); err != nil {
			return nil, err
		}
	}

	return map[string]interface{}{
		"published_message_count": len(messages),
		"message_type":            messageType,
	}, nil
}

func main() {
	lambda.Start(handler)
}
