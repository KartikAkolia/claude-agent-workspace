// Extracts real function source from dashboard.html at test run time, same
// technique as escapeHtml.test.js, generalized to any function name so tests
// can't silently drift from what's actually shipped.
const fs = require('node:fs');
const path = require('node:path');

function readDashboardSource() {
  return fs.readFileSync(path.join(__dirname, '..', 'dashboard.html'), 'utf8');
}

function extractFunction(source, name) {
  const re = new RegExp(`function ${name}\\([^)]*\\) \\{[\\s\\S]*?\\n    \\}`);
  const match = source.match(re);
  if (!match) {
    throw new Error(`Could not find function ${name}() in dashboard.html — has it moved or been renamed?`);
  }
  return match[0];
}

module.exports = { readDashboardSource, extractFunction };
