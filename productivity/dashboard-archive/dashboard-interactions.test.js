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
const { createFakeDocument, findByClass, actionTargetsFromHtml } = require('./test-helpers/dom-stub');

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

// Board view (createCard) delegates through data-action on the click target.
// The target is the nth element createCard actually rendered with that
// data-action, carrying every data-* attribute the template gave it (and only
// those), so renaming or dropping a data-action/data-idx in the template fails
// here rather than being papered over by a dataset written in the test.
function renderedTarget(card, action, nth = 0) {
  const found = actionTargetsFromHtml(card.innerHTML).filter((t) => t.dataset.action === action);
  assert.ok(
    found.length > nth,
    `createCard rendered ${found.length} data-action="${action}" element(s); the test needs #${nth + 1}`
  );
  return captureReplace(found[nth]);
}

test('board view: click -> edit title -> Enter commits the new title', () => {
  const { api, calls } = makeHarness();
  const task = makeTask({ title: 'old' });
  const card = api.createCard(task);
  const target = renderedTarget(card, 'edit-title');
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
  const target = renderedTarget(card, 'edit-note');
  card.dispatch('click', { target });
  target.captured.value = 'a note';
  target.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(task.note, 'a note');
});

// Two subtasks, clicking the second, so the rendered data-idx has to be the
// right one, not just present.
test('board view: click -> edit subtask idx -> Enter commits the new text', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [{ text: 'a', checked: false }, { text: 'b', checked: false }] });
  const card = api.createCard(task);
  const target = renderedTarget(card, 'edit-subtask', 1);
  card.dispatch('click', { target });
  target.captured.value = 'b-edited';
  target.captured.dispatch('keydown', { key: 'Enter' });
  assert.deepEqual(task.subtasks.map((s) => s.text), ['a', 'b-edited']);
});

test('board view: click -> add subtask -> Enter appends it', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [] });
  const card = api.createCard(task);
  const target = renderedTarget(card, 'add-subtask');
  card.dispatch('click', { target });
  target.captured.value = 'new one';
  target.captured.dispatch('keydown', { key: 'Enter' });
  assert.deepEqual(task.subtasks, [{ text: 'new one', checked: false }]);
});

test('board view: click -> toggle checkbox flips task.checked and re-renders', () => {
  const { api, calls } = makeHarness();
  const task = makeTask({ checked: false });
  const card = api.createCard(task);
  card.dispatch('click', { target: renderedTarget(card, 'toggle') });
  assert.equal(task.checked, true);
  assert.equal(calls.markChanged.length, 1);
  assert.equal(calls.renderTasks.length, 1);
});

test('board view: click -> toggle subtask checkbox flips subtasks[idx].checked', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [{ text: 'a', checked: false }, { text: 'b', checked: false }] });
  const card = api.createCard(task);
  card.dispatch('click', { target: renderedTarget(card, 'toggle-sub', 1) });
  assert.deepEqual(task.subtasks.map((s) => s.checked), [false, true]);
});

test('board view: click -> delete calls deleteTask with the task', () => {
  const { api, calls } = makeHarness();
  const task = makeTask();
  const card = api.createCard(task);
  card.dispatch('click', { target: renderedTarget(card, 'delete') });
  assert.deepEqual(calls.deleteTask.at(-1), [task]);
});

// List view (createListItem) attaches real listeners to real child elements,
// so these dispatch directly on the real DOM nodes instead of a markup-derived
// target. startInlineEdit swaps the clicked element out via
// el.replaceWith(input) (dashboard.html:1366) rather than returning it, so wrap
// the element's replaceWith to capture the input it gets handed (renderedTarget
// above uses this for the board view's targets too).
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
  const target = renderedTarget(boardCard, 'edit-title');
  boardCard.dispatch('click', { target });

  const listItem = listApi.createListItem(makeTask());
  const listTitle = captureReplace(findByClass(listItem, 'list-item-title')[0]);
  listTitle.dispatch('click');

  assert.match(target.captured.style.cssText, /font-size: 14px/);
  assert.match(listTitle.captured.style.cssText, /font-size: 15px/);
});
