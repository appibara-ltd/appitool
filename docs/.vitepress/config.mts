import { defineConfigWithTheme, type DefaultTheme } from 'vitepress';
import { readAppitoolVersion } from '../scripts/version.mjs';

/** Default theme config extended with the CLI version (read as `$theme.appitoolVersion` in Markdown). */
interface AppitoolThemeConfig extends DefaultTheme.Config {
  appitoolVersion: string;
}

// Custom domain: https://appitool.appibara.com/
const siteUrl = 'https://appitool.appibara.com';
const base = '/';

// Single source of truth: `version:` in Sources/appitool/appitool.swift.
const appitoolVersion = readAppitoolVersion();

export default defineConfigWithTheme<AppitoolThemeConfig>({
  title: 'appitool',
  description: 'A unified CLI utility and release orchestration engine for Apple App Store Connect and Google Play operations.',
  base,
  cleanUrls: true,
  lastUpdated: true,
  sitemap: {
    hostname: siteUrl,
  },

  head: [
    ['meta', { name: 'theme-color', content: '#0891b2' }],
    ['link', { rel: 'icon', type: 'image/png', href: `${base}logo.png` }],
    ['meta', { property: 'og:image', content: `${siteUrl}/banner.png` }],
    ['link', { rel: 'alternate', type: 'text/plain', title: 'LLM Context Index', href: `${base}llms.txt` }],
    ['link', { rel: 'alternate', type: 'text/plain', title: 'LLM Full Documentation', href: `${base}llms-full.txt` }],
  ],

  themeConfig: {
    // Exposed to Markdown as `{{ $theme.appitoolVersion }}` (use a `-vue` fence suffix inside code blocks).
    appitoolVersion,
    logo: '/logo.png',
    siteTitle: 'appitool',

    search: {
      provider: 'local',
    },

    nav: [
      { text: 'Guide', link: '/guide/getting-started', activeMatch: '/guide/' },
      { text: 'Commands', link: '/commands/overview', activeMatch: '/commands/' },
      { text: 'Flow Pipeline', link: '/guide/flow-architecture' },
      {
        text: `v${appitoolVersion}`,
        items: [
          { text: 'Release Notes', link: 'https://github.com/appibara-ltd/appitool/releases', target: '_blank' },
          { text: 'Updating (self-update)', link: '/commands/self-update' },
        ],
      },
      {
        text: 'AI / LLMs',
        items: [
          { text: 'llms.txt (Index)', link: `${base}llms.txt`, target: '_blank' },
          { text: 'llms-full.txt (Full Context)', link: `${base}llms-full.txt`, target: '_blank' },
        ],
      },
    ],

    sidebar: [
      {
        text: 'Introduction & Guide',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Configuration & .env', link: '/guide/configuration' },
          { text: 'Flow Architecture', link: '/guide/flow-architecture' },
          { text: 'Code Signing & Match', link: '/guide/code-signing-match' },
        ],
      },
      {
        text: 'Core Commands',
        items: [
          { text: 'Command Overview', link: '/commands/overview' },
          { text: 'flow', link: '/commands/flow' },
          { text: 'build', link: '/commands/build' },
          { text: 'check', link: '/commands/check' },
          { text: 'match', link: '/commands/match' },
        ],
      },
      {
        text: 'Provider Commands',
        items: [
          { text: 'apple', link: '/commands/apple' },
          { text: 'google', link: '/commands/google' },
          { text: 'firebase', link: '/commands/firebase' },
        ],
      },
      {
        text: 'Utility Commands',
        items: [
          { text: 'inspect', link: '/commands/inspect' },
          { text: 'clean', link: '/commands/clean' },
          { text: 'notes', link: '/commands/notes' },
          { text: 'kokono', link: '/commands/kokono' },
          { text: 'self-update', link: '/commands/self-update' },
          { text: 'status', link: '/commands/status' },
        ],
      },
      {
        text: 'AI Context',
        items: [
          { text: 'llms.txt', link: `${base}llms.txt`, target: '_blank' },
          { text: 'llms-full.txt', link: `${base}llms-full.txt`, target: '_blank' },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/appibara-ltd/appitool' },
    ],

    outline: {
      level: [2, 3],
    },

    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © Appibara Ltd.',
    },
  },
});
