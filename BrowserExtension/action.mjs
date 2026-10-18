import { domainsForUrl } from './domain.mjs';

const HOST = 'org.eyebeam.selfcontrol.browser';
const pendingTabs = new Set();

async function indicate(chrome, tabId, text, color, title) {
    await Promise.all([
        chrome.action.setBadgeText({ tabId, text }),
        chrome.action.setBadgeBackgroundColor({ tabId, color }),
        chrome.action.setTitle({ tabId, title })
    ]);
}

export async function addCurrentWebsite(chrome, tab) {
    if (!Number.isInteger(tab?.id) || pendingTabs.has(tab.id)) return;
    pendingTabs.add(tab.id);
    try {
        const domains = domainsForUrl(tab.url);
        await indicate(chrome, tab.id, '…', '#666666', `Adding ${domains[0]} to SelfControl…`);
        const response = await chrome.runtime.sendNativeMessage(HOST, { operation: 'append', domains });
        if (!response || typeof response.ok !== 'boolean') throw new Error('Could not confirm the addition. Click again to retry.');
        if (!response.ok) {
            const message = response.saved
                ? `Saved ${domains[0]} for future blocks; the current block could not be updated. Click again to retry. ${response.message || ''}`
                : response.message || 'Could not add this website. Run browser integration setup and try again.';
            await indicate(chrome, tab.id, '!', response.saved ? '#a86500' : '#b3261e', message);
            return;
        }
        const title = response.alreadyPresent
            ? `${domains[0]} is already in your SelfControl blocklist.`
            : response.activeApplied
                ? `Added ${domains[0]} to your saved list and current block.`
                : `Saved ${domains[0]} for future SelfControl blocks.`;
        await indicate(chrome, tab.id, response.alreadyPresent ? 'OK' : '+', '#237a3b', title);
    } catch (error) {
        const detail = error?.message || String(error);
        const message = /native messaging|native host|host.*not found/i.test(detail)
            ? 'SelfControl’s local helper is unavailable. Run browser integration setup and try again.'
            : detail;
        try { await indicate(chrome, tab.id, '!', '#b3261e', message); } catch { /* The clicked tab may have closed. */ }
    } finally {
        pendingTabs.delete(tab.id);
    }
}
