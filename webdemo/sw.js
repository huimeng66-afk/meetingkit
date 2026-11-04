/*
 * MeetingKit 网页测试版 · Service Worker
 *
 * 目标：装到主屏之后，即使完全断网也能打开。
 * 策略：cache-first —— 命中缓存直接返回，未命中再走网络并顺手写入缓存。
 *
 * 升级方式：改动静态资源后把 CACHE_VERSION 加一，旧的缓存会在 activate 阶段清掉。
 */

const CACHE_PREFIX = 'meetingkit-webdemo';
const CACHE_VERSION = 'v1';
const CACHE_NAME = `${CACHE_PREFIX}-${CACHE_VERSION}`;

/** 预缓存清单：全部是相对路径，方便部署到任意子目录。 */
const PRECACHE_URLS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.addAll(PRECACHE_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((names) =>
        Promise.all(
          names
            .filter((name) => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME)
            .map((name) => caches.delete(name))
        )
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;

  // 只缓存 GET；POST 等一律放行给网络
  if (request.method !== 'GET') {
    return;
  }

  // 只处理同源请求，避免把第三方内容塞进缓存
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) {
    return;
  }

  event.respondWith(
    caches.match(request).then((cached) => {
      if (cached) {
        return cached;
      }
      return fetch(request)
        .then((response) => {
          // 只缓存成功的完整响应（response.type === 'basic' 才是同源可读的）
          if (response && response.status === 200 && response.type === 'basic') {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
          }
          return response;
        })
        .catch(() => {
          // 离线且未缓存：导航请求回退到首页，保证主屏图标点开不是白屏
          if (request.mode === 'navigate') {
            return caches.match('./index.html');
          }
          return new Response('离线且未缓存', {
            status: 503,
            statusText: 'Offline',
            headers: { 'Content-Type': 'text/plain; charset=utf-8' }
          });
        });
    })
  );
});
