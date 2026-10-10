/** Exercise the exact shipped worker while recording UI liveness and duration.
 * This measures a deterministic synthetic corpus; no device-speed pass/fail
 * threshold or physical-device performance claim is inferred from a CI host.
 */
export async function measureWorker(page, kind = 'bible') {
  return page.evaluate(async (kind) => {
    const corpus = kind === 'bible' ? {
      abbreviation: 'perf', translation: 'Synthetic worker acceptance corpus',
      language: 'English', lang: 'en', direction: 'LTR',
      books: Array.from({ length: 20 }, (_, b) => ({
        nr: b + 1, name: `Fixture ${b + 1}`,
        chapters: Array.from({ length: 20 }, (_, c) => ({
          chapter: c + 1, name: `Fixture ${b + 1} ${c + 1}`,
          verses: Array.from({ length: 50 }, (_, v) => ({
            chapter: c + 1, verse: v + 1,
            text: `Original synthetic Scripture ${b + 1}:${c + 1}:${v + 1}. Unicode keeps שלום, λόγος, and 😀 intact. `.repeat(3),
          })),
        })),
      })),
    } : {
      schema: 'getbible-dictionary-index-v1', dictionary: 'perf', language: 'en',
      name: 'Synthetic dictionary index', entry_url_template: '{entry}.json',
      entry_count: 20000, unique_key_count: 20000,
      entries: Array.from({ length: 20000 }, (_, entry) => ({
        id: `published-${entry}`, key: `Word ${entry}`, search: `word ${entry}`,
        aliases: [`Wórd ${entry}`, `Λόγος ${entry}`],
      })),
    };
    const bytes = new TextEncoder().encode(JSON.stringify(corpus));
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-1', bytes)),
      (value) => value.toString(16).padStart(2, '0')).join('');
    const metrics = { corpus: 'synthetic-v1', kind, sourceBytes: bytes.length, verses: 0, entries: 0, maximumEntryBatch: 0,
      workerBatches: 0, maximumVerseBatch: 0, uiHeartbeatTicks: 0, longTasks: [] };
    const observer = typeof PerformanceObserver !== 'undefined'
      && PerformanceObserver.supportedEntryTypes.includes('longtask')
      ? new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) metrics.longTasks.push(entry.duration);
      }) : null;
    observer?.observe({ type: 'longtask' });
    const heartbeat = setInterval(() => metrics.uiHeartbeatTicks++, 10);
    const worker = new Worker(new URL('offline_bible_worker.dart.js', document.baseURI));
    const started = performance.now();
    let timeout;
    try {
      await new Promise((resolve, reject) => {
        timeout = setTimeout(() => reject(new Error('Worker acceptance exceeded three minutes')), 180000);
        worker.onerror = (event) => reject(new Error(event.message));
        worker.onmessage = ({ data }) => {
          if (data.error) return reject(new Error(data.error));
          if (data.done) return resolve();
          metrics.workerBatches++;
          if (data.verses) {
            metrics.verses += data.verses.length;
            metrics.maximumVerseBatch = Math.max(metrics.maximumVerseBatch, data.verses.length);
          }
          if (data.entries) {
            metrics.entries += data.entries.length;
            metrics.maximumEntryBatch = Math.max(metrics.maximumEntryBatch, data.entries.length);
            if (data.normalized?.length !== data.entries.length) return reject(new Error('Missing normalized dictionary lookup keys'));
          }
          worker.postMessage({ next: true });
        };
        worker.postMessage(kind === 'bible'
          ? { operation: 'bible', bytes, abbreviation: 'perf', sha: hash }
          : { operation: 'study', kind: 'dictionary-index', module: 'perf', bytes });
      });
      metrics.elapsedMilliseconds = performance.now() - started;
      metrics.jsHeapBytes = performance.memory?.usedJSHeapSize ?? null;
      metrics.longTaskObservationSupported = observer !== null;
      return metrics;
    } finally {
      clearTimeout(timeout);
      clearInterval(heartbeat);
      observer?.disconnect();
      worker.terminate();
    }
  }, kind);
}
