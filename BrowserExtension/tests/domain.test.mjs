import test from 'node:test';
import assert from 'node:assert/strict';
import { domainsForUrl } from '../domain.mjs';

test('adds the main domain and the actual visited hostname', () => {
    assert.deepEqual(domainsForUrl('https://news.reddit.com/some-page?x=1#anchor'), ['reddit.com', 'news.reddit.com']);
    assert.deepEqual(domainsForUrl('https://reddit.com'), ['reddit.com']);
    assert.deepEqual(domainsForUrl('https://NEWS.BBC.CO.UK:8443/path'), ['bbc.co.uk', 'news.bbc.co.uk']);
});
test('respects private suffixes rather than blocking the entire hosting service', () => {
    assert.deepEqual(domainsForUrl('https://alice.github.io/page'), ['alice.github.io']);
    assert.deepEqual(domainsForUrl('https://www.alice.blogspot.com'), ['alice.blogspot.com', 'www.alice.blogspot.com']);
});
test('normalizes international domains, credentials, and trailing dots', () => {
    assert.deepEqual(domainsForUrl('https://bücher.de'), ['xn--bcher-kva.de']);
    assert.deepEqual(domainsForUrl('https://name:secret@www.example.com.:443/path'), ['example.com', 'www.example.com']);
});
test('rejects restricted pages, malformed URLs, local hosts, and IP addresses', () => {
    for (const url of [undefined, '', 'garbage', 'chrome://settings', 'file:///tmp/index.html',
        'about:blank', 'https://127.0.0.1', 'http://[::1]', 'http://localhost', 'http://office.local',
        'http://intranet', 'https://co.uk', 'https://bad_host.com', 'https://-bad.com']) {
        assert.throws(() => domainsForUrl(url), undefined, String(url));
    }
});
