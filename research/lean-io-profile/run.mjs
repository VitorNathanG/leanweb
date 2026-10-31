import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { appendFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, '../..');
const work = resolve(directory, '.work');
const mode = process.argv[2];
if (!['build', 'perf', 'measure', 'test'].includes(mode)) throw new Error('Expected build, perf, measure, or test');
const owner = `leanweb-profile-${randomUUID().slice(0, 8)}`;
const client = `${owner}-client`;
const image = 'leanweb-io-profile:lean-4.33.1';
const goImage = 'golang@sha256:f96cc555eb8db430159a3aa6797cd5bae561945b7b0fe7d0e284c63a3b291609';
const active = new Set();
let sequence = 0;
await mkdir(work, { recursive: true });
const delay = ms => new Promise(resolveTimer => setTimeout(resolveTimer, ms));

async function command(args, timeout = 120000, allowFailure = false) {
  const id = ++sequence;
  return new Promise((resolveCommand, reject) => {
    const child = spawn('/usr/bin/time', ['-p', ...args], { cwd: root, detached: true });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      if (!child.pid) return;
      try { process.kill(-child.pid, 'SIGKILL'); }
      catch (error) { if (error.code !== 'ESRCH') reject(error); }
    }, timeout);
    child.stdout.setEncoding('utf8').on('data', data => { stdout += data; });
    child.stderr.setEncoding('utf8').on('data', data => { stderr += data; });
    child.once('error', error => { clearTimeout(timer); reject(error); });
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
    '{{index .Config.Labels "leanweb.profile"}}'], 10000, true);
  if (label.stdout.trim() === owner) {
    await docker(['stop', '--time=2', name], 10000, true);
    await docker(['rm', name], 10000, true);
  }
  active.delete(name);
}

async function load(workload, concurrency, duration, allowFailure = false) {
  const result = await docker(['exec', client, '/experiment/.work/client', '-workload', workload,
    '-concurrency', String(concurrency), '-duration', duration], 30000, allowFailure);
  return { ...JSON.parse(result.stdout), exitCode: result.code };
}

async function ready() {
  for (let attempt = 0; attempt < 30; attempt++) {
    const result = await load('health', 1, '100ms', true);
    if (result.exitCode === 0) return;
    if (Object.keys(result.errorSamples).some(error => error.startsWith('unexpected response:') ||
      error.startsWith('body mismatch:'))) throw new Error(JSON.stringify(result));
    await delay(100);
  }
  throw new Error('Server did not become ready');
}

async function start(variant, sharedNetwork = true) {
  const name = `${owner}-${variant}`;
  active.add(name);
  await docker(['run', '-d', '--name', name, '--label', `leanweb.profile=${owner}`,
    '--network', sharedNetwork ? `container:${client}` : 'none', '--cpuset-cpus=0,1', '--cpus=2',
    '--memory=2g', '--memory-swap=2g', '--pids-limit=1024', '--ulimit', 'nofile=65536:65536',
    ...(mode === 'perf' ? ['--cap-add=PERFMON', '--security-opt', 'seccomp=unconfined'] : []),
    '-v', `${directory}:/experiment`, '-v', `${resolve(work, 'app')}:/workspace:ro`,
    '-v', `${resolve(work, 'bin', variant)}:/workspace/.lake/build/bin:ro`,
    '-w', '/workspace', image,
    ...(sharedNetwork ? [`/experiment/.work/bin/${variant}/leanweb`, '8080'] : ['sleep', 'infinity'])]);
  return name;
}

async function resource(name) {
  const { stdout } = await docker(['exec', name, 'cat', '/proc/1/stat', '/proc/1/status']);
  const [stat, ...status] = stdout.split('\n');
  const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
  const value = key => Number(status.find(line => line.startsWith(`${key}:`))?.match(/\d+/)?.[0]);
  return { ticks: Number(fields[11]) + Number(fields[12]), rss: value('VmRSS'),
    threads: value('Threads') };
}

async function snapshot(name) {
  await docker(['kill', '--signal=USR1', name]);
  await delay(50);
  const result = await docker(['logs', name]);
  const rows = (result.stdout + result.stderr).split('\n').filter(line => line.startsWith('{"runtime_profile":'));
  if (!rows.length) throw new Error('Missing runtime profile snapshot');
  return JSON.parse(rows.at(-1)).runtime_profile;
}

