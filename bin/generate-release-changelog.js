#!/usr/bin/env node

/**
 * Generates CHANGELOG.md for commits between <from-tag> and <to-ref>.
 * Copied verbatim from wire-team-settings' bin/generate-release-changelog.js
 * so it can be iterated on here.
 *
 * Usage: node bin/generate-release-changelog.js <from-tag> [to-ref]
 * Example: node bin/generate-release-changelog.js v4.24.0 HEAD
 */

const fs = require('fs');
const Changelog = require('generate-changelog');
const path = require('path');
const pkg = require('../package.json');

const fromTag = process.argv[2];
const toRef = process.argv[3] || 'HEAD';

if (!fromTag) {
  console.error('Usage: generate-release-changelog.js <from-tag> [to-ref]');
  process.exit(1);
}

const outputPath = path.join(__dirname, '../CHANGELOG.md');
const range = `${fromTag}...${toRef}`;

Changelog.generate({
  exclude: ['chore', 'build', 'docs', 'refactor', 'style', 'test', 'runfix'],
  repoUrl: pkg.repository.url.replace('.git', ''),
  tag: range,
}).then(changelog => {
  fs.writeFileSync(outputPath, changelog, 'utf8');
  console.info(`Changelog (${range}): ${changelog.length} bytes → ${outputPath}`);
}).catch(err => {
  console.error(err);
  process.exit(1);
});
