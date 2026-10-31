import { access, copyFile, mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const work = resolve(dirname(fileURLToPath(import.meta.url)), '.work');
await mkdir(work, { recursive: true });
const revision = '819816b2e0a3bf405af45ae5c7af2491d8f5bee6';
const archives = [
  [`https://codeload.github.com/leanprover/lean4/tar.gz/${revision}`, 'lean.tar.gz'],
  ['https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.4/llvm-project-22.1.4.src.tar.xz',
    'llvm.tar.xz', 'llvm-project-22.1.4.src/libcxx/include'],
  ['https://codeload.github.com/microsoft/mimalloc/tar.gz/refs/tags/v2.2.3', 'mimalloc.tar.gz'],
  ['https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz', 'gmp.tar.xz'],
];
for (const [url, archive, subtree] of archives) {
  const commands = [];
  try { await access(resolve(work, archive)); } catch {
    commands.push(['curl', '--fail', '--location', '--silent', '--show-error', '--max-time', '120',
      '--max-filesize', '419430400', url, '--output', resolve(work, archive)]);
  }
  commands.push(['tar', '-xf', resolve(work, archive), '-C', work, ...(subtree ?
    [subtree, 'llvm-project-22.1.4.src/libcxx/vendor/llvm/default_assertion_handler.in'] : [])]);
  for (const args of commands) {
    const result = spawnSync('/usr/bin/time', ['-p', ...args], { stdio: 'inherit', timeout: 130000 });
    if (result.status !== 0) throw new Error(`Failed: ${args[0]}`);
  }
}
await copyFile(resolve(work, `lean4-${revision}/src/runtime/object.cpp`), resolve(work, 'object.original.cpp'));
await writeFile(resolve(work, 'sources.json'), JSON.stringify({ revision, archives }, null, 2) + '\n');
