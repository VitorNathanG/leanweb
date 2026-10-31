import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const work = '/experiment/.work';
const source = resolve(work, 'lean4-819816b2e0a3bf405af45ae5c7af2491d8f5bee6');
const prefix = process.env.LEAN_SYSROOT;
if (!prefix) throw new Error('Set LEAN_SYSROOT to lean --print-prefix inside the research image');
const variant = process.argv[2];
if (!['baseline', 'profile'].includes(variant)) throw new Error('Expected baseline or profile');
const hash = data => createHash('sha256').update(data).digest('hex');
function run(args, cwd = source) {
  const result = spawnSync('/usr/bin/time', ['-p', 'timeout', '--kill-after=2s', '180s', ...args],
    { cwd, stdio: 'inherit', timeout: 185000 });
  if (result.status !== 0) throw new Error(`Failed: ${args.join(' ')}`);
}
const headers = resolve(work, 'headers');
await mkdir(headers, { recursive: true });
const gmp = resolve(work, 'gmp-6.3.0');
try { await access(resolve(gmp, 'gmp.h')); } catch {
  run(['./configure', '--disable-shared', '--enable-static', '--with-pic'], gmp);
}
await cp(resolve(gmp, 'gmp.h'), resolve(headers, 'gmp.h'));
await cp(resolve(work, 'llvm-project-22.1.4.src/libcxx/vendor/llvm/default_assertion_handler.in'),
  resolve(headers, '__assertion_handler'));
