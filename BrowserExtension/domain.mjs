import { parse } from 'tldts';

export function domainsForUrl(value) {
    let url;
    try { url = new URL(value); } catch { throw new Error('Open a public website before clicking Add to SelfControl.'); }
    if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Only HTTP and HTTPS websites can be added.');
    const hostname = url.hostname.toLowerCase().replace(/\.$/, '');
    const parsed = parse(hostname, { allowPrivateDomains: true, extractHostname: false });
    if (parsed.isIp || !parsed.domain || (!parsed.isIcann && !parsed.isPrivate) ||
        hostname === 'localhost' || hostname.endsWith('.localhost') || hostname.endsWith('.local')) {
        throw new Error('Local websites and IP addresses are not supported.');
    }
    const domains = [...new Set([parsed.domain, hostname])];
    if (domains.some(domain => domain.length > 253 || domain.split('.').some(label =>
        !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)))) {
        throw new Error('This website does not have a supported domain name.');
    }
    return domains;
}
