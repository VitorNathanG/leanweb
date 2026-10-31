import { access, cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, '../..');
const work = resolve(directory, '.work');
const revision = '819816b2e0a3bf405af45ae5c7af2491d8f5bee6';
await mkdir(work, { recursive: true });
const archives = [
  [`https://codeload.github.com/leanprover/lean4/tar.gz/${revision}`, 'lean.tar.gz'],
  ['https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.4/llvm-project-22.1.4.src.tar.xz',
    'llvm.tar.xz', 'llvm-project-22.1.4.src/libcxx/include',
    'llvm-project-22.1.4.src/libcxx/vendor/llvm/default_assertion_handler.in'],
  ['https://codeload.github.com/microsoft/mimalloc/tar.gz/refs/tags/v2.2.3', 'mimalloc.tar.gz'],
  ['https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz', 'gmp.tar.xz'],
  ['https://codeload.github.com/libuv/libuv/tar.gz/refs/tags/v1.48.0', 'libuv.tar.gz'],
];
function run(args) {
  const result = spawnSync('/usr/bin/time', ['-p', ...args], { stdio: 'inherit', timeout: 130000 });
  if (result.status !== 0) throw new Error(`Failed: ${args[0]}`);
}
for (const [url, name, ...paths] of archives) {
  try { await access(resolve(work, name)); } catch {
    try { await cp(resolve(directory, '../lean-task-wakeup/.work', name), resolve(work, name)); } catch {
      run(['curl', '--fail', '--location', '--silent', '--show-error', '--max-time', '120',
        '--max-filesize', '419430400', url, '--output', resolve(work, name)]);
    }
  }
  run(['tar', '-xf', resolve(work, name), '-C', work, ...paths]);
}
const source = resolve(work, `lean4-${revision}`);
for (const name of ['object.cpp', 'thread.cpp', 'stack_overflow.cpp', 'uv/event_loop.cpp']) {
  const target = resolve(work, 'original', name);
  await mkdir(dirname(target), { recursive: true });
  await cp(resolve(source, 'src/runtime', name), target);
}
const app = resolve(work, 'app');
await mkdir(app, { recursive: true });
for (const name of ['LeanHttp', 'LeanWeb', 'Example', 'Tests', '.lake', 'LeanHttp.lean',
  'LeanWeb.lean', 'Example.lean', 'Tests.lean', 'lakefile.toml', 'lake-manifest.json', 'lean-toolchain']) {
  await cp(resolve(root, name), resolve(app, name), { recursive: true });
}
await cp(resolve(directory, '../lean-task-wakeup/TaskProbe.lean'), resolve(app, 'TaskProbe.lean'));
const lakefile = await readFile(resolve(app, 'lakefile.toml'), 'utf8');
await writeFile(resolve(app, 'lakefile.toml'), lakefile +
  '\n[[lean_exe]]\nname = "task_probe"\nroot = "TaskProbe"\n');
