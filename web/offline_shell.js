/* Register only a generated release shell. Flutter development stays uncached. */
(() => {
  'use strict';
  const enabled = document.querySelector('meta[name="getbible-offline-shell"]');
  if (enabled?.content !== 'enabled' || !window.isSecureContext || !('serviceWorker' in navigator)) return;
  const base = new URL('.', document.baseURI);
  if (base.origin !== window.location.origin) return;
  navigator.serviceWorker.register(new URL('offline_service_worker.js', base), {
    scope: base.href,
    updateViaCache: 'none',
  }).catch(() => {
    // Online reading remains available when storage is full or the host cannot
    // serve the shell. Do not reload an editor or mislabel the app offline-ready.
    console.warn('Offline application files could not be prepared; online reading remains available.');
  });
})();
