import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { appendFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, '../..');
const work = resolve(directory, '.work');
const smoke = process.argv.includes('--smoke');
const skipBuild = process.argv.includes('--skip-build');
const label = smoke ? 'smoke' : 'full';
const prefix = `leanweb-http-bench-${randomUUID().slice(0, 8)}`;
const clientName = `${prefix}-client`;
const images = {
  lean: process.env.LEAN_BENCH_IMAGE ?? 'sha256:cff3da6cbea33731530b06148d0e0d470be5b6b5692b753efbe3d90a5b68725a',
  node: 'node@sha256:813a7480f28fdadac1f7f5c824bcdad435b5bc1322a5968bbbdef8d058f9dff4',
  go: 'golang@sha256:f96cc555eb8db430159a3aa6797cd5bae561945b7b0fe7d0e284c63a3b291609',
  spring: 'maven@sha256:3a4ab3276a087bf276f79cae96b1af04f53731bec53fb2e651aca79e4b10211e',
};
const cases = [
  { workload: 'health', concurrency: 1 },
  { workload: 'health', concurrency: 8 },
  { workload: 'health', concurrency: 32 },
  { workload: 'health', concurrency: 128 },
  { workload: 'echo', concurrency: 32 },
];
const active = new Set();
let commandNumber = 0;
await mkdir(work, { recursive: true });
await mkdir(resolve(work, 'go-tmp'), { recursive: true });

async function command(args, { timeout = 120000, allowFailure = false } = {}) {
  const number = ++commandNumber;
  return new Promise((resolveCommand, reject) => {
    const child = spawn('/usr/bin/time', ['-p', ...args], { cwd: root });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => child.kill('SIGKILL'), timeout);
    child.stdout.setEncoding('utf8').on('data', data => { stdout += data; });
    child.stderr.setEncoding('utf8').on('data', data => { stderr += data; });
    child.on('error', reject);
    child.on('close', async (code, signal) => {
      clearTimeout(timer);
      await writeFile(resolve(work, `${label}-${prefix}-command-${number}.log`),
        `${JSON.stringify(args)}\nexit=${code} signal=${signal}\n${stdout}\n${stderr}`);
      if (code !== 0 && !allowFailure) {
        reject(new Error(`Command ${number} failed: ${args.join(' ')}\n${stderr}\n${stdout}`));
      } else resolveCommand({ stdout, stderr, code });
    });
  });
}

async function docker(args, options) {
  return command(['docker', ...args], options);
}

async function build() {
  console.log('Building unchanged LeanWeb and benchmark programs');
  await docker(['run', '--rm', '--cpus=4', '--memory=4g', '--pids-limit=1024',
    '-v', `${root}:/repo`, '-w', '/repo', images.lean, 'lake', 'build', 'leanweb']);
  for (const source of ['client', 'server']) {
    const common = ['run', '--rm', '--cpus=4', '--memory=2g',
      '-v', `${directory}:/bench`, '-w', '/bench', '-e', 'GOCACHE=/bench/.work/go-cache',
      '-e', 'GOTMPDIR=/bench/.work/go-tmp', images.go];
    await docker([...common, 'gofmt', '-w', `${source}.go`]);
    await docker([...common, 'go', 'vet', `${source}.go`]);
    await docker([...common, 'go', 'build', '-trimpath', '-o', `.work/${source}`, `${source}.go`]);
  }
  await docker(['run', '--rm', '--cpus=4', '--memory=2g',
    '-v', `${directory}:/bench`, '-w', '/bench', images.node, 'node', '--check', 'server.mjs']);
  await docker(['run', '--rm', '--cpus=4', '--memory=3g', '--pids-limit=1024',
    '-v', `${directory}:/bench`, '-w', '/bench', images.spring,
    'mvn', '-B', '--no-transfer-progress', '-Dmaven.repo.local=/bench/.work/m2',
    '-f', 'spring/pom.xml', 'package'], { timeout: 600000 });
}

async function load(testCase, duration, allowFailure = false) {
  const result = await docker(['exec', clientName, '/bench/.work/client',
    '-workload', testCase.workload, '-concurrency', String(testCase.concurrency),
    '-duration', duration], { timeout: 45000, allowFailure });
  return { ...JSON.parse(result.stdout), exitCode: result.code };
}

async function resources(name) {
  const { stdout } = await docker(['exec', name, 'cat', '/proc/1/stat', '/proc/1/status']);
  const [stat, ...status] = stdout.split('\n');
  const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
  const value = key => Number(status.find(line => line.startsWith(`${key}:`))?.match(/\d+/)?.[0]);
  return {
    cpuTicks: Number(fields[11]) + Number(fields[12]),
    rssKiB: value('VmRSS'), peakRssKiB: value('VmHWM'), threads: value('Threads'),
  };
}

async function remove(name) {
  if (!active.has(name)) return;
  const ownership = await docker(['inspect', name, '--format',
    '{{index .Config.Labels "leanweb.http-benchmark"}}'], { allowFailure: true });
  if (ownership.stdout.trim() !== prefix) {
    active.delete(name);
    return;
  }
  await docker(['stop', '--time=2', name], { allowFailure: true });
  await docker(['rm', name], { allowFailure: true });
  active.delete(name);
}

