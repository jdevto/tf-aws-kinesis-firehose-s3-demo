// Lambda: Payment Producer (Node.js, AWS SDK v3)
// Generates mock payment events and writes to Kinesis Data Stream

const { KinesisClient, PutRecordsCommand } = require('@aws-sdk/client-kinesis');

const MERCHANTS = [
  'Amazon',
  'Walmart',
  'Target',
  'Best Buy',
  'Home Depot',
  'Costco',
  'Starbucks',
  'McDonalds',
  'Uber',
  'Netflix'
];
const CURRENCIES = ['USD', 'EUR', 'GBP', 'JPY', 'AUD'];

function randomEvent() {
  const amount = parseFloat((Math.random() * 1000 + 1).toFixed(2));
  const currency = CURRENCIES[Math.floor(Math.random() * CURRENCIES.length)];
  const merchant = MERCHANTS[Math.floor(Math.random() * MERCHANTS.length)];
  const now = Date.now();
  const id = Math.random().toString(36).slice(2, 10).toUpperCase();
  return {
    transaction_id: `TXN${id}`,
    amount,
    currency,
    merchant,
    event_timestamp: now
  };
}

exports.handler = async () => {
  const streamName = process.env.STREAM_NAME;
  const batchSize = parseInt(process.env.EVENTS_PER_INVOCATION || '25', 10);
  if (!streamName) {
    console.log('STREAM_NAME env var is required');
    return;
  }

  const client = new KinesisClient({});

  const records = Array.from({ length: batchSize }).map(() => {
    const evt = randomEvent();
    return {
      PartitionKey: evt.merchant,
      Data: Buffer.from(JSON.stringify(evt))
    };
  });

  const cmd = new PutRecordsCommand({ StreamName: streamName, Records: records });
  const res = await client.send(cmd);
  console.log(`PutRecords status: Failed=${res.FailedRecordCount} Total=${records.length}`);
  return { failed: res.FailedRecordCount, total: records.length };
};
