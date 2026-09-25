/* ============================================================================
 *  sw.js  —  service worker
 * ----------------------------------------------------------------------------
 *  Two jobs:
 *    1. It is what makes the app installable ("Add to Home Screen").
 *    2. It keeps the app shell available offline.
 *
 *  It deliberately never touches requests to Supabase: only same-origin GETs
 *  are cached, so sign-in, issues and every other API call go straight to the
 *  network and are never served stale.
 * ========================================================================= */

var CACHE = "issue-tracker-v2";

var SHELL = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icon-192.png",
  "./icon-512.png",
  "./apple-touch-icon.png"
];

self.addEventListener("install", function (event) {
  event.waitUntil(
    caches.open(CACHE)
      .then(function (cache) { return cache.addAll(SHELL); })
      .then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener("activate", function (event) {
  event.waitUntil(
    caches.keys()
      .then(function (keys) {
        return Promise.all(keys.filter(function (k) { return k !== CACHE; })
                                .map(function (k) { return caches.delete(k); }));
      })
      .then(function () { return self.clients.claim(); })
  );
});

self.addEventListener("fetch", function (event) {
  var request = event.request;

  if (request.method !== "GET") return;

  var url = new URL(request.url);
  if (url.origin !== self.location.origin) return;   // never cache Supabase

  // Network first, so a new deploy is picked up on the next load. The cache is
  // only a fallback for when there is no network at all.
  event.respondWith(
    fetch(request)
      .then(function (response) {
        var copy = response.clone();
        caches.open(CACHE).then(function (cache) { cache.put(request, copy); }).catch(function () {});
        return response;
      })
      .catch(function () {
        return caches.match(request).then(function (hit) {
          return hit || caches.match("./index.html");
        });
      })
  );
});

/* ============================================================================
 *  NOTIFICATIONS
 * ----------------------------------------------------------------------------
 *  A notification shown through the service worker stays on screen after the
 *  page is backgrounded, and tapping it brings the app back to the front.
 *
 *  The "push" handler is here for a future server-sent push. Nothing sends
 *  one yet: without a sender (a server holding a push subscription and a
 *  VAPID key) a push message cannot be delivered to a closed app. Until then
 *  notifications are raised by the page itself, while the app is running, and
 *  reach the screen through this worker.
 * ========================================================================= */

self.addEventListener("push", function (event) {
  var data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = {}; }

  event.waitUntil(
    self.registration.showNotification(data.title || "Issue Tracker", {
      body: data.body || "There is new activity on the board.",
      icon: "./icon-192.png",
      badge: "./icon-192.png",
      tag: data.tag || "issue-tracker",
      data: { url: data.url || "./" }
    })
  );
});

self.addEventListener("notificationclick", function (event) {
  event.notification.close();

  var target = (event.notification.data && event.notification.data.url) || "./";

  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (list) {
      // Already open somewhere? Focus that window rather than opening another.
      for (var i = 0; i < list.length; i++) {
        if ("focus" in list[i]) {
          try { return list[i].focus(); } catch (e) { /* carry on */ }
        }
      }
      if (clients.openWindow) return clients.openWindow(target);
    })
  );
});
