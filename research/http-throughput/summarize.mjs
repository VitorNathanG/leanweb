import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const work = resolve(dirname(fileURLToPath(import.meta.url)), '.work');
const rows = (await readFile(resolve(work, 'full-results.ndjson'), 'utf8')).trim()
  .split('\n').map(line => JSON.parse(line));
const runtimes = ['lean', 'node', 'go', 'spring'];
const workloads = [['health', 1], ['health', 8], ['health', 32], ['health', 128], ['echo', 32]];
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const mean = values => values.reduce((sum, value) => sum + value, 0) / values.length;
const columns = ['runtime', 'repetition', 'workload', 'concurrency', 'seconds', 'successes',
  'errors', 'requestsPerSec', 'meanMs', 'p50Ms', 'p95Ms', 'p99Ms', 'maxMs', 'serverCPUs',
  'serverRssMiB', 'serverPeakRssMiB', 'serverThreads', 'clientCPUs'];
if (rows.length !== runtimes.length * workloads.length * 3) throw new Error('Incomplete experiment');
for (const row of rows) {
  for (const column of columns.filter(column => !['runtime', 'workload'].includes(column))) {
    if (!Number.isFinite(row[column]) || row[column] < 0) throw new Error(`Invalid ${column}`);
  }
  if (row.seconds < 8 || row.seconds > 12 || row.p50Ms > row.p95Ms || row.p95Ms > row.p99Ms ||
      row.p99Ms > row.maxMs || row.serverRssMiB <= 0 ||
      Math.abs(row.requestsPerSec - row.successes / row.seconds) > 0.001) {
    throw new Error(`Inconsistent trial: ${row.runtime} ${row.workload} ${row.concurrency}`);
  }
}
const groups = [];
for (const [workload, concurrency] of workloads) {
  for (const runtime of runtimes) {
    const group = rows.filter(row => row.runtime === runtime && row.workload === workload &&
      row.concurrency === concurrency);
    if (group.length !== 3 || new Set(group.map(row => row.repetition)).size !== 3 ||
        group.some(row => row.errors !== 0 || row.exitCode !== 0 || row.successes <= 0)) {
      throw new Error(`Invalid trials: ${runtime} ${workload} ${concurrency}`);
    }
    groups.push({
      runtime, workload, concurrency,
      rate: median(group.map(row => row.requestsPerSec)),
      rateMin: Math.min(...group.map(row => row.requestsPerSec)),
      rateMax: Math.max(...group.map(row => row.requestsPerSec)),
      p50: median(group.map(row => row.p50Ms)),
      p95: median(group.map(row => row.p95Ms)),
      p99: median(group.map(row => row.p99Ms)),
      serverCPUs: mean(group.map(row => row.serverCPUs)),
      rss: median(group.map(row => row.serverRssMiB)),
      peakRss: Math.max(...group.map(row => row.serverPeakRssMiB)),
      clientCPUs: mean(group.map(row => row.clientCPUs)),
    });
  }
}
const csv = [columns.join(','), ...rows.map(row => columns.map(column => {
  const value = row[column];
  return typeof value === 'number' && !Number.isInteger(value) ? value.toFixed(6) : value;
}).join(','))].join('\n') + '\n';
await writeFile(resolve(work, 'results.csv'), csv);
await writeFile(resolve(work, 'summary.json'), JSON.stringify(groups, null, 2) + '\n');
const table = [
  '| Workload | Clients | Server | Req/s median (range) | p50 ms | p95 ms | p99 ms | Server CPUs | RSS MiB | Client CPUs |',
  '| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |',
  ...groups.map(group => `| ${group.workload} | ${group.concurrency} | ${group.runtime} | ` +
    `${group.rate.toFixed(0)} (${group.rateMin.toFixed(0)}–${group.rateMax.toFixed(0)}) | ` +
    `${group.p50.toFixed(3)} | ${group.p95.toFixed(3)} | ${group.p99.toFixed(3)} | ` +
    `${group.serverCPUs.toFixed(2)} | ${group.rss.toFixed(1)} | ${group.clientCPUs.toFixed(2)} |`),
].join('\n') + '\n';
await writeFile(resolve(work, 'summary.md'), table);
console.log(table);
