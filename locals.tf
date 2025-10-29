locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  project_prefix = "${var.project_name}-${var.environment}"

  # SQL query for Kinesis Data Analytics - embedded in Terraform
  # This query aggregates payment events by 1-minute tumbling windows
  analytics_sql = <<-SQL
    -- Create source table for payment events from Kinesis input stream
    CREATE TABLE payment_events (
        transaction_id VARCHAR,
        amount DOUBLE,
        currency VARCHAR,
        merchant VARCHAR,
        event_timestamp BIGINT,
        proc_time AS PROCTIME(),
        row_time AS TO_TIMESTAMP(FROM_UNIXTIME(event_timestamp / 1000)),
        WATERMARK FOR row_time AS row_time - INTERVAL '5' SECOND
    ) WITH (
        'connector' = 'kinesis',
        'stream' = '${aws_kinesis_stream.payment_stream.name}',
        'aws.region' = '${data.aws_region.current.region}',
        'format' = 'json',
        'json.timestamp-format.standard' = 'ISO-8601'
    );

    -- Create sink table for aggregated results to Kinesis output stream
    CREATE TABLE aggregated_results (
        window_start TIMESTAMP(3),
        window_end TIMESTAMP(3),
        transaction_count BIGINT,
        total_amount DOUBLE,
        avg_amount DOUBLE,
        row_time TIMESTAMP(3)
    ) WITH (
        'connector' = 'kinesis',
        'stream' = '${aws_kinesis_stream.analytics_output.name}',
        'aws.region' = '${data.aws_region.current.region}',
        'format' = 'json'
    );

    -- Insert aggregated results with 1-minute tumbling windows
    INSERT INTO aggregated_results
    SELECT
        TUMBLE_START(row_time, INTERVAL '1' MINUTE) AS window_start,
        TUMBLE_END(row_time, INTERVAL '1' MINUTE) AS window_end,
        COUNT(*) AS transaction_count,
        SUM(amount) AS total_amount,
        AVG(amount) AS avg_amount,
        TUMBLE_START(row_time, INTERVAL '1' MINUTE) AS row_time
    FROM payment_events
    GROUP BY TUMBLE(row_time, INTERVAL '1' MINUTE);
  SQL
}
