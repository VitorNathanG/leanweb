import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { appendFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, '../..');
const work = resolve(directory, '.work');
const mode = process.argv[2];
if (!['build', 'pipeline', 'trace', 'screen', 'measure'].includes(mode)) throw new Error('Expected build, pipeline, trace, screen, or measure');
const owner = `leanweb-perf-${randomUUID().slice(0, 8)}`;
const clientName = `${owner}-client`;
const leanImage = 'sha256:cff3da6cbea33731530b06148d0e0d470be5b6b5692b753efbe3d90a5b68725a';
const goImage = 'golang@sha256:f96cc555eb8db430159a3aa6797cd5bae561945b7b0fe7d0e284c63a3b291609';
const active = new Set();
let sequence = 0;
await mkdir(work, { recursive: true });
await mkdir(resolve(work, 'go-tmp'), { recursive: true });

async function command(args, timeout = 120000, allowFailure = false) {
  const id = ++sequence;
  return new Promise((resolveCommand, reject) => {
    const child = spawn('/usr/bin/time', ['-p', ...args], { cwd: root });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => child.kill('SIGKILL'), timeout);
    child.stdout.setEncoding('utf8').on('data', data => { stdout += data; });
    child.stderr.setEncoding('utf8').on('data', data => { stderr += data; });
    child.once('error', reject);
    child.once('close', async code => {
      clearTimeout(timer);
      await writeFile(resolve(work, `${mode}-${owner}-${id}.log`),
        `${JSON.stringify(args)}\nexit=${code}\n${stdout}\n${stderr}`);
      if (code !== 0 && !allowFailure) reject(new Error(`${args.join(' ')}\n${stdout}\n${stderr}`));
      else resolveCommand({ stdout, stderr, code });
    });
  });
}
const docker = (args, timeout, allowFailure) => command(['docker', ...args], timeout, allowFailure);

async function remove(name) {
  if (!active.has(name)) return;
  const label = await docker(['inspect', name, '--format',
    '{{index .Config.Labels "leanweb.performance"}}'], 10000, true);
  if (label.stdout.trim() === owner) {
    await docker(['stop', '--time=2', name], 10000, true);
    await docker(['rm', name], 10000, true);
  }
  active.delete(name);
}

async function load(workload, concurrency, duration, allowFailure = false) {
  const result = await docker(['exec', clientName, '/bench/.work/client', '-workload', workload,
    '-concurrency', String(concurrency), '-duration', duration], 45000, allowFailure);
  return { ...JSON.parse(result.stdout), exitCode: result.code };
}

async function ready() {
  for (let attempt = 0; attempt < 30; attempt++) {
    const result = await load('health', 1, '100ms', true);
    if (result.exitCode === 0) return result.successes;
    if (Object.keys(result.errorSamples).some(error => error.startsWith('unexpected response:') ||
        error.startsWith('body mismatch:'))) throw new Error(JSON.stringify(result));
    await new Promise(resolveTimer => setTimeout(resolveTimer, 100));
  }
  throw new Error('Server did not become ready');
}

async function resource(name) {
  const { stdout } = await docker(['exec', name, 'cat', '/proc/1/stat', '/proc/1/status']);
  const [stat, ...status] = stdout.split('\n');
  const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
  const value = key => Number(status.find(line => line.startsWith(`${key}:`))?.match(/\d+/)?.[0]);
  return { ticks: Number(fields[11]) + Number(fields[12]), rss: value('VmRSS'),
    peak: value('VmHWM'), threads: value('Threads') };
}

async function server(variant, trace = false) {
  const name = `${owner}-${variant}`;
  const executable = ['/app/.lake/build/bin/leanweb', '8080'];
  const args = trace ? ['timeout', '--signal=INT', '--kill-after=2s', '8s', 'strace', '-f', '-c',
    '-o', `/bench/.work/trace-${variant}.txt`, ...executable] : executable;
  active.add(name);
  await docker(['run', '-d', '--name', name, '--label', `leanweb.performance=${owner}`,
    '--network', `container:${clientName}`, '--cpuset-cpus=0,1', '--cpus=2', '--memory=2g',
    '--memory-swap=2g', '--pids-limit=1024', '--ulimit', 'nofile=65536:65536',
    '-v', `${resolve(work, variant)}:/app:ro`, '-v', `${directory}:/bench`, '-w', '/app',
    trace ? 'leanweb-http-profile:lean-4.33.1' : leanImage, ...args]);
  return name;
}

