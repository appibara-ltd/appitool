#!/usr/bin/env node
// Summarize line coverage from `swift test --enable-code-coverage`.
//
// Usage:
//   swift test --enable-code-coverage
//   node scripts/coverage.mjs "$(swift test --show-codecov-path)" [--markdown] [--files]
//
// Generated OpenAPI sources (under .build/) and test files are excluded.
// Uses only Node.js built-in modules.

import { readFileSync } from "node:fs";

const flags = new Set(process.argv.slice(2).filter((a) => a.startsWith("--")));
const [input] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
if (!input) {
  console.error('Usage: node scripts/coverage.mjs "$(swift test --show-codecov-path)" [--markdown] [--files]');
  process.exit(1);
}

const data = JSON.parse(readFileSync(input, "utf8"));

const files = data.data[0].files
  .filter(({ filename }) => !filename.includes("/.build/") && !filename.includes("/Tests/") && filename.includes("/Sources/"))
  .map(({ filename, summary }) => ({
    name: filename.split("/Sources/").pop(),
    count: summary.lines.count,
    covered: summary.lines.covered,
  }));

const moduleOf = (path) => {
  const parts = path.split("/");
  return parts[0] === "appitool" && parts.length > 2 ? `appitool/${parts[1]}` : parts[0];
};

const modules = new Map();
for (const file of files) {
  const entry = modules.get(moduleOf(file.name)) ?? { count: 0, covered: 0 };
  entry.count += file.count;
  entry.covered += file.covered;
  modules.set(moduleOf(file.name), entry);
}
const sorted = [...modules.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
const total = files.reduce((sum, f) => sum + f.count, 0);
const coveredTotal = files.reduce((sum, f) => sum + f.covered, 0);

const pct = (covered, count) => `${(count ? (covered / count) * 100 : 100).toFixed(1)}%`;

if (flags.has("--markdown")) {
  console.log("| Module | Lines | Covered | Coverage |");
  console.log("|:---|---:|---:|---:|");
  for (const [name, { count, covered }] of sorted) {
    console.log(`| \`${name}\` | ${count} | ${covered} | ${pct(covered, count)} |`);
  }
  console.log(`| **Total** | **${total}** | **${coveredTotal}** | **${pct(coveredTotal, total)}** |`);
} else {
  for (const [name, { count, covered }] of sorted) {
    console.log(`${name.padEnd(28)} ${String(covered).padStart(6)}/${String(count).padStart(6)} ${pct(covered, count).padStart(7)}`);
  }
  console.log(`${"TOTAL".padEnd(28)} ${String(coveredTotal).padStart(6)}/${String(total).padStart(6)} ${pct(coveredTotal, total).padStart(7)}`);
}

if (flags.has("--files")) {
  console.log();
  const ratio = (f) => (f.count ? f.covered / f.count : 1);
  for (const f of [...files].sort((a, b) => ratio(a) - ratio(b))) {
    console.log(`${pct(f.covered, f.count).padStart(7)} ${String(f.covered).padStart(5)}/${String(f.count).padStart(5)} ${f.name}`);
  }
}
