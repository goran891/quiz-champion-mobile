const CACHE='quiz-champion-v4-6-secure-preview';
const CORE=['./','./index.html','./manifest.webmanifest','./icon-192.png','./icon-512.png','./assets/stage1-art.png','./assets/stage2-art.png','./assets/stage3-art.png','./assets/stage1-art.svg','./assets/stage2-art.svg','./assets/stage3-art.svg'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting())));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('quiz-champion-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET') return;
  const url=new URL(e.request.url);
  if(url.origin!==location.origin) return;
  e.respondWith(fetch(e.request).then(r=>{
    if(r.ok){const copy=r.clone();caches.open(CACHE).then(c=>c.put(e.request,copy));}
    return r;
  }).catch(()=>caches.match(e.request)));
});
