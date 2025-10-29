# Payment Data Pipeline with AWS Kinesis and S3

A real-time payment data pipeline that streams events into Kinesis, aggregates with a Lambda function, and delivers results to S3 via Kinesis Firehose for analytics and storage.

## Architecture

```plaintext
┌─────────────────┐
│ Payment Producer│
│  (Lambda Function)│
└────────┬────────┘
         │
         ↓
┌─────────────────────┐
│ Kinesis Data Stream │
│  (input-stream)     │
└─────┬───────────┬───┘
      │           │
      ↓           ↓
┌───────────┐ ┌──────────────────────┐
│ Kinesis   │ │ Lambda Aggregator    │
│ Firehose  │ │ (1-min windows)      │
│ (raw)     │ │                      │
└─────┬─────┘ │                      │
      │       └──────┬───────────────┘
      ↓              ↓
   ┌─────┐    ┌──────────────┐
   │ S3  │    │ Kinesis Stream│
   │Raw  │    │ (output-stream)│
   └─────┘    └──────┬───────┘
                     ↓
              ┌───────────────┐
              │ Kinesis       │
              │ Firehose      │
              │ (analytics)   │
              └───────┬───────┘
                      ↓
                   ┌─────┐
                   │ S3  │
                   │Analytics│
                   └─────┘
```

### Components

1. **Kinesis Data Stream** - Receives raw payment events
2. **Lambda Aggregator** - Processes and aggregates data in 1-minute tumbling windows
3. **Kinesis Firehose** - Delivers data to S3 with automatic partitioning
4. **S3 Buckets** - Stores both raw and processed data with Hive-style partitioning
5. **Lambda Producer** - Generates and sends mock payment events on a schedule

## Prerequisites

- Terraform >= 1.0
- AWS CLI configured with appropriate credentials
- Node.js 18+ and npm (for producer script)
- AWS region: ap-southeast-2 (Sydney)

## Deployment

### 1. Initialize Terraform

```bash
terraform init
```

### 2. Review the infrastructure

```bash
terraform plan
```

### 3. Deploy the infrastructure

```bash
terraform apply
```

This will create:

- 2 S3 buckets (raw data and analytics results)
- 2 Kinesis streams (input and output)
- 2 Firehose delivery streams
- Lambda producer (scheduled)
- Lambda aggregator (stream trigger)
- Required IAM roles and policies

### 4. Note the outputs

After deployment, note the stream name and bucket names from the outputs:

```bash
terraform output
```

## Producer (Lambda)

The producer is an AWS Lambda function invoked on a schedule (default: every minute) via CloudWatch Events. It sends a batch of random payment events to the input Kinesis stream each invocation.

### Control the schedule

- Change rate in Terraform: `aws_cloudwatch_event_rule.lambda_producer_schedule.schedule_expression`
- Disable by removing the rule/target or setting a cron you prefer

### View producer logs

```bash
aws logs tail /aws/lambda/$(terraform output -raw producer_lambda_name) --follow
```

## Verifying Data Flow

### 1. Check S3 buckets for raw data

```bash
aws s3 ls s3://$(terraform output -raw raw_data_bucket)/data/ --recursive
```

### 2. Check S3 buckets for analytics results (GZIP compressed .json.gz)

```bash
aws s3 ls s3://$(terraform output -raw analytics_results_bucket)/aggregations/ --recursive
```

### 3. View a sample aggregated result

```bash
aws s3 cp s3://$(terraform output -raw analytics_results_bucket)/aggregations/[path-to-file].json.gz - | gunzip -c | jq
```

### 4. Monitor CloudWatch Logs

Aggregator logs:

```bash
aws logs tail /aws/lambda/$(terraform output -raw aggregator_lambda_name) --follow
```

## Data Format

### Input Payment Event

```json
{
  "transaction_id": "TXN1234567",
  "amount": 125.50,
  "currency": "USD",
  "merchant": "Amazon",
  "event_timestamp": 1705317000000
}
```

Note: `event_timestamp` is a Unix timestamp in milliseconds (BIGINT) used by the Lambda aggregator for windowing operations.

### Output Aggregation

```json
{
  "window_start": "2024-01-15T10:30:00.000Z",
  "window_end": "2024-01-15T10:31:00.000Z",
  "transaction_count": 45,
  "total_amount": 5234.67,
  "avg_amount": 116.33
}
```

## Aggregation

The pipeline performs real-time aggregations with 1-minute tumbling windows implemented in the Lambda aggregator:

- **transaction_count**: Number of transactions in the window
- **total_amount**: Sum of all transaction amounts
- **avg_amount**: Average transaction amount

## S3 Data Partitioning

Data is automatically partitioned in S3:

- **Raw data**: `s3://bucket/data/year=YYYY/month=MM/day=DD/hour=HH/`
- **Analytics**: `s3://bucket/aggregations/year=YYYY/month=MM/day=DD/hour=HH/`

This enables efficient querying with tools like Athena or Spark.

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

Note: This will delete all data in the S3 buckets.

## Configuration

Modify variables in `variables.tf` to customize:

- Project name
- Environment
- AWS region

Modify `locals.tf` for naming conventions and tags.

## Security

- S3 buckets have versioning enabled
- Server-side encryption (AES256) enabled on all buckets
- S3 lifecycle policies configured for cost optimization (transition to IA after 30 days, Glacier after 90 days)
- IAM roles follow least privilege principle
- All resources are tagged for organization

## Troubleshooting

### Producer can't send to stream

Ensure:

1. Stream name is correct
2. AWS credentials have kinesis:PutRecord permission
3. Stream exists in the correct region

### No data in S3

Check:

1. Firehose delivery stream status in AWS Console
2. CloudWatch logs for errors
3. S3 bucket permissions
4. Analytics application is running (needs manual start after deployment)

### Aggregator not processing

Check Lambda trigger and logs:

```bash
aws lambda list-event-source-mappings --function-name $(terraform output -raw aggregator_lambda_name)
aws logs tail /aws/lambda/$(terraform output -raw aggregator_lambda_name) --since 10m
```

## License

See LICENSE file.
