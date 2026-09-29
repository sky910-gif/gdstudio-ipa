/*
 * 注入到 music.gdstudio.xyz 的桥接脚本（document start）。
 * 1. 监听页面里 <audio>/<video> 的播放状态，通知原生开始/结束“后台保活”；
 * 2. 读取 Media Session / DOM 里的标题、歌手、封面、时长，同步到锁屏；
 * 3. 接收原生（锁屏按钮）发来的 play/pause/next/prev/seek 指令。
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
      childList: true,
      subtree: true
    });
    sendState();
  }

  if (document.documentElement) startObserving();
  else document.addEventListener("DOMContentLoaded", startObserving);

  /* ---------- 元数据：优先 Media Session，其次猜 DOM ---------- */

  function readFromDOM() {
    var title = "", artist = "", artwork = "";

    // 常见播放器 DOM 命名（best effort）
    var t = document.querySelector(
      [
        ".song-title", ".music-title", ".track-title", ".title",
        "[class*='songName']", "[class*='song-name']",
        "[class*='trackName']", "[class*='title']"
      ].join(",")
    );
    if (t) title = (t.textContent || "").trim();

    var a = document.querySelector(
      [
        ".song-artist", ".music-artist", ".artist",
        "[class*='artist']", "[class*='singer']"
      ].join(",")
    );
    if (a) artist = (a.textContent || "").trim();

    var img = document.querySelector(
      ".album-cover img, .music-cover img, [class*='cover'] img, img[class*='cover']"
    );
    if (img) artwork = img.currentSrc || img.src || "";

    return { title: title, artist: artist, artwork: artwork };
  }

  function absUrl(u) {
    if (!u) return "";
    try { return new URL(u, location.href).href; } catch (e) { return ""; }
  }

  function sendMeta() {
    var m = activeMedia();
    var md = (navigator.mediaSession && navigator.mediaSession.metadata) || null;

    var title = md ? md.title : "";
    var artist = md ? md.artist : "";
    var artwork = md && md.artwork && md.artwork.length
      ? md.artwork[md.artwork.length - 1].src
      : "";

    if (!title || !artwork) {
      var dom = readFromDOM();
      if (!title) title = dom.title;
      if (!artist) artist = dom.artist;
      if (!artwork) artwork = dom.artwork;
    }

    var duration = m && isFinite(m.duration) ? m.duration : 0;
    var sig = [title, artist, artwork, duration].join("|");
    if (sig === lastMetaSent) return;
    lastMetaSent = sig;

    post({
      kind: "meta",
      title: title || document.title || "未知曲目",
      artist: artist || "",
      artwork: absUrl(artwork),
      duration: duration
    });
  }

  setInterval(function () {
    sendMeta();
    var m = activeMedia();
    if (m && !m.paused) {
      post({ kind: "tick", time: m.currentTime || 0 });
    }
  }, 1000);

  /* ---------- 原生（锁屏）指令 ---------- */

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
        // 兜底：直接派发 ended，让“播完自动下一首”逻辑触发
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
    }
  };
})();
