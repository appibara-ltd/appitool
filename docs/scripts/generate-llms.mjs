import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ensureTransparentAssets } from './process-assets.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const docsRoot = path.resolve(__dirname, '..');
const publicDir = path.join(docsRoot, 'public');

const sections = [
  {
    title: 'Guide',
    dir: 'guide',
    order: [
      'getting-started.md',
      'configuration.md',
      'flow-architecture.md',
      'code-signing-match.md',
    ],
  },
  {
    title: 'Commands',
    dir: 'commands',
    order: [
      'overview.md',
      'flow.md',
      'build.md',
      'check.md',
      'match.md',
      'apple.md',
      'firebase.md',
      'list-identifiers.md',
      'clean.md',
      'notes.md',
      'kokono.md',
      'self-update.md',
      'status.md',
    ],
  },
];

function stripFrontmatter(raw) {
  const match = raw.match(/^---\r?\n[\s\S]*?\r?\n---\r?\n*/);
  return match ? raw.slice(match[0].length).trim() : raw.trim();
}

function extractTitle(content, fallback) {
  const match = content.match(/^#\s+(.+)$/m);
  return match ? match[1].trim() : fallback;
}

function extractSummary(content) {
  const lines = content.split(/\r?\n/);
  let pastHeading = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (!pastHeading) {
      if (trimmed.startsWith('# ')) pastHeading = true;
      continue;
    }
    if (
      !trimmed ||
      trimmed.startsWith('#') ||
      trimmed.startsWith('!') ||
      trimmed.startsWith('```') ||
      trimmed.startsWith('|') ||
      trimmed.startsWith(':::') ||
      trimmed.startsWith('>')
    ) {
      continue;
    }
    return trimmed.replace(/`([^`]+)`/g, '$1').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
  }
  return '';
}

function listOrderedFiles(dirPath, preferredOrder) {
  if (!fs.existsSync(dirPath)) return [];
  const allMd = fs
    .readdirSync(dirPath)
    .filter((f) => f.endsWith('.md'))
    .sort();
  const ordered = preferredOrder.filter((f) => allMd.includes(f));
  const remaining = allMd.filter((f) => !ordered.includes(f));
  return [...ordered, ...remaining];
}

function generate() {
  fs.mkdirSync(publicDir, { recursive: true });
  ensureTransparentAssets();

  const llmsLines = [
    '# appitool',
    '',
    '> A unified CLI utility and release orchestration engine (v0.9.1) for Apple App Store Connect, Developer Portal, Google Play Console, Firebase App Distribution/Auth, and Fastlane-compatible Match code signing.',
    '',
    '- Source & Repository: https://github.com/appibara-ltd/appitool',
    '- Full Consolidated Context: [/llms-full.txt](/llms-full.txt)',
    '',
  ];

  const fullParts = [
    '# appitool — Complete CLI Documentation',
    '',
    '> Unified CLI utility (v0.9.0) for Apple App Store Connect and Google Play operations.',
    '> Generated automatically from VitePress Markdown documentation.',
    '',
  ];

  for (const section of sections) {
    const dirPath = path.join(docsRoot, section.dir);
    const files = listOrderedFiles(dirPath, section.order);
    if (files.length === 0) continue;

    llmsLines.push(`## ${section.title}`, '');

    for (const file of files) {
      const fullPath = path.join(dirPath, file);
      const raw = fs.readFileSync(fullPath, 'utf8');
      const clean = stripFrontmatter(raw);
      const slug = file.replace(/\.md$/, '');
      const urlPath = `/${section.dir}/${slug}`;
      const title = extractTitle(clean, slug);
      const summary = extractSummary(clean);

      llmsLines.push(`- [${title}](${urlPath})${summary ? `: ${summary}` : ''}`);
      fullParts.push('---', '', `<!-- source: ${section.dir}/${file} -->`, '', clean, '');
    }

    llmsLines.push('');
  }

  llmsLines.push(
    '## AI Context Files',
    '',
    '- [Full Documentation Context](/llms-full.txt): Complete single-file Markdown export of all guides and command references.',
    ''
  );

  fs.writeFileSync(path.join(publicDir, 'llms.txt'), llmsLines.join('\n'), 'utf8');
  fs.writeFileSync(path.join(publicDir, 'llms-full.txt'), fullParts.join('\n'), 'utf8');
  console.log('Generated public/llms.txt and public/llms-full.txt');
}

generate();
