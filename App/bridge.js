/*
 * 注入到音乐站点的桥接脚本（document start）。
 * 网页继续作为“操作界面”，但真正出声由原生 AVPlayer 内核负责：
 *  - 拦截 <audio>/<video> 的 play/pause/seek/currentTime/duration/paused 等；
 *  - 把播放请求转给原生，再把原生状态/事件镜像回该媒体元素；
 *  - 原生播放失败时自动回退到网页自带播放，保证一定能出声；
 *  - 保留锁屏元数据(meta)、播放状态(state)、进度(tick)上报与离线播放。
 */
(function () {
  if (window.__gd && window.__gd.installed) return;

  var NATIVE_NAME = "gdBridge";

  function post(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers &&
          window.webkit.messageHandlers[NATIVE_NAME]) {
        window.webkit.messageHandlers[NATIVE_NAME].postMessage(msg);
      }
    } catch (e) {}
  }

  function fire(el, name) {
    try { el.dispatchEvent(new Event(name)); } catch (e) {}
  }

  function isRouteable(src) {
    return ("" + src).indexOf("http://") === 0 ||
           ("" + src).indexOf("https://") === 0 ||
           ("" + src).indexOf("gdcache://item/") === 0;
  }

  /* ---------- 元素状态表 ---------- */

  var registry = {};     // id -> element
  var idSeq = 0;
  var stateMap = new WeakMap();

  function state(el) {
    var s = stateMap.get(el);
    if (!s) {
      s = {
        id: "m" + (++idSeq),
        src: "",
        playing: false,
        time: 0,
        duration: NaN,
        readyState: 0,
        ended: false,
        fallback: false,
        pending: null
      };
      stateMap.set(el, s);
      registry[s.id] = el;
    }
    return s;
  }

  /* ---------- 劫持 HTMLMediaElement ---------- */

  var proto = window.HTMLMediaElement.prototype;

  var origPlay = proto.play;
  var origPause = proto.pause;
  var origLoad = proto.load;
  var origSetAttribute = proto.setAttribute;
  var origGetAttribute = proto.getAttribute;

  var srcDesc = Object.getOwnPropertyDescriptor(proto, "src");
  var currentTimeDesc = Object.getOwnPropertyDescriptor(proto, "currentTime");
  var durationDesc = Object.getOwnPropertyDescriptor(proto, "duration");
  var pausedDesc = Object.getOwnPropertyDescriptor(proto, "paused");
  var readyStateDesc = Object.getOwnPropertyDescriptor(proto, "readyState");
  var currentSrcDesc = Object.getOwnPropertyDescriptor(proto, "currentSrc");
  var endedDesc = Object.getOwnPropertyDescriptor(proto, "ended");

  // src：只记录意图，不让网页元素自己加载
  Object.defineProperty(proto, "src", {
    configurable: true,
    enumerable: srcDesc.enumerable,
    get: function () { return state(this).src; },
    set: function (v) {
      var s = state(this);
      s.src = ("" + v);
      s.ended = false;
      s.playing = false;
      s.time = 0;
      s.duration = NaN;
      s.readyState = 0;
      s.pending = null;
    }
  });

  proto.setAttribute = function (name, value) {
    if (("" + name).toLowerCase() === "src") {
      state(this).src = ("" + value);
      return;
    }
    return origSetAttribute.apply(this, arguments);
  };
  proto.getAttribute = function (name) {
    if (("" + name).toLowerCase() === "src") return state(this).src;
    return origGetAttribute.apply(this, arguments);
  };

  // currentTime
  Object.defineProperty(proto, "currentTime", {
    configurable: true,
    enumerable: currentTimeDesc.enumerable,
    get: function () {
      var s = state(this);
      if (s.fallback) return currentTimeDesc.get.call(this);
      return s.time || 0;
    },
    set: function (v) {
      var s = state(this);
      if (s.fallback) { currentTimeDesc.set.call(this, v); return; }
      s.time = +v || 0;
      post({ kind: "seek_request", id: s.id, time: s.time });
    }
  });

  Object.defineProperty(proto, "duration", {
    configurable: true,
    enumerable: durationDesc.enumerable,
    get: function () {
      var s = state(this);
      if (s.fallback) return durationDesc.get.call(this);
      return isNaN(s.duration) ? NaN : s.duration;
    }
  });

  Object.defineProperty(proto, "paused", {
    configurable: true,
    enumerable: pausedDesc.enumerable,
    get: function () {
      var s = state(this);
      if (s.fallback) return pausedDesc.get.call(this);
      return !s.playing;
    }
  });

  Object.defineProperty(proto, "readyState", {
    configurable: true,
    enumerable: readyStateDesc.enumerable,
    get: function () {
      var s = state(this);
      if (s.fallback) return readyStateDesc.get.call(this);
      return s.readyState;
    }
  });

  Object.defineProperty(proto, "currentSrc", {
    configurable: true,
    enumerable: currentSrcDesc.enumerable,
    get: function () {
      var s = state(this);
      if (s.fallback) return currentSrcDesc.get.call(this);
      return s.src;
    }
  });

  Object.defineProperty(proto, "ended", {
    configurable: true,
    enumerable: endedDesc.enumerable,
    get: function () {
      var s = state(this);
      if (s.fallback) return endedDesc.get.call(this);
      return s.ended;
    }
  });

  function resolveSrc(el, s) {
    if (s.src) return s.src;
    // 支持 <source src> 形式
    var source = el.querySelector ? el.querySelector("source") : null;
    if (source) return sourceSrc(source);
    return "";
  }

  function enterFallback(el, s) {
    s.fallback = true;
    // 让网页元素真正加载并播放
    if (srcDesc.set) srcDesc.set.call(el, s.src);
    return origPlay.call(el);
  }

  proto.play = function () {
    var s = state(this);
    if (s.fallback) return origPlay.call(this);

    var src = resolveSrc(this, s);
    s.src = src;
    s.ended = false;

    if (!isRouteable(src)) {
      // blob/data 等无法交给原生的地址：直接用网页播放
      return enterFallback(this, s);
    }

    post({ kind: "play_request", id: s.id, src: src, time: s.time || 0 });

    return new Promise(function (resolve, reject) {
      s.pending = { resolve: resolve, reject: reject };
    });
  };

  proto.pause = function () {
    var s = state(this);
    if (s.fallback) return origPause.call(this);
    post({ kind: "pause_request", id: s.id });
  };

  proto.load = function () {
    var s = state(this);
    if (s.fallback) return origLoad.call(this);
    // 路由模式下网页不需要自己加载
  };

  /* ---------- <source src> 捕获 ---------- */

  var sourceMap = new WeakMap();
  function sourceSrc(el) {
    var v = sourceMap.get(el);
    return v != null ? v : (el.getAttribute ? el.getAttribute("src") : "");
  }
  try {
    var sproto = window.HTMLSourceElement.prototype;
    var sdesc = Object.getOwnPropertyDescriptor(sproto, "src");
    Object.defineProperty(sproto, "src", {
      configurable: true,
      enumerable: sdesc.enumerable,
      get: function () {
        var v = sourceMap.get(this);
        return v != null ? v : "";
      },
      set: function (v) { sourceMap.set(this, "" + v); }
    });
  } catch (e) {}

  /* ---------- 原生事件回流 ---------- */

  function rejectPlay(s, msg) {
    if (s.pending) {
      var err;
      try { err = new DOMException(msg || "playback error", "NotSupportedError"); }
      catch (e) { err = new Error(msg || "playback error"); }
      s.pending.reject(err);
      s.pending = null;
    }
  }

  window.__gdNativeEvent = function (obj) {
    var s, el;
    if (!obj || !obj.id) return;
    el = registry[obj.id];
    if (!el) return;
    s = stateMap.get(el);
    if (!s) return;
    // 已回退到网页播放的元素，忽略陈旧的原生回调
    if (s.fallback) return;

    switch (obj.kind) {
      case "native_ready":
        if (typeof obj.duration === "number") s.duration = obj.duration;
        s.readyState = 2;
        fire(el, "loadedmetadata");
        fire(el, "durationchange");
        s.readyState = 3;
        fire(el, "canplay");
        fire(el, "canplaythrough");
        break;

      case "native_state":
        if (obj.playing) {
          s.playing = true;
          s.ended = false;
          fire(el, "play");
          fire(el, "playing");
          if (s.pending) { s.pending.resolve(); s.pending = null; }
          post({ kind: "state", playing: true });
        } else {
          s.playing = false;
          fire(el, "pause");
          post({ kind: "state", playing: false });
        }
        break;

      case "native_time":
        s.time = obj.time;
        fire(el, "timeupdate");
        break;

      case "native_ended":
        s.playing = false;
        s.ended = true;
        fire(el, "ended");
        post({ kind: "state", playing: false });
        break;

      case "native_error":
        rejectPlay(s, obj.message);
        post({ kind: "state", playing: false });
        // 自动回退到网页播放（在线地址才有意义）
        if (isRouteable(s.src) && s.src.indexOf("gdcache://item/") !== 0) {
          try {
            var p = enterFallback(el, s);
            if (p && p.catch) p.catch(function () {});
          } catch (e) {}
        }
        break;
    }
  };

  /* ---------- 现有：DOM 媒体发现（回退元素的真实事件仍需监听） ---------- */

  function activeMedia() {
    var list = document.querySelectorAll("audio, video");
    for (var i = 0; i < list.length; i++) {
      var m = list[i];
      var ms = state(m);
      if (!ms.fallback && ms.playing) return m;
      if (ms.fallback && !m.paused && !m.ended) return m;
    }
    return list.length ? list[0] : null;
  }

  var lastStateSent = null;
  function sendStateFromElement(el) {
    var s = state(el);
    var playing = s.fallback ? (!el.paused && !el.ended) : s.playing;
    if (playing !== lastStateSent) {
      lastStateSent = playing;
      post({ kind: "state", playing: playing });
    }
  }

  function bindMedia(el) {
    if (!el || el.__gdBound) return;
    el.__gdBound = true;
    ["play", "pause", "ended", "loadedmetadata"].forEach(function (ev) {
      el.addEventListener(ev, function () { sendStateFromElement(el); }, true);
    });
  }

  var mo = new MutationObserver(function () {
    var list = document.querySelectorAll("audio, video");
    for (var i = 0; i < list.length; i++) bindMedia(list[i]);
  });
  function startObserving() {
    var list = document.querySelectorAll("audio, video");
    for (var i = 0; i < list.length; i++) bindMedia(list[i]);
    mo.observe(document.documentElement || document, { childList: true, subtree: true });
  }
  if (document.documentElement) startObserving();
  else document.addEventListener("DOMContentLoaded", startObserving);

  /* ---------- 元数据上报（锁屏/缓存） ---------- */

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

  var lastMetaSent = null;
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
    var s = m ? state(m) : null;
    var duration = s ? (isNaN(s.duration) ? 0 : s.duration) : 0;
    var src = s ? s.src : "";
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
    if (m) {
      var s = state(m);
      if (s.playing || (s.fallback && !m.paused)) {
        post({ kind: "tick", time: s.fallback ? m.currentTime : s.time });
      }
    }
  }, 1000);

  /* ---------- 对外指令（锁屏/车载按钮、离线播放） ---------- */

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
        if (m) m.play();
        else clickButton([".play", "[class*='play']"]);
      } else if (name === "pause") {
        if (m) m.pause();
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
    },

    seek: function (sec) {
      var m = activeMedia();
      if (m) m.currentTime = sec;
    },

    time: function () {
      var m = activeMedia();
      return m ? m.currentTime : 0;
    },

    /// 离线曲库：创建元素并指向本地缓存，play 会被路由到原生
    playCached: function (cacheURL, metaObj) {
      var existing = document.getElementById("__gd_offline_player");
      if (existing) existing.remove();
      var audio = document.createElement("audio");
      audio.id = "__gd_offline_player";
      audio.setAttribute("playsinline", "");
      document.documentElement.appendChild(audio);
      audio.src = cacheURL;              // gdcache://item/<key>
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
    }
  };
})();
