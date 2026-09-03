// Phase 2 interaction/regression tests for the createCard/createListItem merge
// (docs/dashboard-card-listitem-merge-roadmap.md). Phase 0 and Phase 1 test
// createCard/createListItem and the extracted "start editing" helpers in
// isolation; this file exercises the full click -> edit -> commit chain end
// to end, through the real call sites this refactor actually touched, for
// both views — the thing most likely to break if a call site was wired up
// wrong even though each piece tests fine alone.
const test = require('node:test');
const assert = require('node:assert/strict');
const { readDashboardSource, extractFunction } = require('./test-helpers/extract-source');
const { createFakeDocument, findByClass } = require('./test-helpers/dom-stub');

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
  'toggleTaskChecked',
  'toggleSubtaskChecked',
];

const combinedSource = FN_NAMES.map((name) => extractFunction(source, name)).join('\n\n');

function makeHarness() {
  const calls = { deleteTask: [], markChanged: [], renderTasks: [] };
  const fakeDocument = createFakeDocument();
  const factory = new Function(
    'document',
    'deleteTask',
    'markChanged',
    'renderTasks',
    `
    ${combinedSource}
    return { createCard, createListItem, toggleTaskChecked, toggleSubtaskChecked };
    `
  );
  const api = factory(
    fakeDocument,
    (...a) => calls.deleteTask.push(a),
    (...a) => calls.markChanged.push(a),
    (...a) => calls.renderTasks.push(a)
  );
  return { api, calls };
}

function makeTask(overrides = {}) {
  return { id: 't1', title: 'Title', note: '', checked: false, subtasks: [], ...overrides };
}

// Board view (createCard) delegates through data-action on the click target;
// simulate the click carrying a real fake element as e.target, the same way
// the browser would when the click lands on the innerHTML-templated span.
function fakeActionTarget(action, extra = {}) {
  const target = { dataset: { action, ...extra } };
  target.replaceWith = (el) => { target.captured = el; };
  return target;
}

test('board view: click -> edit title -> Enter commits the new title', () => {
  const { api, calls } = makeHarness();
  const task = makeTask({ title: 'old' });
  const card = api.createCard(task);
  const target = fakeActionTarget('edit-title');
  card.dispatch('click', { target });
  target.captured.value = 'new title';
  target.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(task.title, 'new title');
  assert.equal(calls.markChanged.length, 1);
  assert.equal(calls.renderTasks.length, 1);
});

test('board view: click -> edit note -> Enter commits the new note', () => {
  const { api } = makeHarness();
  const task = makeTask({ note: '' });
  const card = api.createCard(task);
  const target = fakeActionTarget('edit-note');
  card.dispatch('click', { target });
  target.captured.value = 'a note';
  target.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(task.note, 'a note');
});

test('board view: click -> edit subtask idx -> Enter commits the new text', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [{ text: 'a', checked: false }] });
  const card = api.createCard(task);
  const target = fakeActionTarget('edit-subtask', { idx: '0' });
  card.dispatch('click', { target });
  target.captured.value = 'a-edited';
  target.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(task.subtasks[0].text, 'a-edited');
});

test('board view: click -> add subtask -> Enter appends it', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [] });
  const card = api.createCard(task);
  const target = fakeActionTarget('add-subtask');
  card.dispatch('click', { target });
  target.captured.value = 'new one';
  target.captured.dispatch('keydown', { key: 'Enter' });
  assert.deepEqual(task.subtasks, [{ text: 'new one', checked: false }]);
});

test('board view: click -> toggle checkbox flips task.checked and re-renders', () => {
  const { api, calls } = makeHarness();
  const task = makeTask({ checked: false });
  const card = api.createCard(task);
  card.dispatch('click', { target: fakeActionTarget('toggle') });
  assert.equal(task.checked, true);
  assert.equal(calls.markChanged.length, 1);
  assert.equal(calls.renderTasks.length, 1);
});

test('board view: click -> toggle subtask checkbox flips subtasks[idx].checked', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [{ text: 'a', checked: false }] });
  const card = api.createCard(task);
  card.dispatch('click', { target: fakeActionTarget('toggle-sub', { idx: '0' }) });
  assert.equal(task.subtasks[0].checked, true);
});

