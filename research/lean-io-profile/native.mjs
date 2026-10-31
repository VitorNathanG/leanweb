import { spawn } from 'node:child_process';
import { cp, mkdir, readFile, writeFile, appendFile } from 'node:fs/promises';
import net from 'node:net';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, '../..');
const work = resolve(directory, '.work/native');
const mode = process.argv[2];
if (process.platform !== 'darwin' || !['build', 'measure', 'test'].includes(mode)) {
  throw new Error('Expected build, measure, or test on macOS');
}
await mkdir(work, { recursive: true });
let sequence = 0;
const delay = ms => new Promise(resolveTimer => setTimeout(resolveTimer, ms));

async function command(args, cwd = work, timeout = 120000, allowFailure = false) {
  const id = ++sequence;
  return new Promise((resolveCommand, reject) => {
    const child = spawn('/usr/bin/time', ['-p', ...args], { cwd, detached: true,
      env: { ...process.env, GOMAXPROCS: '6' } });
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
      await writeFile(resolve(work, `${mode}-${id}.log`), `${JSON.stringify(args)}\n${stdout}\n${stderr}`);
      if (code !== 0 && !allowFailure) reject(new Error(`${args.join(' ')}\n${stdout}\n${stderr}`));
      else resolveCommand({ code, stdout, stderr });
    });
  });
}

async function startServer() {
  const reservation = net.createServer();
  await new Promise((resolveListen, reject) => {
    reservation.once('error', reject);
    reservation.listen(0, '127.0.0.1', resolveListen);
  });
  const port = reservation.address().port;
  await new Promise(resolveClose => reservation.close(resolveClose));
  const child = spawn(resolve(work, 'app/.lake/build/bin/leanweb'), [String(port)], { cwd: work });
  let logs = '';
  let spawnError;
  child.stdout.on('data', data => { logs += data; });
  child.stderr.on('data', data => { logs += data; });
  child.once('error', error => { spawnError = error; });
  const closed = new Promise(resolveClose => child.once('close', resolveClose));
  async function stop() {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    const force = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }, 2000);
    await closed;
    clearTimeout(force);
    await writeFile(resolve(work, `server-${port}.log`), logs);
  }
  try {
    for (let attempt = 0; attempt < 40; attempt++) {
      if (spawnError) throw spawnError;
      if (child.exitCode !== null || child.signalCode !== null) throw new Error(logs);
      const result = await command(['/usr/sbin/lsof', '-a', '-p', String(child.pid),
        `-iTCP:${port}`, '-sTCP:LISTEN', '-t'], work, 5000, true);
      if (result.code === 0 && result.stdout.trim() === String(child.pid)) return { child, port, stop };
      await delay(50);
    }
    throw new Error('Owned native server did not listen');
  } catch (error) { await stop(); throw error; }
}

async function load(server, concurrency, duration, requests = 8000) {
  if (server.child.exitCode !== null || server.child.signalCode !== null) throw new Error('Server exited');
  const result = await command([resolve(work, 'client'), '-address', `127.0.0.1:${server.port}`,
    '-concurrency', String(concurrency), '-duration', duration, '-requests', String(requests)], work, 20000);
  return JSON.parse(result.stdout);
}

async function resource(server) {
  const { stdout } = await command(['/bin/ps', '-p', String(server.child.pid), '-o', 'time=', '-o', 'rss=']);
  const [time, rss] = stdout.trim().split(/\s+/);
  const seconds = time.split(':').reduce((sum, part) => sum * 60 + Number(part), 0);
  if (!Number.isFinite(seconds) || !Number.isFinite(Number(rss))) throw new Error('Invalid native process counters');
  return { seconds, rssKiB: Number(rss) };
}

async function coolDownPorts() {
  const { stdout } = await command(['/usr/sbin/sysctl', '-n', 'net.inet.tcp.msl']);
  const msl = Number(stdout.trim());
  if (!Number.isFinite(msl) || msl <= 0 || msl > 30000) throw new Error('Review native TCP cooldown budget');
  await delay(2 * msl + 5000);
}

