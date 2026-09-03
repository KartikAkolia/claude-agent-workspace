// Phase 1 unit tests for the "start editing" helpers extracted in Option B of
// docs/dashboard-card-listitem-merge-roadmap.md. Before the merge these were
// eight functions (four board/list pairs differing mainly in styleCss); now
// they're four functions parameterized by styleCss. These tests call each one
// with two different styleCss strings (standing in for a board-styled and a
// list-styled call site) and assert identical commit/cancel behavior in both,
// which is the property Option B is supposed to preserve.
const test = require('node:test');
const assert = require('node:assert/strict');
const { readDashboardSource, extractFunction } = require('./test-helpers/extract-source');
const { createFakeDocument } = require('./test-helpers/dom-stub');

const source = readDashboardSource();

const FN_NAMES = [
  'startInlineEdit',
  'startEditingItemTitle',
  'startEditingItemNote',
  'startEditingItemSubtask',
  'startAddingItemSubtask',
];

const combinedSource = FN_NAMES.map((name) => extractFunction(source, name)).join('\n\n');

const BOARD_STYLE = 'width: 100%; font-size: 14px;';
const LIST_STYLE = 'width: 100%; font-size: 15px;';

function makeHarness() {
  const calls = { markChanged: [], renderTasks: [] };
  const fakeDocument = createFakeDocument();
  const factory = new Function(
    'document',
    'markChanged',
    'renderTasks',
    `
    ${combinedSource}
    return { startInlineEdit, startEditingItemTitle, startEditingItemNote, startEditingItemSubtask, startAddingItemSubtask };
    `
  );
  const api = factory(
    fakeDocument,
    (...a) => calls.markChanged.push(a),
    (...a) => calls.renderTasks.push(a)
  );
  return { api, calls };
}

function makeTask(overrides = {}) {
  return { id: 't1', title: 'Title', note: '', checked: false, subtasks: [], ...overrides };
}

function captureAnchor() {
  const anchor = { dataset: {} };
  anchor.replaceWith = (el) => { anchor.captured = el; };
  return anchor;
}

test('startEditingItemTitle: echoes the passed styleCss verbatim, board and list', () => {
  const { api } = makeHarness();
  const boardAnchor = captureAnchor();
  api.startEditingItemTitle(boardAnchor, makeTask(), BOARD_STYLE);
  const listAnchor = captureAnchor();
  api.startEditingItemTitle(listAnchor, makeTask(), LIST_STYLE);
  assert.equal(boardAnchor.captured.style.cssText, BOARD_STYLE);
  assert.equal(listAnchor.captured.style.cssText, LIST_STYLE);
});

test('startEditingItemTitle: commits a changed, non-empty title in both styles', () => {
  const { api, calls } = makeHarness();
  const boardTask = makeTask({ title: 'old' });
  const listTask = makeTask({ title: 'old' });
  const boardAnchor = captureAnchor();
  api.startEditingItemTitle(boardAnchor, boardTask, BOARD_STYLE);
  const listAnchor = captureAnchor();
  api.startEditingItemTitle(listAnchor, listTask, LIST_STYLE);

  boardAnchor.captured.value = 'new';
  boardAnchor.captured.dispatch('keydown', { key: 'Enter' });
  listAnchor.captured.value = 'new';
  listAnchor.captured.dispatch('keydown', { key: 'Enter' });

  assert.equal(boardTask.title, 'new');
  assert.equal(listTask.title, 'new');
  assert.equal(calls.markChanged.length, 2);
  assert.equal(calls.renderTasks.length, 2);
});

test('startEditingItemTitle: empty commit leaves the title unchanged (no-op, not cleared)', () => {
  const { api, calls } = makeHarness();
  const task = makeTask({ title: 'keep me' });
  const anchor = captureAnchor();
  api.startEditingItemTitle(anchor, task, BOARD_STYLE);
  anchor.captured.value = '   ';
  anchor.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(task.title, 'keep me');
  assert.equal(calls.markChanged.length, 0);
  assert.equal(calls.renderTasks.length, 1);
});

test('startEditingItemNote: commits, including clearing to empty, in both styles', () => {
  const { api } = makeHarness();
  const boardTask = makeTask({ note: 'old note' });
  const listTask = makeTask({ note: 'old note' });
  const boardAnchor = captureAnchor();
  api.startEditingItemNote(boardAnchor, boardTask, BOARD_STYLE);
  const listAnchor = captureAnchor();
  api.startEditingItemNote(listAnchor, listTask, LIST_STYLE);

  boardAnchor.captured.value = '';
  boardAnchor.captured.dispatch('keydown', { key: 'Enter' });
  listAnchor.captured.value = '';
  listAnchor.captured.dispatch('keydown', { key: 'Enter' });

  assert.equal(boardTask.note, '');
  assert.equal(listTask.note, '');
});

