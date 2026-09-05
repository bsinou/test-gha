#!/usr/bin/env node

/**
 * Generates CHANGELOG.md for commits between <from-tag> and <to-ref>.
 * Simplified stand-in for wire-team-settings' bin/generate-release-changelog.js:
 * plain `git log` instead of the `generate-changelog` npm package, since this
 * test repo has no package.json / node_modules setup.
 *
 * Usage: node bin/generate-release-changelog.js <from-tag> [to-ref]
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const fromTag = process.argv[2];
const toRef = process.argv[3] || 'HEAD';

if (!fromTag) {
  console.error('Usage: generate-release-changelog.js <from-tag> [to-ref]');
  process.exit(1);
}

const range = `${fromTag}..${toRef}`;
const log = execSync(`git log ${range} --pretty=format:"- %s (%h)"`, { encoding: 'utf8' }).trim();
const outputPath = path.join(__dirname, '../CHANGELOG.md');
const changelog = `## ${toRef} (since ${fromTag})\n\n${log || '- No changes'}\n`;

fs.writeFileSync(outputPath, changelog, 'utf8');
console.info(`Changelog (${range}): ${changelog.length} bytes -> ${outputPath}`);