if (mode === 'build') {
  const app = resolve(work, 'app');
  await mkdir(app, { recursive: true });
  for (const name of ['LeanHttp', 'LeanWeb', 'Example', 'Tests', 'LeanHttp.lean', 'LeanWeb.lean',
    'Example.lean', 'Tests.lean', 'lakefile.toml', 'lake-manifest.json', 'lean-toolchain']) {
    await cp(resolve(root, name), resolve(app, name), { recursive: true });
  }
  await cp(resolve(directory, '../http-performance/PipelineMain.lean'), resolve(app, 'PipelineMain.lean'));
  const lakefile = await readFile(resolve(app, 'lakefile.toml'), 'utf8');
  await writeFile(resolve(app, 'lakefile.toml'), lakefile +
    '\n[[lean_exe]]\nname = "pipeline_probe"\nroot = "PipelineMain"\n');
  const version = await command(['lean', '--version'], app);
  if (!version.stdout.includes('4.33.1') || !version.stdout.includes('819816b2e0a3bf405af45ae5c7af2491d8f5bee6')) {
    throw new Error('Native toolchain does not match the pinned revision');
  }
  await writeFile(resolve(work, 'toolchain.txt'), version.stdout);
  await command(['lake', 'build', 'leanweb', 'leanweb_tests', 'leanweb_transport_tests', 'pipeline_probe'], app, 600000);
  let source = await readFile(resolve(directory, '../http-throughput/client.go'), 'utf8');
  const condition = 'if *address != "127.0.0.1:8080"';
  if (!source.includes(condition)) throw new Error('Review changed client address validation');
  source = source.replace(condition,
    'host, port, addressErr := net.SplitHostPort(*address)\n\tif addressErr != nil || host != "127.0.0.1" || port == ""');
  const changes = [
    ['"sync"', '"sync"\n\t"sync/atomic"'],
    ['flag.Parse()', 'maxRequests := flag.Uint64("requests", 8000, "maximum attempts in a native batch")\n\tflag.Parse()'],
    ['*duration > 30*time.Second {', '*duration > 30*time.Second || *maxRequests == 0 || *maxRequests > 8000 {'],
    ['var deadline time.Time', 'var deadline time.Time\n\tvar issued atomic.Uint64'],
    ['for time.Now().Before(deadline) {',
      'for time.Now().Before(deadline) {\n\t\t\t\tif issued.Add(1) > *maxRequests { break }'],
  ];
  for (const [original, replacement] of changes) {
    if (!source.includes(original)) throw new Error('Review changed client request loop');
    source = source.replace(original, replacement);
  }
  await writeFile(resolve(work, 'client.go'), source);
  await command(['gofmt', '-w', resolve(work, 'client.go')]);
  await command(['go', 'build', '-trimpath', '-o', resolve(work, 'client'), resolve(work, 'client.go')]);
  await command(['go', 'vet', resolve(work, 'client.go')]);
  console.log('Native application and client built');
} else if (mode === 'test') {
  await command([resolve(work, 'app/.lake/build/bin/leanweb_tests')]);
  await command(['node', '--test', 'Tests/http.test.mjs'], resolve(work, 'app'), 45000);
  console.log('Native executable and TCP checks passed');
} else if (mode === 'measure') {
  const pipeline = await command([resolve(work, 'app/.lake/build/bin/pipeline_probe')]);
  await writeFile(resolve(work, 'pipeline.ndjson'), pipeline.stdout);
  await writeFile(resolve(work, 'measure.ndjson'), '');
  for (let repetition = 1; repetition <= 3; repetition++) {
    const concurrency = 32;
    await coolDownPorts();
    const server = await startServer();
    try {
      await load(server, 4, '1s', 256);
      const before = await resource(server);
      const result = await load(server, concurrency, '3s');
      const after = await resource(server);
      await appendFile(resolve(work, 'measure.ndjson'), JSON.stringify({ repetition, ...result,
        serverCPUs: (after.seconds - before.seconds) / result.seconds, rssMiB: after.rssKiB / 1024 }) + '\n');
      console.log(`native run=${repetition} c=${concurrency}: ${result.requestsPerSec.toFixed(0)} req/s p99=${result.p99Ms.toFixed(3)}ms`);
    } finally { await server.stop(); }
  }
}
