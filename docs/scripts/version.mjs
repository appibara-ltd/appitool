import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Absolute path to the Swift source that declares the CLI version (single source of truth). */
export const appitoolSwiftPath = path.resolve(__dirname, '../../Sources/appitool/appitool.swift');

/** Placeholder used in Markdown (rendered by VitePress via `$theme`, substituted by generate-llms.mjs). */
export const versionPlaceholder = '{{ $theme.appitoolVersion }}';

/**
 * Reads the CLI version from `CommandConfiguration(version: "x.y.z")` in `Sources/appitool/appitool.swift`.
 * Throws if the file or the `version:` declaration cannot be found, so stale docs never build silently.
 */
export function readAppitoolVersion() {
  const source = fs.readFileSync(appitoolSwiftPath, 'utf8');
  const match = source.match(/\bversion:\s*"([^"]+)"/);
  if (!match) {
    throw new Error(`Could not find \`version: "x.y.z"\` in ${appitoolSwiftPath}`);
  }
  return match[1];
}
