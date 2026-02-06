package main

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	awslambda "github.com/aws/aws-sdk-go-v2/service/lambda"
	"github.com/aws/aws-sdk-go-v2/service/lambda/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type fakeLambdaInvoker struct {
	invokeFn func(ctx context.Context, params *awslambda.InvokeInput, optFns ...func(*awslambda.Options)) (*awslambda.InvokeOutput, error)
}

func (f *fakeLambdaInvoker) Invoke(ctx context.Context, params *awslambda.InvokeInput, optFns ...func(*awslambda.Options)) (*awslambda.InvokeOutput, error) {
	if f.invokeFn != nil {
		return f.invokeFn(ctx, params, optFns...)
	}
	return &awslambda.InvokeOutput{StatusCode: 202}, nil
}

func resetReplayerTestState() {
	lambdaClientOnce = sync.Once{}
	lambdaClient = nil
	lambdaClientErr = nil
	getLambdaClientFunc = getLambdaClient
	replayOneFunc = replayOne
}

func mustJSON(t *testing.T, v interface{}) string {
	t.Helper()
	b, err := json.Marshal(v)
	require.NoError(t, err)
	return string(b)
}

func TestExtractOriginalPayload(t *testing.T) {
	body := `{"requestPayload":{"awslogs":{"data":"abc"}},"requestContext":{"requestId":"r1"}}`
	payload, err := extractOriginalPayload(body)
	require.NoError(t, err)
	assert.Equal(t, `{"awslogs":{"data":"abc"}}`, string(payload))

	_, err = extractOriginalPayload(`{"requestContext":{"requestId":"r1"}}`)
	require.Error(t, err)
}

func TestReplayOne(t *testing.T) {
	record := events.SQSMessage{Body: `{"requestPayload":{"awslogs":{"data":"abc"}}}`}

	t.Run("success", func(t *testing.T) {
		invoker := &fakeLambdaInvoker{invokeFn: func(ctx context.Context, params *awslambda.InvokeInput, optFns ...func(*awslambda.Options)) (*awslambda.InvokeOutput, error) {
			require.NotNil(t, params.FunctionName)
			assert.Equal(t, "bridge", *params.FunctionName)
			assert.Equal(t, types.InvocationTypeEvent, params.InvocationType)
			assert.Equal(t, `{"awslogs":{"data":"abc"}}`, string(params.Payload))
			return &awslambda.InvokeOutput{StatusCode: 202}, nil
		}}

		require.NoError(t, replayOne(context.Background(), invoker, "bridge", record))
	})

	t.Run("invoke error", func(t *testing.T) {
		invoker := &fakeLambdaInvoker{invokeFn: func(ctx context.Context, params *awslambda.InvokeInput, optFns ...func(*awslambda.Options)) (*awslambda.InvokeOutput, error) {
			return nil, errors.New("boom")
		}}

		require.Error(t, replayOne(context.Background(), invoker, "bridge", record))
	})

	t.Run("non 2xx status", func(t *testing.T) {
		invoker := &fakeLambdaInvoker{invokeFn: func(ctx context.Context, params *awslambda.InvokeInput, optFns ...func(*awslambda.Options)) (*awslambda.InvokeOutput, error) {
			return &awslambda.InvokeOutput{StatusCode: 500}, nil
		}}

		require.Error(t, replayOne(context.Background(), invoker, "bridge", record))
	})
}

func TestHandler(t *testing.T) {
	resetReplayerTestState()
	t.Cleanup(resetReplayerTestState)

	t.Setenv("TARGET_BRIDGE_FUNCTION_NAME", "bridge")
	getLambdaClientFunc = func(ctx context.Context) (lambdaInvoker, error) {
		return &fakeLambdaInvoker{}, nil
	}

	replayOneFunc = func(ctx context.Context, client lambdaInvoker, targetFunctionName string, record events.SQSMessage) error {
		if record.MessageId == "bad" {
			return errors.New("replay failed")
		}
		return nil
	}

	event := events.SQSEvent{Records: []events.SQSMessage{
		{MessageId: "ok", Body: mustJSON(t, map[string]interface{}{"requestPayload": map[string]interface{}{"k": "v"}})},
		{MessageId: "bad", Body: mustJSON(t, map[string]interface{}{"requestPayload": map[string]interface{}{"k": "v2"}})},
	}}

	resp, err := handler(context.Background(), event)
	require.NoError(t, err)
	require.Len(t, resp.BatchItemFailures, 1)
	assert.Equal(t, "bad", resp.BatchItemFailures[0].ItemIdentifier)
}

func TestHandlerErrors(t *testing.T) {
	resetReplayerTestState()
	t.Cleanup(resetReplayerTestState)

	t.Run("missing target env", func(t *testing.T) {
		t.Setenv("TARGET_BRIDGE_FUNCTION_NAME", "")
		_, err := handler(context.Background(), events.SQSEvent{})
		require.Error(t, err)
	})

	t.Run("client creation error", func(t *testing.T) {
		t.Setenv("TARGET_BRIDGE_FUNCTION_NAME", "bridge")
		getLambdaClientFunc = func(ctx context.Context) (lambdaInvoker, error) {
			return nil, errors.New("no client")
		}
		_, err := handler(context.Background(), events.SQSEvent{})
		require.Error(t, err)
	})
}
