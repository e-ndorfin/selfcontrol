import test from 'node:test';
import assert from 'node:assert/strict';
import { addCurrentWebsite } from '../action.mjs';

function mock(send) {
    const events = [], requests = [];
    const chrome = {
        action: Object.fromEntries(['setBadgeText', 'setBadgeBackgroundColor', 'setTitle'].map(name =>
            [name, async value => events.push([name, value])])),
        runtime: { sendNativeMessage: async (host, request) => { requests.push({ host, request }); return send(); } }
    };
    return { chrome, events, requests };
}
const tab = { id: 7, url: 'https://news.reddit.com/page' };
test('one click sends only the domains and leaves the page alone', async () => {
    const m = mock(() => ({ ok: true, saved: true, activeApplied: true }));
    await addCurrentWebsite(m.chrome, tab);
    assert.deepEqual(m.requests, [{ host: 'org.eyebeam.selfcontrol.browser', request: { operation: 'append', domains: ['reddit.com', 'news.reddit.com'] } }]);
    assert.match(m.events.at(-1)[1].title, /saved list and current block/);
});
test('idle success and duplicate success have accurate feedback', async () => {
    for (const [result, title] of [
        [{ ok: true, saved: true, activeApplied: false }, /future SelfControl blocks/],
        [{ ok: true, saved: true, alreadyPresent: true }, /already in/]
    ]) {
        const m = mock(() => result);
        await addCurrentWebsite(m.chrome, tab);
        assert.match(m.events.at(-1)[1].title, title);
    }
});
test('partial failures distinguish saved sites from active enforcement', async () => {
    const m = mock(() => ({ ok: false, saved: true, message: 'Disk error' }));
    await addCurrentWebsite(m.chrome, tab);
    assert.match(m.events.at(-1)[1].title, /Saved.*current block could not be updated/);
    assert.equal(m.events.at(-2)[1].color, '#a86500');
});
test('unsupported pages do not contact the native helper', async () => {
    const m = mock(() => assert.fail('unexpected native request'));
    await addCurrentWebsite(m.chrome, { id: 7, url: 'chrome://extensions' });
    assert.equal(m.requests.length, 0);
    assert.equal(m.events[0][1].text, '!');
});
test('missing helper errors point to setup and allow a retry', async () => {
    const m = mock(() => { throw new Error('Specified native messaging host not found.'); });
    await addCurrentWebsite(m.chrome, tab);
    assert.match(m.events.at(-1)[1].title, /Run browser integration setup/);
    await addCurrentWebsite(m.chrome, tab);
    assert.equal(m.requests.length, 2);
});
test('overlapping clicks on the same tab are coalesced', async () => {
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    const m = mock(() => gate);
    const first = addCurrentWebsite(m.chrome, tab);
    await new Promise(resolve => setImmediate(resolve));
    await addCurrentWebsite(m.chrome, tab);
    release({ ok: true, saved: true });
    await first;
    assert.equal(m.requests.length, 1);
});
