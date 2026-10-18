import { addCurrentWebsite } from './action.mjs';
chrome.action.onClicked.addListener(tab => { void addCurrentWebsite(chrome, tab); });
