import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const work = '/experiment/.work';
const source = resolve(work, 'lean4-819816b2e0a3bf405af45ae5c7af2491d8f5bee6');
const prefix = process.env.LEAN_SYSROOT;
if (!prefix) throw new Error('Run in the research image with LEAN_SYSROOT set to lean --print-prefix');
const variant = process.argv[2];
if (!['baseline', 'patched'].includes(variant)) throw new Error('Expected baseline or patched');
const hash = data => createHash('sha256').update(data).digest('hex');
function run(args, cwd = source) {
  const result = spawnSync('/usr/bin/time', ['-p', ...args], { cwd, stdio: 'inherit', timeout: 180000 });
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
const config = await readFile(resolve(work, 'llvm-project-22.1.4.src/libcxx/include/__config_site.in'), 'utf8');
await writeFile(resolve(headers, '__config_site'), config
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
  .replace(/^#cmakedefine.*$/gm, '')
  .replace(/@[^@\n]+@/g, ''));
const pkg = resolve(work, 'pkgconfig');
await mkdir(pkg, { recursive: true });
await writeFile(resolve(pkg, 'gmp.pc'),
  `Name: GMP\nDescription: GMP bundled with the pinned Lean release\nVersion: 6.3.0\nLibs: ${prefix}/lib/libgmp.a\nCflags: -I${headers}\n`);
const original = await readFile(resolve(work, 'object.original.cpp'), 'utf8');
if (hash(original) !== 'e03ea4317ad44fb91a4cc9097abe1601b1e1cf8fb77f5ab7b0620fdfcf348430') {
  throw new Error('Original runtime source does not match the pinned revision');
}
await writeFile(resolve(source, 'src/runtime/object.cpp'), original);
if (variant === 'patched') run(['git', 'apply', '/experiment/runtime.patch']);
await cp(resolve(work, 'mimalloc-2.2.3'), resolve(source, 'build/mimalloc/src/mimalloc'), { recursive: true });
const libcxx = resolve(work, 'llvm-project-22.1.4.src/libcxx/include');
process.env.PKG_CONFIG_PATH = pkg;
process.env.CCACHE_DIR = resolve(work, 'ccache');
process.env.CCACHE_TEMPDIR = resolve(work, 'ccache-tmp');
await mkdir(process.env.CCACHE_TEMPDIR, { recursive: true });
run(['cmake', '-S', 'src', '-B', 'build/release', '-DSTAGE=1', `-DPREV_STAGE=${prefix}`,
  '-DCMAKE_BUILD_TYPE=Release', '-DWFAIL=ON', '-DUSE_GITHASH=OFF',
  `-DCMAKE_C_COMPILER=${prefix}/bin/clang`, `-DCMAKE_CXX_COMPILER=${prefix}/bin/clang`,
  '-DCMAKE_C_COMPILER_WORKS=1', '-DCMAKE_CXX_COMPILER_WORKS=1',
  `-DCMAKE_CXX_FLAGS=-Werror -nostdinc++ -isystem ${headers} -isystem ${libcxx} -isystem ${prefix}/include/clang`,
  `-DGMP_INCLUDE_DIR=${headers}`, `-DGMP_LIBRARIES=${prefix}/lib/libgmp.a`]);
run(['make', '-j4', '-C', 'build/release', 'leanrt']);
const runtime = resolve(work, 'runtime', variant);
await mkdir(runtime, { recursive: true });
await cp(resolve(source, 'build/release/runtime/CMakeFiles/leanrt.dir/object.cpp.o'), resolve(runtime, 'object.cpp.o'));
await cp(resolve(prefix, 'lib/lean/libleanrt.a'), resolve(runtime, 'libleanrt.a'));
run(['ar', 'rcs', resolve(runtime, 'libleanrt.a'), resolve(runtime, 'object.cpp.o')]);
function archiveRead(path, member) {
  const result = spawnSync('ar', [member ? 'p' : 't', path, ...(member ? [member] : [])]);
  if (result.status !== 0) throw new Error('Cannot inspect runtime archive');
  return result.stdout;
}
const originalArchive = resolve(prefix, 'lib/lean/libleanrt.a');
const candidateArchive = resolve(runtime, 'libleanrt.a');
const members = archiveRead(originalArchive).toString().trim().split('\n');
if (archiveRead(candidateArchive).toString() !== archiveRead(originalArchive).toString()) {
  throw new Error('Archive member set changed');
}
const changed = members.filter(member =>
  hash(archiveRead(originalArchive, member)) !== hash(archiveRead(candidateArchive, member)));
if (changed.length !== 1 || changed[0] !== 'object.cpp.o') throw new Error('Unexpected runtime changes');
await writeFile(resolve(runtime, 'provenance.json'), JSON.stringify({ variant, members: members.length, changed,
  sourceSHA256: hash(await readFile(resolve(source, 'src/runtime/object.cpp'))),
  objectSHA256: hash(await readFile(resolve(runtime, 'object.cpp.o'))),
  patchSHA256: hash(await readFile('/experiment/runtime.patch')),
}, null, 2) + '\n');
const binaries = resolve(work, 'bin', variant);
await mkdir(binaries, { recursive: true });
for (const name of ['leanweb', 'leanweb_tests', 'leanweb_transport_tests', 'task_probe']) {
  run([resolve(prefix, 'bin/clang'), '-o', resolve(binaries, name), `-Wl,-Map=${binaries}/${name}.map`, '-L', runtime,
    `@${work}/app/.lake/build/bin/${name}.rsp`], resolve(work, 'app'));
  if (variant === 'baseline') {
    await mkdir(resolve(work, 'bin/stock'), { recursive: true });
    await cp(resolve(work, 'app/.lake/build/bin', name), resolve(work, 'bin/stock', name));
  }
}