try {
  if (mode === 'build') {
    await command(['node', 'research/lean-io-profile/prepare.mjs'], 400000);
    await docker(['build', '-t', image, 'research/lean-io-profile'], 300000);
    await docker(['run', '--rm', '--cpus=4', '--memory=4g', '-v', `${resolve(work, 'app')}:/workspace`,
      '-w', '/workspace', image, 'lake', 'build', 'leanweb', 'leanweb_tests', 'leanweb_transport_tests', 'task_probe']);
    for (const variant of ['baseline', 'profile']) {
      await docker(['run', '--rm', '--cpus=4', '--memory=4g', '--pids-limit=512',
        '-v', `${directory}:/experiment`, '-v', `${resolve(work, 'app')}:/workspace`, '-w', '/experiment',
        image, 'sh', '-c', 'LEAN_SYSROOT=$(lean --print-prefix) node build.mjs "$1"', 'sh', variant], 240000);
    }
    await docker(['run', '--rm', '--cpus=4', '--memory=2g', '-v', `${root}:/repo:ro`,
      '-v', `${directory}:/experiment`, '-e', 'GOCACHE=/experiment/.work/go-cache', goImage,
      'go', 'build', '-trimpath', '-o', '/experiment/.work/client', '/repo/research/http-throughput/client.go']);
  } else if (mode === 'test') {
    for (const variant of ['baseline', 'profile']) {
      const name = await start(variant, false);
      try {
        for (const args of [[], ['shutdown']]) {
          await docker(['exec', '-e', 'LEAN_NUM_THREADS=2', name, 'timeout', '30s', '.lake/build/bin/task_probe', ...args], 35000);
        }
        await docker(['exec', name, 'timeout', '60s', '.lake/build/bin/leanweb_tests'], 65000);
        await docker(['exec', name, 'timeout', '40s', 'node', '--test', 'Tests/http.test.mjs'], 45000);
        console.log(`${variant}: task, executable, and TCP tests passed`);
      } finally { await remove(name); }
    }
  } else {
    active.add(client);
    await docker(['run', '-d', '--name', client, '--label', `leanweb.profile=${owner}`,
      '--network=none', '--cpuset-cpus=2,3,4,5,6,7', '--cpus=6', '--memory=1g', '--memory-swap=1g',
      '--pids-limit=256', '--ulimit', 'nofile=65536:65536', '-v', `${directory}:/experiment:ro`,
      goImage, 'sleep', 'infinity']);
    await writeFile(resolve(work, `${mode}.ndjson`), '');
    for (let repetition = 1; repetition <= 3; repetition++) {
      const variants = mode === 'perf' ? ['stock'] :
        (repetition % 2 ? ['baseline', 'profile'] : ['profile', 'baseline']);
      for (const variant of variants) {
        const name = await start(variant);
        try {
          await ready();
          await load('health', 32, '3s');
          if (mode === 'perf') {
            const path = `/experiment/.work/perf-${repetition}.data`;
            const recording = docker(['exec', name, 'perf', 'record', '-e', 'cpu-clock', '-F', '997',
              '--call-graph', 'dwarf,8192', '-p', '1', '--inherit', '-o', path, '--', 'sleep', '8'], 12000)
              .then(result => ({ result }), error => ({ error }));
            await delay(300);
            const result = await load('health', 32, '6s');
            const recorded = await recording;
            if (recorded.error) throw recorded.error;
            for (const [label, args] of [['self', ['--no-children', '--call-graph', 'none']],
              ['callers', ['--children']]]) {
              const report = await docker(['exec', name, 'perf', 'report', '-i', path, '--stdio', '--header',
                '--percent-limit', '0.5', '--sort', 'comm,dso,symbol', ...args]);
              await writeFile(resolve(work, `perf-${repetition}-${label}.txt`), report.stdout);
            }
            const report = await docker(['exec', name, 'perf', 'script', '-i', path, '--hide-call-graph',
              '-F', 'comm,pid,tid,event,ip,sym,dso']);
            await writeFile(resolve(work, `perf-${repetition}-samples.txt`), report.stdout);
            await appendFile(resolve(work, 'perf.ndjson'), JSON.stringify({ repetition, ...result }) + '\n');
            console.log(`perf run=${repetition}: ${result.requestsPerSec.toFixed(0)} req/s`);
          } else {
            for (const concurrency of [1, 32, 128]) {
              const before = await resource(name);
              const initial = variant === 'profile' ? await snapshot(name) : null;
              const result = await load('health', concurrency, '6s');
              await delay(100);
              const final = variant === 'profile' ? await snapshot(name) : null;
              const after = await resource(name);
              const row = { variant, repetition, ...result, initial, final,
                serverCPUs: (after.ticks - before.ticks) / 100 / result.seconds,
                rssMiB: after.rss / 1024 };
              await appendFile(resolve(work, 'measure.ndjson'), JSON.stringify(row) + '\n');
              console.log(`${variant} run=${repetition} c=${concurrency}: ${result.requestsPerSec.toFixed(0)} req/s`);
            }
          }
        } finally { await remove(name); }
      }
    }
  }
} finally {
  for (const name of active) await remove(name);
}
