---
layout: home

hero:
  name: appitool
  text: Unified Mobile Release & Store CLI
  tagline: Opinionated release orchestration, Fastlane-compatible code signing, and direct App Store Connect, Google Play & Firebase automation built in Swift 6.4.
  image:
    src: /logo.png
    alt: appitool
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: Command Reference
      link: /commands/overview
    - theme: alt
      text: llms-full.txt (AI Context)
      link: /appitool/llms-full.txt

features:
  - icon: 🌊
    title: 7-Stage Flow Pipeline
    details: Deterministic release lifecycle (setup → prebuild → build → postbuild → prerelease → release → postrelease) across iOS and Android with global error boundaries.
  - icon: 🔐
    title: Fastlane-Compatible Match
    details: 100% compatible AES-256-GCM (V2) & AES-256-CBC (V1) Git-backed code signing for Apple certificates/profiles and Android keystores.
  - icon: 🍎
    title: Apple Developer & TestFlight
    details: OpenAPI-powered App Store Connect client to manage apps, bundle IDs, 28 capabilities, certificates, profiles, devices, and TestFlight uploads.
  - icon: 🤖
    title: Google Play & Gradle Builds
    details: Build AAB/APK artifacts with product flavors and signing injection, inspect latest remote version codes, and upload to Google Play Console tracks.
  - icon: 🔥
    title: Firebase Distribution & Auth
    details: Manage Firebase App Distribution releases and tester groups, plus list, search, export to CSV, and clean up Firebase Auth users.
  - icon: 📣
    title: Smart Alerts & AI-Ready Docs
    details: Automated Slack and E2E-encrypted KokoNo (X25519 + AES-256-GCM) webhook alerts, plus machine-readable /llms.txt and /llms-full.txt context files.
---

## Quick Install

Install the latest release binary on macOS (Apple Silicon `arm64`) or Linux (`x86_64`, `arm64`):

```bash
curl -fsSL https://raw.githubusercontent.com/appibara-ltd/appitool/main/install.sh | bash
```

Verify the installation:

```bash
appitool status
```

## Release Flow at a Glance

```bash
# Run automated iOS release flow for App Store / TestFlight
appitool flow ios -d appstore

# Run automated Android release flow via Firebase App Distribution
appitool flow android -d adhoc

# Simulate and validate configuration without mutating files or uploading
appitool flow ios --dry-run
```

## AI & LLM Integration

This documentation site exposes structured plain-text context files following the [llmstxt.org](https://llmstxt.org/) specification so coding assistants and agents can ingest the full CLI specification accurately:

- [`/llms.txt`](/llms.txt) — Structured index of all guides and command pages.
- [`/llms-full.txt`](/llms-full.txt) — Single-file consolidated Markdown documentation covering every command, flag, `.env` variable, and architecture detail.