test('startEditingItemNote: placeholder is "Add a note..." and value defaults to empty when task.note is falsy', () => {
  const { api } = makeHarness();
  const anchor = captureAnchor();
  api.startEditingItemNote(anchor, makeTask({ note: undefined }), BOARD_STYLE);
  assert.equal(anchor.captured.placeholder, 'Add a note...');
  assert.equal(anchor.captured.value, '');
});

test('startEditingItemSubtask: non-empty commit updates text, empty commit deletes it, in both styles', () => {
  const { api } = makeHarness();
  const boardTask = makeTask({ subtasks: [{ text: 'a', checked: false }, { text: 'b', checked: false }] });
  const listTask = makeTask({ subtasks: [{ text: 'a', checked: false }] });

  const boardAnchor = captureAnchor();
  api.startEditingItemSubtask(boardAnchor, boardTask, 0, BOARD_STYLE);
  boardAnchor.captured.value = 'a-edited';
  boardAnchor.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(boardTask.subtasks[0].text, 'a-edited');
  assert.equal(boardTask.subtasks.length, 2);

  const listAnchor = captureAnchor();
  api.startEditingItemSubtask(listAnchor, listTask, 0, LIST_STYLE);
  listAnchor.captured.value = '';
  listAnchor.captured.dispatch('keydown', { key: 'Enter' });
  assert.equal(listTask.subtasks.length, 0);
});

test('startAddingItemSubtask: non-empty commit appends an unchecked subtask, in both styles', () => {
  const { api } = makeHarness();
  const boardTask = makeTask({ subtasks: [] });
  const listTask = makeTask({ subtasks: [] });

  const boardAnchor = captureAnchor();
  api.startAddingItemSubtask(boardAnchor, boardTask, BOARD_STYLE);
  boardAnchor.captured.value = 'new';
  boardAnchor.captured.dispatch('keydown', { key: 'Enter' });

  const listAnchor = captureAnchor();
  api.startAddingItemSubtask(listAnchor, listTask, LIST_STYLE);
  listAnchor.captured.value = 'new';
  listAnchor.captured.dispatch('keydown', { key: 'Enter' });

  assert.deepEqual(boardTask.subtasks, [{ text: 'new', checked: false }]);
  assert.deepEqual(listTask.subtasks, [{ text: 'new', checked: false }]);
});

test('startAddingItemSubtask: tolerates a task with no subtasks array yet (guard preserved from the list-view original)', () => {
  const { api } = makeHarness();
  const task = makeTask();
  delete task.subtasks;
  const anchor = captureAnchor();
  api.startAddingItemSubtask(anchor, task, BOARD_STYLE);
  anchor.captured.value = 'first';
  anchor.captured.dispatch('keydown', { key: 'Enter' });
  assert.deepEqual(task.subtasks, [{ text: 'first', checked: false }]);
});

test('startAddingItemSubtask: empty commit does not append', () => {
  const { api } = makeHarness();
  const task = makeTask({ subtasks: [] });
  const anchor = captureAnchor();
  api.startAddingItemSubtask(anchor, task, BOARD_STYLE);
  anchor.captured.value = '   ';
  anchor.captured.dispatch('keydown', { key: 'Enter' });
  assert.deepEqual(task.subtasks, []);
});

test('Escape cancels without committing, for every helper', () => {
  const { api, calls } = makeHarness();
  const task = makeTask({ title: 'unchanged' });
  const anchor = captureAnchor();
  api.startEditingItemTitle(anchor, task, BOARD_STYLE);
  anchor.captured.value = 'should not stick';
  anchor.captured.dispatch('keydown', { key: 'Escape' });
  assert.equal(task.title, 'unchanged');
  assert.equal(calls.markChanged.length, 0);
  assert.equal(calls.renderTasks.length, 1);
});

test('blur commits the same way Enter does (shared startInlineEdit behavior)', () => {
  const { api, calls } = makeHarness();
  const task = makeTask({ title: 'old' });
  const anchor = captureAnchor();
  api.startEditingItemTitle(anchor, task, BOARD_STYLE);
  anchor.captured.value = 'via blur';
  anchor.captured.dispatch('blur');
  assert.equal(task.title, 'via blur');
  assert.equal(calls.markChanged.length, 1);
});
