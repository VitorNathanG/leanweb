// Validate the repository-local workflow without loading providers or agent plugins.
import assert from 'node:assert/strict';
import { access, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const ignored = new Set(['.git', '.lake', '.work', 'node_modules']);
const required = [
  'AGENTS.md', 'PRODUCT.md', 'ROADMAP.md', 'README.md',
  'docs/architecture.md', 'docs/development.md',
  '.agents/MEMORY.md', '.agents/SUGGESTIONS.md', 'research/index/README.md',
  '.opencode/agents/compatibility-researcher.md',
  '.opencode/agents/research-curator.md', '.opencode/agents/proof-reviewer.md',
  '.opencode/skills/lean-proof-development/SKILL.md',
  '.opencode/skills/lean-runtime-research/SKILL.md',
];

async function markdownFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (ignored.has(entry.name)) continue;
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await markdownFiles(file));
    else if (entry.isFile() && entry.name.endsWith('.md')) files.push(file);
  }
  return files;
}

for (const file of required) {
  await access(path.join(root, file)).catch(() => {
    throw new Error(`Missing required workflow file: ${file}`);
  });
}

const files = await markdownFiles(root);
for (const file of files) {
  const relative = path.relative(root, file).split(path.sep).join('/');
  const text = await readFile(file, 'utf8');
  for (const match of text.matchAll(/\[[^\]]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)/g)) {
    const href = match[1];
    if (/^(https?:|mailto:)/i.test(href) || href.startsWith('#')) continue;
    assert.ok(!/^[a-z][a-z0-9+.-]*:/i.test(href), `${relative}: unsupported link ${href}`);
    const linkPath = decodeURIComponent(href.split('#')[0]);
    assert.ok(!path.isAbsolute(linkPath), `${relative}: use repository-relative links: ${href}`);
    const target = path.resolve(path.dirname(file), linkPath);
    const within = path.relative(root, target);
    assert.ok(!path.isAbsolute(within) && within !== '..' && !within.startsWith(`..${path.sep}`),
      `${relative}: link leaves repository: ${href}`);
    await access(target).catch(() => { throw new Error(`${relative}: broken link ${href}`); });
  }

  if (relative.startsWith('.opencode/agents/') || relative.endsWith('/SKILL.md')) {
    const metadata = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
    assert.ok(metadata, `${relative}: missing YAML frontmatter`);
    assert.match(metadata[1], /^description: .+$/m, `${relative}: missing description`);
    if (relative.startsWith('.opencode/agents/')) {
      assert.match(metadata[1], /^mode: subagent$/m, `${relative}: expected subagent mode`);
      assert.match(metadata[1], /^permission:$/m, `${relative}: missing permission policy`);
    } else {
      const name = metadata[1].match(/^name: ([a-z0-9]+(?:-[a-z0-9]+)*)$/m)?.[1];
      assert.equal(name, path.basename(path.dirname(file)), `${relative}: skill name/folder mismatch`);
      assert.ok(name.length <= 64, `${relative}: skill name too long`);
    }
  }

  if (relative.startsWith('research/') && !relative.startsWith('research/index/') &&
      path.basename(file) === 'README.md') {
    for (const heading of ['Question', 'References', 'Procedure', 'Evidence',
      'Conclusion', 'Uncertainty', 'Follow-ups', 'Artifacts']) {
      assert.ok(text.split(/\r?\n/).includes(`## ${heading}`), `${relative}: missing ${heading} section`);
    }
  }
}

const roadmap = await readFile(path.join(root, 'ROADMAP.md'), 'utf8');
assert.doesNotMatch(roadmap, /^\s*(?:\d+\.\s|[-*] \[[ xX]\])/m,
  'ROADMAP.md must use an unnumbered future-only list, not numbered/checklist status entries');
console.log(`Workflow checks passed (${files.length} Markdown files)`);
