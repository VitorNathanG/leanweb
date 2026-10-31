import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const work = resolve(dirname(fileURLToPath(import.meta.url)), '.work');
const rows = (await readFile(resolve(work, 'measure.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
if (rows.length !== 18) throw new Error('Incomplete measured matrix');
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const columns = ['variant', 'repetition', 'concurrency', 'successes', 'errors', 'seconds',
  'requestsPerSec', 'p50Ms', 'p99Ms', 'maxMs', 'serverCPUs', 'rssMiB', 'clientCPUs'];
const metrics = [];
const sampling = [];
for (let repetition = 1; repetition <= 3; repetition++) {
  const tids = new Set();
  const symbols = new Map();
  let samples = 0;
  let kernelSamples = 0;
  const text = await readFile(resolve(work, `perf-${repetition}-samples.txt`), 'utf8');
  for (const line of text.trim().split('\n')) {
    const match = line.match(/^\s*leanweb\s+\d+\/(\d+)\s+cpu-clock:\s+(\w+)\s+(.*?)\s+\((.*?)\)$/);
    if (!match) throw new Error('Unexpected perf sample');
    samples++;
    tids.add(match[1]);
    const kernel = match[2].startsWith('ffff800');
    if (kernel) kernelSamples++;
    const symbol = kernel ? 'unresolved kernel' : match[3];
    symbols.set(symbol, (symbols.get(symbol) ?? 0) + 1);
  }
  sampling.push({ repetition, samples, sampledThreads: tids.size, kernelSamples,
    topSymbols: [...symbols].sort((a, b) => b[1] - a[1]).slice(0, 12) });
}
for (const row of rows) {
  if (row.exitCode !== 0 || row.errors !== 0 || row.successes <= 0) throw new Error('Failed workload');
  if (row.variant !== 'profile') continue;
  for (const [name, final] of Object.entries(row.final)) {
    const initial = row.initial[name];
    const difference = key => final[key] - initial[key];
    const calls = difference('calls');
    const histogram = final.wall_log2_ns.map((value, i) => value - initial.wall_log2_ns[i]);
    if ([calls, difference('cpu_ns'), difference('wall_ns'), ...histogram].some(value => value < 0)) {
      throw new Error('Nonmonotone profile');
    }
    if (Math.abs(histogram.reduce((sum, value) => sum + value, 0) - calls) > 64) {
      throw new Error('Inconsistent profile snapshot');
    }
    metrics.push({ repetition: row.repetition, concurrency: row.concurrency, metric: name, calls,
      callsPerRequest: calls / row.successes, cpuUsPerRequest: difference('cpu_ns') / row.successes / 1000,
      wallUsPerRequest: difference('wall_ns') / row.successes / 1000,
      wallUsPerCall: calls ? difference('wall_ns') / calls / 1000 : 0, histogram });
  }
}
const summary = [];
for (const concurrency of [1, 32, 128]) {
  for (const variant of ['baseline', 'profile']) {
    const group = rows.filter(row => row.variant === variant && row.concurrency === concurrency);
    if (group.length !== 3) throw new Error('Missing repetitions');
    const entry = { variant, concurrency, requestsPerSec: median(group.map(row => row.requestsPerSec)),
      p99Ms: median(group.map(row => row.p99Ms)), serverCPUs: median(group.map(row => row.serverCPUs)),
      min: Math.min(...group.map(row => row.requestsPerSec)), max: Math.max(...group.map(row => row.requestsPerSec)) };
    summary.push(entry);
    console.log(entry);
  }
  console.log(`Profile c=${concurrency}`);
  const names = [...new Set(metrics.map(row => row.metric))];
  for (const metric of names) {
    const group = metrics.filter(row => row.concurrency === concurrency && row.metric === metric);
    console.log(`${metric}: calls/req=${median(group.map(row => row.callsPerRequest)).toFixed(3)} ` +
      `CPU us/req=${median(group.map(row => row.cpuUsPerRequest)).toFixed(3)} ` +
      `wall us/call=${median(group.map(row => row.wallUsPerCall)).toFixed(3)}`);
  }
}
await writeFile(resolve(work, 'results.csv'), [columns.join(','), ...rows.map(row =>
  columns.map(key => row[key]).join(','))].join('\n') + '\n');
await writeFile(resolve(work, 'scopes.json'), JSON.stringify(metrics, null, 2) + '\n');
const scopeColumns = ['repetition', 'concurrency', 'metric', 'calls', 'callsPerRequest',
  'cpuUsPerRequest', 'wallUsPerRequest', 'wallUsPerCall'];
await writeFile(resolve(work, 'scopes.csv'), [scopeColumns.join(','), ...metrics.map(row =>
  scopeColumns.map(key => row[key]).join(','))].join('\n') + '\n');
await writeFile(resolve(work, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
await writeFile(resolve(work, 'sampling.json'), JSON.stringify(sampling, null, 2) + '\n');
const inputs = {};
for (const variant of ['baseline', 'profile']) {
  inputs[variant] = JSON.parse(await readFile(resolve(work, 'runtime', variant, 'inputs.json'), 'utf8'));
}
await writeFile(resolve(work, 'build-inputs.json'), JSON.stringify(inputs, null, 2) + '\n');
if (process.argv.includes('--native')) {
  const native = (await readFile(resolve(work, 'native/measure.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  if (native.length !== 3 || native.some(row => row.errors !== 0 || row.successes !== 8000)) {
    throw new Error('Incomplete or failed native bounded batches');
  }
  const nativeColumns = ['repetition', 'concurrency', 'successes', 'errors', 'seconds', 'requestsPerSec',
    'p50Ms', 'p99Ms', 'maxMs', 'serverCPUs', 'rssMiB', 'clientCPUs', 'goVersion'];
  await writeFile(resolve(work, 'native.csv'), [nativeColumns.join(','), ...native.map(row =>
    nativeColumns.map(key => row[key]).join(','))].join('\n') + '\n');
  const pipeline = (await readFile(resolve(work, 'native/pipeline.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  if (pipeline.length !== 12) throw new Error('Incomplete native pipeline probe');
  await writeFile(resolve(work, 'native-pipeline.json'), JSON.stringify(pipeline, null, 2) + '\n');
  console.log('Native bounded batches:', { requestsPerSec: median(native.map(row => row.requestsPerSec)),
    p99Ms: median(native.map(row => row.p99Ms)), serverCPUs: median(native.map(row => row.serverCPUs)) });
}
