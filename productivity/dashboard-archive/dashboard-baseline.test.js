// Phase 0 baseline / regression tests for the createCard/createListItem merge
// (see docs/dashboard-card-listitem-merge-roadmap.md). Covers createCard and
// createListItem, which Option B leaves untouched, extracted live from
// dashboard.html so this can't silently drift from the shipped source. The
// four "start editing" helper pairs this file originally characterized were
// collapsed into shared functions in Phase (start-on-Option-B) — their
// coverage now lives in dashboard-start-editing.test.js instead of here.
const test = require('node:test');
const assert = require('node:assert/strict');
const { readDashboardSource, extractFunction } = require('./test-helpers/extract-source');
const { createFakeDocument, findAll, findByClass } = require('./test-helpers/dom-stub');

const source = readDashboardSource();

const FN_NAMES = [
  'escapeHtml',
  'startInlineEdit',
  'createCard',
  'createListItem',
  'startEditingItemTitle',
  'startEditingItemNote',
  'startEditingItemSubtask',
  'startAddingItemSubtask',
];

const combinedSource = FN_NAMES.map((name) => extractFunction(source, name)).join('\n\n');

// Builds a fresh instance of the real dashboard functions above, wired to spy
// stand-ins for their external side-effect boundaries (task-list mutation,
// autosave scheduling, re-render). Function declarations pasted together share
// one lexical scope here exactly as they do inside dashboard.html's <script>,
// so cross-calls between them (e.g. createCard's click handler calling
// startEditingItemTitle) resolve correctly without any module system.
function makeHarness() {
  const calls = {
    toggleTaskChecked: [],
    toggleSubtaskChecked: [],
    deleteTask: [],
    markChanged: [],
    renderTasks: [],
  };
  const fakeDocument = createFakeDocument();
  const factory = new Function(
    'document',
    'toggleTaskChecked',
    'toggleSubtaskChecked',
    'deleteTask',
    'markChanged',
    'renderTasks',
    `
    ${combinedSource}
    return {
      escapeHtml, startInlineEdit, createCard, createListItem,
      startEditingItemTitle, startEditingItemNote, startEditingItemSubtask, startAddingItemSubtask,
    };
    `
  );
  const api = factory(
    fakeDocument,
    (...a) => calls.toggleTaskChecked.push(a),
    (...a) => calls.toggleSubtaskChecked.push(a),
    (...a) => calls.deleteTask.push(a),
    (...a) => calls.markChanged.push(a),
    (...a) => calls.renderTasks.push(a)
  );
  return { api, calls, fakeDocument };
}

function makeTask(overrides = {}) {
  return {
    id: 'task-1',
    title: 'Write tests',
    note: '',
    checked: false,
    subtasks: [],
    ...overrides,
  };
}

// --- createCard (board view) ---

test('createCard: root element has expected class, draggable, and id', () => {
  const { api } = makeHarness();
  const card = api.createCard(makeTask());
  assert.equal(card.className, 'task-card');
  assert.equal(card.draggable, true);
  assert.equal(card.dataset.id, 'task-1');
});

test('createCard: escapes title and note in the assembled HTML', () => {
  const { api } = makeHarness();
  const card = api.createCard(makeTask({ title: '<b>x</b>', note: '<i>y</i>' }));
  assert.match(card.innerHTML, /&lt;b&gt;x&lt;\/b&gt;/);
  assert.match(card.innerHTML, /&lt;i&gt;y&lt;\/i&gt;/);
  assert.doesNotMatch(card.innerHTML, /<b>x<\/b>/);
});

test('createCard: shows "+ Add note" placeholder when note is empty', () => {
  const { api } = makeHarness();
  const card = api.createCard(makeTask({ note: '' }));
  assert.match(card.innerHTML, /\+ Add note/);
});

test('createCard: renders each subtask, escaped, when subtasks exist', () => {
  const { api } = makeHarness();
  const card = api.createCard(makeTask({ subtasks: [{ text: '<x>', checked: true }, { text: 'plain', checked: false }] }));
  assert.match(card.innerHTML, /&lt;x&gt;/);
  assert.match(card.innerHTML, /plain/);
  assert.match(card.innerHTML, /\+ Add subtask/);
});