const template = await readFile(resolve(work, 'llvm-project-22.1.4.src/libcxx/include/__config_site.in'), 'utf8');
await writeFile(resolve(headers, '__config_site'), template
  .replace('#cmakedefine _LIBCPP_ABI_VERSION @_LIBCPP_ABI_VERSION@', '#define _LIBCPP_ABI_VERSION 1')
  .replace('#cmakedefine _LIBCPP_ABI_NAMESPACE @_LIBCPP_ABI_NAMESPACE@', '#define _LIBCPP_ABI_NAMESPACE __1')
  .replace(/^#cmakedefine01 (\w+)$/gm, (_, name) => '#define ' + name + ' ' +
    (['_LIBCPP_HAS_THREADS', '_LIBCPP_HAS_MONOTONIC_CLOCK', '_LIBCPP_HAS_TERMINAL',
      '_LIBCPP_HAS_THREAD_API_PTHREAD', '_LIBCPP_HAS_FILESYSTEM', '_LIBCPP_HAS_RANDOM_DEVICE',
      '_LIBCPP_HAS_LOCALIZATION', '_LIBCPP_HAS_UNICODE', '_LIBCPP_HAS_WIDE_CHARACTERS',
      '_LIBCPP_HAS_TIME_ZONE_DATABASE'].includes(name) ? '1' : '0'))
  .replace('#cmakedefine _LIBCPP_HARDENING_MODE_DEFAULT @_LIBCPP_HARDENING_MODE_DEFAULT@',
    '#define _LIBCPP_HARDENING_MODE_DEFAULT _LIBCPP_HARDENING_MODE_NONE')
  .replace('#cmakedefine _LIBCPP_ASSERTION_SEMANTIC_DEFAULT @_LIBCPP_ASSERTION_SEMANTIC_DEFAULT@',
    '#define _LIBCPP_ASSERTION_SEMANTIC_DEFAULT _LIBCPP_ASSERTION_SEMANTIC_IGNORE')
  .replace(/^#cmakedefine.*$/gm, '').replace(/@[^@\n]+@/g, ''));
const pkg = resolve(work, 'pkgconfig');
await mkdir(pkg, { recursive: true });
await writeFile(resolve(pkg, 'gmp.pc'),
  `Name: GMP\nDescription: Pinned Lean GMP\nVersion: 6.3.0\nLibs: ${prefix}/lib/libgmp.a\nCflags: -I${headers}\n`);
const modules = ['object.cpp', 'thread.cpp', 'stack_overflow.cpp', 'uv/event_loop.cpp'];
for (const name of modules) await cp(resolve(work, 'original', name), resolve(source, 'src/runtime', name));
await cp('/experiment/profile.hpp', resolve(source, 'src/runtime/profile.hpp'));
if (variant === 'profile') run(['git', 'apply', '/experiment/runtime.patch']);
await cp(resolve(work, 'mimalloc-2.2.3'), resolve(source, 'build/mimalloc/src/mimalloc'), { recursive: true });
process.env.PKG_CONFIG_PATH = pkg;
process.env.CCACHE_DIR = resolve(work, 'ccache');
process.env.CCACHE_TEMPDIR = resolve(work, 'ccache-tmp');
await mkdir(process.env.CCACHE_TEMPDIR, { recursive: true });
run(['cmake', '-S', 'src', '-B', 'build/release', '-DSTAGE=1', `-DPREV_STAGE=${prefix}`,
  '-DCMAKE_BUILD_TYPE=Release', '-DWFAIL=ON', '-DUSE_GITHASH=OFF',
  `-DCMAKE_C_COMPILER=${prefix}/bin/clang`, `-DCMAKE_CXX_COMPILER=${prefix}/bin/clang`,
  '-DCMAKE_C_COMPILER_WORKS=1', '-DCMAKE_CXX_COMPILER_WORKS=1',
  `-DCMAKE_CXX_FLAGS=-Werror -nostdinc++ -isystem ${headers} -isystem ${work}/llvm-project-22.1.4.src/libcxx/include -isystem ${prefix}/include/clang -isystem ${work}/libuv-1.48.0/include`,
  `-DGMP_INCLUDE_DIR=${headers}`, `-DGMP_LIBRARIES=${prefix}/lib/libgmp.a`]);
run(['make', '-j4', '-C', 'build/release', 'leanrt']);
const runtime = resolve(work, 'runtime', variant);
await mkdir(runtime, { recursive: true });
const archive = resolve(runtime, 'libleanrt.a');
await cp(resolve(prefix, 'lib/lean/libleanrt.a'), archive);
for (const name of modules) {
  const object = resolve(source, 'build/release/runtime/CMakeFiles/leanrt.dir', name + '.o');
  run(['ar', 'rcs', archive, object]);
}
function readArchive(path, member) {
  const result = spawnSync('ar', [member ? 'p' : 't', path, ...(member ? [member] : [])]);
  if (result.status !== 0) throw new Error('Cannot inspect runtime archive');
  return result.stdout;
}
const originalArchive = resolve(prefix, 'lib/lean/libleanrt.a');
const originalMembers = readArchive(originalArchive).toString();
if (readArchive(archive).toString() !== originalMembers) throw new Error('Archive member set changed');
const allowed = new Set(modules.map(name => name.split('/').at(-1) + '.o'));
const changed = originalMembers.trim().split('\n').filter(member =>
  hash(readArchive(archive, member)) !== hash(readArchive(originalArchive, member)));
if (changed.some(member => !allowed.has(member))) throw new Error('Unexpected runtime object change');
const inputs = {};
for (const name of modules) inputs[name] = hash(await readFile(resolve(source, 'src/runtime', name)));
inputs['profile.hpp'] = hash(await readFile('/experiment/profile.hpp'));
await writeFile(resolve(runtime, 'inputs.json'), JSON.stringify({ inputs, changed }, null, 2) + '\n');
const binaries = resolve(work, 'bin', variant);
await mkdir(binaries, { recursive: true });
for (const name of ['leanweb', 'leanweb_tests', 'leanweb_transport_tests', 'task_probe']) {
  run([resolve(prefix, 'bin/clang'), '-o', resolve(binaries, name), `-Wl,-Map=${binaries}/${name}.map`,
    '-L', runtime, `@${work}/app/.lake/build/bin/${name}.rsp`], resolve(work, 'app'));
  if (variant === 'baseline') {
    await mkdir(resolve(work, 'bin/stock'), { recursive: true });
    await cp(resolve(work, 'app/.lake/build/bin', name), resolve(work, 'bin/stock', name));
  }
}
