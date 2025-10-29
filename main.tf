data "aws_region" "current" {}

# S3 Buckets
resource "aws_s3_bucket" "raw_data" {
  bucket        = "${local.project_prefix}-raw-data"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${local.project_prefix}-raw-data"
  })
}

# Package Lambda producer code
data "archive_file" "lambda_producer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-producer"
  output_path = "${path.module}/build/lambda-producer.zip"
  depends_on  = [null_resource.lambda_build]
}

# Package Lambda aggregator code
data "archive_file" "lambda_aggregator_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-aggregator"
  output_path = "${path.module}/build/lambda-aggregator.zip"
  depends_on  = [null_resource.lambda_build]
}

# Build Lambda dependencies locally so node_modules are included in archives
resource "null_resource" "lambda_build" {
  triggers = {
    producer_pkg   = filesha1("${path.module}/lambda-producer/package.json")
    aggregator_pkg = filesha1("${path.module}/lambda-aggregator/package.json")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      cd ${path.module}/lambda-producer && npm ci || npm install
      cd ${path.module}/lambda-aggregator && npm ci || npm install
    EOT
  }
}

# IAM role for Lambda producer
resource "aws_iam_role" "lambda_producer_role" {
  name = "${local.project_prefix}-producer-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "lambda.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${local.project_prefix}-producer-lambda-role" })
}

resource "aws_iam_role_policy" "lambda_producer_policy" {
  name = "${local.project_prefix}-producer-lambda-policy"
  role = aws_iam_role.lambda_producer_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid : "KinesisWrite",
        Effect : "Allow",
        Action : [
          "kinesis:PutRecord",
          "kinesis:PutRecords",
          "kinesis:DescribeStream"
        ],
        Resource : [aws_kinesis_stream.payment_stream.arn]
      },
      {
        Sid : "Logs",
        Effect : "Allow",
        Action : [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource : "arn:aws:logs:${data.aws_region.current.region}:*:*"
      }
    ]
  })
}

# IAM role for Lambda aggregator
resource "aws_iam_role" "lambda_aggregator_role" {
  name = "${local.project_prefix}-aggregator-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "lambda.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${local.project_prefix}-aggregator-lambda-role" })
}

resource "aws_iam_role_policy" "lambda_aggregator_policy" {
  name = "${local.project_prefix}-aggregator-lambda-policy"
  role = aws_iam_role.lambda_aggregator_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid : "KinesisRead",
        Effect : "Allow",
        Action : [
          "kinesis:DescribeStream",
          "kinesis:GetShardIterator",
          "kinesis:GetRecords",
          "kinesis:ListShards"
        ],
        Resource : [aws_kinesis_stream.payment_stream.arn]
      },
      {
        Sid : "KinesisWrite",
        Effect : "Allow",
        Action : [
          "kinesis:PutRecord",
          "kinesis:PutRecords"
        ],
        Resource : [aws_kinesis_stream.analytics_output.arn]
      },
      {
        Sid : "Logs",
        Effect : "Allow",
        Action : [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource : "arn:aws:logs:${data.aws_region.current.region}:*:*"
      }
    ]
  })
}

# CloudWatch log group for Lambda aggregator
resource "aws_cloudwatch_log_group" "lambda_aggregator" {
  name              = "/aws/lambda/${local.project_prefix}-aggregator"
  retention_in_days = 1

  lifecycle {
    prevent_destroy = false
  }

  tags = local.common_tags
}

