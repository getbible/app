/**
 * Match only browser diagnostics caused by this harness's completed disconnects.
 * A page/phase and one-use request record prevent a past URL from becoming a
 * permanent allowlist. Runtime exceptions never pass through this classifier.
 */
export function classifyNetworkDiagnostics(consoleErrors, injectedDisconnects) {
  const consumed = new Set();
  const expected = [];
  const unexpected = [];
  for (const diagnostic of consoleErrors) {
    const url = disconnectedUrl(diagnostic);
    const index = url && diagnostic.type === 'console' && diagnostic.apiOffline &&
        Number.isSafeInteger(diagnostic.pageId) && diagnostic.pageId > 0
      ? injectedDisconnects.findIndex((request, index) =>
        !consumed.has(index) && request.url === url &&
        request.pageId === diagnostic.pageId && request.phase === diagnostic.phase &&
        request.method === 'GET' && request.knownFixture === true &&
        request.code === 'internetdisconnected' && request.apiOffline === true)
      : -1;
    if (index >= 0) {
      consumed.add(index);
      expected.push({ ...diagnostic, injectedDisconnect: injectedDisconnects[index] });
    } else {
      unexpected.push(diagnostic);
    }
  }
  return { expected, unexpected };
}

function disconnectedUrl({ message, locationUrl }) {
  // Firefox reports an intentionally aborted cross-origin request through its
  // CORS diagnostic. Missing headers, policy rejection and HTTP errors do not
  // match this exact network-failure form observed in the compiled-app CI run.
  const firefox = /^\[JavaScript Error: "Cross-Origin Request Blocked: The Same Origin Policy disallows reading the remote resource at (https?:\/\/[^\s]+)\. \(Reason: CORS request did not succeed\)\. Status code: \(null\)\."\]$/.exec(message);
  if (firefox) return firefox[1];
  if (/^Failed to load resource: (?:net::ERR_INTERNET_DISCONNECTED|The network connection was lost\.|The Internet connection appears to be offline\.)$/.test(message)) {
    return locationUrl;
  }
  return null;
}