test('createCard: checkbox carries "checked" class iff task.checked', () => {
  const { api } = makeHarness();
  const checkedCard = api.createCard(makeTask({ checked: true }));
  const uncheckedCard = api.createCard(makeTask({ checked: false }));
  assert.match(checkedCard.innerHTML, /checkbox checked/);
  assert.doesNotMatch(uncheckedCard.innerHTML, /checkbox checked/);
});

test('createCard: dragstart/dragend toggle the dragging class', () => {
  const { api } = makeHarness();
  const task = makeTask();
  const card = api.createCard(task);
  card.dispatch('dragstart');
  assert.equal(card.classList.contains('dragging'), true);
  card.dispatch('dragend');
  assert.equal(card.classList.contains('dragging'), false);
});

test('createCard: delegated click dispatches to the right handler per data-action', () => {
  const { api, calls } = makeHarness();
  const task = makeTask({ subtasks: [{ text: 'a', checked: false }] });
  const card = api.createCard(task);

  card.dispatch('click', { target: { dataset: { action: 'toggle' } } });
  assert.deepEqual(calls.toggleTaskChecked.at(-1), [task]);

  card.dispatch('click', { target: { dataset: { action: 'toggle-sub', idx: '0' } } });
  assert.deepEqual(calls.toggleSubtaskChecked.at(-1), [task, 0]);

  card.dispatch('click', { target: { dataset: { action: 'delete' } } });
  assert.deepEqual(calls.deleteTask.at(-1), [task]);
});

// --- createListItem (list view) ---

test('createListItem: root element has expected class, draggable, and taskId', () => {
  const { api } = makeHarness();
  const item = api.createListItem(makeTask(), 'some-section');
  assert.equal(item.className, 'list-item');
  assert.equal(item.draggable, true);
  assert.equal(item.dataset.taskId, 'task-1');
});

test('createListItem: title textContent is unescaped (safe by construction via textContent, not innerHTML)', () => {
  const { api } = makeHarness();
  const item = api.createListItem(makeTask({ title: '<b>x</b>' }), 's');
  const title = findAll(item, (el) => el.classList.contains('list-item-title'))[0];
  assert.equal(title.textContent, '<b>x</b>');
});

test('createListItem: shows "+ Add note" element when note is empty, real note text otherwise', () => {
  const { api } = makeHarness();
  const empty = api.createListItem(makeTask({ note: '' }), 's');
  const withNote = api.createListItem(makeTask({ note: 'hello' }), 's');
  assert.equal(findByClass(empty, 'add-note').length, 1);
  const noteEl = findByClass(withNote, 'list-item-note')[0];
  assert.equal(noteEl.textContent, 'hello');
});

test('createListItem: renders one element per subtask when subtasks exist, none when empty', () => {
  const { api } = makeHarness();
  const withSubtasks = api.createListItem(makeTask({ subtasks: [{ text: 'a', checked: false }, { text: 'b', checked: true }] }), 's');
  const noSubtasks = api.createListItem(makeTask({ subtasks: [] }), 's');
  assert.equal(findByClass(withSubtasks, 'list-item-subtask').length, 2);
  assert.equal(findByClass(noSubtasks, 'list-item-subtask').length, 0);
});

test('createListItem: checkbox click toggles the task via toggleTaskChecked', () => {
  const { api, calls } = makeHarness();
  const task = makeTask();
  const item = api.createListItem(task, 's');
  const checkbox = item.children[0];
  assert.equal(checkbox.className.split(' ')[0], 'checkbox');
  checkbox.dispatch('click');
  assert.deepEqual(calls.toggleTaskChecked.at(-1), [task]);
});

test('createListItem: delete button click calls deleteTask with the task', () => {
  const { api, calls } = makeHarness();
  const task = makeTask();
  const item = api.createListItem(task, 's');
  const actions = findByClass(item, 'list-item-actions')[0];
  const deleteBtn = actions.children[0];
  deleteBtn.dispatch('click');
  assert.deepEqual(calls.deleteTask.at(-1), [task]);
});

test('createListItem: no longer accepts a `section` parameter (dead param removed)', () => {
  const { api } = makeHarness();
  assert.equal(api.createListItem.length, 1);
});
