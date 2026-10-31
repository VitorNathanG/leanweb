import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, '../..');
const source = await readFile(resolve(root, 'LeanHttp/Server.lean'), 'utf8');
const start = source.indexOf('/--\nServe one request per connection');
const end = source.indexOf('\nend LeanHttp.Server', start);
if (start < 0 || end < 0 || !source.includes('IO.asTask (respond socket handler config deadline) .dedicated')) {
  throw new Error('Unexpected baseline server; review the variant before regenerating it');
}
const body = await readFile(resolve(directory, 'pool-body.lean'), 'utf8');
const nativeBody = await readFile(resolve(directory, 'native-body.lean'), 'utf8');
for (const variant of process.argv[2] ? [process.argv[2]] : ['baseline', 'pool', 'native']) {
  if (!['baseline', 'pool', 'native'].includes(variant)) throw new Error('Unknown variant');
  const workspace = resolve(directory, '.work', variant);
  await mkdir(workspace, { recursive: true });
  for (const path of ['LeanHttp', 'LeanWeb', 'Example', 'Tests', '.lake', 'LeanHttp.lean',
    'LeanWeb.lean', 'Example.lean', 'Tests.lean', 'lakefile.toml', 'lake-manifest.json', 'lean-toolchain']) {
    await cp(resolve(root, path), resolve(workspace, path), { recursive: true });
  }
  if (variant !== 'baseline') {
    const changed = source.slice(0, start).replace('import Std.Internal.UV.Timer',
      'import Std.Internal.UV.Timer\nimport Std.Sync.Channel\nimport Std.Sync.Mutex') +
      (variant === 'pool' ? body : nativeBody) + source.slice(end);
    await writeFile(resolve(workspace, 'LeanHttp/Server.lean'), changed);
  }
  if (variant === 'baseline') {
    await cp(resolve(directory, 'PipelineMain.lean'), resolve(workspace, 'PipelineMain.lean'));
    const lakefile = await readFile(resolve(workspace, 'lakefile.toml'), 'utf8');
    await writeFile(resolve(workspace, 'lakefile.toml'), lakefile +
      '\n[[lean_exe]]\nname = "pipeline_probe"\nroot = "PipelineMain"\n');
  }
}
console.log('Prepared isolated baseline and persistent-worker workspaces');
