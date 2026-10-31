import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, '../..');
const workspace = resolve(directory, '.work/app');
await mkdir(workspace, { recursive: true });
for (const path of ['LeanHttp', 'LeanWeb', 'Example', 'Tests', '.lake', 'LeanHttp.lean',
  'LeanWeb.lean', 'Example.lean', 'Tests.lean', 'lakefile.toml', 'lake-manifest.json', 'lean-toolchain']) {
  await cp(resolve(root, path), resolve(workspace, path), { recursive: true });
}
await cp(resolve(directory, 'TaskProbe.lean'), resolve(workspace, 'TaskProbe.lean'));
const lakefile = await readFile(resolve(workspace, 'lakefile.toml'), 'utf8');
await writeFile(resolve(workspace, 'lakefile.toml'), lakefile +
  '\n[[lean_exe]]\nname = "task_probe"\nroot = "TaskProbe"\n');
console.log('Prepared unchanged application and task probe');
