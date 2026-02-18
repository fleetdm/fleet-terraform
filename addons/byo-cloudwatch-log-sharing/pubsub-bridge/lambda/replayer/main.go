package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	awslambda "github.com/aws/aws-sdk-go-v2/service/lambda"
	"github.com/aws/aws-sdk-go-v2/service/lambda/types"
)

type asyncDestinationMessage struct {
	RequestPayload json.RawMessage `json:"requestPayload"`
	RequestContext struct {
		RequestID string `json:"requestId"`
	} `json:"requestContext"`
}

type lambdaInvoker interface {
	Invoke(ctx context.Context, params *awslambda.InvokeInput, optFns ...func(*awslambda.Options)) (*awslambda.InvokeOutput, error)
}

var (
	lambdaClientOnce sync.Once
	lambdaClient     lambdaInvoker
	lambdaClientErr  error

	getLambdaClientFunc = getLambdaClient
	replayOneFunc       = replayOne
)

func getTargetFunctionName() (string, error) {
	name := strings.TrimSpace(os.Getenv("TARGET_BRIDGE_FUNCTION_NAME"))
	if name == "" {
		return "", errors.New("missing required environment variable: TARGET_BRIDGE_FUNCTION_NAME")
	}
	return name, nil
}

func getLambdaClient(ctx context.Context) (lambdaInvoker, error) {
	lambdaClientOnce.Do(func() {
		cfg, err := awsconfig.LoadDefaultConfig(ctx)
		if err != nil {
			lambdaClientErr = fmt.Errorf("load aws sdk config: %w", err)
			return
		}
		lambdaClient = awslambda.NewFromConfig(cfg)
	})

	if lambdaClientErr != nil {
		return nil, lambdaClientErr
	}
	return lambdaClient, nil
}

func extractOriginalPayload(body string) ([]byte, error) {
	var message asyncDestinationMessage
	if err := json.Unmarshal([]byte(body), &message); err != nil {
		return nil, fmt.Errorf("parse async destination message: %w", err)
	}

	if len(message.RequestPayload) == 0 {
		return nil, errors.New("async destination message does not include requestPayload")
	}

	return message.RequestPayload, nil
}

func replayOne(ctx context.Context, client lambdaInvoker, targetFunctionName string, record events.SQSMessage) error {
	payload, err := extractOriginalPayload(record.Body)
	if err != nil {
		return err
	}

	resp, err := client.Invoke(ctx, &awslambda.InvokeInput{
		FunctionName:   aws.String(targetFunctionName),
		InvocationType: types.InvocationTypeEvent,
		Payload:        payload,
	})
	if err != nil {
		return fmt.Errorf("invoke bridge lambda: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Errorf("invoke bridge lambda unexpected status code: %d", resp.StatusCode)
	}

	return nil
}

func handler(ctx context.Context, event events.SQSEvent) (events.SQSEventResponse, error) {
	targetFunctionName, err := getTargetFunctionName()
	if err != nil {
		return events.SQSEventResponse{}, err
	}

	client, err := getLambdaClientFunc(ctx)
	if err != nil {
		return events.SQSEventResponse{}, err
	}

	failures := make([]events.SQSBatchItemFailure, 0)
	for _, record := range event.Records {
		if err := replayOneFunc(ctx, client, targetFunctionName, record); err != nil {
			failures = append(failures, events.SQSBatchItemFailure{ItemIdentifier: record.MessageId})
		}
	}

	return events.SQSEventResponse{BatchItemFailures: failures}, nil
}

func main() {
	lambda.Start(handler)
}
