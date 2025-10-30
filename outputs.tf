output "kinesis_stream_arn" {
  description = "ARN of the input Kinesis stream"
  value       = aws_kinesis_stream.payment_stream.arn
}

output "kinesis_stream_name" {
  description = "Name of the input Kinesis stream"
  value       = aws_kinesis_stream.payment_stream.name
}

output "raw_data_bucket" {
  description = "Name of the raw data S3 bucket"
  value       = aws_s3_bucket.raw_data.id
}

output "analytics_results_bucket" {
  description = "Name of the analytics results S3 bucket"
  value       = aws_s3_bucket.analytics_results.id
}


output "analytics_output_stream" {
  description = "Name of the analytics output stream"
  value       = aws_kinesis_stream.analytics_output.name
}

output "producer_lambda_name" {
  description = "Name of the Lambda producer function"
  value       = aws_lambda_function.producer.function_name
}

output "producer_schedule_rule" {
  description = "CloudWatch Events rule that schedules the producer"
  value       = aws_cloudwatch_event_rule.lambda_producer_schedule.name
}

output "aggregator_lambda_name" {
  description = "Name of the Lambda aggregator function"
  value       = aws_lambda_function.aggregator.function_name
}