async function measure(runtime, repetition) {
  const name = `${prefix}-${runtime}`;
  const executable = {
    lean: ['/repo/.lake/build/bin/leanweb', '8080'],
    node: ['node', '/bench/server.mjs'],
    go: ['/bench/.work/server'],
    spring: ['java', '-Xms64m', '-Xmx512m', '-XX:-UsePerfData', '-jar',
      '/bench/.work/spring-target/http-baseline-1.0.jar',
      '--server.address=127.0.0.1', '--server.port=8080',
      '--spring.main.banner-mode=off', '--logging.level.root=ERROR'],
  }[runtime];
  active.add(name);
  try {
    await docker(['run', '-d', '--name', name, '--network', `container:${clientName}`,
      '--label', `leanweb.http-benchmark=${prefix}`,
      '--cpuset-cpus=0,1', '--cpus=2', '--memory=2g', '--memory-swap=2g',
      '--pids-limit=1024', '--ulimit', 'nofile=65536:65536',
      '-v', `${root}:/repo:ro`, '-v', `${directory}:/bench:ro`,
      '-w', '/bench', images[runtime], ...executable]);
    let ready = false;
    for (let attempt = 0; attempt < 40; attempt++) {
      const probe = await load(cases[0], '100ms', true);
      if (probe.exitCode === 0) { ready = true; break; }
      if (Object.keys(probe.errorSamples).some(error => error.startsWith('unexpected response:') ||
          error.startsWith('body mismatch:'))) {
        throw new Error(`${runtime} failed response validation: ${JSON.stringify(probe.errorSamples)}`);
      }
      await new Promise(resolveTimer => setTimeout(resolveTimer, 500));
    }
    if (!ready) throw new Error(`${runtime} did not start`);
    if (!smoke) {
      await load(cases[2], '15s');
      await load(cases[4], '5s');
    }
    const selected = smoke ? [cases[2], cases[4]] : cases;
    const offset = (repetition - 1) % selected.length;
    for (const testCase of [...selected.slice(offset), ...selected.slice(0, offset)]) {
      const before = await resources(name);
      const result = await load(testCase, smoke ? '1s' : '8s');
      const after = await resources(name);
      const row = {
        runtime, repetition, ...result,
        serverCPUs: (after.cpuTicks - before.cpuTicks) / 100 / result.seconds,
        serverRssMiB: after.rssKiB / 1024,
        serverPeakRssMiB: after.peakRssKiB / 1024,
        serverThreads: after.threads,
      };
      await appendFile(resolve(work, `${label}-results.ndjson`), `${JSON.stringify(row)}\n`);
      console.log(`${runtime} run=${repetition} ${testCase.workload} c=${testCase.concurrency}: ` +
        `${row.requestsPerSec.toFixed(0)} req/s p99=${row.p99Ms.toFixed(3)}ms ` +
        `server=${row.serverCPUs.toFixed(2)} CPUs client=${row.clientCPUs.toFixed(2)} CPUs`);
    }
  } finally {
    const logs = await docker(['logs', name], { allowFailure: true });
    await writeFile(resolve(work, `${label}-${prefix}-${runtime}-${repetition}.log`), logs.stdout + logs.stderr);
    await remove(name);
  }
}

try {
  if (!skipBuild) await build();
  const info = await docker(['info', '--format',
    '{{.ServerVersion}} {{.KernelVersion}} {{.Architecture}} CPUs={{.NCPU}} RAM={{.MemTotal}}']);
  const inspection = await docker(['image', 'inspect', ...Object.values(images), '--format',
    '{{json .RepoDigests}} {{.Id}} {{.Architecture}}']);
  const versionCommands = {
    lean: ['lean', '--version'], node: ['node', '--version'],
    go: ['go', 'version'], spring: ['java', '-version'],
  };
  let versions = '';
  for (const [runtime, executable] of Object.entries(versionCommands)) {
    const version = await docker(['run', '--rm', '--network=none', images[runtime], ...executable]);
    versions += `${runtime}: ${version.stdout}${version.stderr.replace(/^(real|user|sys) .*\n/gm, '')}`;
  }
  await writeFile(resolve(work, `${label}-environment.txt`), info.stdout + inspection.stdout + versions);
  await writeFile(resolve(work, `${label}-results.ndjson`), '');
  active.add(clientName);
  await docker(['run', '-d', '--name', clientName, '--network=none',
    '--label', `leanweb.http-benchmark=${prefix}`,
    '--cpuset-cpus=2,3,4,5,6,7', '--cpus=6', '--memory=1g', '--memory-swap=1g',
    '--pids-limit=256', '--ulimit', 'nofile=65536:65536',
    '-v', `${directory}:/bench:ro`, images.go, 'sleep', 'infinity']);
  const settings = await docker(['exec', clientName, 'cat',
    '/proc/sys/net/ipv4/tcp_tw_reuse', '/proc/sys/net/ipv4/ip_local_port_range']);
  const ticks = await docker(['exec', clientName, 'getconf', 'CLK_TCK']);
  if (Number(ticks.stdout.trim()) !== 100) throw new Error('CPU accounting expects 100 ticks/second');
  await appendFile(resolve(work, `${label}-environment.txt`),
    `tcp_tw_reuse; ip_local_port_range:\n${settings.stdout}CLK_TCK=${ticks.stdout}`);
  const runtimeOrder = ['lean', 'node', 'go', 'spring'];
  for (let repetition = 1; repetition <= (smoke ? 1 : 3); repetition++) {
    const offset = repetition - 1;
    for (const runtime of [...runtimeOrder.slice(offset), ...runtimeOrder.slice(0, offset)]) {
      await measure(runtime, repetition);
    }
  }
} finally {
  for (const name of active) await remove(name);
}
