/*
 * 注入到音乐站点的桥接脚本（document start）。
 * 1. 把网页音频地址改写成 gdcache://，交给原生做“在线代理 + 自动缓存”；
 * 2. 监听 <audio>/<video> 播放状态，控制后台保活；
 * 3. 读取标题、歌手、封面、时长（并带上当前音频地址），同步到锁屏与缓存索引；
 * 4. 接收原生（锁屏/车载/离线曲库）发来的 play/pause/next/prev/seek/playCached。
 */
(function () {
  if (window.__gd && window.__gd.installed) return;

  var NATIVE_NAME = "gdBridge";
  var lastStateSent = null;
  var lastMetaSent = null;

  function post(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers &&
          window.webkit.messageHandlers[NATIVE_NAME]) {
        window.webkit.messageHandlers[NATIVE_NAME].postMessage(msg);
      }
    } catch (e) {}
  }

  /* ---------- 音频 URL 改写：http(s) -> gdcache://fetch ---------- */

  function wrapURL(u) {
    if (!u || typeof u !== "string") return u;
    if (u.indexOf("gdcache:") === 0 || u.indexOf("blob:") === 0 ||
        u.indexOf("data:") === 0) {
      return u;
    }
    if (u.indexOf("http://") === 0 || u.indexOf("https://") === 0) {
      return "gdcache://fetch?u=" + encodeURIComponent(u);
    }
    return u;
  }

  function unwrapURL(u) {
    if (!u || u.indexOf("gdcache://fetch?u=") !== 0) return u;
    try {
      var q = u.split("?u=")[1];
      return decodeURIComponent(q);
    } catch (e) { return u; }
  }

  // 拦截 HTMLMediaElement.src 的赋值
  try {
    var mediaProto =
      (window.HTMLMediaElement && window.HTMLMediaElement.prototype) || null;
    if (mediaProto) {
      var srcDesc = Object.getOwnPropertyDescriptor(mediaProto, "src");
      if (srcDesc && srcDesc.set && srcDesc.get) {
        Object.defineProperty(mediaProto, "src", {
          configurable: true,
          enumerable: srcDesc.enumerable,
          get: function () { return srcDesc.get.call(this); },
          set: function (v) { srcDesc.set.call(this, wrapURL(v)); }
        });
      }
      // setAttribute("src", ...)
      var origSetAttr = mediaProto.setAttribute;
      mediaProto.setAttribute = function (name, value) {
        if (typeof name === "string" && name.toLowerCase() === "src") {
          arguments[1] = wrapURL(value);
        }
        return origSetAttr.apply(this, arguments);
      };
    }

    // 拦截 <source src="...">
    var sourceProto =
      (window.HTMLSourceElement && window.HTMLSourceElement.prototype) || null;
    if (sourceProto) {
      var sDesc = Object.getOwnPropertyDescriptor(sourceProto, "src");
      if (sDesc && sDesc.set && sDesc.get) {
        Object.defineProperty(sourceProto, "src", {
          configurable: true,
          enumerable: sDesc.enumerable,
          get: function () { return sDesc.get.call(this); },
          set: function (v) { sDesc.set.call(this, wrapURL(v)); }
        });
      }
    }
  } catch (e) {}

  /* ---------- 当前媒体元素 ---------- */

  function activeMedia() {
    var list = document.querySelectorAll("audio, video");
    for (var i = 0; i < list.length; i++) {
      var m = list[i];
      if (!m.paused && !m.ended && m.readyState > 0) return m;
    }
    return list.length ? list[0] : null;
  }

  /* ---------- 播放状态 ---------- */

  function sendState() {
    var m = activeMedia();
    var playing = !!(m && !m.paused && !m.ended);
    if (playing !== lastStateSent) {
      lastStateSent = playing;
      post({ kind: "state", playing: playing });
    }
  }

  function bindMedia(el) {
    if (!el || el.__gdBound) return;
    el.__gdBound = true;
    ["play", "pause", "ended", "loadedmetadata"].forEach(function (ev) {
      el.addEventListener(ev, sendState, true);
    });
  }

  var mo = new MutationObserver(function () {
    var list = document.querySelectorAll("audio, video");
    for (var i = 0; i < list.length; i++) bindMedia(list[i]);
    sendState();
  });

  function startObserving() {
    var list = document.querySelectorAll("audio, video");
    for (var i = 0; i < list.length; i++) bindMedia(list[i]);
    mo.observe(document.documentElement || document, {
      childList: true, subtree: true
    });
    sendState();
  }

  if (document.documentElement) startObserving();
  else document.addEventListener("DOMContentLoaded", startObserving);

  /* ---------- 元数据 ---------- */

  function readFromDOM() {
    var title = "", artist = "", artwork = "";
    var t = document.querySelector(
      [".song-title", ".music-title", ".track-title", ".title",
       "[class*='songName']", "[class*='song-name']",
       "[class*='trackName']", "[class*='title']"].join(","));
    if (t) title = (t.textContent || "").trim();

    var a = document.querySelector(
      [".song-artist", ".music-artist", ".artist",
       "[class*='artist']", "[class*='singer']"].join(","));
    if (a) artist = (a.textContent || "").trim();

    var img = document.querySelector(
      ".album-cover img, .music-cover img, [class*='cover'] img, img[class*='cover']");
    if (img) artwork = img.currentSrc || img.src || "";

    return { title: title, artist: artist, artwork: artwork };
  }

  function absUrl(u) {
    if (!u) return "";
    try { return new URL(u, location.href).href; } catch (e) { return ""; }
  }

  function currentOriginalURL() {
    var m = activeMedia();
    if (!m) return "";
    // currentSrc/src 可能已被改写成 gdcache，需还原成原始 URL
    return unwrapURL(m.currentSrc || m.src || "");
  }

  function sendMeta() {
    var m = activeMedia();
    var md = (navigator.mediaSession && navigator.mediaSession.metadata) || null;

    var title = md ? md.title : "";
    var artist = md ? md.artist : "";
    var artwork = md && md.artwork && md.artwork.length
      ? md.artwork[md.artwork.length - 1].src : "";

    if (!title || !artwork) {
      var dom = readFromDOM();
      if (!title) title = dom.title;
      if (!artist) artist = dom.artist;
      if (!artwork) artwork = dom.artwork;
    }

    var duration = m && isFinite(m.duration) ? m.duration : 0;
    var src = currentOriginalURL();
    var sig = [title, artist, artwork, duration, src].join("|");
    if (sig === lastMetaSent) return;
    lastMetaSent = sig;

    post({
      kind: "meta",
      title: title || document.title || "未知曲目",
      artist: artist || "",
      artwork: absUrl(artwork),
      duration: duration,
      src: src
    });
  }

  setInterval(function () {
    sendMeta();
    var m = activeMedia();
    if (m && !m.paused) {
      post({ kind: "tick", time: m.currentTime || 0 });
    }
  }, 1000);

  /* ---------- 原生指令 ---------- */

  function clickButton(selectors) {
    for (var i = 0; i < selectors.length; i++) {
      var el = document.querySelector(selectors[i]);
      if (el) { el.click(); return true; }
    }
    return false;
  }

  window.__gd = {
    installed: true,

    cmd: function (name) {
      var m = activeMedia();
      if (name === "play") {
        if (m) {
          var p = m.play();
          if (p && p.catch) p.catch(function () {
            clickButton([".play", "[class*='play']"]);
          });
        } else {
          clickButton([".play", "[class*='play']"]);
        }
      } else if (name === "pause") {
        if (m) m.pause();
        else clickButton([".pause", "[class*='pause']"]);
      } else if (name === "next") {
        var ok = clickButton([
          ".next", ".btn-next", "[aria-label='Next']",
          "[aria-label='下一首']", "[class*='next']", "[title*='下一首']"
        ]);
        if (!ok && m) m.dispatchEvent(new Event("ended"));
      } else if (name === "prev") {
        clickButton([
          ".prev", ".previous", ".btn-prev", "[aria-label='Previous']",
          "[aria-label='上一首']", "[class*='prev']", "[title*='上一首']"
        ]);
      }
      setTimeout(sendState, 200);
      setTimeout(sendMeta, 500);
    },

    seek: function (sec) {
      var mm = activeMedia();
      if (mm && isFinite(mm.duration)) {
        mm.currentTime = Math.min(Math.max(0, sec), mm.duration);
      }
    },

    time: function () {
      var mm = activeMedia();
      return mm ? (mm.currentTime || 0) : 0;
    },

    /// 离线曲库：直接用一个独立 audio 播放已缓存文件
    playCached: function (cacheURL, metaObj) {
      try {
        var existing = document.getElementById("__gd_offline_player");
        if (existing) existing.remove();

        var audio = document.createElement("audio");
        audio.id = "__gd_offline_player";
        audio.setAttribute("playsinline", "");
        audio.src = cacheURL;                 // gdcache://item/<key>
        document.documentElement.appendChild(audio);

        var pr = audio.play();
        if (pr && pr.catch) pr.catch(function () {});

        if (metaObj) {
          post({
            kind: "meta",
            title: metaObj.title || "未知曲目",
            artist: metaObj.artist || "",
            artwork: metaObj.artwork || "",
            duration: metaObj.duration || 0,
            src: cacheURL
          });
          post({ kind: "state", playing: true });
        }
      } catch (e) {}
    }
  };
})();