try {
  if (mode === 'build') {
    await command(['node', 'research/http-performance/prepare.mjs']);
    for (const variant of ['baseline', 'pool', 'native']) {
      await docker(['run', '--rm', '--cpus=4', '--memory=4g', '-v',
        `${resolve(work, variant)}:/workspace`, '-w', '/workspace', leanImage,
        'lake', 'build', ...(variant === 'baseline' ? ['leanweb', 'pipeline_probe'] :
          ['leanweb', 'leanweb_tests', 'leanweb_transport_tests'])]);
    }
    await docker(['run', '--rm', '--cpus=4', '--memory=2g', '-v', `${root}:/repo:ro`,
      '-v', `${directory}:/bench`, '-w', '/bench', '-e', 'GOCACHE=/bench/.work/go-cache',
      '-e', 'GOTMPDIR=/bench/.work/go-tmp', goImage, 'go', 'build', '-trimpath', '-o',
      '/bench/.work/client', '/repo/research/http-throughput/client.go']);
  } else if (mode === 'pipeline') {
    const result = await docker(['run', '--rm', '--network=none', '--cpuset-cpus=0,1', '--cpus=2',
      '--memory=2g', '-v', `${resolve(work, 'baseline')}:/app:ro`, '-w', '/app', leanImage,
      '/app/.lake/build/bin/pipeline_probe']);
    await writeFile(resolve(work, 'pipeline.ndjson'), result.stdout);
    console.log(result.stdout);
  } else {
    active.add(clientName);
    await docker(['run', '-d', '--name', clientName, '--label', `leanweb.performance=${owner}`,
      '--network=none', '--cpuset-cpus=2,3,4,5,6,7', '--cpus=6', '--memory=1g', '--memory-swap=1g',
      '--pids-limit=256', '--ulimit', 'nofile=65536:65536', '-v', `${directory}:/bench:ro`,
      goImage, 'sleep', 'infinity']);
    if (mode === 'trace') {
      for (const variant of ['baseline', 'pool', 'native']) {
        const name = await server(variant, true);
        try {
          const readyRequests = await ready();
          const result = await load('health', 32, '3s');
          await docker(['wait', name], 15000);
          await writeFile(resolve(work, `trace-${variant}.json`), JSON.stringify({
            variant, readyRequests, ...result,
          }, null, 2) + '\n');
          console.log(`${variant}: ${readyRequests + result.successes} traced requests`);
        } finally { await remove(name); }
      }
    } else {
      await writeFile(resolve(work, `${mode}.ndjson`), '');
      const cases = mode === 'screen' ? [['health', 32]] :
        [['health', 1], ['health', 32], ['health', 128], ['echo', 32]];
      const variants = mode === 'screen' ? ['baseline', 'pool', 'native'] : ['baseline', 'native'];
      for (let repetition = 1; repetition <= 3; repetition++) {
        for (const variant of repetition % 2 ? variants : variants.toReversed()) {
          const name = await server(variant);
          try {
            await ready();
            await load('health', 32, mode === 'screen' ? '1s' : '5s');
            if (mode !== 'screen') await load('echo', 32, '3s');
            const offset = repetition - 1;
            for (const [workload, concurrency] of [...cases.slice(offset), ...cases.slice(0, offset)]) {
              const before = await resource(name);
              const result = await load(workload, concurrency, mode === 'screen' ? '2s' : '8s');
              const after = await resource(name);
              const row = { variant, repetition, ...result,
                serverCPUs: (after.ticks - before.ticks) / 100 / result.seconds,
                rssMiB: after.rss / 1024, peakRssMiB: after.peak / 1024, threads: after.threads };
              await appendFile(resolve(work, `${mode}.ndjson`), JSON.stringify(row) + '\n');
              console.log(`${variant} run=${repetition} ${workload} c=${concurrency}: ` +
                `${result.requestsPerSec.toFixed(0)} req/s p99=${result.p99Ms.toFixed(3)}ms ` +
                `CPU=${row.serverCPUs.toFixed(2)} RSS=${row.rssMiB.toFixed(1)}MiB`);
            }
          } finally { await remove(name); }
        }
      }
    }
  }
} finally {
  for (const name of active) await remove(name);
}
