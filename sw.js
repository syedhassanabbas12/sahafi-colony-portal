// Sahafi Colony Portal — service worker.
//
// Caches the static app shell (HTML/CSS/JS/icons — everything this app needs
// to *display*) so it opens instantly and works offline. Financial data
// always comes live from Supabase and is never cached here — an offline
// visitor sees the last screen they had open, not stale numbers presented
// as current.
const CACHE_NAME = "sahafi-colony-shell-v1";
const SHELL_FILES = ["./", "index.html", "config.js", "manifest.json", "icons/icon-192.png", "icons/icon-512.png"];

self.addEventListener("install", function (e) {
  e.waitUntil(
    caches.open(CACHE_NAME).then(function (cache) {
      return cache.addAll(SHELL_FILES);
    }).then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener("activate", function (e) {
  e.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.filter(function (k) { return k !== CACHE_NAME; }).map(function (k) { return caches.delete(k); }));
    }).then(function () { return self.clients.claim(); })
  );
});

self.addEventListener("fetch", function (e) {
  const url = new URL(e.request.url);
  // Only serve the app shell from cache; every other request (Supabase RPC
  // calls, tel: links, etc.) goes straight to the network untouched.
  if (e.request.method !== "GET" || url.origin !== self.location.origin) return;
  if (!SHELL_FILES.some(function (f) { return url.pathname.endsWith(f.replace("./", "")) || (f === "./" && url.pathname === "/"); })) return;

  e.respondWith(
    caches.match(e.request).then(function (cached) {
      const network = fetch(e.request).then(function (res) {
        caches.open(CACHE_NAME).then(function (cache) { cache.put(e.request, res.clone()); });
        return res;
      }).catch(function () { return cached; });
      return cached || network;
    })
  );
});
