#!/usr/bin/env node
'use strict';

// Portable synthetic notification regressions. Node is a test-only dependency.
// Runs methods extracted verbatim from the selected QML source. QML property
// bindings, signals, Timer scheduling and execDetached are simulated below.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// An optional source directory supports checking the same tests against an old
// revision without editing either the tests or the production source.
const rootDir = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const notifierSource = fs.readFileSync(path.join(rootDir, 'Notifier.qml'), 'utf8');
const storeSource = fs.readFileSync(path.join(rootDir, 'PotStore.qml'), 'utf8');
const panelSource = fs.readFileSync(path.join(rootDir, 'Panel.qml'), 'utf8');

function functions(source, names) {
  return names.map(name => {
    const match = source.match(new RegExp('^  function ' + name + '\\([^\\n]*\\) \\{[\\s\\S]*?^  \\}', 'm'));
    assert(match, 'Missing production method: ' + name);
    return match[0];
  }).join('\n');
}

function harness(kind = 'hook') {
  const clock = { now: 1000 };
  const output = [];
  const timer = {
    due: null,
    restart() { this.due = clock.now + 3000; },
    stop() { this.due = null; },
  };
  const notify = {
    enabled: true, cooldownMs: 60000, settleMs: 3000,
    focusedPaneId: '', focusedWindow: '', lastFired: {}, pending: [],
    glyphAttention: 'attention', glyphReady: 'ready', glyphBurnt: 'burnt',
    settle: timer, Date: { now: () => clock.now },
    Quickshell: { execDetached(argv) { output.push(JSON.parse(JSON.stringify(argv))); } },
  };
  notify.root = notify;
  const names = ['glyphFor', 'consider', 'flush', 'send'];
  if (/function isFocused\(/.test(notifierSource)) names.push('isFocused');
  vm.createContext(notify);
  vm.runInContext(functions(notifierSource, names), notify, { timeout: 1000 });
  const disabled = notifierSource.match(/^  onEnabledChanged: \{([\s\S]*?)^  \}/m);
  if (disabled) vm.runInContext('function enabledChanged() {' + disabled[1] + '}', notify, { timeout: 1000 });

  const store = {
    herdrPots: [], hookPots: {}, remotePots: {}, piModels: {},
    Date: { now: () => clock.now },
    potChanged(pot, fromState) { notify.consider(pot, fromState); },
  };
  store.root = store;
  vm.createContext(store);
  const storeNames = [
    'mapStatus', 'reconcile', 'reconcileRemote', 'ingest', 'agentLabel',
    'canonAddr', 'basename', 'seenWindow',
    'dropHookPot', 'acknowledgeHookPot', 'dropClosedHookWindows',
    'dropRemoteHost', 'clear', 'isLive',
  ];
  if (/function canonDesktopThread\(/.test(storeSource)) storeNames.push('canonDesktopThread');
  if (/function runTiming\(/.test(storeSource)) storeNames.push('runTiming');
  // The navigation-adapter branch replaces canonDesktopThread with this
  // production module. Load it when present so combined-source checks use
  // the same normalization and key policy rather than a navigation mock.
  if (/import "Navigation\.js" as Navigation/.test(storeSource)) {
    const navigation = {};
    vm.createContext(navigation);
    vm.runInContext(fs.readFileSync(path.join(rootDir, 'Navigation.js'), 'utf8')
      .replace(/^\.pragma library\r?\n/, ''), navigation, { timeout: 1000 });
    store.Navigation = navigation;
    store.hookRevision = 0;
  }
  vm.runInContext(functions(storeSource, storeNames), store, { timeout: 1000 });
  store.liveStates = ['simmering', 'needs-attention'];
  const pots = storeSource.match(/^  readonly property var pots: \{([\s\S]*?)^  \}/m);
  assert(pots, 'Missing production pot-list binding');
  vm.runInContext('function allPots() {' + pots[1] + '}', store, { timeout: 1000 });
  Object.defineProperty(notify, 'currentPots', { get() { return store.allPots(); } });

  const agents = new Map();
  function update(state, id = 'a', extra = {}) {
    if (kind === 'hook' || kind === 'remote-hook') {
      store.ingest({ id, state, agent: 'opencode', cwd: '/project', window: '0x123',
        host: kind === 'remote-hook' ? 'remote' : '', ...extra });
    } else {
      const previous = agents.get(id);
      agents.set(id, { pane_id: id, agent: 'opencode', name: 'opencode', cwd: '/project',
        agent_status: state === 'finished' ? 'done' : state,
        state_change_seq: previous ? previous.state_change_seq + 1 : 1, ...extra });
      if (kind === 'herdr') store.reconcile([...agents.values()]);
      else store.reconcileRemote('remote', [...agents.values()]);
    }
  }
  function refresh(id = 'a', extra = {}) {
    if (kind === 'hook' || kind === 'remote-hook') {
      const current = get(id);
      const state = { simmering: 'working', 'needs-attention': 'blocked', ready: 'finished' }[current.state];
      update(state, id, extra);
    } else {
      update(agents.get(id).agent_status, id, { state_change_seq: agents.get(id).state_change_seq, ...extra });
    }
  }
  function key(id = 'a') {
    return kind === 'hook' ? 'agent:' + id : kind === 'remote-hook' ? 'agent:remote:' + id
      : kind === 'herdr' ? 'herdr:' + id : 'rherdr:remote:' + id;
  }
  function get(id = 'a') { return store.allPots().find(p => p.key === key(id)); }
  function remove(id = 'a') {
    if (kind === 'hook' || kind === 'remote-hook') update('gone', id);
    else {
      agents.delete(id);
      if (kind === 'herdr') store.reconcile([...agents.values()]);
      else store.reconcileRemote('remote', [...agents.values()]);
    }
  }
  function focus(id = 'a') {
    if (kind === 'herdr' || kind === 'remote-herdr') notify.focusedPaneId = id;
    else notify.focusedWindow = get(id).windowAddr;
  }
  function enabled(value) {
    notify.enabled = value;
    if (notify.enabledChanged) notify.enabledChanged();
  }
  function advance(ms) {
    clock.now += ms;
    if (timer.due !== null && timer.due <= clock.now) {
      timer.due = null;
      notify.flush();
    }
  }
  return { clock, output, timer, notify, store, update, refresh, remove, get, key, focus, enabled, advance };
}

const results = [];
function test(name, body) {
  try { body(); results.push({ name, pass: true }); }
  catch (error) { results.push({ name, pass: false, error: error.message }); }
}
function onlyReady(h) {
  assert.equal(h.output.length, 1);
  assert.equal(h.output[0][4], 'normal');
  assert.equal(h.output[0][5], 'opencode is ready');
  assert.deepEqual(h.output[0].slice(-5), ['--exec', 'omarchy-shell', 'kettle', 'jump', h.key()]);
}

for (const kind of ['hook', 'remote-hook', 'herdr', 'remote-herdr']) {
  test(kind + ': first sighting is silent', () => {
    const h = harness(kind); h.update('blocked'); h.advance(3000);
    assert.equal(h.output.length, 0);
  });
  test(kind + ': blocked then ready is one normal toast', () => {
    const h = harness(kind); h.update('working'); h.update('blocked'); h.update('finished'); h.advance(3000);
    onlyReady(h);
  });
  test(kind + ': resumed work cancels blocked toast', () => {
    const h = harness(kind); h.update('working'); h.update('blocked'); h.update('working'); h.advance(3000);
    assert.equal(h.output.length, 0);
  });
  test(kind + ': removal cancels delayed toast', () => {
    const h = harness(kind); h.update('working'); h.update('finished'); h.remove(); h.advance(3000);
    assert.equal(h.output.length, 0);
  });
  test(kind + ': same-key same-millisecond recreation is silent', () => {
    const h = harness(kind); h.update('working'); h.update('finished'); h.remove(); h.update('finished'); h.advance(3000);
    assert.equal(h.output.length, 0);
  });
  test(kind + ': disabling before flush suppresses toast', () => {
    const h = harness(kind); h.update('working'); h.update('finished'); h.enabled(false); h.advance(3000);
    assert.equal(h.output.length, 0);
  });
  test(kind + ': disable then enable cannot resurrect queued toast', () => {
    const h = harness(kind); h.update('working'); h.update('finished'); h.enabled(false); h.enabled(true); h.advance(3000);
    assert.equal(h.output.length, 0);
  });
  test(kind + ': flush fails closed when disabled without signal delivery', () => {
    const h = harness(kind); h.update('working'); h.update('finished'); h.notify.enabled = false; h.notify.flush();
    assert.equal(h.output.length, 0);
  });
  test(kind + ': focus before flush suppresses toast', () => {
    const h = harness(kind); h.update('working'); h.update('finished'); h.focus(); h.advance(3000);
    assert.equal(h.output.length, 0);
  });
  test(kind + ': two distinct pots summarize once', () => {
    const h = harness(kind); h.update('working'); h.update('working', 'b'); h.update('blocked'); h.update('finished', 'b'); h.advance(3000);
    assert.equal(h.output.length, 1); assert.equal(h.output[0][4], 'critical');
    assert.equal(h.output[0][5], '2 pots need you');
    assert.deepEqual(h.output[0].slice(-4), ['--exec', 'omarchy-shell', 'kettle', 'open']);
  });
  test(kind + ': unchanged snapshot preserves candidate and newest label', () => {
    const h = harness(kind); h.update('working'); h.update('finished');
    const token = h.get().notificationToken;
    h.refresh('a', { cwd: '/new-project' });
    assert.equal(h.get().notificationToken, token); h.advance(3000);
    onlyReady(h); assert.equal(h.output[0][6], 'new-project');
  });
  test(kind + ': cooldown remains per key and state', () => {
    const h = harness(kind); h.update('working'); h.update('blocked'); h.advance(3000);
    h.update('working'); h.update('blocked'); h.advance(3000);
    assert.equal(h.output.length, 1);
    h.update('finished'); h.advance(3000); assert.equal(h.output.length, 2);
  });
  test(kind + ': cooldown-rejected transition cannot leave old ready queued', () => {
    const h = harness(kind); h.update('working'); h.update('blocked'); h.update('finished'); h.update('blocked'); h.advance(3000);
    assert.equal(h.output.length, 0);
  });
}

test('hook: acknowledgment cancels exact completed candidate', () => {
  const h = harness(); h.update('working'); h.update('finished'); h.store.acknowledgeHookPot(h.get()); h.advance(3000);
  assert.equal(h.output.length, 0);
});
test('hook: closed window cancels candidate', () => {
  const h = harness(); h.update('working'); h.update('finished'); h.store.dropClosedHookWindows([]); h.advance(3000);
  assert.equal(h.output.length, 0);
});
test('herdr: lost source cancels candidate', () => {
  const h = harness('herdr'); h.update('working'); h.update('finished'); h.store.clear(); h.advance(3000);
  assert.equal(h.output.length, 0);
});
test('remote herdr: host removal cancels candidate', () => {
  const h = harness('remote-herdr'); h.update('working'); h.update('finished'); h.store.dropRemoteHost('remote'); h.advance(3000);
  assert.equal(h.output.length, 0);
});
for (const kind of ['herdr', 'remote-herdr']) {
  test(kind + ': advanced sequence does not borrow an earlier transition', () => {
    const h = harness(kind); h.update('working'); h.update('finished'); h.refresh('a', { state_change_seq: 50 }); h.advance(3000);
    assert.equal(h.output.length, 0);
  });
}
test('timer: existing trailing-edge deadline is unchanged', () => {
  const h = harness(); h.update('working'); h.update('working', 'b'); h.update('finished');
  h.advance(1000); h.update('finished', 'b'); h.advance(2000);
  assert.equal(h.output.length, 0); h.advance(1000); assert.equal(h.output.length, 1);
});
test('desktop: another shared-window chat is not treated as focused', () => {
  const h = harness(); const id = '11111111-1111-4111-8111-111111111111';
  const desktop = { agent: 'codex', desktopThread: id, window: '0x123' };
  h.update('working', id, desktop); h.update('finished', id, desktop);
  h.notify.focusedWindow = '0x123'; h.advance(3000); assert.equal(h.output.length, 1);
});
test('integration: Panel binds current pots into notifier', () => {
  assert.match(panelSource, /Notifier \{\s+id: notifier\s+enabled: root\.notify\s+currentPots: store\.pots/);
});
test('copy: single-pot wording and click argv stay stable', () => {
  for (const [state, glyph, urgency, headline] of [
    ['needs-attention', 'attention', 'critical', 'opencode needs approval'],
    ['ready', 'ready', 'normal', 'opencode is ready'],
    ['burnt', 'burnt', 'normal', 'opencode failed'],
  ]) {
    const h = harness();
    h.notify.send({ state, label: 'opencode', project: 'project', key: 'agent:a' });
    assert.deepEqual(h.output, [[
      'omarchy-notification-send', '-g', glyph, '-u', urgency, headline, 'project',
      '--exec', 'omarchy-shell', 'kettle', 'jump', 'agent:a',
    ]]);
  }
});
test('initialization: disabling before Timer construction does not throw', () => {
  const h = harness(); h.notify.settle = null;
  assert.doesNotThrow(() => h.enabled(false));
  assert.equal(h.notify.pending.length, 0);
});

test('mixed summary drops focused member and sends current remaining item', () => {
  const h = harness('herdr'); h.update('working'); h.update('working', 'b');
  h.update('blocked'); h.update('finished', 'b'); h.focus('a'); h.advance(3000);
  assert.equal(h.output.length, 1); assert.equal(h.output[0][5], 'opencode is ready');
  assert.equal(h.output[0].at(-1), h.key('b'));
});
test('mixed summary drops removed member without losing remaining item', () => {
  const h = harness(); h.update('working'); h.update('working', 'b');
  h.update('blocked'); h.update('finished', 'b'); h.remove('a'); h.advance(3000);
  assert.equal(h.output.length, 1); assert.equal(h.output[0].at(-1), h.key('b'));
});
test('old acknowledgment cannot remove a newer completed snapshot', () => {
  const h = harness(); h.update('working'); h.update('finished'); const old = h.get();
  h.refresh('a', { cwd: '/updated' }); h.store.acknowledgeHookPot(old); h.advance(3000);
  assert.equal(h.output.length, 1); assert.equal(h.output[0][6], 'updated');
});
test('changed window metadata is evaluated at flush, not enqueue', () => {
  const h = harness(); h.update('working'); h.update('finished');
  h.refresh('a', { window: '0x456' }); h.notify.focusedWindow = '0x456'; h.advance(3000);
  assert.equal(h.output.length, 0);
});
test('register retirement and same-key reappearance cannot reuse queued candidate', () => {
  const h = harness(); h.update('working'); h.update('finished');
  h.update('register'); h.update('finished'); h.advance(3000); assert.equal(h.output.length, 0);
});
test('focus acknowledgement persists after focus moves away', () => {
  const h = harness(); h.update('working'); h.update('finished'); h.store.seenWindow('123');
  h.notify.focusedWindow = ''; h.advance(3000); assert.equal(h.output.length, 0);
});
test('separate sources with identical pane IDs retain independent transition tokens', () => {
  const h = harness('herdr'); h.update('working'); h.update('finished'); const local = h.get();
  h.store.reconcileRemote('remote', [{ pane_id: 'a', agent_status: 'working', state_change_seq: 1 }]);
  h.store.reconcileRemote('remote', [{ pane_id: 'a', agent_status: 'done', state_change_seq: 2 }]);
  assert.notEqual(local.notificationToken, h.store.remotePots['rherdr:remote:a'].notificationToken);
  h.store.clear(); h.advance(3000); assert.equal(h.output.length, 1);
  assert.equal(h.output[0].at(-1), 'rherdr:remote:a');
});

const failed = results.filter(result => !result.pass);
const summary = { passed: results.length - failed.length, failed: failed.length, total: results.length, results };
process.stdout.write(JSON.stringify(summary, null, 2) + '\n');
process.exitCode = failed.length ? 1 : 0;
