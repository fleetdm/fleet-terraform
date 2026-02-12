package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"testing"

	pubsub "cloud.google.com/go/pubsub/v2"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func resetMainTestState() {
	cacheMu.Lock()
	cache = cacheState{}
	cacheMu.Unlock()

	credentialsCacheTTL = defaultCredentialsCacheTTL
	getPublisherFunc = getPublisher
	publishBatchFunc = publishBatch
}

func makeCloudWatchEvent(t *testing.T, payload map[string]interface{}) cloudWatchLogsEvent {
	t.Helper()

	raw, err := json.Marshal(payload)
	require.NoError(t, err)

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	_, err = gz.Write(raw)
	require.NoError(t, err)
	require.NoError(t, gz.Close())

	var ev cloudWatchLogsEvent
	ev.AWSLogs.Data = base64.StdEncoding.EncodeToString(buf.Bytes())
	return ev
}

func TestParseServiceAccountSecret(t *testing.T) {
	t.Run("direct service account", func(t *testing.T) {
		secret := `{"client_email":"x@example.com","private_key":"key"}`
		got, err := parseServiceAccountSecret(secret)
		require.NoError(t, err)

		var parsed serviceAccountCredentials
		require.NoError(t, json.Unmarshal(got, &parsed))
		assert.Equal(t, "x@example.com", parsed.ClientEmail)
	})

	t.Run("nested service_account_json string", func(t *testing.T) {
		secret := `{"service_account_json":"{\"client_email\":\"x@example.com\",\"private_key\":\"key\"}"}`
		_, err := parseServiceAccountSecret(secret)
		require.NoError(t, err)
	})

	t.Run("nested service_account_json object", func(t *testing.T) {
		secret := `{"service_account_json":{"client_email":"x@example.com","private_key":"key"}}`
		_, err := parseServiceAccountSecret(secret)
		require.NoError(t, err)
	})

	t.Run("missing required fields", func(t *testing.T) {
		_, err := parseServiceAccountSecret(`{"client_email":"x@example.com"}`)
		require.Error(t, err)
	})
}

func TestDecodeCloudWatchPayload(t *testing.T) {
	t.Run("success", func(t *testing.T) {
		ev := makeCloudWatchEvent(t, map[string]interface{}{
			"owner":       "123",
			"logGroup":    "group",
			"logStream":   "stream",
			"messageType": "DATA_MESSAGE",
			"logEvents": []map[string]interface{}{
				{"id": "1", "timestamp": 10, "message": "hello"},
			},
		})

		payload, err := decodeCloudWatchPayload(ev)
		require.NoError(t, err)
		assert.Equal(t, "group", payload.LogGroup)
	})

	t.Run("missing data", func(t *testing.T) {
		_, err := decodeCloudWatchPayload(cloudWatchLogsEvent{})
		require.Error(t, err)
	})

	t.Run("invalid base64", func(t *testing.T) {
		var ev cloudWatchLogsEvent
		ev.AWSLogs.Data = "%%%%"
		_, err := decodeCloudWatchPayload(ev)
		require.Error(t, err)
	})
}

func TestBuildOutboundMessages(t *testing.T) {
	payload := &cloudWatchPayload{
		Owner:       "123",
		LogGroup:    "group",
		LogStream:   "stream",
		MessageType: "DATA_MESSAGE",
		LogEvents: []struct {
			ID        string `json:"id"`
			Timestamp int64  `json:"timestamp"`
			Message   string `json:"message"`
		}{
			{ID: "1", Timestamp: 10, Message: "hello"},
		},
	}

	msgs, err := buildOutboundMessages(payload)
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, "group", msgs[0].Attributes["log_group"])

	control, err := buildOutboundMessages(&cloudWatchPayload{MessageType: "CONTROL_MESSAGE"})
	require.NoError(t, err)
	assert.Nil(t, control)
}