# Lambda aggregator function
resource "aws_lambda_function" "aggregator" {
  function_name = "${local.project_prefix}-aggregator"
  role          = aws_iam_role.lambda_aggregator_role.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"

  filename         = data.archive_file.lambda_aggregator_zip.output_path
  source_code_hash = data.archive_file.lambda_aggregator_zip.output_base64sha256

  environment {
    variables = {
      OUTPUT_STREAM_NAME = aws_kinesis_stream.analytics_output.name
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_aggregator_policy,
    aws_cloudwatch_log_group.lambda_aggregator
  ]

  tags = local.common_tags
}

# Event source mapping: input stream -> aggregator
resource "aws_lambda_event_source_mapping" "aggregator_from_input" {
  event_source_arn                   = aws_kinesis_stream.payment_stream.arn
  function_name                      = aws_lambda_function.aggregator.arn
  starting_position                  = "TRIM_HORIZON"
  batch_size                         = 100
  maximum_batching_window_in_seconds = 5
  enabled                            = true
}

# CloudWatch log group for Lambda producer
resource "aws_cloudwatch_log_group" "lambda_producer" {
  name              = "/aws/lambda/${local.project_prefix}-producer"
  retention_in_days = 1

  lifecycle {
    prevent_destroy = false
  }

  tags = local.common_tags
}

# Lambda function
resource "aws_lambda_function" "producer" {
  function_name = "${local.project_prefix}-producer"
  role          = aws_iam_role.lambda_producer_role.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"

  filename         = data.archive_file.lambda_producer_zip.output_path
  source_code_hash = data.archive_file.lambda_producer_zip.output_base64sha256

  environment {
    variables = {
      STREAM_NAME           = aws_kinesis_stream.payment_stream.name
      EVENTS_PER_INVOCATION = "25"
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_producer_policy,
    aws_cloudwatch_log_group.lambda_producer
  ]

  tags = local.common_tags
}

# Schedule Lambda with CloudWatch Events (every minute)
resource "aws_cloudwatch_event_rule" "lambda_producer_schedule" {
  name                = "${local.project_prefix}-producer-schedule"
  schedule_expression = "rate(1 minute)"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "lambda_producer_target" {
  rule      = aws_cloudwatch_event_rule.lambda_producer_schedule.name
  target_id = "lambda-producer"
  arn       = aws_lambda_function.producer.arn
}

resource "aws_lambda_permission" "allow_events_invoke" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.producer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_producer_schedule.arn
}

resource "aws_s3_bucket_versioning" "raw_data" {
  bucket = aws_s3_bucket.raw_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_data" {
  bucket = aws_s3_bucket.raw_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "raw_data" {
  bucket = aws_s3_bucket.raw_data.id

  rule {
    id     = "transition_to_ia"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }

  rule {
    id     = "transition_to_glacier"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }

  rule {
    id     = "delete_old_versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

resource "aws_s3_bucket" "analytics_results" {
  bucket        = "${local.project_prefix}-analytics-results"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${local.project_prefix}-analytics-results"
  })
}

resource "aws_s3_bucket_versioning" "analytics_results" {
  bucket = aws_s3_bucket.analytics_results.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "analytics_results" {
  bucket = aws_s3_bucket.analytics_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "analytics_results" {
  bucket = aws_s3_bucket.analytics_results.id

  rule {
    id     = "transition_to_ia"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }

  rule {
    id     = "transition_to_glacier"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }

  rule {
    id     = "delete_old_versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# Kinesis Data Stream
resource "aws_kinesis_stream" "payment_stream" {
  name             = "${local.project_prefix}-input-stream"
  shard_count      = 1
  retention_period = 24

  tags = merge(local.common_tags, {
    Name = "${local.project_prefix}-input-stream"
  })
}

# IAM Role for Kinesis Analytics

# Output Kinesis Stream for Analytics
resource "aws_kinesis_stream" "analytics_output" {
  name             = "${local.project_prefix}-output-stream"
  shard_count      = 1
  retention_period = 24

  tags = local.common_tags
}

# IAM Role for Kinesis Firehose
resource "aws_iam_role" "firehose_role" {
  name = "${local.project_prefix}-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "firehose.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.project_prefix}-firehose-role"
  })
}

resource "aws_iam_role_policy" "firehose_policy" {
  name = "${local.project_prefix}-firehose-policy"
  role = aws_iam_role.firehose_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads"
        ]
        Resource = [
          aws_s3_bucket.raw_data.arn,
          aws_s3_bucket.analytics_results.arn
        ]
      },
      {
        Sid    = "S3ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = [
          "${aws_s3_bucket.raw_data.arn}/*",
          "${aws_s3_bucket.analytics_results.arn}/*"
        ]
      },
      {
        Sid    = "KinesisReadAccess"
        Effect = "Allow"
        Action = [
          "kinesis:DescribeStream",
          "kinesis:GetShardIterator",
          "kinesis:GetRecords",
          "kinesis:ListShards"
        ]
        Resource = [
          aws_kinesis_stream.payment_stream.arn,
          aws_kinesis_stream.analytics_output.arn
        ]
      },
      {
        Sid    = "CloudWatchLogAccess"
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:*:*"
      }
    ]
  })
}

# CloudWatch Log Group for Analytics


# Kinesis Firehose for Raw Data
resource "aws_kinesis_firehose_delivery_stream" "raw_data_firehose" {
  name        = "${local.project_prefix}-raw-firehose"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.payment_stream.arn
    role_arn           = aws_iam_role.firehose_role.arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose_role.arn
    bucket_arn          = aws_s3_bucket.raw_data.arn
    prefix              = "data/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    buffering_size      = 1
    buffering_interval  = 60
    compression_format  = "UNCOMPRESSED"
  }

  tags = local.common_tags
}

# Kinesis Firehose for Analytics Results
resource "aws_kinesis_firehose_delivery_stream" "analytics_firehose" {
  name        = "${local.project_prefix}-analytics-firehose"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.analytics_output.arn
    role_arn           = aws_iam_role.firehose_role.arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose_role.arn
    bucket_arn          = aws_s3_bucket.analytics_results.arn
    prefix              = "aggregations/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    buffering_size      = 1
    buffering_interval  = 60
    compression_format  = "GZIP"
    file_extension      = ".json.gz"
  }

  tags = local.common_tags
}
