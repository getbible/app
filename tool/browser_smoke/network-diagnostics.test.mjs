import assert from 'node:assert/strict';
import test from 'node:test';
import { classifyNetworkDiagnostics } from './network-diagnostics.mjs';

const url = 'https://api.getbible.net/v3/kjv/1/1.sha';
const firefox = `[JavaScript Error: "Cross-Origin Request Blocked: The Same Origin Policy disallows reading the remote resource at ${url}. (Reason: CORS request did not succeed). Status code: (null)."]`;
const diagnostic = { type: 'console', message: firefox, locationUrl: '', pageId: 2, phase: 1, apiOffline: true };
const abort = { url, method: 'GET', knownFixture: true, code: 'internetdisconnected', pageId: 2, phase: 1, apiOffline: true };

test('accepts the exact Firefox diagnostic for one completed injected disconnect', () => {
  const result = classifyNetworkDiagnostics([diagnostic], [abort]);
  assert.deepEqual(result.unexpected, []);
  assert.equal(result.expected.length, 1);
  assert.deepEqual(result.expected[0].injectedDisconnect, abort);
});

test('three real aborted retries can explain three Firefox diagnostics', () => {
  const result = classifyNetworkDiagnostics(Array(3).fill(diagnostic), Array(3).fill(abort));
  assert.equal(result.expected.length, 3);
  assert.deepEqual(result.unexpected, []);
});

test('never treats a prior URL as an unrestricted or reusable allowlist', () => {
  for (const changes of [
    { apiOffline: false }, { pageId: 3 }, { phase: 2 }, { type: 'pageerror' },
    { message: firefox.replace(url, 'https://unknown.example/resource.sha') },
  ]) {
    const changed = { ...diagnostic, ...changes };
    assert.deepEqual(classifyNetworkDiagnostics([changed], [abort]).unexpected, [changed]);
  }
  assert.deepEqual(classifyNetworkDiagnostics([diagnostic], []).unexpected, [diagnostic]);
  const unowned = { ...diagnostic, pageId: undefined };
  assert.deepEqual(classifyNetworkDiagnostics([unowned], [{ ...abort, pageId: undefined }]).unexpected, [unowned]);
  const duplicate = classifyNetworkDiagnostics([diagnostic, diagnostic], [abort]);
  assert.equal(duplicate.expected.length, 1);
  assert.deepEqual(duplicate.unexpected, [diagnostic]);
});

test('requires the actual fixture GET abort provenance', () => {
  for (const changes of [
    { knownFixture: false }, { method: 'POST' }, { code: 'blockedbyclient' },
    { apiOffline: false }, { pageId: null }, { phase: 0 },
  ]) {
    assert.deepEqual(classifyNetworkDiagnostics([diagnostic], [{ ...abort, ...changes }]).unexpected, [diagnostic]);
  }
});

test('CORS header, policy and HTTP failures remain errors even for an aborted URL', () => {
  for (const message of [
    firefox.replace('CORS request did not succeed', "CORS header 'Access-Control-Allow-Origin' missing"),
    firefox.replace('CORS request did not succeed', 'CORS request external redirect not allowed'),
    firefox.replace('(null)', '403'),
    'TypeError: Failed to fetch',
    'NetworkError when attempting to fetch resource.',
  ]) {
    const changed = { ...diagnostic, message };
    assert.deepEqual(classifyNetworkDiagnostics([changed], [abort]).unexpected, [changed]);
  }
});

test('Chromium and WebKit disconnect wording must carry the exact request URL', () => {
  for (const message of [
    'Failed to load resource: net::ERR_INTERNET_DISCONNECTED',
    'Failed to load resource: The network connection was lost.',
    'Failed to load resource: The Internet connection appears to be offline.',
  ]) {
    const changed = { ...diagnostic, message, locationUrl: url };
    assert.deepEqual(classifyNetworkDiagnostics([changed], [abort]).unexpected, []);
    const missingUrl = { ...changed, locationUrl: '' };
    assert.deepEqual(classifyNetworkDiagnostics([missingUrl], [abort]).unexpected, [missingUrl]);
  }
});
