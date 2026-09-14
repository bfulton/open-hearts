// The global Playwright's Chromium, which is what this machine has.
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const require = createRequire(import.meta.url);
export const { chromium } = require(`${execSync('npm root -g').toString().trim()}/playwright`);
