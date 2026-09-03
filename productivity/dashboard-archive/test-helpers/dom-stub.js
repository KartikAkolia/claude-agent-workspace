// Minimal, dependency-free DOM stand-in for testing dashboard.html's DOM-building
// functions under plain node:test. Deliberately not jsdom: SPEC.md's non-goals
// rule out adding build/runtime dependencies to this project, and this stub only
// needs to support the handful of DOM APIs createCard/createListItem/startInlineEdit
// actually call, not a full browser.
class FakeElement {
  constructor(tagName) {
    this.tagName = (tagName || 'div').toUpperCase();
    this._className = '';
    this.dataset = {};
    this.style = { cssText: '' };
    this.children = [];
    this.parentNode = null;
    this.draggable = false;
    this.disabled = false;
    this._listeners = {};
    this._text = '';
    this._html = '';
    this.value = '';
    this.type = '';
    this.placeholder = '';
    this.focused = false;
    this.selected = false;
  }

  get className() { return this._className; }
  set className(v) { this._className = v; }

  get classList() {
    const self = this;
    const set = () => new Set(self._className.split(/\s+/).filter(Boolean));
    return {
      add: (...names) => { const s = set(); names.forEach(n => s.add(n)); self._className = [...s].join(' '); },
      remove: (...names) => { const s = set(); names.forEach(n => s.delete(n)); self._className = [...s].join(' '); },
      contains: (name) => set().has(name),
    };
  }

  get textContent() { return this._text; }
  set textContent(v) { this._text = String(v); this.children = []; this._html = ''; }

  get innerHTML() { return this._html; }
  set innerHTML(v) {
    this._html = String(v);
    this._text = '';
    // Only used by createListItem's `actions.innerHTML = '<button>...</button>'`
    // pattern (dashboard.html:2171) so it can then querySelector('button') back
    // out — not a general HTML parser, just enough to make that round-trip work.
    this.children = parseSimpleHtml(this._html, this);
  }

  appendChild(child) {
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  remove() {
    if (this.parentNode) {
      const idx = this.parentNode.children.indexOf(this);
      if (idx !== -1) this.parentNode.children.splice(idx, 1);
      this.parentNode = null;
    }
  }

  replaceWith(newEl) {
    if (this.parentNode) {
      const idx = this.parentNode.children.indexOf(this);
      if (idx !== -1) this.parentNode.children.splice(idx, 1, newEl);
      newEl.parentNode = this.parentNode;
    }
    this.parentNode = null;
  }

  addEventListener(type, handler) {
    if (!this._listeners[type]) this._listeners[type] = [];
    this._listeners[type].push(handler);
  }

  // Not a real dispatch (no bubbling/capturing) — invokes handlers registered
  // directly on this element, which is all these functions' delegation model needs:
  // createCard delegates via a single listener on the card root with a synthetic
  // `target`, createListItem attaches one listener per real child element.
  dispatch(type, evtOverrides = {}) {
    const event = {
      target: this,
      currentTarget: this,
      preventDefault() {},
      stopPropagation() {},
      dataTransfer: { setData() {}, effectAllowed: undefined },
      ...evtOverrides,
    };
    (this._listeners[type] || []).forEach(h => h(event));
    return event;
  }

  focus() { this.focused = true; }
  select() { this.selected = true; }

  querySelector(selector) {
    return matches(this, selector) || null;
  }

  querySelectorAll() { return []; }
}

// Handles exactly the one innerHTML shape this codebase produces in scope
// (a single flat tag, optionally with attributes and text/entity content) —
// not nested markup, since nothing in the tested functions needs that.
function parseSimpleHtml(html, parent) {
  const children = [];
  const re = /<(\w+)((?:\s+[^>]*)?)>([\s\S]*?)<\/\1>/g;
  let m;
  while ((m = re.exec(html))) {
    const [, tag, , inner] = m;
    const el = new FakeElement(tag);
    el.parentNode = parent;
    el.textContent = inner.replace(/&times;/g, '×').replace(/&amp;/g, '&');
    children.push(el);
  }
  return children;
}

// Simple descendant tag-name lookup — the only selector shape used by the
// functions under test (`actions.querySelector('button')`).
function matches(root, selector) {
  const tag = selector.trim().toLowerCase();
  return findAll(root, (el) => el !== root && el.tagName.toLowerCase() === tag)[0];
}

function createFakeDocument() {
  return {
    createElement: (tag) => new FakeElement(tag),
    querySelectorAll: () => [],
  };
}

function findAll(root, predicate) {
  const out = [];
  (function walk(el) {
    if (predicate(el)) out.push(el);
    el.children.forEach(walk);
  })(root);
  return out;
}

function findByClass(root, className) {
  return findAll(root, el => el.classList.contains(className));
}

module.exports = { FakeElement, createFakeDocument, findAll, findByClass };
