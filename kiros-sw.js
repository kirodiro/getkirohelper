/* Kiros helper: lets the Live board show alerts as system notifications on phones (they only allow them through a service worker).
   It does nothing else: no caching, no network requests. Tapping a notification brings the Live board back to the front. */
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) { if (/live\.html/.test(list[i].url) && "focus" in list[i]) return list[i].focus(); }
    if (self.clients.openWindow) return self.clients.openWindow("live.html");
  }));
});