func TestResolveBatchSize(t *testing.T) {
	t.Setenv("PUBSUB_BATCH_SIZE", "5")
	assert.Equal(t, 5, resolveBatchSize())

	t.Setenv("PUBSUB_BATCH_SIZE", "2000")
	assert.Equal(t, defaultPubSubBatchMax, resolveBatchSize())

	t.Setenv("PUBSUB_BATCH_SIZE", "nope")
	assert.Equal(t, defaultPubSubBatchMax, resolveBatchSize())
}

func TestSplitBatches(t *testing.T) {
	messages := []outboundMessage{{}, {}, {}, {}, {}}
	batches := splitBatches(messages, 2)
	require.Len(t, batches, 3)
	assert.Len(t, batches[2], 1)
}

func TestHandler(t *testing.T) {
	resetMainTestState()
	t.Cleanup(resetMainTestState)

	t.Setenv("GCP_PUBSUB_PROJECT_ID", "proj")
	t.Setenv("GCP_PUBSUB_TOPIC_ID", "topic")
	t.Setenv("GCP_CREDENTIALS_SECRET_ARN", "arn:aws:secretsmanager:us-east-2:111111111111:secret:x")
	t.Setenv("PUBSUB_BATCH_SIZE", "2")

	ev := makeCloudWatchEvent(t, map[string]interface{}{
		"owner":       "123",
		"logGroup":    "group",
		"logStream":   "stream",
		"messageType": "DATA_MESSAGE",
		"logEvents": []map[string]interface{}{
			{"id": "1", "timestamp": 10, "message": "m1"},
			{"id": "2", "timestamp": 11, "message": "m2"},
			{"id": "3", "timestamp": 12, "message": "m3"},
		},
	})

	var batchSizes []int
	getPublisherFunc = func(ctx context.Context, projectID, topicID, secretARN string) (*pubsub.Publisher, error) {
		return nil, nil
	}
	publishBatchFunc = func(ctx context.Context, publisher *pubsub.Publisher, messages []outboundMessage) error {
		batchSizes = append(batchSizes, len(messages))
		return nil
	}

	resp, err := handler(context.Background(), ev)
	require.NoError(t, err)
	assert.Equal(t, []int{2, 1}, batchSizes)
	assert.Equal(t, 3, resp["published_message_count"])
	assert.Equal(t, "DATA_MESSAGE", resp["message_type"])
}

func TestHandlerPublishError(t *testing.T) {
	resetMainTestState()
	t.Cleanup(resetMainTestState)

	t.Setenv("GCP_PUBSUB_PROJECT_ID", "proj")
	t.Setenv("GCP_PUBSUB_TOPIC_ID", "topic")
	t.Setenv("GCP_CREDENTIALS_SECRET_ARN", "arn:aws:secretsmanager:us-east-2:111111111111:secret:x")

	ev := makeCloudWatchEvent(t, map[string]interface{}{
		"owner":       "123",
		"messageType": "DATA_MESSAGE",
		"logEvents": []map[string]interface{}{
			{"id": "1", "timestamp": 10, "message": "m1"},
		},
	})

	getPublisherFunc = func(ctx context.Context, projectID, topicID, secretARN string) (*pubsub.Publisher, error) {
		return nil, nil
	}
	publishBatchFunc = func(ctx context.Context, publisher *pubsub.Publisher, messages []outboundMessage) error {
		return errors.New("boom")
	}

	_, err := handler(context.Background(), ev)
	require.Error(t, err)
}

func TestHandlerMissingEnv(t *testing.T) {
	resetMainTestState()
	t.Cleanup(resetMainTestState)

	t.Setenv("GCP_PUBSUB_PROJECT_ID", "")
	t.Setenv("GCP_PUBSUB_TOPIC_ID", "topic")
	t.Setenv("GCP_CREDENTIALS_SECRET_ARN", "arn:aws:secretsmanager:us-east-2:111111111111:secret:x")

	ev := makeCloudWatchEvent(t, map[string]interface{}{
		"messageType": "CONTROL_MESSAGE",
	})

	_, err := handler(context.Background(), ev)
	require.Error(t, err)
}
