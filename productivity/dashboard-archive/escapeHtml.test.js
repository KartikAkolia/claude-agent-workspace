// Tests escapeHtml() as it actually exists in dashboard.html, extracted at run
// time rather than copy-pasted, so a change to the real function can't drift
// silently out of sync with what's tested here.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const dashboardPath = path.join(__dirname, 'dashboard.html');
const source = fs.readFileSync(dashboardPath, 'utf8');
const match = source.match(/function escapeHtml\(text\) \{[\s\S]*?\n    \}/);
if (!match) {
  throw new Error('Could not find escapeHtml() in dashboard.html — has it moved or been renamed?');
}
const escapeHtml = new Function(`return ${match[0].replace('function escapeHtml', 'function')};`)();

test('passes plain text through unchanged', () => {
  assert.equal(escapeHtml('hello world'), 'hello world');
});

test('escapes an XSS payload', () => {
  assert.equal(
    escapeHtml('<script>alert(1)</script>'),
    '&lt;script&gt;alert(1)&lt;/script&gt;'
  );
});

test('escapes each special character individually', () => {
  assert.equal(escapeHtml('&'), '&amp;');
  assert.equal(escapeHtml('<'), '&lt;');
  assert.equal(escapeHtml('>'), '&gt;');
  assert.equal(escapeHtml('"'), '&quot;');
  assert.equal(escapeHtml("'"), '&#39;');
});

test('escapes all special characters together in the correct order', () => {
  // Regression guard: & must be escaped first. If any other replace ran
  // before it, the entity characters that replace introduces (e.g. the "&"
  // in "&lt;") would themselves get escaped on a later pass, corrupting output.
  assert.equal(escapeHtml(`&<>"'`), '&amp;&lt;&gt;&quot;&#39;');
});

test('does not try to detect or skip already-escaped entities', () => {
  // A user literally typing "&amp;" as task text is raw input, not markup —
  // escaping it again to "&amp;amp;" is correct, not a bug.
  assert.equal(escapeHtml('&amp;'), '&amp;amp;');
});

test('treats null and undefined as empty string', () => {
  assert.equal(escapeHtml(null), '');
  assert.equal(escapeHtml(undefined), '');
});

test('treats empty string as empty string', () => {
  assert.equal(escapeHtml(''), '');
});

test('coerces non-string input to string', () => {
  assert.equal(escapeHtml(42), '42');
});
