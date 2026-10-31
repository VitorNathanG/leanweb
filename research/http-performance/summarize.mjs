import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const work = resolve(dirname(fileURLToPath(import.meta.url)), '.work');
const readLines = async name => (await readFile(resolve(work, name), 'utf8')).trim()
  .split('\n').map(line => JSON.parse(line));
const measured = await readLines('measure.ndjson');
const screened = await readLines('screen.ndjson');
const pipeline = await readLines('pipeline.ndjson');
if (measured.length !== 24 || screened.length !== 9 || pipeline.length !== 12) {
  throw new Error('Incomplete experiment');
}
const columns = ['kind', 'variant', 'repetition', 'workload', 'concurrency', 'seconds',
  'successes', 'errors', 'requestsPerSec', 'p50Ms', 'p95Ms', 'p99Ms', 'maxMs', 'serverCPUs',
  'rssMiB', 'peakRssMiB', 'threads', 'clientCPUs'];
const rows = [...measured.map(row => ({ kind: 'measure', ...row })),
  ...screened.map(row => ({ kind: 'screen', ...row }))];
for (const row of rows) {
  if (row.errors !== 0 || row.exitCode !== 0 || row.successes <= 0) throw new Error('Failed trial');
  for (const column of columns.slice(2).filter(column => column !== 'workload')) {
    if (!Number.isFinite(row[column]) || row[column] < 0) throw new Error(`Invalid ${column}`);
  }
}
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const summary = [];
for (const [workload, concurrency] of [['health', 1], ['health', 32], ['health', 128], ['echo', 32]]) {
  for (const variant of ['baseline', 'native']) {
    const group = measured.filter(row => row.workload === workload && row.concurrency === concurrency &&
      row.variant === variant);
    if (group.length !== 3 || new Set(group.map(row => row.repetition)).size !== 3) {
      throw new Error('Missing repetition');
    }
    summary.push({ workload, concurrency, variant, rate: median(group.map(row => row.requestsPerSec)),
      min: Math.min(...group.map(row => row.requestsPerSec)), max: Math.max(...group.map(row => row.requestsPerSec)),
      p50: median(group.map(row => row.p50Ms)), p99: median(group.map(row => row.p99Ms)),
      rss: median(group.map(row => row.rssMiB)), cpu: median(group.map(row => row.serverCPUs)) });
  }
}
const traces = [];
for (const variant of ['baseline', 'pool', 'native']) {
  const run = JSON.parse(await readFile(resolve(work, `trace-${variant}.json`), 'utf8'));
  const text = await readFile(resolve(work, `trace-${variant}.txt`), 'utf8');
  const calls = syscall => {
    const line = text.split('\n').find(line => line.trim().split(/\s+/).at(-1) === syscall);
    return line ? Number(line.trim().split(/\s+/)[3]) : 0;
  };
  traces.push({ variant, requests: run.readyRequests + run.successes,
    clone: calls('clone') + calls('clone3'), futex: calls('futex'), getrandom: calls('getrandom') });
}
await writeFile(resolve(work, 'results.csv'), [columns.join(','), ...rows.map(row => columns.map(column => {
  const value = row[column];
  return typeof value === 'number' && !Number.isInteger(value) ? value.toFixed(6) : value;
}).join(','))].join('\n') + '\n');
await writeFile(resolve(work, 'diagnostics.json'), JSON.stringify({ pipeline, traces }, null, 2) + '\n');
await writeFile(resolve(work, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
for (const row of summary) console.log(`${row.workload} c=${row.concurrency} ${row.variant}: ` +
  `${row.rate.toFixed(0)} (${row.min.toFixed(0)}–${row.max.toFixed(0)}) req/s; ` +
  `p50=${row.p50.toFixed(3)} p99=${row.p99.toFixed(3)}ms; RSS=${row.rss.toFixed(1)}MiB; CPU=${row.cpu.toFixed(2)}`);
console.log(JSON.stringify({ measuredRequests: measured.reduce((sum, row) => sum + row.successes, 0),
  screenRequests: screened.reduce((sum, row) => sum + row.successes, 0), traces }, null, 2));
