// Dependency-free owned-process runner. Run from this assignment directory.
import { spawn } from 'node:child_process';
import { mkdir, writeFile, readdir } from 'node:fs/promises';
import { resolve, basename } from 'node:path';
import { performance } from 'node:perf_hooks';

const tools = process.env.LEAN_BIN_DIR;
if (!tools) throw new Error('Set LEAN_BIN_DIR to the candidate toolchain bin directory');
const work = resolve('.work');
const normalize = text => text.replaceAll(resolve(tools), '<toolchain>/bin').replaceAll(resolve('.'), '<assignment>');
await mkdir(work, { recursive: true });
const metadata = { repetitions: 3, compileBudgetMs: 120000, executionBudgetMs: 40000, commands: [], runs: [] };
async function execute(label, command, args, budget, sample = false) {
  const start = performance.now();
  const child = spawn(command, args, { cwd: work, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '', partial = '', timedOut = false;
  const checkpoints = [];
  const samples = [];
  const timeout = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, budget);
  child.stdout.on('data', chunk => {
    stdout += chunk;
    partial += chunk;
    const lines = partial.split('\n'); partial = lines.pop();
    if (sample) for (const line of lines) if (line.startsWith('CHECKPOINT ')) {
      samples.push(readdir(`/proc/${child.pid}/fd`).then(fds => checkpoints.push({ phase: line.slice(11), fds: fds.length })).catch(error => checkpoints.push({ phase: line.slice(11), error: error.code })));
    }
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  const outcome = await new Promise((ok, fail) => {
    child.once('error', fail);
    child.once('close', (code, signal) => ok({ code, signal }));
  }).finally(() => clearTimeout(timeout));
  await Promise.all(samples);
  stdout = normalize(stdout);
  stderr = normalize(stderr);
  const result = { label, command: [basename(command), ...args], elapsedMs: Math.round(performance.now() - start), timedOut, ...outcome, checkpoints };
  metadata.commands.push(result);
  await writeFile(resolve(work, `${label}.stdout.txt`), stdout);
  await writeFile(resolve(work, `${label}.stderr.txt`), stderr);
  await writeFile(resolve(work, 'results.json'), JSON.stringify(metadata, null, 2) + '\n');
  console.log(JSON.stringify(result));
  if (sample) console.log(stdout.trim());
  if (timedOut || outcome.code !== 0) throw new Error(`${label} failed; inspect its owned stdout/stderr files`);
  return stdout.trim();
}
metadata.node = process.version;
metadata.platform = process.platform;
metadata.arch = process.arch;
metadata.lean = await execute('lean-version', resolve(tools, 'lean'), ['--version'], 10000);
metadata.compiler = await execute('compiler-version', resolve(tools, 'leanc'), ['--version'], 10000);
metadata.os = await execute('os-version', 'uname', ['-srm'], 10000);
metadata.libc = await execute('libc-version', 'getconf', ['GNU_LIBC_VERSION'], 10000);
await execute('compile-lean', resolve(tools, 'lean'), ['--root=..', '-DwarningAsError=true', '-o', 'Probe.olean', '-c', 'Probe.c', '../Probe.lean'], 120000);
await execute('compile-native', resolve(tools, 'leanc'), ['-O2', '-o', 'probe', 'Probe.c'], 120000);
for (let i = 1; i <= 3; i++) await execute(`run-${i}`, resolve(work, 'probe'), [], 40000, true);
await writeFile(resolve(work, 'results.json'), JSON.stringify(metadata, null, 2) + '\n');
