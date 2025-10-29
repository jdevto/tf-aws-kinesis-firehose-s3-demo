// Lambda: Payment Aggregator (Node.js, AWS SDK v3)
// Consumes events from input Kinesis, aggregates per 1-minute tumbling window, writes to output Kinesis

const { KinesisClient, PutRecordsCommand } = require('@aws-sdk/client-kinesis');

function floorToMinute(ms) {
  return Math.floor(ms / 60000) * 60000;
}

exports.handler = async (event) => {
  const outStream = process.env.OUTPUT_STREAM_NAME;
  if (!outStream) {
    console.log('OUTPUT_STREAM_NAME env var is required');
    return;
  }

  const client = new KinesisClient({});

  // windows keyed by windowStartMs
  const windows = new Map();

  for (const rec of event.Records || []) {
    try {
      const payload = Buffer.from(rec.kinesis.data, 'base64').toString('utf-8');
      const obj = JSON.parse(payload);
      const ts = typeof obj.event_timestamp === 'number' ? obj.event_timestamp : Date.parse(obj.timestamp);
      if (!ts || isNaN(ts)) continue;

      const windowStart = floorToMinute(ts);
      const agg = windows.get(windowStart) || { count: 0, total: 0 };
      agg.count += 1;
      agg.total += Number(obj.amount) || 0;
      windows.set(windowStart, agg);
    } catch (e) {
      console.log('Record parse error, skipping:', e.message);
    }
  }

  if (windows.size === 0) {
    console.log('No aggregates to emit');
    return { emitted: 0 };
  }

  // Build output records
  const outRecords = [];
  for (const [windowStart, agg] of windows.entries()) {
    const windowEnd = windowStart + 60000;
    const avg = agg.count > 0 ? agg.total / agg.count : 0;
    const out = {
      window_start: new Date(windowStart).toISOString(),
      window_end: new Date(windowEnd).toISOString(),
      transaction_count: agg.count,
      total_amount: Number(agg.total.toFixed(2)),
      avg_amount: Number(avg.toFixed(2))
    };
    outRecords.push({ PartitionKey: String(windowStart), Data: Buffer.from(JSON.stringify(out)) });
  }

  // Put in batches (max 500)
  let failed = 0; let total = 0;
  for (let i = 0; i < outRecords.length; i += 500) {
    const batch = outRecords.slice(i, i + 500);
    const res = await client.send(new PutRecordsCommand({ StreamName: outStream, Records: batch }));
    failed += res.FailedRecordCount || 0;
    total += batch.length;
  }

  console.log(`Emitted aggregates: total=${total} failed=${failed}`);
  return { emitted: total, failed };
};