test('board view: click -> delete calls deleteTask with the task', () => {
  const { api, calls } = makeHarness();
  const task = makeTask();
  const card = api.createCard(task);
  card.dispatch('click', { target: fakeActionTarget('delete') });
  assert.deepEqual(calls.deleteTask.at(-1), [task]);
});

// List view (createListItem) attaches real listeners to real child elements,
// so these dispatch directly on the real DOM nodes instead of a synthetic target.
// startInlineEdit swaps the clicked element out via el.replaceWith(input)
// (dashboard.html:1366) rather than returning it, so wrap the real element's
// replaceWith to capture the input it gets handed, the same way captureAnchor
// does for synthetic targets.
function captureReplace(el) {
  const original = el.replaceWith.bind(el);
  el.replaceWith = (newEl) => { el.captured = newEl; original(newEl); };
  return el;
}

test('list view: click title -> Enter commits the new title', () => {
  const { api } = makeHarness();
  const task = makeTask({ title: 'old' });
  const item = api.createListItem(task);
  const title = captureReplace(findByClass(item, 'list-item-title')[0]);
  title.dispatch('click');
  title.captured.value = 'new title';
  title.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(task.title, 'new title');
});

test('list view: click "+ Add note" -> Enter commits the new note', () => {
  const { api } = makeHarness();
  const task = makeTask({ note: '' });
  const item = api.createListItem(task);
  const addNote = captureReplace(findByClass(item, 'add-note')[0]);
  addNote.dispatch('click');
  addNote.captured.value = 'a note';
  addNote.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(task.note, 'a note');
});

test('list view: click subtask text -> Enter commits the new text', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [{ text: 'a', checked: false }] });
  const item = api.createListItem(task);
  const subtaskText = captureReplace(findByClass(item, 'list-item-subtask')[0].children[1]);
  subtaskText.dispatch('click');
  subtaskText.captured.value = 'a-edited';
  subtaskText.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(task.subtasks[0].text, 'a-edited');
});

test('list view: click "+ Add subtask" -> Enter appends it', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [] });
  const item = api.createListItem(task);
  const addSubtask = captureReplace(findByClass(item, 'list-item-add-subtask')[0]);
  addSubtask.dispatch('click');
  addSubtask.captured.value = 'new one';
  addSubtask.captured.dispatch('keydown', { key: 'Enter' });
  assert.deepEqual(task.subtasks, [{ text: 'new one', checked: false }]);
});

test('list view: click checkbox flips task.checked', () => {
  const { api } = makeHarness();
  const task = makeTask({ checked: false });
  const item = api.createListItem(task);
  item.children[0].dispatch('click');
  assert.equal(task.checked, true);
});

test('list view: click subtask checkbox flips subtasks[idx].checked', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [{ text: 'a', checked: false }] });
  const item = api.createListItem(task);
  const subtaskCheckbox = findByClass(item, 'list-item-subtask')[0].children[0];
  subtaskCheckbox.dispatch('click');
  assert.equal(task.subtasks[0].checked, true);
});

test('list view: click delete button calls deleteTask with the task', () => {
  const { api, calls } = makeHarness();
  const task = makeTask();
  const item = api.createListItem(task);
  const deleteBtn = findByClass(item, 'list-item-actions')[0].children[0];
  deleteBtn.dispatch('click');
  assert.deepEqual(calls.deleteTask.at(-1), [task]);
});

test('both views: title editing styleCss differs (board 14px vs list 15px font-size), confirming each view still gets its own layout', () => {
  const { api: boardApi } = makeHarness();
  const { api: listApi } = makeHarness();
  const boardCard = boardApi.createCard(makeTask());
  const target = fakeActionTarget('edit-title');
  boardCard.dispatch('click', { target });

  const listItem = listApi.createListItem(makeTask());
  const listTitle = captureReplace(findByClass(listItem, 'list-item-title')[0]);
  listTitle.dispatch('click');

  assert.match(target.captured.style.cssText, /font-size: 14px/);
  assert.match(listTitle.captured.style.cssText, /font-size: 15px/);
});
