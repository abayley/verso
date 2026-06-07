(() => {
  var __create = Object.create;
  var __getProtoOf = Object.getPrototypeOf;
  var __defProp = Object.defineProperty;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  function __accessProp(key) {
    return this[key];
  }
  var __toESMCache_node;
  var __toESMCache_esm;
  var __toESM = (mod, isNodeMode, target) => {
    var canCache = mod != null && typeof mod === "object";
    if (canCache) {
      var cache = isNodeMode ? __toESMCache_node ??= new WeakMap : __toESMCache_esm ??= new WeakMap;
      var cached = cache.get(mod);
      if (cached)
        return cached;
    }
    target = mod != null ? __create(__getProtoOf(mod)) : {};
    const to = isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target;
    for (let key of __getOwnPropNames(mod))
      if (!__hasOwnProp.call(to, key))
        __defProp(to, key, {
          get: __accessProp.bind(mod, key),
          enumerable: true
        });
    if (canCache)
      cache.set(mod, to);
    return to;
  };
  var __commonJS = (cb, mod) => () => (mod || cb((mod = { exports: {} }).exports, mod), mod.exports);
  var __returnValue = (v) => v;
  function __exportSetter(name, newValue) {
    this[name] = __returnValue.bind(null, newValue);
  }
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: __exportSetter.bind(all, name)
      });
  };
  var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
    get: (a, b) => (typeof require !== "undefined" ? require : a)[b]
  }) : x)(function(x) {
    if (typeof require !== "undefined")
      return require.apply(this, arguments);
    throw Error('Dynamic require of "' + x + '" is not supported');
  });

  // node_modules/ms/index.js
  var require_ms = __commonJS((exports, module) => {
    var s = 1000;
    var m = s * 60;
    var h = m * 60;
    var d = h * 24;
    var w = d * 7;
    var y = d * 365.25;
    module.exports = function(val, options) {
      options = options || {};
      var type = typeof val;
      if (type === "string" && val.length > 0) {
        return parse(val);
      } else if (type === "number" && isFinite(val)) {
        return options.long ? fmtLong(val) : fmtShort(val);
      }
      throw new Error("val is not a non-empty string or a valid number. val=" + JSON.stringify(val));
    };
    function parse(str) {
      str = String(str);
      if (str.length > 100) {
        return;
      }
      var match = /^(-?(?:\d+)?\.?\d+) *(milliseconds?|msecs?|ms|seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w|years?|yrs?|y)?$/i.exec(str);
      if (!match) {
        return;
      }
      var n = parseFloat(match[1]);
      var type = (match[2] || "ms").toLowerCase();
      switch (type) {
        case "years":
        case "year":
        case "yrs":
        case "yr":
        case "y":
          return n * y;
        case "weeks":
        case "week":
        case "w":
          return n * w;
        case "days":
        case "day":
        case "d":
          return n * d;
        case "hours":
        case "hour":
        case "hrs":
        case "hr":
        case "h":
          return n * h;
        case "minutes":
        case "minute":
        case "mins":
        case "min":
        case "m":
          return n * m;
        case "seconds":
        case "second":
        case "secs":
        case "sec":
        case "s":
          return n * s;
        case "milliseconds":
        case "millisecond":
        case "msecs":
        case "msec":
        case "ms":
          return n;
        default:
          return;
      }
    }
    function fmtShort(ms) {
      var msAbs = Math.abs(ms);
      if (msAbs >= d) {
        return Math.round(ms / d) + "d";
      }
      if (msAbs >= h) {
        return Math.round(ms / h) + "h";
      }
      if (msAbs >= m) {
        return Math.round(ms / m) + "m";
      }
      if (msAbs >= s) {
        return Math.round(ms / s) + "s";
      }
      return ms + "ms";
    }
    function fmtLong(ms) {
      var msAbs = Math.abs(ms);
      if (msAbs >= d) {
        return plural(ms, msAbs, d, "day");
      }
      if (msAbs >= h) {
        return plural(ms, msAbs, h, "hour");
      }
      if (msAbs >= m) {
        return plural(ms, msAbs, m, "minute");
      }
      if (msAbs >= s) {
        return plural(ms, msAbs, s, "second");
      }
      return ms + " ms";
    }
    function plural(ms, msAbs, n, name) {
      var isPlural = msAbs >= n * 1.5;
      return Math.round(ms / n) + " " + name + (isPlural ? "s" : "");
    }
  });

  // node_modules/debug/src/common.js
  var require_common = __commonJS((exports, module) => {
    function setup(env) {
      createDebug.debug = createDebug;
      createDebug.default = createDebug;
      createDebug.coerce = coerce;
      createDebug.disable = disable2;
      createDebug.enable = enable;
      createDebug.enabled = enabled;
      createDebug.humanize = require_ms();
      createDebug.destroy = destroy;
      Object.keys(env).forEach((key) => {
        createDebug[key] = env[key];
      });
      createDebug.names = [];
      createDebug.skips = [];
      createDebug.formatters = {};
      function selectColor(namespace) {
        let hash = 0;
        for (let i = 0;i < namespace.length; i++) {
          hash = (hash << 5) - hash + namespace.charCodeAt(i);
          hash |= 0;
        }
        return createDebug.colors[Math.abs(hash) % createDebug.colors.length];
      }
      createDebug.selectColor = selectColor;
      function createDebug(namespace) {
        let prevTime;
        let enableOverride = null;
        let namespacesCache;
        let enabledCache;
        function debug(...args) {
          if (!debug.enabled) {
            return;
          }
          const self = debug;
          const curr = Number(new Date);
          const ms = curr - (prevTime || curr);
          self.diff = ms;
          self.prev = prevTime;
          self.curr = curr;
          prevTime = curr;
          args[0] = createDebug.coerce(args[0]);
          if (typeof args[0] !== "string") {
            args.unshift("%O");
          }
          let index = 0;
          args[0] = args[0].replace(/%([a-zA-Z%])/g, (match, format) => {
            if (match === "%%") {
              return "%";
            }
            index++;
            const formatter = createDebug.formatters[format];
            if (typeof formatter === "function") {
              const val = args[index];
              match = formatter.call(self, val);
              args.splice(index, 1);
              index--;
            }
            return match;
          });
          createDebug.formatArgs.call(self, args);
          const logFn = self.log || createDebug.log;
          logFn.apply(self, args);
        }
        debug.namespace = namespace;
        debug.useColors = createDebug.useColors();
        debug.color = createDebug.selectColor(namespace);
        debug.extend = extend;
        debug.destroy = createDebug.destroy;
        Object.defineProperty(debug, "enabled", {
          enumerable: true,
          configurable: false,
          get: () => {
            if (enableOverride !== null) {
              return enableOverride;
            }
            if (namespacesCache !== createDebug.namespaces) {
              namespacesCache = createDebug.namespaces;
              enabledCache = createDebug.enabled(namespace);
            }
            return enabledCache;
          },
          set: (v) => {
            enableOverride = v;
          }
        });
        if (typeof createDebug.init === "function") {
          createDebug.init(debug);
        }
        return debug;
      }
      function extend(namespace, delimiter) {
        const newDebug = createDebug(this.namespace + (typeof delimiter === "undefined" ? ":" : delimiter) + namespace);
        newDebug.log = this.log;
        return newDebug;
      }
      function enable(namespaces) {
        createDebug.save(namespaces);
        createDebug.namespaces = namespaces;
        createDebug.names = [];
        createDebug.skips = [];
        const split = (typeof namespaces === "string" ? namespaces : "").trim().replace(/\s+/g, ",").split(",").filter(Boolean);
        for (const ns of split) {
          if (ns[0] === "-") {
            createDebug.skips.push(ns.slice(1));
          } else {
            createDebug.names.push(ns);
          }
        }
      }
      function matchesTemplate(search, template) {
        let searchIndex = 0;
        let templateIndex = 0;
        let starIndex = -1;
        let matchIndex = 0;
        while (searchIndex < search.length) {
          if (templateIndex < template.length && (template[templateIndex] === search[searchIndex] || template[templateIndex] === "*")) {
            if (template[templateIndex] === "*") {
              starIndex = templateIndex;
              matchIndex = searchIndex;
              templateIndex++;
            } else {
              searchIndex++;
              templateIndex++;
            }
          } else if (starIndex !== -1) {
            templateIndex = starIndex + 1;
            matchIndex++;
            searchIndex = matchIndex;
          } else {
            return false;
          }
        }
        while (templateIndex < template.length && template[templateIndex] === "*") {
          templateIndex++;
        }
        return templateIndex === template.length;
      }
      function disable2() {
        const namespaces = [
          ...createDebug.names,
          ...createDebug.skips.map((namespace) => "-" + namespace)
        ].join(",");
        createDebug.enable("");
        return namespaces;
      }
      function enabled(name) {
        for (const skip of createDebug.skips) {
          if (matchesTemplate(name, skip)) {
            return false;
          }
        }
        for (const ns of createDebug.names) {
          if (matchesTemplate(name, ns)) {
            return true;
          }
        }
        return false;
      }
      function coerce(val) {
        if (val instanceof Error) {
          return val.stack || val.message;
        }
        return val;
      }
      function destroy() {
        console.warn("Instance method `debug.destroy()` is deprecated and no longer does anything. It will be removed in the next major version of `debug`.");
      }
      createDebug.enable(createDebug.load());
      return createDebug;
    }
    module.exports = setup;
  });

  // node_modules/debug/src/browser.js
  var require_browser = __commonJS((exports, module) => {
    exports.formatArgs = formatArgs;
    exports.save = save;
    exports.load = load;
    exports.useColors = useColors;
    exports.storage = localstorage();
    exports.destroy = (() => {
      let warned = false;
      return () => {
        if (!warned) {
          warned = true;
          console.warn("Instance method `debug.destroy()` is deprecated and no longer does anything. It will be removed in the next major version of `debug`.");
        }
      };
    })();
    exports.colors = [
      "#0000CC",
      "#0000FF",
      "#0033CC",
      "#0033FF",
      "#0066CC",
      "#0066FF",
      "#0099CC",
      "#0099FF",
      "#00CC00",
      "#00CC33",
      "#00CC66",
      "#00CC99",
      "#00CCCC",
      "#00CCFF",
      "#3300CC",
      "#3300FF",
      "#3333CC",
      "#3333FF",
      "#3366CC",
      "#3366FF",
      "#3399CC",
      "#3399FF",
      "#33CC00",
      "#33CC33",
      "#33CC66",
      "#33CC99",
      "#33CCCC",
      "#33CCFF",
      "#6600CC",
      "#6600FF",
      "#6633CC",
      "#6633FF",
      "#66CC00",
      "#66CC33",
      "#9900CC",
      "#9900FF",
      "#9933CC",
      "#9933FF",
      "#99CC00",
      "#99CC33",
      "#CC0000",
      "#CC0033",
      "#CC0066",
      "#CC0099",
      "#CC00CC",
      "#CC00FF",
      "#CC3300",
      "#CC3333",
      "#CC3366",
      "#CC3399",
      "#CC33CC",
      "#CC33FF",
      "#CC6600",
      "#CC6633",
      "#CC9900",
      "#CC9933",
      "#CCCC00",
      "#CCCC33",
      "#FF0000",
      "#FF0033",
      "#FF0066",
      "#FF0099",
      "#FF00CC",
      "#FF00FF",
      "#FF3300",
      "#FF3333",
      "#FF3366",
      "#FF3399",
      "#FF33CC",
      "#FF33FF",
      "#FF6600",
      "#FF6633",
      "#FF9900",
      "#FF9933",
      "#FFCC00",
      "#FFCC33"
    ];
    function useColors() {
      if (typeof window !== "undefined" && window.process && (window.process.type === "renderer" || window.process.__nwjs)) {
        return true;
      }
      if (typeof navigator !== "undefined" && navigator.userAgent && navigator.userAgent.toLowerCase().match(/(edge|trident)\/(\d+)/)) {
        return false;
      }
      let m;
      return typeof document !== "undefined" && document.documentElement && document.documentElement.style && document.documentElement.style.WebkitAppearance || typeof window !== "undefined" && window.console && (window.console.firebug || window.console.exception && window.console.table) || typeof navigator !== "undefined" && navigator.userAgent && (m = navigator.userAgent.toLowerCase().match(/firefox\/(\d+)/)) && parseInt(m[1], 10) >= 31 || typeof navigator !== "undefined" && navigator.userAgent && navigator.userAgent.toLowerCase().match(/applewebkit\/(\d+)/);
    }
    function formatArgs(args) {
      args[0] = (this.useColors ? "%c" : "") + this.namespace + (this.useColors ? " %c" : " ") + args[0] + (this.useColors ? "%c " : " ") + "+" + module.exports.humanize(this.diff);
      if (!this.useColors) {
        return;
      }
      const c = "color: " + this.color;
      args.splice(1, 0, c, "color: inherit");
      let index = 0;
      let lastC = 0;
      args[0].replace(/%[a-zA-Z%]/g, (match) => {
        if (match === "%%") {
          return;
        }
        index++;
        if (match === "%c") {
          lastC = index;
        }
      });
      args.splice(lastC, 0, c);
    }
    exports.log = console.debug || console.log || (() => {});
    function save(namespaces) {
      try {
        if (namespaces) {
          exports.storage.setItem("debug", namespaces);
        } else {
          exports.storage.removeItem("debug");
        }
      } catch (error) {}
    }
    function load() {
      let r;
      try {
        r = exports.storage.getItem("debug") || exports.storage.getItem("DEBUG");
      } catch (error) {}
      if (!r && typeof process !== "undefined" && "env" in process) {
        r = process.env.DEBUG;
      }
      return r;
    }
    function localstorage() {
      try {
        return localStorage;
      } catch (error) {}
    }
    module.exports = require_common()(exports);
    var { formatters } = module.exports;
    formatters.j = function(v) {
      try {
        return JSON.stringify(v);
      } catch (error) {
        return "[UnexpectedJSONParseError]: " + error.message;
      }
    };
  });

  // node_modules/extend/index.js
  var require_extend = __commonJS((exports, module) => {
    var hasOwn = Object.prototype.hasOwnProperty;
    var toStr = Object.prototype.toString;
    var defineProperty = Object.defineProperty;
    var gOPD = Object.getOwnPropertyDescriptor;
    var isArray = function isArray2(arr) {
      if (typeof Array.isArray === "function") {
        return Array.isArray(arr);
      }
      return toStr.call(arr) === "[object Array]";
    };
    var isPlainObject = function isPlainObject2(obj) {
      if (!obj || toStr.call(obj) !== "[object Object]") {
        return false;
      }
      var hasOwnConstructor = hasOwn.call(obj, "constructor");
      var hasIsPrototypeOf = obj.constructor && obj.constructor.prototype && hasOwn.call(obj.constructor.prototype, "isPrototypeOf");
      if (obj.constructor && !hasOwnConstructor && !hasIsPrototypeOf) {
        return false;
      }
      var key;
      for (key in obj) {}
      return typeof key === "undefined" || hasOwn.call(obj, key);
    };
    var setProperty = function setProperty2(target, options) {
      if (defineProperty && options.name === "__proto__") {
        defineProperty(target, options.name, {
          enumerable: true,
          configurable: true,
          value: options.newValue,
          writable: true
        });
      } else {
        target[options.name] = options.newValue;
      }
    };
    var getProperty = function getProperty2(obj, name) {
      if (name === "__proto__") {
        if (!hasOwn.call(obj, name)) {
          return;
        } else if (gOPD) {
          return gOPD(obj, name).value;
        }
      }
      return obj[name];
    };
    module.exports = function extend() {
      var options, name, src, copy, copyIsArray, clone;
      var target = arguments[0];
      var i = 1;
      var length = arguments.length;
      var deep = false;
      if (typeof target === "boolean") {
        deep = target;
        target = arguments[1] || {};
        i = 2;
      }
      if (target == null || typeof target !== "object" && typeof target !== "function") {
        target = {};
      }
      for (;i < length; ++i) {
        options = arguments[i];
        if (options != null) {
          for (name in options) {
            src = getProperty(target, name);
            copy = getProperty(options, name);
            if (target !== copy) {
              if (deep && copy && (isPlainObject(copy) || (copyIsArray = isArray(copy)))) {
                if (copyIsArray) {
                  copyIsArray = false;
                  clone = src && isArray(src) ? src : [];
                } else {
                  clone = src && isPlainObject(src) ? src : {};
                }
                setProperty(target, { name, newValue: extend(deep, clone, copy) });
              } else if (typeof copy !== "undefined") {
                setProperty(target, { name, newValue: copy });
              }
            }
          }
        }
      }
      return target;
    };
  });

  // node_modules/ccount/index.js
  function ccount(value, character) {
    const source = String(value);
    if (typeof character !== "string") {
      throw new TypeError("Expected character");
    }
    let count = 0;
    let index = source.indexOf(character);
    while (index !== -1) {
      count++;
      index = source.indexOf(character, index + character.length);
    }
    return count;
  }

  // node_modules/devlop/lib/development.js
  var codesWarned = new Set;

  class AssertionError extends Error {
    name = "Assertion";
    code = "ERR_ASSERTION";
    constructor(message, actual, expected, operator, generated) {
      super(message);
      if (Error.captureStackTrace) {
        Error.captureStackTrace(this, this.constructor);
      }
      this.actual = actual;
      this.expected = expected;
      this.generated = generated;
      this.operator = operator;
    }
  }
  function ok(value, message) {
    assert(Boolean(value), false, true, "ok", "Expected value to be truthy", message);
  }
  function assert(bool, actual, expected, operator, defaultMessage, userMessage) {
    if (!bool) {
      throw userMessage instanceof Error ? userMessage : new AssertionError(userMessage || defaultMessage, actual, expected, operator, !userMessage);
    }
  }

  // node_modules/micromark-util-symbol/lib/codes.js
  var codes = {
    carriageReturn: -5,
    lineFeed: -4,
    carriageReturnLineFeed: -3,
    horizontalTab: -2,
    virtualSpace: -1,
    eof: null,
    nul: 0,
    soh: 1,
    stx: 2,
    etx: 3,
    eot: 4,
    enq: 5,
    ack: 6,
    bel: 7,
    bs: 8,
    ht: 9,
    lf: 10,
    vt: 11,
    ff: 12,
    cr: 13,
    so: 14,
    si: 15,
    dle: 16,
    dc1: 17,
    dc2: 18,
    dc3: 19,
    dc4: 20,
    nak: 21,
    syn: 22,
    etb: 23,
    can: 24,
    em: 25,
    sub: 26,
    esc: 27,
    fs: 28,
    gs: 29,
    rs: 30,
    us: 31,
    space: 32,
    exclamationMark: 33,
    quotationMark: 34,
    numberSign: 35,
    dollarSign: 36,
    percentSign: 37,
    ampersand: 38,
    apostrophe: 39,
    leftParenthesis: 40,
    rightParenthesis: 41,
    asterisk: 42,
    plusSign: 43,
    comma: 44,
    dash: 45,
    dot: 46,
    slash: 47,
    digit0: 48,
    digit1: 49,
    digit2: 50,
    digit3: 51,
    digit4: 52,
    digit5: 53,
    digit6: 54,
    digit7: 55,
    digit8: 56,
    digit9: 57,
    colon: 58,
    semicolon: 59,
    lessThan: 60,
    equalsTo: 61,
    greaterThan: 62,
    questionMark: 63,
    atSign: 64,
    uppercaseA: 65,
    uppercaseB: 66,
    uppercaseC: 67,
    uppercaseD: 68,
    uppercaseE: 69,
    uppercaseF: 70,
    uppercaseG: 71,
    uppercaseH: 72,
    uppercaseI: 73,
    uppercaseJ: 74,
    uppercaseK: 75,
    uppercaseL: 76,
    uppercaseM: 77,
    uppercaseN: 78,
    uppercaseO: 79,
    uppercaseP: 80,
    uppercaseQ: 81,
    uppercaseR: 82,
    uppercaseS: 83,
    uppercaseT: 84,
    uppercaseU: 85,
    uppercaseV: 86,
    uppercaseW: 87,
    uppercaseX: 88,
    uppercaseY: 89,
    uppercaseZ: 90,
    leftSquareBracket: 91,
    backslash: 92,
    rightSquareBracket: 93,
    caret: 94,
    underscore: 95,
    graveAccent: 96,
    lowercaseA: 97,
    lowercaseB: 98,
    lowercaseC: 99,
    lowercaseD: 100,
    lowercaseE: 101,
    lowercaseF: 102,
    lowercaseG: 103,
    lowercaseH: 104,
    lowercaseI: 105,
    lowercaseJ: 106,
    lowercaseK: 107,
    lowercaseL: 108,
    lowercaseM: 109,
    lowercaseN: 110,
    lowercaseO: 111,
    lowercaseP: 112,
    lowercaseQ: 113,
    lowercaseR: 114,
    lowercaseS: 115,
    lowercaseT: 116,
    lowercaseU: 117,
    lowercaseV: 118,
    lowercaseW: 119,
    lowercaseX: 120,
    lowercaseY: 121,
    lowercaseZ: 122,
    leftCurlyBrace: 123,
    verticalBar: 124,
    rightCurlyBrace: 125,
    tilde: 126,
    del: 127,
    byteOrderMarker: 65279,
    replacementCharacter: 65533
  };
  // node_modules/micromark-util-symbol/lib/constants.js
  var constants = {
    attentionSideAfter: 2,
    attentionSideBefore: 1,
    atxHeadingOpeningFenceSizeMax: 6,
    autolinkDomainSizeMax: 63,
    autolinkSchemeSizeMax: 32,
    cdataOpeningString: "CDATA[",
    characterGroupPunctuation: 2,
    characterGroupWhitespace: 1,
    characterReferenceDecimalSizeMax: 7,
    characterReferenceHexadecimalSizeMax: 6,
    characterReferenceNamedSizeMax: 31,
    codeFencedSequenceSizeMin: 3,
    contentTypeContent: "content",
    contentTypeDocument: "document",
    contentTypeFlow: "flow",
    contentTypeString: "string",
    contentTypeText: "text",
    hardBreakPrefixSizeMin: 2,
    htmlBasic: 6,
    htmlCdata: 5,
    htmlComment: 2,
    htmlComplete: 7,
    htmlDeclaration: 4,
    htmlInstruction: 3,
    htmlRawSizeMax: 8,
    htmlRaw: 1,
    linkResourceDestinationBalanceMax: 32,
    linkReferenceSizeMax: 999,
    listItemValueSizeMax: 10,
    numericBaseDecimal: 10,
    numericBaseHexadecimal: 16,
    tabSize: 4,
    thematicBreakMarkerCountMin: 3,
    v8MaxSafeChunkSize: 1e4
  };
  // node_modules/micromark-util-symbol/lib/types.js
  var types = {
    data: "data",
    whitespace: "whitespace",
    lineEnding: "lineEnding",
    lineEndingBlank: "lineEndingBlank",
    linePrefix: "linePrefix",
    lineSuffix: "lineSuffix",
    atxHeading: "atxHeading",
    atxHeadingSequence: "atxHeadingSequence",
    atxHeadingText: "atxHeadingText",
    autolink: "autolink",
    autolinkEmail: "autolinkEmail",
    autolinkMarker: "autolinkMarker",
    autolinkProtocol: "autolinkProtocol",
    characterEscape: "characterEscape",
    characterEscapeValue: "characterEscapeValue",
    characterReference: "characterReference",
    characterReferenceMarker: "characterReferenceMarker",
    characterReferenceMarkerNumeric: "characterReferenceMarkerNumeric",
    characterReferenceMarkerHexadecimal: "characterReferenceMarkerHexadecimal",
    characterReferenceValue: "characterReferenceValue",
    codeFenced: "codeFenced",
    codeFencedFence: "codeFencedFence",
    codeFencedFenceSequence: "codeFencedFenceSequence",
    codeFencedFenceInfo: "codeFencedFenceInfo",
    codeFencedFenceMeta: "codeFencedFenceMeta",
    codeFlowValue: "codeFlowValue",
    codeIndented: "codeIndented",
    codeText: "codeText",
    codeTextData: "codeTextData",
    codeTextPadding: "codeTextPadding",
    codeTextSequence: "codeTextSequence",
    content: "content",
    definition: "definition",
    definitionDestination: "definitionDestination",
    definitionDestinationLiteral: "definitionDestinationLiteral",
    definitionDestinationLiteralMarker: "definitionDestinationLiteralMarker",
    definitionDestinationRaw: "definitionDestinationRaw",
    definitionDestinationString: "definitionDestinationString",
    definitionLabel: "definitionLabel",
    definitionLabelMarker: "definitionLabelMarker",
    definitionLabelString: "definitionLabelString",
    definitionMarker: "definitionMarker",
    definitionTitle: "definitionTitle",
    definitionTitleMarker: "definitionTitleMarker",
    definitionTitleString: "definitionTitleString",
    emphasis: "emphasis",
    emphasisSequence: "emphasisSequence",
    emphasisText: "emphasisText",
    escapeMarker: "escapeMarker",
    hardBreakEscape: "hardBreakEscape",
    hardBreakTrailing: "hardBreakTrailing",
    htmlFlow: "htmlFlow",
    htmlFlowData: "htmlFlowData",
    htmlText: "htmlText",
    htmlTextData: "htmlTextData",
    image: "image",
    label: "label",
    labelText: "labelText",
    labelLink: "labelLink",
    labelImage: "labelImage",
    labelMarker: "labelMarker",
    labelImageMarker: "labelImageMarker",
    labelEnd: "labelEnd",
    link: "link",
    paragraph: "paragraph",
    reference: "reference",
    referenceMarker: "referenceMarker",
    referenceString: "referenceString",
    resource: "resource",
    resourceDestination: "resourceDestination",
    resourceDestinationLiteral: "resourceDestinationLiteral",
    resourceDestinationLiteralMarker: "resourceDestinationLiteralMarker",
    resourceDestinationRaw: "resourceDestinationRaw",
    resourceDestinationString: "resourceDestinationString",
    resourceMarker: "resourceMarker",
    resourceTitle: "resourceTitle",
    resourceTitleMarker: "resourceTitleMarker",
    resourceTitleString: "resourceTitleString",
    setextHeading: "setextHeading",
    setextHeadingText: "setextHeadingText",
    setextHeadingLine: "setextHeadingLine",
    setextHeadingLineSequence: "setextHeadingLineSequence",
    strong: "strong",
    strongSequence: "strongSequence",
    strongText: "strongText",
    thematicBreak: "thematicBreak",
    thematicBreakSequence: "thematicBreakSequence",
    blockQuote: "blockQuote",
    blockQuotePrefix: "blockQuotePrefix",
    blockQuoteMarker: "blockQuoteMarker",
    blockQuotePrefixWhitespace: "blockQuotePrefixWhitespace",
    listOrdered: "listOrdered",
    listUnordered: "listUnordered",
    listItemIndent: "listItemIndent",
    listItemMarker: "listItemMarker",
    listItemPrefix: "listItemPrefix",
    listItemPrefixWhitespace: "listItemPrefixWhitespace",
    listItemValue: "listItemValue",
    chunkDocument: "chunkDocument",
    chunkContent: "chunkContent",
    chunkFlow: "chunkFlow",
    chunkText: "chunkText",
    chunkString: "chunkString"
  };
  // node_modules/micromark-util-symbol/lib/values.js
  var values = {
    ht: "\t",
    lf: `
`,
    cr: "\r",
    space: " ",
    exclamationMark: "!",
    quotationMark: '"',
    numberSign: "#",
    dollarSign: "$",
    percentSign: "%",
    ampersand: "&",
    apostrophe: "'",
    leftParenthesis: "(",
    rightParenthesis: ")",
    asterisk: "*",
    plusSign: "+",
    comma: ",",
    dash: "-",
    dot: ".",
    slash: "/",
    digit0: "0",
    digit1: "1",
    digit2: "2",
    digit3: "3",
    digit4: "4",
    digit5: "5",
    digit6: "6",
    digit7: "7",
    digit8: "8",
    digit9: "9",
    colon: ":",
    semicolon: ";",
    lessThan: "<",
    equalsTo: "=",
    greaterThan: ">",
    questionMark: "?",
    atSign: "@",
    uppercaseA: "A",
    uppercaseB: "B",
    uppercaseC: "C",
    uppercaseD: "D",
    uppercaseE: "E",
    uppercaseF: "F",
    uppercaseG: "G",
    uppercaseH: "H",
    uppercaseI: "I",
    uppercaseJ: "J",
    uppercaseK: "K",
    uppercaseL: "L",
    uppercaseM: "M",
    uppercaseN: "N",
    uppercaseO: "O",
    uppercaseP: "P",
    uppercaseQ: "Q",
    uppercaseR: "R",
    uppercaseS: "S",
    uppercaseT: "T",
    uppercaseU: "U",
    uppercaseV: "V",
    uppercaseW: "W",
    uppercaseX: "X",
    uppercaseY: "Y",
    uppercaseZ: "Z",
    leftSquareBracket: "[",
    backslash: "\\",
    rightSquareBracket: "]",
    caret: "^",
    underscore: "_",
    graveAccent: "`",
    lowercaseA: "a",
    lowercaseB: "b",
    lowercaseC: "c",
    lowercaseD: "d",
    lowercaseE: "e",
    lowercaseF: "f",
    lowercaseG: "g",
    lowercaseH: "h",
    lowercaseI: "i",
    lowercaseJ: "j",
    lowercaseK: "k",
    lowercaseL: "l",
    lowercaseM: "m",
    lowercaseN: "n",
    lowercaseO: "o",
    lowercaseP: "p",
    lowercaseQ: "q",
    lowercaseR: "r",
    lowercaseS: "s",
    lowercaseT: "t",
    lowercaseU: "u",
    lowercaseV: "v",
    lowercaseW: "w",
    lowercaseX: "x",
    lowercaseY: "y",
    lowercaseZ: "z",
    leftCurlyBrace: "{",
    verticalBar: "|",
    rightCurlyBrace: "}",
    tilde: "~",
    replacementCharacter: "�"
  };
  // node_modules/micromark-util-character/dev/index.js
  var asciiAlpha = regexCheck(/[A-Za-z]/);
  var asciiAlphanumeric = regexCheck(/[\dA-Za-z]/);
  var asciiAtext = regexCheck(/[#-'*+\--9=?A-Z^-~]/);
  function asciiControl(code) {
    return code !== null && (code < codes.space || code === codes.del);
  }
  var asciiDigit = regexCheck(/\d/);
  var asciiHexDigit = regexCheck(/[\dA-Fa-f]/);
  var asciiPunctuation = regexCheck(/[!-/:-@[-`{-~]/);
  function markdownLineEnding(code) {
    return code !== null && code < codes.horizontalTab;
  }
  function markdownLineEndingOrSpace(code) {
    return code !== null && (code < codes.nul || code === codes.space);
  }
  function markdownSpace(code) {
    return code === codes.horizontalTab || code === codes.virtualSpace || code === codes.space;
  }
  var unicodePunctuation = regexCheck(/\p{P}|\p{S}/u);
  var unicodeWhitespace = regexCheck(/\s/);
  function regexCheck(regex) {
    return check;
    function check(code) {
      return code !== null && code > -1 && regex.test(String.fromCharCode(code));
    }
  }

  // node_modules/escape-string-regexp/index.js
  function escapeStringRegexp(string) {
    if (typeof string !== "string") {
      throw new TypeError("Expected a string");
    }
    return string.replace(/[|\\{}()[\]^$+*?.]/g, "\\$&").replace(/-/g, "\\x2d");
  }

  // node_modules/unist-util-is/lib/index.js
  var convert = function(test) {
    if (test === null || test === undefined) {
      return ok2;
    }
    if (typeof test === "function") {
      return castFactory(test);
    }
    if (typeof test === "object") {
      return Array.isArray(test) ? anyFactory(test) : propertiesFactory(test);
    }
    if (typeof test === "string") {
      return typeFactory(test);
    }
    throw new Error("Expected function, string, or object as test");
  };
  function anyFactory(tests) {
    const checks = [];
    let index = -1;
    while (++index < tests.length) {
      checks[index] = convert(tests[index]);
    }
    return castFactory(any);
    function any(...parameters) {
      let index2 = -1;
      while (++index2 < checks.length) {
        if (checks[index2].apply(this, parameters))
          return true;
      }
      return false;
    }
  }
  function propertiesFactory(check) {
    const checkAsRecord = check;
    return castFactory(all);
    function all(node) {
      const nodeAsRecord = node;
      let key;
      for (key in check) {
        if (nodeAsRecord[key] !== checkAsRecord[key])
          return false;
      }
      return true;
    }
  }
  function typeFactory(check) {
    return castFactory(type);
    function type(node) {
      return node && node.type === check;
    }
  }
  function castFactory(testFunction) {
    return check;
    function check(value, index, parent) {
      return Boolean(looksLikeANode(value) && testFunction.call(this, value, typeof index === "number" ? index : undefined, parent || undefined));
    }
  }
  function ok2() {
    return true;
  }
  function looksLikeANode(value) {
    return value !== null && typeof value === "object" && "type" in value;
  }
  // node_modules/unist-util-visit-parents/lib/color.js
  function color(d) {
    return d;
  }

  // node_modules/unist-util-visit-parents/lib/index.js
  var empty = [];
  var CONTINUE = true;
  var EXIT = false;
  var SKIP = "skip";
  function visitParents(tree, test, visitor, reverse) {
    let check;
    if (typeof test === "function" && typeof visitor !== "function") {
      reverse = visitor;
      visitor = test;
    } else {
      check = test;
    }
    const is2 = convert(check);
    const step = reverse ? -1 : 1;
    factory(tree, undefined, [])();
    function factory(node, index, parents) {
      const value = node && typeof node === "object" ? node : {};
      if (typeof value.type === "string") {
        const name = typeof value.tagName === "string" ? value.tagName : typeof value.name === "string" ? value.name : undefined;
        Object.defineProperty(visit, "name", {
          value: "node (" + color(node.type + (name ? "<" + name + ">" : "")) + ")"
        });
      }
      return visit;
      function visit() {
        let result = empty;
        let subresult;
        let offset;
        let grandparents;
        if (!test || is2(node, index, parents[parents.length - 1] || undefined)) {
          result = toResult(visitor(node, parents));
          if (result[0] === EXIT) {
            return result;
          }
        }
        if ("children" in node && node.children) {
          const nodeAsParent = node;
          if (nodeAsParent.children && result[0] !== SKIP) {
            offset = (reverse ? nodeAsParent.children.length : -1) + step;
            grandparents = parents.concat(nodeAsParent);
            while (offset > -1 && offset < nodeAsParent.children.length) {
              const child = nodeAsParent.children[offset];
              subresult = factory(child, offset, grandparents)();
              if (subresult[0] === EXIT) {
                return subresult;
              }
              offset = typeof subresult[1] === "number" ? subresult[1] : offset + step;
            }
          }
        }
        return result;
      }
    }
  }
  function toResult(value) {
    if (Array.isArray(value)) {
      return value;
    }
    if (typeof value === "number") {
      return [CONTINUE, value];
    }
    return value === null || value === undefined ? empty : [value];
  }
  // node_modules/mdast-util-find-and-replace/lib/index.js
  function findAndReplace(tree, list, options) {
    const settings = options || {};
    const ignored = convert(settings.ignore || []);
    const pairs = toPairs(list);
    let pairIndex = -1;
    while (++pairIndex < pairs.length) {
      visitParents(tree, "text", visitor);
    }
    function visitor(node, parents) {
      let index = -1;
      let grandparent;
      while (++index < parents.length) {
        const parent = parents[index];
        const siblings = grandparent ? grandparent.children : undefined;
        if (ignored(parent, siblings ? siblings.indexOf(parent) : undefined, grandparent)) {
          return;
        }
        grandparent = parent;
      }
      if (grandparent) {
        return handler(node, parents);
      }
    }
    function handler(node, parents) {
      const parent = parents[parents.length - 1];
      const find = pairs[pairIndex][0];
      const replace = pairs[pairIndex][1];
      let start = 0;
      const siblings = parent.children;
      const index = siblings.indexOf(node);
      let change = false;
      let nodes = [];
      find.lastIndex = 0;
      let match = find.exec(node.value);
      while (match) {
        const position = match.index;
        const matchObject = {
          index: match.index,
          input: match.input,
          stack: [...parents, node]
        };
        let value = replace(...match, matchObject);
        if (typeof value === "string") {
          value = value.length > 0 ? { type: "text", value } : undefined;
        }
        if (value === false) {
          find.lastIndex = position + 1;
        } else {
          if (start !== position) {
            nodes.push({
              type: "text",
              value: node.value.slice(start, position)
            });
          }
          if (Array.isArray(value)) {
            nodes.push(...value);
          } else if (value) {
            nodes.push(value);
          }
          start = position + match[0].length;
          change = true;
        }
        if (!find.global) {
          break;
        }
        match = find.exec(node.value);
      }
      if (change) {
        if (start < node.value.length) {
          nodes.push({ type: "text", value: node.value.slice(start) });
        }
        parent.children.splice(index, 1, ...nodes);
      } else {
        nodes = [node];
      }
      return index + nodes.length;
    }
  }
  function toPairs(tupleOrList) {
    const result = [];
    if (!Array.isArray(tupleOrList)) {
      throw new TypeError("Expected find and replace tuple or list of tuples");
    }
    const list = !tupleOrList[0] || Array.isArray(tupleOrList[0]) ? tupleOrList : [tupleOrList];
    let index = -1;
    while (++index < list.length) {
      const tuple = list[index];
      result.push([toExpression(tuple[0]), toFunction(tuple[1])]);
    }
    return result;
  }
  function toExpression(find) {
    return typeof find === "string" ? new RegExp(escapeStringRegexp(find), "g") : find;
  }
  function toFunction(replace) {
    return typeof replace === "function" ? replace : function() {
      return replace;
    };
  }
  // node_modules/mdast-util-gfm-autolink-literal/lib/index.js
  var inConstruct = "phrasing";
  var notInConstruct = ["autolink", "link", "image", "label"];
  function gfmAutolinkLiteralFromMarkdown() {
    return {
      transforms: [transformGfmAutolinkLiterals],
      enter: {
        literalAutolink: enterLiteralAutolink,
        literalAutolinkEmail: enterLiteralAutolinkValue,
        literalAutolinkHttp: enterLiteralAutolinkValue,
        literalAutolinkWww: enterLiteralAutolinkValue
      },
      exit: {
        literalAutolink: exitLiteralAutolink,
        literalAutolinkEmail: exitLiteralAutolinkEmail,
        literalAutolinkHttp: exitLiteralAutolinkHttp,
        literalAutolinkWww: exitLiteralAutolinkWww
      }
    };
  }
  function gfmAutolinkLiteralToMarkdown() {
    return {
      unsafe: [
        {
          character: "@",
          before: "[+\\-.\\w]",
          after: "[\\-.\\w]",
          inConstruct,
          notInConstruct
        },
        {
          character: ".",
          before: "[Ww]",
          after: "[\\-.\\w]",
          inConstruct,
          notInConstruct
        },
        {
          character: ":",
          before: "[ps]",
          after: "\\/",
          inConstruct,
          notInConstruct
        }
      ]
    };
  }
  function enterLiteralAutolink(token) {
    this.enter({ type: "link", title: null, url: "", children: [] }, token);
  }
  function enterLiteralAutolinkValue(token) {
    this.config.enter.autolinkProtocol.call(this, token);
  }
  function exitLiteralAutolinkHttp(token) {
    this.config.exit.autolinkProtocol.call(this, token);
  }
  function exitLiteralAutolinkWww(token) {
    this.config.exit.data.call(this, token);
    const node = this.stack[this.stack.length - 1];
    ok(node.type === "link");
    node.url = "http://" + this.sliceSerialize(token);
  }
  function exitLiteralAutolinkEmail(token) {
    this.config.exit.autolinkEmail.call(this, token);
  }
  function exitLiteralAutolink(token) {
    this.exit(token);
  }
  function transformGfmAutolinkLiterals(tree) {
    findAndReplace(tree, [
      [/(https?:\/\/|www(?=\.))([-.\w]+)([^ \t\r\n]*)/gi, findUrl],
      [/(?<=^|\s|\p{P}|\p{S})([-.\w+]+)@([-\w]+(?:\.[-\w]+)+)/gu, findEmail]
    ], { ignore: ["link", "linkReference"] });
  }
  function findUrl(_, protocol, domain, path, match) {
    let prefix = "";
    if (!previous(match)) {
      return false;
    }
    if (/^w/i.test(protocol)) {
      domain = protocol + domain;
      protocol = "";
      prefix = "http://";
    }
    if (!isCorrectDomain(domain)) {
      return false;
    }
    const parts = splitUrl(domain + path);
    if (!parts[0])
      return false;
    const result = {
      type: "link",
      title: null,
      url: prefix + protocol + parts[0],
      children: [{ type: "text", value: protocol + parts[0] }]
    };
    if (parts[1]) {
      return [result, { type: "text", value: parts[1] }];
    }
    return result;
  }
  function findEmail(_, atext, label, match) {
    if (!previous(match, true) || /[-\d_]$/.test(label)) {
      return false;
    }
    return {
      type: "link",
      title: null,
      url: "mailto:" + atext + "@" + label,
      children: [{ type: "text", value: atext + "@" + label }]
    };
  }
  function isCorrectDomain(domain) {
    const parts = domain.split(".");
    if (parts.length < 2 || parts[parts.length - 1] && (/_/.test(parts[parts.length - 1]) || !/[a-zA-Z\d]/.test(parts[parts.length - 1])) || parts[parts.length - 2] && (/_/.test(parts[parts.length - 2]) || !/[a-zA-Z\d]/.test(parts[parts.length - 2]))) {
      return false;
    }
    return true;
  }
  function splitUrl(url) {
    const trailExec = /[!"&'),.:;<>?\]}]+$/.exec(url);
    if (!trailExec) {
      return [url, undefined];
    }
    url = url.slice(0, trailExec.index);
    let trail = trailExec[0];
    let closingParenIndex = trail.indexOf(")");
    const openingParens = ccount(url, "(");
    let closingParens = ccount(url, ")");
    while (closingParenIndex !== -1 && openingParens > closingParens) {
      url += trail.slice(0, closingParenIndex + 1);
      trail = trail.slice(closingParenIndex + 1);
      closingParenIndex = trail.indexOf(")");
      closingParens++;
    }
    return [url, trail];
  }
  function previous(match, email) {
    const code = match.input.charCodeAt(match.index - 1);
    return (match.index === 0 || unicodeWhitespace(code) || unicodePunctuation(code)) && (!email || code !== 47);
  }
  // node_modules/micromark-util-normalize-identifier/dev/index.js
  function normalizeIdentifier(value) {
    return value.replace(/[\t\n\r ]+/g, values.space).replace(/^ | $/g, "").toLowerCase().toUpperCase();
  }

  // node_modules/mdast-util-gfm-footnote/lib/index.js
  footnoteReference.peek = footnoteReferencePeek;
  function enterFootnoteCallString() {
    this.buffer();
  }
  function enterFootnoteCall(token) {
    this.enter({ type: "footnoteReference", identifier: "", label: "" }, token);
  }
  function enterFootnoteDefinitionLabelString() {
    this.buffer();
  }
  function enterFootnoteDefinition(token) {
    this.enter({ type: "footnoteDefinition", identifier: "", label: "", children: [] }, token);
  }
  function exitFootnoteCallString(token) {
    const label = this.resume();
    const node = this.stack[this.stack.length - 1];
    ok(node.type === "footnoteReference");
    node.identifier = normalizeIdentifier(this.sliceSerialize(token)).toLowerCase();
    node.label = label;
  }
  function exitFootnoteCall(token) {
    this.exit(token);
  }
  function exitFootnoteDefinitionLabelString(token) {
    const label = this.resume();
    const node = this.stack[this.stack.length - 1];
    ok(node.type === "footnoteDefinition");
    node.identifier = normalizeIdentifier(this.sliceSerialize(token)).toLowerCase();
    node.label = label;
  }
  function exitFootnoteDefinition(token) {
    this.exit(token);
  }
  function footnoteReferencePeek() {
    return "[";
  }
  function footnoteReference(node, _, state, info) {
    const tracker = state.createTracker(info);
    let value = tracker.move("[^");
    const exit = state.enter("footnoteReference");
    const subexit = state.enter("reference");
    value += tracker.move(state.safe(state.associationId(node), { after: "]", before: value }));
    subexit();
    exit();
    value += tracker.move("]");
    return value;
  }
  function gfmFootnoteFromMarkdown() {
    return {
      enter: {
        gfmFootnoteCallString: enterFootnoteCallString,
        gfmFootnoteCall: enterFootnoteCall,
        gfmFootnoteDefinitionLabelString: enterFootnoteDefinitionLabelString,
        gfmFootnoteDefinition: enterFootnoteDefinition
      },
      exit: {
        gfmFootnoteCallString: exitFootnoteCallString,
        gfmFootnoteCall: exitFootnoteCall,
        gfmFootnoteDefinitionLabelString: exitFootnoteDefinitionLabelString,
        gfmFootnoteDefinition: exitFootnoteDefinition
      }
    };
  }
  function gfmFootnoteToMarkdown(options) {
    let firstLineBlank = false;
    if (options && options.firstLineBlank) {
      firstLineBlank = true;
    }
    return {
      handlers: { footnoteDefinition, footnoteReference },
      unsafe: [{ character: "[", inConstruct: ["label", "phrasing", "reference"] }]
    };
    function footnoteDefinition(node, _, state, info) {
      const tracker = state.createTracker(info);
      let value = tracker.move("[^");
      const exit = state.enter("footnoteDefinition");
      const subexit = state.enter("label");
      value += tracker.move(state.safe(state.associationId(node), { before: value, after: "]" }));
      subexit();
      value += tracker.move("]:");
      if (node.children && node.children.length > 0) {
        tracker.shift(4);
        value += tracker.move((firstLineBlank ? `
` : " ") + state.indentLines(state.containerFlow(node, tracker.current()), firstLineBlank ? mapAll : mapExceptFirst));
      }
      exit();
      return value;
    }
  }
  function mapExceptFirst(line, index, blank) {
    return index === 0 ? line : mapAll(line, index, blank);
  }
  function mapAll(line, index, blank) {
    return (blank ? "" : "    ") + line;
  }
  // node_modules/mdast-util-gfm-strikethrough/lib/index.js
  var constructsWithoutStrikethrough = [
    "autolink",
    "destinationLiteral",
    "destinationRaw",
    "reference",
    "titleQuote",
    "titleApostrophe"
  ];
  handleDelete.peek = peekDelete;
  function gfmStrikethroughFromMarkdown() {
    return {
      canContainEols: ["delete"],
      enter: { strikethrough: enterStrikethrough },
      exit: { strikethrough: exitStrikethrough }
    };
  }
  function gfmStrikethroughToMarkdown() {
    return {
      unsafe: [
        {
          character: "~",
          inConstruct: "phrasing",
          notInConstruct: constructsWithoutStrikethrough
        }
      ],
      handlers: { delete: handleDelete }
    };
  }
  function enterStrikethrough(token) {
    this.enter({ type: "delete", children: [] }, token);
  }
  function exitStrikethrough(token) {
    this.exit(token);
  }
  function handleDelete(node, _, state, info) {
    const tracker = state.createTracker(info);
    const exit = state.enter("strikethrough");
    let value = tracker.move("~~");
    value += state.containerPhrasing(node, {
      ...tracker.current(),
      before: value,
      after: "~"
    });
    value += tracker.move("~~");
    exit();
    return value;
  }
  function peekDelete() {
    return "~";
  }
  // node_modules/markdown-table/index.js
  function defaultStringLength(value) {
    return value.length;
  }
  function markdownTable(table, options) {
    const settings = options || {};
    const align = (settings.align || []).concat();
    const stringLength = settings.stringLength || defaultStringLength;
    const alignments = [];
    const cellMatrix = [];
    const sizeMatrix = [];
    const longestCellByColumn = [];
    let mostCellsPerRow = 0;
    let rowIndex = -1;
    while (++rowIndex < table.length) {
      const row2 = [];
      const sizes2 = [];
      let columnIndex2 = -1;
      if (table[rowIndex].length > mostCellsPerRow) {
        mostCellsPerRow = table[rowIndex].length;
      }
      while (++columnIndex2 < table[rowIndex].length) {
        const cell = serialize(table[rowIndex][columnIndex2]);
        if (settings.alignDelimiters !== false) {
          const size = stringLength(cell);
          sizes2[columnIndex2] = size;
          if (longestCellByColumn[columnIndex2] === undefined || size > longestCellByColumn[columnIndex2]) {
            longestCellByColumn[columnIndex2] = size;
          }
        }
        row2.push(cell);
      }
      cellMatrix[rowIndex] = row2;
      sizeMatrix[rowIndex] = sizes2;
    }
    let columnIndex = -1;
    if (typeof align === "object" && "length" in align) {
      while (++columnIndex < mostCellsPerRow) {
        alignments[columnIndex] = toAlignment(align[columnIndex]);
      }
    } else {
      const code = toAlignment(align);
      while (++columnIndex < mostCellsPerRow) {
        alignments[columnIndex] = code;
      }
    }
    columnIndex = -1;
    const row = [];
    const sizes = [];
    while (++columnIndex < mostCellsPerRow) {
      const code = alignments[columnIndex];
      let before = "";
      let after = "";
      if (code === 99) {
        before = ":";
        after = ":";
      } else if (code === 108) {
        before = ":";
      } else if (code === 114) {
        after = ":";
      }
      let size = settings.alignDelimiters === false ? 1 : Math.max(1, longestCellByColumn[columnIndex] - before.length - after.length);
      const cell = before + "-".repeat(size) + after;
      if (settings.alignDelimiters !== false) {
        size = before.length + size + after.length;
        if (size > longestCellByColumn[columnIndex]) {
          longestCellByColumn[columnIndex] = size;
        }
        sizes[columnIndex] = size;
      }
      row[columnIndex] = cell;
    }
    cellMatrix.splice(1, 0, row);
    sizeMatrix.splice(1, 0, sizes);
    rowIndex = -1;
    const lines = [];
    while (++rowIndex < cellMatrix.length) {
      const row2 = cellMatrix[rowIndex];
      const sizes2 = sizeMatrix[rowIndex];
      columnIndex = -1;
      const line = [];
      while (++columnIndex < mostCellsPerRow) {
        const cell = row2[columnIndex] || "";
        let before = "";
        let after = "";
        if (settings.alignDelimiters !== false) {
          const size = longestCellByColumn[columnIndex] - (sizes2[columnIndex] || 0);
          const code = alignments[columnIndex];
          if (code === 114) {
            before = " ".repeat(size);
          } else if (code === 99) {
            if (size % 2) {
              before = " ".repeat(size / 2 + 0.5);
              after = " ".repeat(size / 2 - 0.5);
            } else {
              before = " ".repeat(size / 2);
              after = before;
            }
          } else {
            after = " ".repeat(size);
          }
        }
        if (settings.delimiterStart !== false && !columnIndex) {
          line.push("|");
        }
        if (settings.padding !== false && !(settings.alignDelimiters === false && cell === "") && (settings.delimiterStart !== false || columnIndex)) {
          line.push(" ");
        }
        if (settings.alignDelimiters !== false) {
          line.push(before);
        }
        line.push(cell);
        if (settings.alignDelimiters !== false) {
          line.push(after);
        }
        if (settings.padding !== false) {
          line.push(" ");
        }
        if (settings.delimiterEnd !== false || columnIndex !== mostCellsPerRow - 1) {
          line.push("|");
        }
      }
      lines.push(settings.delimiterEnd === false ? line.join("").replace(/ +$/, "") : line.join(""));
    }
    return lines.join(`
`);
  }
  function serialize(value) {
    return value === null || value === undefined ? "" : String(value);
  }
  function toAlignment(value) {
    const code = typeof value === "string" ? value.codePointAt(0) : 0;
    return code === 67 || code === 99 ? 99 : code === 76 || code === 108 ? 108 : code === 82 || code === 114 ? 114 : 0;
  }
  // node_modules/mdast-util-to-markdown/lib/handle/blockquote.js
  function blockquote(node, _, state, info) {
    const exit = state.enter("blockquote");
    const tracker = state.createTracker(info);
    tracker.move("> ");
    tracker.shift(2);
    const value = state.indentLines(state.containerFlow(node, tracker.current()), map);
    exit();
    return value;
  }
  function map(line, _, blank) {
    return ">" + (blank ? "" : " ") + line;
  }

  // node_modules/mdast-util-to-markdown/lib/util/pattern-in-scope.js
  function patternInScope(stack, pattern) {
    return listInScope(stack, pattern.inConstruct, true) && !listInScope(stack, pattern.notInConstruct, false);
  }
  function listInScope(stack, list, none) {
    if (typeof list === "string") {
      list = [list];
    }
    if (!list || list.length === 0) {
      return none;
    }
    let index = -1;
    while (++index < list.length) {
      if (stack.includes(list[index])) {
        return true;
      }
    }
    return false;
  }

  // node_modules/mdast-util-to-markdown/lib/handle/break.js
  function hardBreak(_, _1, state, info) {
    let index = -1;
    while (++index < state.unsafe.length) {
      if (state.unsafe[index].character === `
` && patternInScope(state.stack, state.unsafe[index])) {
        return /[ \t]/.test(info.before) ? "" : " ";
      }
    }
    return "\\\n";
  }

  // node_modules/longest-streak/index.js
  function longestStreak(value, substring) {
    const source = String(value);
    let index = source.indexOf(substring);
    let expected = index;
    let count = 0;
    let max = 0;
    if (typeof substring !== "string") {
      throw new TypeError("Expected substring");
    }
    while (index !== -1) {
      if (index === expected) {
        if (++count > max) {
          max = count;
        }
      } else {
        count = 1;
      }
      expected = index + substring.length;
      index = source.indexOf(substring, expected);
    }
    return max;
  }

  // node_modules/mdast-util-to-markdown/lib/util/format-code-as-indented.js
  function formatCodeAsIndented(node, state) {
    return Boolean(state.options.fences === false && node.value && !node.lang && /[^ \r\n]/.test(node.value) && !/^[\t ]*(?:[\r\n]|$)|(?:^|[\r\n])[\t ]*$/.test(node.value));
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-fence.js
  function checkFence(state) {
    const marker = state.options.fence || "`";
    if (marker !== "`" && marker !== "~") {
      throw new Error("Cannot serialize code with `" + marker + "` for `options.fence`, expected `` ` `` or `~`");
    }
    return marker;
  }

  // node_modules/mdast-util-to-markdown/lib/handle/code.js
  function code(node, _, state, info) {
    const marker = checkFence(state);
    const raw = node.value || "";
    const suffix = marker === "`" ? "GraveAccent" : "Tilde";
    if (formatCodeAsIndented(node, state)) {
      const exit2 = state.enter("codeIndented");
      const value2 = state.indentLines(raw, map2);
      exit2();
      return value2;
    }
    const tracker = state.createTracker(info);
    const sequence = marker.repeat(Math.max(longestStreak(raw, marker) + 1, 3));
    const exit = state.enter("codeFenced");
    let value = tracker.move(sequence);
    if (node.lang) {
      const subexit = state.enter(`codeFencedLang${suffix}`);
      value += tracker.move(state.safe(node.lang, {
        before: value,
        after: " ",
        encode: ["`"],
        ...tracker.current()
      }));
      subexit();
    }
    if (node.lang && node.meta) {
      const subexit = state.enter(`codeFencedMeta${suffix}`);
      value += tracker.move(" ");
      value += tracker.move(state.safe(node.meta, {
        before: value,
        after: `
`,
        encode: ["`"],
        ...tracker.current()
      }));
      subexit();
    }
    value += tracker.move(`
`);
    if (raw) {
      value += tracker.move(raw + `
`);
    }
    value += tracker.move(sequence);
    exit();
    return value;
  }
  function map2(line, _, blank) {
    return (blank ? "" : "    ") + line;
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-quote.js
  function checkQuote(state) {
    const marker = state.options.quote || '"';
    if (marker !== '"' && marker !== "'") {
      throw new Error("Cannot serialize title with `" + marker + "` for `options.quote`, expected `\"`, or `'`");
    }
    return marker;
  }

  // node_modules/mdast-util-to-markdown/lib/handle/definition.js
  function definition(node, _, state, info) {
    const quote = checkQuote(state);
    const suffix = quote === '"' ? "Quote" : "Apostrophe";
    const exit = state.enter("definition");
    let subexit = state.enter("label");
    const tracker = state.createTracker(info);
    let value = tracker.move("[");
    value += tracker.move(state.safe(state.associationId(node), {
      before: value,
      after: "]",
      ...tracker.current()
    }));
    value += tracker.move("]: ");
    subexit();
    if (!node.url || /[\0- \u007F]/.test(node.url)) {
      subexit = state.enter("destinationLiteral");
      value += tracker.move("<");
      value += tracker.move(state.safe(node.url, { before: value, after: ">", ...tracker.current() }));
      value += tracker.move(">");
    } else {
      subexit = state.enter("destinationRaw");
      value += tracker.move(state.safe(node.url, {
        before: value,
        after: node.title ? " " : `
`,
        ...tracker.current()
      }));
    }
    subexit();
    if (node.title) {
      subexit = state.enter(`title${suffix}`);
      value += tracker.move(" " + quote);
      value += tracker.move(state.safe(node.title, {
        before: value,
        after: quote,
        ...tracker.current()
      }));
      value += tracker.move(quote);
      subexit();
    }
    exit();
    return value;
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-emphasis.js
  function checkEmphasis(state) {
    const marker = state.options.emphasis || "*";
    if (marker !== "*" && marker !== "_") {
      throw new Error("Cannot serialize emphasis with `" + marker + "` for `options.emphasis`, expected `*`, or `_`");
    }
    return marker;
  }

  // node_modules/mdast-util-to-markdown/lib/util/encode-character-reference.js
  function encodeCharacterReference(code2) {
    return "&#x" + code2.toString(16).toUpperCase() + ";";
  }

  // node_modules/micromark-util-classify-character/dev/index.js
  function classifyCharacter(code2) {
    if (code2 === codes.eof || markdownLineEndingOrSpace(code2) || unicodeWhitespace(code2)) {
      return constants.characterGroupWhitespace;
    }
    if (unicodePunctuation(code2)) {
      return constants.characterGroupPunctuation;
    }
  }

  // node_modules/mdast-util-to-markdown/lib/util/encode-info.js
  function encodeInfo(outside, inside, marker) {
    const outsideKind = classifyCharacter(outside);
    const insideKind = classifyCharacter(inside);
    if (outsideKind === undefined) {
      return insideKind === undefined ? marker === "_" ? { inside: true, outside: true } : { inside: false, outside: false } : insideKind === 1 ? { inside: true, outside: true } : { inside: false, outside: true };
    }
    if (outsideKind === 1) {
      return insideKind === undefined ? { inside: false, outside: false } : insideKind === 1 ? { inside: true, outside: true } : { inside: false, outside: false };
    }
    return insideKind === undefined ? { inside: false, outside: false } : insideKind === 1 ? { inside: true, outside: false } : { inside: false, outside: false };
  }

  // node_modules/mdast-util-to-markdown/lib/handle/emphasis.js
  emphasis.peek = emphasisPeek;
  function emphasis(node, _, state, info) {
    const marker = checkEmphasis(state);
    const exit = state.enter("emphasis");
    const tracker = state.createTracker(info);
    const before = tracker.move(marker);
    let between = tracker.move(state.containerPhrasing(node, {
      after: marker,
      before,
      ...tracker.current()
    }));
    const betweenHead = between.charCodeAt(0);
    const open = encodeInfo(info.before.charCodeAt(info.before.length - 1), betweenHead, marker);
    if (open.inside) {
      between = encodeCharacterReference(betweenHead) + between.slice(1);
    }
    const betweenTail = between.charCodeAt(between.length - 1);
    const close = encodeInfo(info.after.charCodeAt(0), betweenTail, marker);
    if (close.inside) {
      between = between.slice(0, -1) + encodeCharacterReference(betweenTail);
    }
    const after = tracker.move(marker);
    exit();
    state.attentionEncodeSurroundingInfo = {
      after: close.outside,
      before: open.outside
    };
    return before + between + after;
  }
  function emphasisPeek(_, _1, state) {
    return state.options.emphasis || "*";
  }

  // node_modules/unist-util-visit/lib/index.js
  function visit(tree, testOrVisitor, visitorOrReverse, maybeReverse) {
    let reverse;
    let test;
    let visitor;
    if (typeof testOrVisitor === "function" && typeof visitorOrReverse !== "function") {
      test = undefined;
      visitor = testOrVisitor;
      reverse = visitorOrReverse;
    } else {
      test = testOrVisitor;
      visitor = visitorOrReverse;
      reverse = maybeReverse;
    }
    visitParents(tree, test, overload, reverse);
    function overload(node, parents) {
      const parent = parents[parents.length - 1];
      const index = parent ? parent.children.indexOf(node) : undefined;
      return visitor(node, index, parent);
    }
  }
  // node_modules/mdast-util-to-string/lib/index.js
  var emptyOptions = {};
  function toString(value, options) {
    const settings = options || emptyOptions;
    const includeImageAlt = typeof settings.includeImageAlt === "boolean" ? settings.includeImageAlt : true;
    const includeHtml = typeof settings.includeHtml === "boolean" ? settings.includeHtml : true;
    return one(value, includeImageAlt, includeHtml);
  }
  function one(value, includeImageAlt, includeHtml) {
    if (node(value)) {
      if ("value" in value) {
        return value.type === "html" && !includeHtml ? "" : value.value;
      }
      if (includeImageAlt && "alt" in value && value.alt) {
        return value.alt;
      }
      if ("children" in value) {
        return all(value.children, includeImageAlt, includeHtml);
      }
    }
    if (Array.isArray(value)) {
      return all(value, includeImageAlt, includeHtml);
    }
    return "";
  }
  function all(values2, includeImageAlt, includeHtml) {
    const result = [];
    let index = -1;
    while (++index < values2.length) {
      result[index] = one(values2[index], includeImageAlt, includeHtml);
    }
    return result.join("");
  }
  function node(value) {
    return Boolean(value && typeof value === "object");
  }
  // node_modules/mdast-util-to-markdown/lib/util/format-heading-as-setext.js
  function formatHeadingAsSetext(node2, state) {
    let literalWithBreak = false;
    visit(node2, function(node3) {
      if ("value" in node3 && /\r?\n|\r/.test(node3.value) || node3.type === "break") {
        literalWithBreak = true;
        return EXIT;
      }
    });
    return Boolean((!node2.depth || node2.depth < 3) && toString(node2) && (state.options.setext || literalWithBreak));
  }

  // node_modules/mdast-util-to-markdown/lib/handle/heading.js
  function heading(node2, _, state, info) {
    const rank = Math.max(Math.min(6, node2.depth || 1), 1);
    const tracker = state.createTracker(info);
    if (formatHeadingAsSetext(node2, state)) {
      const exit2 = state.enter("headingSetext");
      const subexit2 = state.enter("phrasing");
      const value2 = state.containerPhrasing(node2, {
        ...tracker.current(),
        before: `
`,
        after: `
`
      });
      subexit2();
      exit2();
      return value2 + `
` + (rank === 1 ? "=" : "-").repeat(value2.length - (Math.max(value2.lastIndexOf("\r"), value2.lastIndexOf(`
`)) + 1));
    }
    const sequence = "#".repeat(rank);
    const exit = state.enter("headingAtx");
    const subexit = state.enter("phrasing");
    tracker.move(sequence + " ");
    let value = state.containerPhrasing(node2, {
      before: "# ",
      after: `
`,
      ...tracker.current()
    });
    if (/^[\t ]/.test(value)) {
      value = encodeCharacterReference(value.charCodeAt(0)) + value.slice(1);
    }
    value = value ? sequence + " " + value : sequence;
    if (state.options.closeAtx) {
      value += " " + sequence;
    }
    subexit();
    exit();
    return value;
  }

  // node_modules/mdast-util-to-markdown/lib/handle/html.js
  html.peek = htmlPeek;
  function html(node2) {
    return node2.value || "";
  }
  function htmlPeek() {
    return "<";
  }

  // node_modules/mdast-util-to-markdown/lib/handle/image.js
  image.peek = imagePeek;
  function image(node2, _, state, info) {
    const quote = checkQuote(state);
    const suffix = quote === '"' ? "Quote" : "Apostrophe";
    const exit = state.enter("image");
    let subexit = state.enter("label");
    const tracker = state.createTracker(info);
    let value = tracker.move("![");
    value += tracker.move(state.safe(node2.alt, { before: value, after: "]", ...tracker.current() }));
    value += tracker.move("](");
    subexit();
    if (!node2.url && node2.title || /[\0- \u007F]/.test(node2.url)) {
      subexit = state.enter("destinationLiteral");
      value += tracker.move("<");
      value += tracker.move(state.safe(node2.url, { before: value, after: ">", ...tracker.current() }));
      value += tracker.move(">");
    } else {
      subexit = state.enter("destinationRaw");
      value += tracker.move(state.safe(node2.url, {
        before: value,
        after: node2.title ? " " : ")",
        ...tracker.current()
      }));
    }
    subexit();
    if (node2.title) {
      subexit = state.enter(`title${suffix}`);
      value += tracker.move(" " + quote);
      value += tracker.move(state.safe(node2.title, {
        before: value,
        after: quote,
        ...tracker.current()
      }));
      value += tracker.move(quote);
      subexit();
    }
    value += tracker.move(")");
    exit();
    return value;
  }
  function imagePeek() {
    return "!";
  }

  // node_modules/mdast-util-to-markdown/lib/handle/image-reference.js
  imageReference.peek = imageReferencePeek;
  function imageReference(node2, _, state, info) {
    const type = node2.referenceType;
    const exit = state.enter("imageReference");
    let subexit = state.enter("label");
    const tracker = state.createTracker(info);
    let value = tracker.move("![");
    const alt = state.safe(node2.alt, {
      before: value,
      after: "]",
      ...tracker.current()
    });
    value += tracker.move(alt + "][");
    subexit();
    const stack = state.stack;
    state.stack = [];
    subexit = state.enter("reference");
    const reference = state.safe(state.associationId(node2), {
      before: value,
      after: "]",
      ...tracker.current()
    });
    subexit();
    state.stack = stack;
    exit();
    if (type === "full" || !alt || alt !== reference) {
      value += tracker.move(reference + "]");
    } else if (type === "shortcut") {
      value = value.slice(0, -1);
    } else {
      value += tracker.move("]");
    }
    return value;
  }
  function imageReferencePeek() {
    return "!";
  }

  // node_modules/mdast-util-to-markdown/lib/handle/inline-code.js
  inlineCode.peek = inlineCodePeek;
  function inlineCode(node2, _, state) {
    let value = node2.value || "";
    let sequence = "`";
    let index = -1;
    while (new RegExp("(^|[^`])" + sequence + "([^`]|$)").test(value)) {
      sequence += "`";
    }
    if (/[^ \r\n]/.test(value) && (/^[ \r\n]/.test(value) && /[ \r\n]$/.test(value) || /^`|`$/.test(value))) {
      value = " " + value + " ";
    }
    while (++index < state.unsafe.length) {
      const pattern = state.unsafe[index];
      const expression = state.compilePattern(pattern);
      let match;
      if (!pattern.atBreak)
        continue;
      while (match = expression.exec(value)) {
        let position = match.index;
        if (value.charCodeAt(position) === 10 && value.charCodeAt(position - 1) === 13) {
          position--;
        }
        value = value.slice(0, position) + " " + value.slice(match.index + 1);
      }
    }
    return sequence + value + sequence;
  }
  function inlineCodePeek() {
    return "`";
  }

  // node_modules/mdast-util-to-markdown/lib/util/format-link-as-autolink.js
  function formatLinkAsAutolink(node2, state) {
    const raw = toString(node2);
    return Boolean(!state.options.resourceLink && node2.url && !node2.title && node2.children && node2.children.length === 1 && node2.children[0].type === "text" && (raw === node2.url || "mailto:" + raw === node2.url) && /^[a-z][a-z+.-]+:/i.test(node2.url) && !/[\0- <>\u007F]/.test(node2.url));
  }

  // node_modules/mdast-util-to-markdown/lib/handle/link.js
  link.peek = linkPeek;
  function link(node2, _, state, info) {
    const quote = checkQuote(state);
    const suffix = quote === '"' ? "Quote" : "Apostrophe";
    const tracker = state.createTracker(info);
    let exit;
    let subexit;
    if (formatLinkAsAutolink(node2, state)) {
      const stack = state.stack;
      state.stack = [];
      exit = state.enter("autolink");
      let value2 = tracker.move("<");
      value2 += tracker.move(state.containerPhrasing(node2, {
        before: value2,
        after: ">",
        ...tracker.current()
      }));
      value2 += tracker.move(">");
      exit();
      state.stack = stack;
      return value2;
    }
    exit = state.enter("link");
    subexit = state.enter("label");
    let value = tracker.move("[");
    value += tracker.move(state.containerPhrasing(node2, {
      before: value,
      after: "](",
      ...tracker.current()
    }));
    value += tracker.move("](");
    subexit();
    if (!node2.url && node2.title || /[\0- \u007F]/.test(node2.url)) {
      subexit = state.enter("destinationLiteral");
      value += tracker.move("<");
      value += tracker.move(state.safe(node2.url, { before: value, after: ">", ...tracker.current() }));
      value += tracker.move(">");
    } else {
      subexit = state.enter("destinationRaw");
      value += tracker.move(state.safe(node2.url, {
        before: value,
        after: node2.title ? " " : ")",
        ...tracker.current()
      }));
    }
    subexit();
    if (node2.title) {
      subexit = state.enter(`title${suffix}`);
      value += tracker.move(" " + quote);
      value += tracker.move(state.safe(node2.title, {
        before: value,
        after: quote,
        ...tracker.current()
      }));
      value += tracker.move(quote);
      subexit();
    }
    value += tracker.move(")");
    exit();
    return value;
  }
  function linkPeek(node2, _, state) {
    return formatLinkAsAutolink(node2, state) ? "<" : "[";
  }

  // node_modules/mdast-util-to-markdown/lib/handle/link-reference.js
  linkReference.peek = linkReferencePeek;
  function linkReference(node2, _, state, info) {
    const type = node2.referenceType;
    const exit = state.enter("linkReference");
    let subexit = state.enter("label");
    const tracker = state.createTracker(info);
    let value = tracker.move("[");
    const text = state.containerPhrasing(node2, {
      before: value,
      after: "]",
      ...tracker.current()
    });
    value += tracker.move(text + "][");
    subexit();
    const stack = state.stack;
    state.stack = [];
    subexit = state.enter("reference");
    const reference = state.safe(state.associationId(node2), {
      before: value,
      after: "]",
      ...tracker.current()
    });
    subexit();
    state.stack = stack;
    exit();
    if (type === "full" || !text || text !== reference) {
      value += tracker.move(reference + "]");
    } else if (type === "shortcut") {
      value = value.slice(0, -1);
    } else {
      value += tracker.move("]");
    }
    return value;
  }
  function linkReferencePeek() {
    return "[";
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-bullet.js
  function checkBullet(state) {
    const marker = state.options.bullet || "*";
    if (marker !== "*" && marker !== "+" && marker !== "-") {
      throw new Error("Cannot serialize items with `" + marker + "` for `options.bullet`, expected `*`, `+`, or `-`");
    }
    return marker;
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-bullet-other.js
  function checkBulletOther(state) {
    const bullet = checkBullet(state);
    const bulletOther = state.options.bulletOther;
    if (!bulletOther) {
      return bullet === "*" ? "-" : "*";
    }
    if (bulletOther !== "*" && bulletOther !== "+" && bulletOther !== "-") {
      throw new Error("Cannot serialize items with `" + bulletOther + "` for `options.bulletOther`, expected `*`, `+`, or `-`");
    }
    if (bulletOther === bullet) {
      throw new Error("Expected `bullet` (`" + bullet + "`) and `bulletOther` (`" + bulletOther + "`) to be different");
    }
    return bulletOther;
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-bullet-ordered.js
  function checkBulletOrdered(state) {
    const marker = state.options.bulletOrdered || ".";
    if (marker !== "." && marker !== ")") {
      throw new Error("Cannot serialize items with `" + marker + "` for `options.bulletOrdered`, expected `.` or `)`");
    }
    return marker;
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-rule.js
  function checkRule(state) {
    const marker = state.options.rule || "*";
    if (marker !== "*" && marker !== "-" && marker !== "_") {
      throw new Error("Cannot serialize rules with `" + marker + "` for `options.rule`, expected `*`, `-`, or `_`");
    }
    return marker;
  }

  // node_modules/mdast-util-to-markdown/lib/handle/list.js
  function list(node2, parent, state, info) {
    const exit = state.enter("list");
    const bulletCurrent = state.bulletCurrent;
    let bullet = node2.ordered ? checkBulletOrdered(state) : checkBullet(state);
    const bulletOther = node2.ordered ? bullet === "." ? ")" : "." : checkBulletOther(state);
    let useDifferentMarker = parent && state.bulletLastUsed ? bullet === state.bulletLastUsed : false;
    if (!node2.ordered) {
      const firstListItem = node2.children ? node2.children[0] : undefined;
      if ((bullet === "*" || bullet === "-") && firstListItem && (!firstListItem.children || !firstListItem.children[0]) && state.stack[state.stack.length - 1] === "list" && state.stack[state.stack.length - 2] === "listItem" && state.stack[state.stack.length - 3] === "list" && state.stack[state.stack.length - 4] === "listItem" && state.indexStack[state.indexStack.length - 1] === 0 && state.indexStack[state.indexStack.length - 2] === 0 && state.indexStack[state.indexStack.length - 3] === 0) {
        useDifferentMarker = true;
      }
      if (checkRule(state) === bullet && firstListItem) {
        let index = -1;
        while (++index < node2.children.length) {
          const item = node2.children[index];
          if (item && item.type === "listItem" && item.children && item.children[0] && item.children[0].type === "thematicBreak") {
            useDifferentMarker = true;
            break;
          }
        }
      }
    }
    if (useDifferentMarker) {
      bullet = bulletOther;
    }
    state.bulletCurrent = bullet;
    const value = state.containerFlow(node2, info);
    state.bulletLastUsed = bullet;
    state.bulletCurrent = bulletCurrent;
    exit();
    return value;
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-list-item-indent.js
  function checkListItemIndent(state) {
    const style = state.options.listItemIndent || "one";
    if (style !== "tab" && style !== "one" && style !== "mixed") {
      throw new Error("Cannot serialize items with `" + style + "` for `options.listItemIndent`, expected `tab`, `one`, or `mixed`");
    }
    return style;
  }

  // node_modules/mdast-util-to-markdown/lib/handle/list-item.js
  function listItem(node2, parent, state, info) {
    const listItemIndent = checkListItemIndent(state);
    let bullet = state.bulletCurrent || checkBullet(state);
    if (parent && parent.type === "list" && parent.ordered) {
      bullet = (typeof parent.start === "number" && parent.start > -1 ? parent.start : 1) + (state.options.incrementListMarker === false ? 0 : parent.children.indexOf(node2)) + bullet;
    }
    let size = bullet.length + 1;
    if (listItemIndent === "tab" || listItemIndent === "mixed" && (parent && parent.type === "list" && parent.spread || node2.spread)) {
      size = Math.ceil(size / 4) * 4;
    }
    const tracker = state.createTracker(info);
    tracker.move(bullet + " ".repeat(size - bullet.length));
    tracker.shift(size);
    const exit = state.enter("listItem");
    const value = state.indentLines(state.containerFlow(node2, tracker.current()), map3);
    exit();
    return value;
    function map3(line, index, blank) {
      if (index) {
        return (blank ? "" : " ".repeat(size)) + line;
      }
      return (blank ? bullet : bullet + " ".repeat(size - bullet.length)) + line;
    }
  }

  // node_modules/mdast-util-to-markdown/lib/handle/paragraph.js
  function paragraph(node2, _, state, info) {
    const exit = state.enter("paragraph");
    const subexit = state.enter("phrasing");
    const value = state.containerPhrasing(node2, info);
    subexit();
    exit();
    return value;
  }

  // node_modules/mdast-util-phrasing/lib/index.js
  var phrasing = convert([
    "break",
    "delete",
    "emphasis",
    "footnote",
    "footnoteReference",
    "image",
    "imageReference",
    "inlineCode",
    "inlineMath",
    "link",
    "linkReference",
    "mdxJsxTextElement",
    "mdxTextExpression",
    "strong",
    "text",
    "textDirective"
  ]);
  // node_modules/mdast-util-to-markdown/lib/handle/root.js
  function root(node2, _, state, info) {
    const hasPhrasing = node2.children.some(function(d) {
      return phrasing(d);
    });
    const container = hasPhrasing ? state.containerPhrasing : state.containerFlow;
    return container.call(state, node2, info);
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-strong.js
  function checkStrong(state) {
    const marker = state.options.strong || "*";
    if (marker !== "*" && marker !== "_") {
      throw new Error("Cannot serialize strong with `" + marker + "` for `options.strong`, expected `*`, or `_`");
    }
    return marker;
  }

  // node_modules/mdast-util-to-markdown/lib/handle/strong.js
  strong.peek = strongPeek;
  function strong(node2, _, state, info) {
    const marker = checkStrong(state);
    const exit = state.enter("strong");
    const tracker = state.createTracker(info);
    const before = tracker.move(marker + marker);
    let between = tracker.move(state.containerPhrasing(node2, {
      after: marker,
      before,
      ...tracker.current()
    }));
    const betweenHead = between.charCodeAt(0);
    const open = encodeInfo(info.before.charCodeAt(info.before.length - 1), betweenHead, marker);
    if (open.inside) {
      between = encodeCharacterReference(betweenHead) + between.slice(1);
    }
    const betweenTail = between.charCodeAt(between.length - 1);
    const close = encodeInfo(info.after.charCodeAt(0), betweenTail, marker);
    if (close.inside) {
      between = between.slice(0, -1) + encodeCharacterReference(betweenTail);
    }
    const after = tracker.move(marker + marker);
    exit();
    state.attentionEncodeSurroundingInfo = {
      after: close.outside,
      before: open.outside
    };
    return before + between + after;
  }
  function strongPeek(_, _1, state) {
    return state.options.strong || "*";
  }

  // node_modules/mdast-util-to-markdown/lib/handle/text.js
  function text(node2, _, state, info) {
    return state.safe(node2.value, info);
  }

  // node_modules/mdast-util-to-markdown/lib/util/check-rule-repetition.js
  function checkRuleRepetition(state) {
    const repetition = state.options.ruleRepetition || 3;
    if (repetition < 3) {
      throw new Error("Cannot serialize rules with repetition `" + repetition + "` for `options.ruleRepetition`, expected `3` or more");
    }
    return repetition;
  }

  // node_modules/mdast-util-to-markdown/lib/handle/thematic-break.js
  function thematicBreak(_, _1, state) {
    const value = (checkRule(state) + (state.options.ruleSpaces ? " " : "")).repeat(checkRuleRepetition(state));
    return state.options.ruleSpaces ? value.slice(0, -1) : value;
  }

  // node_modules/mdast-util-to-markdown/lib/handle/index.js
  var handle = {
    blockquote,
    break: hardBreak,
    code,
    definition,
    emphasis,
    hardBreak,
    heading,
    html,
    image,
    imageReference,
    inlineCode,
    link,
    linkReference,
    list,
    listItem,
    paragraph,
    root,
    strong,
    text,
    thematicBreak
  };
  // node_modules/mdast-util-gfm-table/lib/index.js
  function gfmTableFromMarkdown() {
    return {
      enter: {
        table: enterTable,
        tableData: enterCell,
        tableHeader: enterCell,
        tableRow: enterRow
      },
      exit: {
        codeText: exitCodeText,
        table: exitTable,
        tableData: exit,
        tableHeader: exit,
        tableRow: exit
      }
    };
  }
  function enterTable(token) {
    const align = token._align;
    ok(align, "expected `_align` on table");
    this.enter({
      type: "table",
      align: align.map(function(d) {
        return d === "none" ? null : d;
      }),
      children: []
    }, token);
    this.data.inTable = true;
  }
  function exitTable(token) {
    this.exit(token);
    this.data.inTable = undefined;
  }
  function enterRow(token) {
    this.enter({ type: "tableRow", children: [] }, token);
  }
  function exit(token) {
    this.exit(token);
  }
  function enterCell(token) {
    this.enter({ type: "tableCell", children: [] }, token);
  }
  function exitCodeText(token) {
    let value = this.resume();
    if (this.data.inTable) {
      value = value.replace(/\\([\\|])/g, replace);
    }
    const node2 = this.stack[this.stack.length - 1];
    ok(node2.type === "inlineCode");
    node2.value = value;
    this.exit(token);
  }
  function replace($0, $1) {
    return $1 === "|" ? $1 : $0;
  }
  function gfmTableToMarkdown(options) {
    const settings = options || {};
    const padding = settings.tableCellPadding;
    const alignDelimiters = settings.tablePipeAlign;
    const stringLength = settings.stringLength;
    const around = padding ? " " : "|";
    return {
      unsafe: [
        { character: "\r", inConstruct: "tableCell" },
        { character: `
`, inConstruct: "tableCell" },
        { atBreak: true, character: "|", after: "[\t :-]" },
        { character: "|", inConstruct: "tableCell" },
        { atBreak: true, character: ":", after: "-" },
        { atBreak: true, character: "-", after: "[:|-]" }
      ],
      handlers: {
        inlineCode: inlineCodeWithTable,
        table: handleTable,
        tableCell: handleTableCell,
        tableRow: handleTableRow
      }
    };
    function handleTable(node2, _, state, info) {
      return serializeData(handleTableAsData(node2, state, info), node2.align);
    }
    function handleTableRow(node2, _, state, info) {
      const row = handleTableRowAsData(node2, state, info);
      const value = serializeData([row]);
      return value.slice(0, value.indexOf(`
`));
    }
    function handleTableCell(node2, _, state, info) {
      const exit2 = state.enter("tableCell");
      const subexit = state.enter("phrasing");
      const value = state.containerPhrasing(node2, {
        ...info,
        before: around,
        after: around
      });
      subexit();
      exit2();
      return value;
    }
    function serializeData(matrix, align) {
      return markdownTable(matrix, {
        align,
        alignDelimiters,
        padding,
        stringLength
      });
    }
    function handleTableAsData(node2, state, info) {
      const children = node2.children;
      let index = -1;
      const result = [];
      const subexit = state.enter("table");
      while (++index < children.length) {
        result[index] = handleTableRowAsData(children[index], state, info);
      }
      subexit();
      return result;
    }
    function handleTableRowAsData(node2, state, info) {
      const children = node2.children;
      let index = -1;
      const result = [];
      const subexit = state.enter("tableRow");
      while (++index < children.length) {
        result[index] = handleTableCell(children[index], node2, state, info);
      }
      subexit();
      return result;
    }
    function inlineCodeWithTable(node2, parent, state) {
      let value = handle.inlineCode(node2, parent, state);
      if (state.stack.includes("tableCell")) {
        value = value.replace(/\|/g, "\\$&");
      }
      return value;
    }
  }
  // node_modules/mdast-util-gfm-task-list-item/lib/index.js
  function gfmTaskListItemFromMarkdown() {
    return {
      exit: {
        taskListCheckValueChecked: exitCheck,
        taskListCheckValueUnchecked: exitCheck,
        paragraph: exitParagraphWithTaskListItem
      }
    };
  }
  function gfmTaskListItemToMarkdown() {
    return {
      unsafe: [{ atBreak: true, character: "-", after: "[:|-]" }],
      handlers: { listItem: listItemWithTaskListItem }
    };
  }
  function exitCheck(token) {
    const node2 = this.stack[this.stack.length - 2];
    ok(node2.type === "listItem");
    node2.checked = token.type === "taskListCheckValueChecked";
  }
  function exitParagraphWithTaskListItem(token) {
    const parent = this.stack[this.stack.length - 2];
    if (parent && parent.type === "listItem" && typeof parent.checked === "boolean") {
      const node2 = this.stack[this.stack.length - 1];
      ok(node2.type === "paragraph");
      const head = node2.children[0];
      if (head && head.type === "text") {
        const siblings = parent.children;
        let index = -1;
        let firstParaghraph;
        while (++index < siblings.length) {
          const sibling = siblings[index];
          if (sibling.type === "paragraph") {
            firstParaghraph = sibling;
            break;
          }
        }
        if (firstParaghraph === node2) {
          head.value = head.value.slice(1);
          if (head.value.length === 0) {
            node2.children.shift();
          } else if (node2.position && head.position && typeof head.position.start.offset === "number") {
            head.position.start.column++;
            head.position.start.offset++;
            node2.position.start = Object.assign({}, head.position.start);
          }
        }
      }
    }
    this.exit(token);
  }
  function listItemWithTaskListItem(node2, parent, state, info) {
    const head = node2.children[0];
    const checkable = typeof node2.checked === "boolean" && head && head.type === "paragraph";
    const checkbox = "[" + (node2.checked ? "x" : " ") + "] ";
    const tracker = state.createTracker(info);
    if (checkable) {
      tracker.move(checkbox);
    }
    let value = handle.listItem(node2, parent, state, {
      ...info,
      ...tracker.current()
    });
    if (checkable) {
      value = value.replace(/^(?:[*+-]|\d+\.)([\r\n]| {1,3})/, check);
    }
    return value;
    function check($0) {
      return $0 + checkbox;
    }
  }
  // node_modules/mdast-util-gfm/lib/index.js
  function gfmFromMarkdown() {
    return [
      gfmAutolinkLiteralFromMarkdown(),
      gfmFootnoteFromMarkdown(),
      gfmStrikethroughFromMarkdown(),
      gfmTableFromMarkdown(),
      gfmTaskListItemFromMarkdown()
    ];
  }
  function gfmToMarkdown(options) {
    return {
      extensions: [
        gfmAutolinkLiteralToMarkdown(),
        gfmFootnoteToMarkdown(options),
        gfmStrikethroughToMarkdown(),
        gfmTableToMarkdown(options),
        gfmTaskListItemToMarkdown()
      ]
    };
  }
  // node_modules/micromark-util-chunked/dev/index.js
  function splice(list2, start, remove, items) {
    const end = list2.length;
    let chunkStart = 0;
    let parameters;
    if (start < 0) {
      start = -start > end ? 0 : end + start;
    } else {
      start = start > end ? end : start;
    }
    remove = remove > 0 ? remove : 0;
    if (items.length < constants.v8MaxSafeChunkSize) {
      parameters = Array.from(items);
      parameters.unshift(start, remove);
      list2.splice(...parameters);
    } else {
      if (remove)
        list2.splice(start, remove);
      while (chunkStart < items.length) {
        parameters = items.slice(chunkStart, chunkStart + constants.v8MaxSafeChunkSize);
        parameters.unshift(start, 0);
        list2.splice(...parameters);
        chunkStart += constants.v8MaxSafeChunkSize;
        start += constants.v8MaxSafeChunkSize;
      }
    }
  }
  function push(list2, items) {
    if (list2.length > 0) {
      splice(list2, list2.length, 0, items);
      return list2;
    }
    return items;
  }

  // node_modules/micromark-util-combine-extensions/index.js
  var hasOwnProperty = {}.hasOwnProperty;
  function combineExtensions(extensions) {
    const all2 = {};
    let index = -1;
    while (++index < extensions.length) {
      syntaxExtension(all2, extensions[index]);
    }
    return all2;
  }
  function syntaxExtension(all2, extension) {
    let hook;
    for (hook in extension) {
      const maybe = hasOwnProperty.call(all2, hook) ? all2[hook] : undefined;
      const left = maybe || (all2[hook] = {});
      const right = extension[hook];
      let code2;
      if (right) {
        for (code2 in right) {
          if (!hasOwnProperty.call(left, code2))
            left[code2] = [];
          const value = right[code2];
          constructs(left[code2], Array.isArray(value) ? value : value ? [value] : []);
        }
      }
    }
  }
  function constructs(existing, list2) {
    let index = -1;
    const before = [];
    while (++index < list2.length) {
      (list2[index].add === "after" ? existing : before).push(list2[index]);
    }
    splice(existing, 0, 0, before);
  }

  // node_modules/micromark-extension-gfm-autolink-literal/dev/lib/syntax.js
  var wwwPrefix = { tokenize: tokenizeWwwPrefix, partial: true };
  var domain = { tokenize: tokenizeDomain, partial: true };
  var path = { tokenize: tokenizePath, partial: true };
  var trail = { tokenize: tokenizeTrail, partial: true };
  var emailDomainDotTrail = {
    tokenize: tokenizeEmailDomainDotTrail,
    partial: true
  };
  var wwwAutolink = {
    name: "wwwAutolink",
    tokenize: tokenizeWwwAutolink,
    previous: previousWww
  };
  var protocolAutolink = {
    name: "protocolAutolink",
    tokenize: tokenizeProtocolAutolink,
    previous: previousProtocol
  };
  var emailAutolink = {
    name: "emailAutolink",
    tokenize: tokenizeEmailAutolink,
    previous: previousEmail
  };
  var text2 = {};
  function gfmAutolinkLiteral() {
    return { text: text2 };
  }
  var code2 = codes.digit0;
  while (code2 < codes.leftCurlyBrace) {
    text2[code2] = emailAutolink;
    code2++;
    if (code2 === codes.colon)
      code2 = codes.uppercaseA;
    else if (code2 === codes.leftSquareBracket)
      code2 = codes.lowercaseA;
  }
  text2[codes.plusSign] = emailAutolink;
  text2[codes.dash] = emailAutolink;
  text2[codes.dot] = emailAutolink;
  text2[codes.underscore] = emailAutolink;
  text2[codes.uppercaseH] = [emailAutolink, protocolAutolink];
  text2[codes.lowercaseH] = [emailAutolink, protocolAutolink];
  text2[codes.uppercaseW] = [emailAutolink, wwwAutolink];
  text2[codes.lowercaseW] = [emailAutolink, wwwAutolink];
  function tokenizeEmailAutolink(effects, ok3, nok) {
    const self = this;
    let dot;
    let data;
    return start;
    function start(code3) {
      if (!gfmAtext(code3) || !previousEmail.call(self, self.previous) || previousUnbalanced(self.events)) {
        return nok(code3);
      }
      effects.enter("literalAutolink");
      effects.enter("literalAutolinkEmail");
      return atext(code3);
    }
    function atext(code3) {
      if (gfmAtext(code3)) {
        effects.consume(code3);
        return atext;
      }
      if (code3 === codes.atSign) {
        effects.consume(code3);
        return emailDomain;
      }
      return nok(code3);
    }
    function emailDomain(code3) {
      if (code3 === codes.dot) {
        return effects.check(emailDomainDotTrail, emailDomainAfter, emailDomainDot)(code3);
      }
      if (code3 === codes.dash || code3 === codes.underscore || asciiAlphanumeric(code3)) {
        data = true;
        effects.consume(code3);
        return emailDomain;
      }
      return emailDomainAfter(code3);
    }
    function emailDomainDot(code3) {
      effects.consume(code3);
      dot = true;
      return emailDomain;
    }
    function emailDomainAfter(code3) {
      if (data && dot && asciiAlpha(self.previous)) {
        effects.exit("literalAutolinkEmail");
        effects.exit("literalAutolink");
        return ok3(code3);
      }
      return nok(code3);
    }
  }
  function tokenizeWwwAutolink(effects, ok3, nok) {
    const self = this;
    return wwwStart;
    function wwwStart(code3) {
      if (code3 !== codes.uppercaseW && code3 !== codes.lowercaseW || !previousWww.call(self, self.previous) || previousUnbalanced(self.events)) {
        return nok(code3);
      }
      effects.enter("literalAutolink");
      effects.enter("literalAutolinkWww");
      return effects.check(wwwPrefix, effects.attempt(domain, effects.attempt(path, wwwAfter), nok), nok)(code3);
    }
    function wwwAfter(code3) {
      effects.exit("literalAutolinkWww");
      effects.exit("literalAutolink");
      return ok3(code3);
    }
  }
  function tokenizeProtocolAutolink(effects, ok3, nok) {
    const self = this;
    let buffer = "";
    let seen = false;
    return protocolStart;
    function protocolStart(code3) {
      if ((code3 === codes.uppercaseH || code3 === codes.lowercaseH) && previousProtocol.call(self, self.previous) && !previousUnbalanced(self.events)) {
        effects.enter("literalAutolink");
        effects.enter("literalAutolinkHttp");
        buffer += String.fromCodePoint(code3);
        effects.consume(code3);
        return protocolPrefixInside;
      }
      return nok(code3);
    }
    function protocolPrefixInside(code3) {
      if (asciiAlpha(code3) && buffer.length < 5) {
        buffer += String.fromCodePoint(code3);
        effects.consume(code3);
        return protocolPrefixInside;
      }
      if (code3 === codes.colon) {
        const protocol = buffer.toLowerCase();
        if (protocol === "http" || protocol === "https") {
          effects.consume(code3);
          return protocolSlashesInside;
        }
      }
      return nok(code3);
    }
    function protocolSlashesInside(code3) {
      if (code3 === codes.slash) {
        effects.consume(code3);
        if (seen) {
          return afterProtocol;
        }
        seen = true;
        return protocolSlashesInside;
      }
      return nok(code3);
    }
    function afterProtocol(code3) {
      return code3 === codes.eof || asciiControl(code3) || markdownLineEndingOrSpace(code3) || unicodeWhitespace(code3) || unicodePunctuation(code3) ? nok(code3) : effects.attempt(domain, effects.attempt(path, protocolAfter), nok)(code3);
    }
    function protocolAfter(code3) {
      effects.exit("literalAutolinkHttp");
      effects.exit("literalAutolink");
      return ok3(code3);
    }
  }
  function tokenizeWwwPrefix(effects, ok3, nok) {
    let size = 0;
    return wwwPrefixInside;
    function wwwPrefixInside(code3) {
      if ((code3 === codes.uppercaseW || code3 === codes.lowercaseW) && size < 3) {
        size++;
        effects.consume(code3);
        return wwwPrefixInside;
      }
      if (code3 === codes.dot && size === 3) {
        effects.consume(code3);
        return wwwPrefixAfter;
      }
      return nok(code3);
    }
    function wwwPrefixAfter(code3) {
      return code3 === codes.eof ? nok(code3) : ok3(code3);
    }
  }
  function tokenizeDomain(effects, ok3, nok) {
    let underscoreInLastSegment;
    let underscoreInLastLastSegment;
    let seen;
    return domainInside;
    function domainInside(code3) {
      if (code3 === codes.dot || code3 === codes.underscore) {
        return effects.check(trail, domainAfter, domainAtPunctuation)(code3);
      }
      if (code3 === codes.eof || markdownLineEndingOrSpace(code3) || unicodeWhitespace(code3) || code3 !== codes.dash && unicodePunctuation(code3)) {
        return domainAfter(code3);
      }
      seen = true;
      effects.consume(code3);
      return domainInside;
    }
    function domainAtPunctuation(code3) {
      if (code3 === codes.underscore) {
        underscoreInLastSegment = true;
      } else {
        underscoreInLastLastSegment = underscoreInLastSegment;
        underscoreInLastSegment = undefined;
      }
      effects.consume(code3);
      return domainInside;
    }
    function domainAfter(code3) {
      if (underscoreInLastLastSegment || underscoreInLastSegment || !seen) {
        return nok(code3);
      }
      return ok3(code3);
    }
  }
  function tokenizePath(effects, ok3) {
    let sizeOpen = 0;
    let sizeClose = 0;
    return pathInside;
    function pathInside(code3) {
      if (code3 === codes.leftParenthesis) {
        sizeOpen++;
        effects.consume(code3);
        return pathInside;
      }
      if (code3 === codes.rightParenthesis && sizeClose < sizeOpen) {
        return pathAtPunctuation(code3);
      }
      if (code3 === codes.exclamationMark || code3 === codes.quotationMark || code3 === codes.ampersand || code3 === codes.apostrophe || code3 === codes.rightParenthesis || code3 === codes.asterisk || code3 === codes.comma || code3 === codes.dot || code3 === codes.colon || code3 === codes.semicolon || code3 === codes.lessThan || code3 === codes.questionMark || code3 === codes.rightSquareBracket || code3 === codes.underscore || code3 === codes.tilde) {
        return effects.check(trail, ok3, pathAtPunctuation)(code3);
      }
      if (code3 === codes.eof || markdownLineEndingOrSpace(code3) || unicodeWhitespace(code3)) {
        return ok3(code3);
      }
      effects.consume(code3);
      return pathInside;
    }
    function pathAtPunctuation(code3) {
      if (code3 === codes.rightParenthesis) {
        sizeClose++;
      }
      effects.consume(code3);
      return pathInside;
    }
  }
  function tokenizeTrail(effects, ok3, nok) {
    return trail2;
    function trail2(code3) {
      if (code3 === codes.exclamationMark || code3 === codes.quotationMark || code3 === codes.apostrophe || code3 === codes.rightParenthesis || code3 === codes.asterisk || code3 === codes.comma || code3 === codes.dot || code3 === codes.colon || code3 === codes.semicolon || code3 === codes.questionMark || code3 === codes.underscore || code3 === codes.tilde) {
        effects.consume(code3);
        return trail2;
      }
      if (code3 === codes.ampersand) {
        effects.consume(code3);
        return trailCharacterReferenceStart;
      }
      if (code3 === codes.rightSquareBracket) {
        effects.consume(code3);
        return trailBracketAfter;
      }
      if (code3 === codes.lessThan || code3 === codes.eof || markdownLineEndingOrSpace(code3) || unicodeWhitespace(code3)) {
        return ok3(code3);
      }
      return nok(code3);
    }
    function trailBracketAfter(code3) {
      if (code3 === codes.eof || code3 === codes.leftParenthesis || code3 === codes.leftSquareBracket || markdownLineEndingOrSpace(code3) || unicodeWhitespace(code3)) {
        return ok3(code3);
      }
      return trail2(code3);
    }
    function trailCharacterReferenceStart(code3) {
      return asciiAlpha(code3) ? trailCharacterReferenceInside(code3) : nok(code3);
    }
    function trailCharacterReferenceInside(code3) {
      if (code3 === codes.semicolon) {
        effects.consume(code3);
        return trail2;
      }
      if (asciiAlpha(code3)) {
        effects.consume(code3);
        return trailCharacterReferenceInside;
      }
      return nok(code3);
    }
  }
  function tokenizeEmailDomainDotTrail(effects, ok3, nok) {
    return start;
    function start(code3) {
      effects.consume(code3);
      return after;
    }
    function after(code3) {
      return asciiAlphanumeric(code3) ? nok(code3) : ok3(code3);
    }
  }
  function previousWww(code3) {
    return code3 === codes.eof || code3 === codes.leftParenthesis || code3 === codes.asterisk || code3 === codes.underscore || code3 === codes.leftSquareBracket || code3 === codes.rightSquareBracket || code3 === codes.tilde || markdownLineEndingOrSpace(code3);
  }
  function previousProtocol(code3) {
    return !asciiAlpha(code3);
  }
  function previousEmail(code3) {
    return !(code3 === codes.slash || gfmAtext(code3));
  }
  function gfmAtext(code3) {
    return code3 === codes.plusSign || code3 === codes.dash || code3 === codes.dot || code3 === codes.underscore || asciiAlphanumeric(code3);
  }
  function previousUnbalanced(events) {
    let index = events.length;
    let result = false;
    while (index--) {
      const token = events[index][1];
      if ((token.type === "labelLink" || token.type === "labelImage") && !token._balanced) {
        result = true;
        break;
      }
      if (token._gfmAutolinkLiteralWalkedInto) {
        result = false;
        break;
      }
    }
    if (events.length > 0 && !result) {
      events[events.length - 1][1]._gfmAutolinkLiteralWalkedInto = true;
    }
    return result;
  }
  // node_modules/micromark-util-resolve-all/index.js
  function resolveAll(constructs2, events, context) {
    const called = [];
    let index = -1;
    while (++index < constructs2.length) {
      const resolve = constructs2[index].resolveAll;
      if (resolve && !called.includes(resolve)) {
        events = resolve(events, context);
        called.push(resolve);
      }
    }
    return events;
  }

  // node_modules/micromark-core-commonmark/dev/lib/attention.js
  var attention = {
    name: "attention",
    resolveAll: resolveAllAttention,
    tokenize: tokenizeAttention
  };
  function resolveAllAttention(events, context) {
    let index = -1;
    let open;
    let group;
    let text3;
    let openingSequence;
    let closingSequence;
    let use;
    let nextEvents;
    let offset;
    while (++index < events.length) {
      if (events[index][0] === "enter" && events[index][1].type === "attentionSequence" && events[index][1]._close) {
        open = index;
        while (open--) {
          if (events[open][0] === "exit" && events[open][1].type === "attentionSequence" && events[open][1]._open && context.sliceSerialize(events[open][1]).charCodeAt(0) === context.sliceSerialize(events[index][1]).charCodeAt(0)) {
            if ((events[open][1]._close || events[index][1]._open) && (events[index][1].end.offset - events[index][1].start.offset) % 3 && !((events[open][1].end.offset - events[open][1].start.offset + events[index][1].end.offset - events[index][1].start.offset) % 3)) {
              continue;
            }
            use = events[open][1].end.offset - events[open][1].start.offset > 1 && events[index][1].end.offset - events[index][1].start.offset > 1 ? 2 : 1;
            const start = { ...events[open][1].end };
            const end = { ...events[index][1].start };
            movePoint(start, -use);
            movePoint(end, use);
            openingSequence = {
              type: use > 1 ? types.strongSequence : types.emphasisSequence,
              start,
              end: { ...events[open][1].end }
            };
            closingSequence = {
              type: use > 1 ? types.strongSequence : types.emphasisSequence,
              start: { ...events[index][1].start },
              end
            };
            text3 = {
              type: use > 1 ? types.strongText : types.emphasisText,
              start: { ...events[open][1].end },
              end: { ...events[index][1].start }
            };
            group = {
              type: use > 1 ? types.strong : types.emphasis,
              start: { ...openingSequence.start },
              end: { ...closingSequence.end }
            };
            events[open][1].end = { ...openingSequence.start };
            events[index][1].start = { ...closingSequence.end };
            nextEvents = [];
            if (events[open][1].end.offset - events[open][1].start.offset) {
              nextEvents = push(nextEvents, [
                ["enter", events[open][1], context],
                ["exit", events[open][1], context]
              ]);
            }
            nextEvents = push(nextEvents, [
              ["enter", group, context],
              ["enter", openingSequence, context],
              ["exit", openingSequence, context],
              ["enter", text3, context]
            ]);
            ok(context.parser.constructs.insideSpan.null, "expected `insideSpan` to be populated");
            nextEvents = push(nextEvents, resolveAll(context.parser.constructs.insideSpan.null, events.slice(open + 1, index), context));
            nextEvents = push(nextEvents, [
              ["exit", text3, context],
              ["enter", closingSequence, context],
              ["exit", closingSequence, context],
              ["exit", group, context]
            ]);
            if (events[index][1].end.offset - events[index][1].start.offset) {
              offset = 2;
              nextEvents = push(nextEvents, [
                ["enter", events[index][1], context],
                ["exit", events[index][1], context]
              ]);
            } else {
              offset = 0;
            }
            splice(events, open - 1, index - open + 3, nextEvents);
            index = open + nextEvents.length - offset - 2;
            break;
          }
        }
      }
    }
    index = -1;
    while (++index < events.length) {
      if (events[index][1].type === "attentionSequence") {
        events[index][1].type = "data";
      }
    }
    return events;
  }
  function tokenizeAttention(effects, ok3) {
    const attentionMarkers = this.parser.constructs.attentionMarkers.null;
    const previous2 = this.previous;
    const before = classifyCharacter(previous2);
    let marker;
    return start;
    function start(code3) {
      ok(code3 === codes.asterisk || code3 === codes.underscore, "expected asterisk or underscore");
      marker = code3;
      effects.enter("attentionSequence");
      return inside(code3);
    }
    function inside(code3) {
      if (code3 === marker) {
        effects.consume(code3);
        return inside;
      }
      const token = effects.exit("attentionSequence");
      const after = classifyCharacter(code3);
      ok(attentionMarkers, "expected `attentionMarkers` to be populated");
      const open = !after || after === constants.characterGroupPunctuation && before || attentionMarkers.includes(code3);
      const close = !before || before === constants.characterGroupPunctuation && after || attentionMarkers.includes(previous2);
      token._open = Boolean(marker === codes.asterisk ? open : open && (before || !close));
      token._close = Boolean(marker === codes.asterisk ? close : close && (after || !open));
      return ok3(code3);
    }
  }
  function movePoint(point, offset) {
    point.column += offset;
    point.offset += offset;
    point._bufferIndex += offset;
  }
  // node_modules/micromark-core-commonmark/dev/lib/autolink.js
  var autolink = { name: "autolink", tokenize: tokenizeAutolink };
  function tokenizeAutolink(effects, ok3, nok) {
    let size = 0;
    return start;
    function start(code3) {
      ok(code3 === codes.lessThan, "expected `<`");
      effects.enter(types.autolink);
      effects.enter(types.autolinkMarker);
      effects.consume(code3);
      effects.exit(types.autolinkMarker);
      effects.enter(types.autolinkProtocol);
      return open;
    }
    function open(code3) {
      if (asciiAlpha(code3)) {
        effects.consume(code3);
        return schemeOrEmailAtext;
      }
      if (code3 === codes.atSign) {
        return nok(code3);
      }
      return emailAtext(code3);
    }
    function schemeOrEmailAtext(code3) {
      if (code3 === codes.plusSign || code3 === codes.dash || code3 === codes.dot || asciiAlphanumeric(code3)) {
        size = 1;
        return schemeInsideOrEmailAtext(code3);
      }
      return emailAtext(code3);
    }
    function schemeInsideOrEmailAtext(code3) {
      if (code3 === codes.colon) {
        effects.consume(code3);
        size = 0;
        return urlInside;
      }
      if ((code3 === codes.plusSign || code3 === codes.dash || code3 === codes.dot || asciiAlphanumeric(code3)) && size++ < constants.autolinkSchemeSizeMax) {
        effects.consume(code3);
        return schemeInsideOrEmailAtext;
      }
      size = 0;
      return emailAtext(code3);
    }
    function urlInside(code3) {
      if (code3 === codes.greaterThan) {
        effects.exit(types.autolinkProtocol);
        effects.enter(types.autolinkMarker);
        effects.consume(code3);
        effects.exit(types.autolinkMarker);
        effects.exit(types.autolink);
        return ok3;
      }
      if (code3 === codes.eof || code3 === codes.space || code3 === codes.lessThan || asciiControl(code3)) {
        return nok(code3);
      }
      effects.consume(code3);
      return urlInside;
    }
    function emailAtext(code3) {
      if (code3 === codes.atSign) {
        effects.consume(code3);
        return emailAtSignOrDot;
      }
      if (asciiAtext(code3)) {
        effects.consume(code3);
        return emailAtext;
      }
      return nok(code3);
    }
    function emailAtSignOrDot(code3) {
      return asciiAlphanumeric(code3) ? emailLabel(code3) : nok(code3);
    }
    function emailLabel(code3) {
      if (code3 === codes.dot) {
        effects.consume(code3);
        size = 0;
        return emailAtSignOrDot;
      }
      if (code3 === codes.greaterThan) {
        effects.exit(types.autolinkProtocol).type = types.autolinkEmail;
        effects.enter(types.autolinkMarker);
        effects.consume(code3);
        effects.exit(types.autolinkMarker);
        effects.exit(types.autolink);
        return ok3;
      }
      return emailValue(code3);
    }
    function emailValue(code3) {
      if ((code3 === codes.dash || asciiAlphanumeric(code3)) && size++ < constants.autolinkDomainSizeMax) {
        const next = code3 === codes.dash ? emailValue : emailLabel;
        effects.consume(code3);
        return next;
      }
      return nok(code3);
    }
  }
  // node_modules/micromark-factory-space/dev/index.js
  function factorySpace(effects, ok3, type, max) {
    const limit = max ? max - 1 : Number.POSITIVE_INFINITY;
    let size = 0;
    return start;
    function start(code3) {
      if (markdownSpace(code3)) {
        effects.enter(type);
        return prefix(code3);
      }
      return ok3(code3);
    }
    function prefix(code3) {
      if (markdownSpace(code3) && size++ < limit) {
        effects.consume(code3);
        return prefix;
      }
      effects.exit(type);
      return ok3(code3);
    }
  }

  // node_modules/micromark-core-commonmark/dev/lib/blank-line.js
  var blankLine = { partial: true, tokenize: tokenizeBlankLine };
  function tokenizeBlankLine(effects, ok3, nok) {
    return start;
    function start(code3) {
      return markdownSpace(code3) ? factorySpace(effects, after, types.linePrefix)(code3) : after(code3);
    }
    function after(code3) {
      return code3 === codes.eof || markdownLineEnding(code3) ? ok3(code3) : nok(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/block-quote.js
  var blockQuote = {
    continuation: { tokenize: tokenizeBlockQuoteContinuation },
    exit: exit2,
    name: "blockQuote",
    tokenize: tokenizeBlockQuoteStart
  };
  function tokenizeBlockQuoteStart(effects, ok3, nok) {
    const self = this;
    return start;
    function start(code3) {
      if (code3 === codes.greaterThan) {
        const state = self.containerState;
        ok(state, "expected `containerState` to be defined in container");
        if (!state.open) {
          effects.enter(types.blockQuote, { _container: true });
          state.open = true;
        }
        effects.enter(types.blockQuotePrefix);
        effects.enter(types.blockQuoteMarker);
        effects.consume(code3);
        effects.exit(types.blockQuoteMarker);
        return after;
      }
      return nok(code3);
    }
    function after(code3) {
      if (markdownSpace(code3)) {
        effects.enter(types.blockQuotePrefixWhitespace);
        effects.consume(code3);
        effects.exit(types.blockQuotePrefixWhitespace);
        effects.exit(types.blockQuotePrefix);
        return ok3;
      }
      effects.exit(types.blockQuotePrefix);
      return ok3(code3);
    }
  }
  function tokenizeBlockQuoteContinuation(effects, ok3, nok) {
    const self = this;
    return contStart;
    function contStart(code3) {
      if (markdownSpace(code3)) {
        ok(self.parser.constructs.disable.null, "expected `disable.null` to be populated");
        return factorySpace(effects, contBefore, types.linePrefix, self.parser.constructs.disable.null.includes("codeIndented") ? undefined : constants.tabSize)(code3);
      }
      return contBefore(code3);
    }
    function contBefore(code3) {
      return effects.attempt(blockQuote, ok3, nok)(code3);
    }
  }
  function exit2(effects) {
    effects.exit(types.blockQuote);
  }
  // node_modules/micromark-core-commonmark/dev/lib/character-escape.js
  var characterEscape = {
    name: "characterEscape",
    tokenize: tokenizeCharacterEscape
  };
  function tokenizeCharacterEscape(effects, ok3, nok) {
    return start;
    function start(code3) {
      ok(code3 === codes.backslash, "expected `\\`");
      effects.enter(types.characterEscape);
      effects.enter(types.escapeMarker);
      effects.consume(code3);
      effects.exit(types.escapeMarker);
      return inside;
    }
    function inside(code3) {
      if (asciiPunctuation(code3)) {
        effects.enter(types.characterEscapeValue);
        effects.consume(code3);
        effects.exit(types.characterEscapeValue);
        effects.exit(types.characterEscape);
        return ok3;
      }
      return nok(code3);
    }
  }
  // node_modules/decode-named-character-reference/index.dom.js
  var element = document.createElement("i");
  function decodeNamedCharacterReference(value) {
    const characterReference = "&" + value + ";";
    element.innerHTML = characterReference;
    const character = element.textContent;
    if (character.charCodeAt(character.length - 1) === 59 && value !== "semi") {
      return false;
    }
    return character === characterReference ? false : character;
  }

  // node_modules/micromark-core-commonmark/dev/lib/character-reference.js
  var characterReference = {
    name: "characterReference",
    tokenize: tokenizeCharacterReference
  };
  function tokenizeCharacterReference(effects, ok3, nok) {
    const self = this;
    let size = 0;
    let max;
    let test;
    return start;
    function start(code3) {
      ok(code3 === codes.ampersand, "expected `&`");
      effects.enter(types.characterReference);
      effects.enter(types.characterReferenceMarker);
      effects.consume(code3);
      effects.exit(types.characterReferenceMarker);
      return open;
    }
    function open(code3) {
      if (code3 === codes.numberSign) {
        effects.enter(types.characterReferenceMarkerNumeric);
        effects.consume(code3);
        effects.exit(types.characterReferenceMarkerNumeric);
        return numeric;
      }
      effects.enter(types.characterReferenceValue);
      max = constants.characterReferenceNamedSizeMax;
      test = asciiAlphanumeric;
      return value(code3);
    }
    function numeric(code3) {
      if (code3 === codes.uppercaseX || code3 === codes.lowercaseX) {
        effects.enter(types.characterReferenceMarkerHexadecimal);
        effects.consume(code3);
        effects.exit(types.characterReferenceMarkerHexadecimal);
        effects.enter(types.characterReferenceValue);
        max = constants.characterReferenceHexadecimalSizeMax;
        test = asciiHexDigit;
        return value;
      }
      effects.enter(types.characterReferenceValue);
      max = constants.characterReferenceDecimalSizeMax;
      test = asciiDigit;
      return value(code3);
    }
    function value(code3) {
      if (code3 === codes.semicolon && size) {
        const token = effects.exit(types.characterReferenceValue);
        if (test === asciiAlphanumeric && !decodeNamedCharacterReference(self.sliceSerialize(token))) {
          return nok(code3);
        }
        effects.enter(types.characterReferenceMarker);
        effects.consume(code3);
        effects.exit(types.characterReferenceMarker);
        effects.exit(types.characterReference);
        return ok3;
      }
      if (test(code3) && size++ < max) {
        effects.consume(code3);
        return value;
      }
      return nok(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/code-fenced.js
  var nonLazyContinuation = {
    partial: true,
    tokenize: tokenizeNonLazyContinuation
  };
  var codeFenced = {
    concrete: true,
    name: "codeFenced",
    tokenize: tokenizeCodeFenced
  };
  function tokenizeCodeFenced(effects, ok3, nok) {
    const self = this;
    const closeStart = { partial: true, tokenize: tokenizeCloseStart };
    let initialPrefix = 0;
    let sizeOpen = 0;
    let marker;
    return start;
    function start(code3) {
      return beforeSequenceOpen(code3);
    }
    function beforeSequenceOpen(code3) {
      ok(code3 === codes.graveAccent || code3 === codes.tilde, "expected `` ` `` or `~`");
      const tail = self.events[self.events.length - 1];
      initialPrefix = tail && tail[1].type === types.linePrefix ? tail[2].sliceSerialize(tail[1], true).length : 0;
      marker = code3;
      effects.enter(types.codeFenced);
      effects.enter(types.codeFencedFence);
      effects.enter(types.codeFencedFenceSequence);
      return sequenceOpen(code3);
    }
    function sequenceOpen(code3) {
      if (code3 === marker) {
        sizeOpen++;
        effects.consume(code3);
        return sequenceOpen;
      }
      if (sizeOpen < constants.codeFencedSequenceSizeMin) {
        return nok(code3);
      }
      effects.exit(types.codeFencedFenceSequence);
      return markdownSpace(code3) ? factorySpace(effects, infoBefore, types.whitespace)(code3) : infoBefore(code3);
    }
    function infoBefore(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.codeFencedFence);
        return self.interrupt ? ok3(code3) : effects.check(nonLazyContinuation, atNonLazyBreak, after)(code3);
      }
      effects.enter(types.codeFencedFenceInfo);
      effects.enter(types.chunkString, { contentType: constants.contentTypeString });
      return info(code3);
    }
    function info(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.chunkString);
        effects.exit(types.codeFencedFenceInfo);
        return infoBefore(code3);
      }
      if (markdownSpace(code3)) {
        effects.exit(types.chunkString);
        effects.exit(types.codeFencedFenceInfo);
        return factorySpace(effects, metaBefore, types.whitespace)(code3);
      }
      if (code3 === codes.graveAccent && code3 === marker) {
        return nok(code3);
      }
      effects.consume(code3);
      return info;
    }
    function metaBefore(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        return infoBefore(code3);
      }
      effects.enter(types.codeFencedFenceMeta);
      effects.enter(types.chunkString, { contentType: constants.contentTypeString });
      return meta(code3);
    }
    function meta(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.chunkString);
        effects.exit(types.codeFencedFenceMeta);
        return infoBefore(code3);
      }
      if (code3 === codes.graveAccent && code3 === marker) {
        return nok(code3);
      }
      effects.consume(code3);
      return meta;
    }
    function atNonLazyBreak(code3) {
      ok(markdownLineEnding(code3), "expected eol");
      return effects.attempt(closeStart, after, contentBefore)(code3);
    }
    function contentBefore(code3) {
      ok(markdownLineEnding(code3), "expected eol");
      effects.enter(types.lineEnding);
      effects.consume(code3);
      effects.exit(types.lineEnding);
      return contentStart;
    }
    function contentStart(code3) {
      return initialPrefix > 0 && markdownSpace(code3) ? factorySpace(effects, beforeContentChunk, types.linePrefix, initialPrefix + 1)(code3) : beforeContentChunk(code3);
    }
    function beforeContentChunk(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        return effects.check(nonLazyContinuation, atNonLazyBreak, after)(code3);
      }
      effects.enter(types.codeFlowValue);
      return contentChunk(code3);
    }
    function contentChunk(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.codeFlowValue);
        return beforeContentChunk(code3);
      }
      effects.consume(code3);
      return contentChunk;
    }
    function after(code3) {
      effects.exit(types.codeFenced);
      return ok3(code3);
    }
    function tokenizeCloseStart(effects2, ok4, nok2) {
      let size = 0;
      return startBefore;
      function startBefore(code3) {
        ok(markdownLineEnding(code3), "expected eol");
        effects2.enter(types.lineEnding);
        effects2.consume(code3);
        effects2.exit(types.lineEnding);
        return start2;
      }
      function start2(code3) {
        ok(self.parser.constructs.disable.null, "expected `disable.null` to be populated");
        effects2.enter(types.codeFencedFence);
        return markdownSpace(code3) ? factorySpace(effects2, beforeSequenceClose, types.linePrefix, self.parser.constructs.disable.null.includes("codeIndented") ? undefined : constants.tabSize)(code3) : beforeSequenceClose(code3);
      }
      function beforeSequenceClose(code3) {
        if (code3 === marker) {
          effects2.enter(types.codeFencedFenceSequence);
          return sequenceClose(code3);
        }
        return nok2(code3);
      }
      function sequenceClose(code3) {
        if (code3 === marker) {
          size++;
          effects2.consume(code3);
          return sequenceClose;
        }
        if (size >= sizeOpen) {
          effects2.exit(types.codeFencedFenceSequence);
          return markdownSpace(code3) ? factorySpace(effects2, sequenceCloseAfter, types.whitespace)(code3) : sequenceCloseAfter(code3);
        }
        return nok2(code3);
      }
      function sequenceCloseAfter(code3) {
        if (code3 === codes.eof || markdownLineEnding(code3)) {
          effects2.exit(types.codeFencedFence);
          return ok4(code3);
        }
        return nok2(code3);
      }
    }
  }
  function tokenizeNonLazyContinuation(effects, ok3, nok) {
    const self = this;
    return start;
    function start(code3) {
      if (code3 === codes.eof) {
        return nok(code3);
      }
      ok(markdownLineEnding(code3), "expected eol");
      effects.enter(types.lineEnding);
      effects.consume(code3);
      effects.exit(types.lineEnding);
      return lineStart;
    }
    function lineStart(code3) {
      return self.parser.lazy[self.now().line] ? nok(code3) : ok3(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/code-indented.js
  var codeIndented = {
    name: "codeIndented",
    tokenize: tokenizeCodeIndented
  };
  var furtherStart = { partial: true, tokenize: tokenizeFurtherStart };
  function tokenizeCodeIndented(effects, ok3, nok) {
    const self = this;
    return start;
    function start(code3) {
      ok(markdownSpace(code3));
      effects.enter(types.codeIndented);
      return factorySpace(effects, afterPrefix, types.linePrefix, constants.tabSize + 1)(code3);
    }
    function afterPrefix(code3) {
      const tail = self.events[self.events.length - 1];
      return tail && tail[1].type === types.linePrefix && tail[2].sliceSerialize(tail[1], true).length >= constants.tabSize ? atBreak(code3) : nok(code3);
    }
    function atBreak(code3) {
      if (code3 === codes.eof) {
        return after(code3);
      }
      if (markdownLineEnding(code3)) {
        return effects.attempt(furtherStart, atBreak, after)(code3);
      }
      effects.enter(types.codeFlowValue);
      return inside(code3);
    }
    function inside(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.codeFlowValue);
        return atBreak(code3);
      }
      effects.consume(code3);
      return inside;
    }
    function after(code3) {
      effects.exit(types.codeIndented);
      return ok3(code3);
    }
  }
  function tokenizeFurtherStart(effects, ok3, nok) {
    const self = this;
    return furtherStart2;
    function furtherStart2(code3) {
      if (self.parser.lazy[self.now().line]) {
        return nok(code3);
      }
      if (markdownLineEnding(code3)) {
        effects.enter(types.lineEnding);
        effects.consume(code3);
        effects.exit(types.lineEnding);
        return furtherStart2;
      }
      return factorySpace(effects, afterPrefix, types.linePrefix, constants.tabSize + 1)(code3);
    }
    function afterPrefix(code3) {
      const tail = self.events[self.events.length - 1];
      return tail && tail[1].type === types.linePrefix && tail[2].sliceSerialize(tail[1], true).length >= constants.tabSize ? ok3(code3) : markdownLineEnding(code3) ? furtherStart2(code3) : nok(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/code-text.js
  var codeText = {
    name: "codeText",
    previous: previous2,
    resolve: resolveCodeText,
    tokenize: tokenizeCodeText
  };
  function resolveCodeText(events) {
    let tailExitIndex = events.length - 4;
    let headEnterIndex = 3;
    let index;
    let enter;
    if ((events[headEnterIndex][1].type === types.lineEnding || events[headEnterIndex][1].type === "space") && (events[tailExitIndex][1].type === types.lineEnding || events[tailExitIndex][1].type === "space")) {
      index = headEnterIndex;
      while (++index < tailExitIndex) {
        if (events[index][1].type === types.codeTextData) {
          events[headEnterIndex][1].type = types.codeTextPadding;
          events[tailExitIndex][1].type = types.codeTextPadding;
          headEnterIndex += 2;
          tailExitIndex -= 2;
          break;
        }
      }
    }
    index = headEnterIndex - 1;
    tailExitIndex++;
    while (++index <= tailExitIndex) {
      if (enter === undefined) {
        if (index !== tailExitIndex && events[index][1].type !== types.lineEnding) {
          enter = index;
        }
      } else if (index === tailExitIndex || events[index][1].type === types.lineEnding) {
        events[enter][1].type = types.codeTextData;
        if (index !== enter + 2) {
          events[enter][1].end = events[index - 1][1].end;
          events.splice(enter + 2, index - enter - 2);
          tailExitIndex -= index - enter - 2;
          index = enter + 2;
        }
        enter = undefined;
      }
    }
    return events;
  }
  function previous2(code3) {
    return code3 !== codes.graveAccent || this.events[this.events.length - 1][1].type === types.characterEscape;
  }
  function tokenizeCodeText(effects, ok3, nok) {
    const self = this;
    let sizeOpen = 0;
    let size;
    let token;
    return start;
    function start(code3) {
      ok(code3 === codes.graveAccent, "expected `` ` ``");
      ok(previous2.call(self, self.previous), "expected correct previous");
      effects.enter(types.codeText);
      effects.enter(types.codeTextSequence);
      return sequenceOpen(code3);
    }
    function sequenceOpen(code3) {
      if (code3 === codes.graveAccent) {
        effects.consume(code3);
        sizeOpen++;
        return sequenceOpen;
      }
      effects.exit(types.codeTextSequence);
      return between(code3);
    }
    function between(code3) {
      if (code3 === codes.eof) {
        return nok(code3);
      }
      if (code3 === codes.space) {
        effects.enter("space");
        effects.consume(code3);
        effects.exit("space");
        return between;
      }
      if (code3 === codes.graveAccent) {
        token = effects.enter(types.codeTextSequence);
        size = 0;
        return sequenceClose(code3);
      }
      if (markdownLineEnding(code3)) {
        effects.enter(types.lineEnding);
        effects.consume(code3);
        effects.exit(types.lineEnding);
        return between;
      }
      effects.enter(types.codeTextData);
      return data(code3);
    }
    function data(code3) {
      if (code3 === codes.eof || code3 === codes.space || code3 === codes.graveAccent || markdownLineEnding(code3)) {
        effects.exit(types.codeTextData);
        return between(code3);
      }
      effects.consume(code3);
      return data;
    }
    function sequenceClose(code3) {
      if (code3 === codes.graveAccent) {
        effects.consume(code3);
        size++;
        return sequenceClose;
      }
      if (size === sizeOpen) {
        effects.exit(types.codeTextSequence);
        effects.exit(types.codeText);
        return ok3(code3);
      }
      token.type = types.codeTextData;
      return data(code3);
    }
  }
  // node_modules/micromark-util-subtokenize/dev/lib/splice-buffer.js
  class SpliceBuffer {
    constructor(initial) {
      this.left = initial ? [...initial] : [];
      this.right = [];
    }
    get(index) {
      if (index < 0 || index >= this.left.length + this.right.length) {
        throw new RangeError("Cannot access index `" + index + "` in a splice buffer of size `" + (this.left.length + this.right.length) + "`");
      }
      if (index < this.left.length)
        return this.left[index];
      return this.right[this.right.length - index + this.left.length - 1];
    }
    get length() {
      return this.left.length + this.right.length;
    }
    shift() {
      this.setCursor(0);
      return this.right.pop();
    }
    slice(start, end) {
      const stop = end === null || end === undefined ? Number.POSITIVE_INFINITY : end;
      if (stop < this.left.length) {
        return this.left.slice(start, stop);
      }
      if (start > this.left.length) {
        return this.right.slice(this.right.length - stop + this.left.length, this.right.length - start + this.left.length).reverse();
      }
      return this.left.slice(start).concat(this.right.slice(this.right.length - stop + this.left.length).reverse());
    }
    splice(start, deleteCount, items) {
      const count = deleteCount || 0;
      this.setCursor(Math.trunc(start));
      const removed = this.right.splice(this.right.length - count, Number.POSITIVE_INFINITY);
      if (items)
        chunkedPush(this.left, items);
      return removed.reverse();
    }
    pop() {
      this.setCursor(Number.POSITIVE_INFINITY);
      return this.left.pop();
    }
    push(item) {
      this.setCursor(Number.POSITIVE_INFINITY);
      this.left.push(item);
    }
    pushMany(items) {
      this.setCursor(Number.POSITIVE_INFINITY);
      chunkedPush(this.left, items);
    }
    unshift(item) {
      this.setCursor(0);
      this.right.push(item);
    }
    unshiftMany(items) {
      this.setCursor(0);
      chunkedPush(this.right, items.reverse());
    }
    setCursor(n) {
      if (n === this.left.length || n > this.left.length && this.right.length === 0 || n < 0 && this.left.length === 0)
        return;
      if (n < this.left.length) {
        const removed = this.left.splice(n, Number.POSITIVE_INFINITY);
        chunkedPush(this.right, removed.reverse());
      } else {
        const removed = this.right.splice(this.left.length + this.right.length - n, Number.POSITIVE_INFINITY);
        chunkedPush(this.left, removed.reverse());
      }
    }
  }
  function chunkedPush(list2, right) {
    let chunkStart = 0;
    if (right.length < constants.v8MaxSafeChunkSize) {
      list2.push(...right);
    } else {
      while (chunkStart < right.length) {
        list2.push(...right.slice(chunkStart, chunkStart + constants.v8MaxSafeChunkSize));
        chunkStart += constants.v8MaxSafeChunkSize;
      }
    }
  }

  // node_modules/micromark-util-subtokenize/dev/index.js
  function subtokenize(eventsArray) {
    const jumps = {};
    let index = -1;
    let event;
    let lineIndex;
    let otherIndex;
    let otherEvent;
    let parameters;
    let subevents;
    let more;
    const events = new SpliceBuffer(eventsArray);
    while (++index < events.length) {
      while (index in jumps) {
        index = jumps[index];
      }
      event = events.get(index);
      if (index && event[1].type === types.chunkFlow && events.get(index - 1)[1].type === types.listItemPrefix) {
        ok(event[1]._tokenizer, "expected `_tokenizer` on subtokens");
        subevents = event[1]._tokenizer.events;
        otherIndex = 0;
        if (otherIndex < subevents.length && subevents[otherIndex][1].type === types.lineEndingBlank) {
          otherIndex += 2;
        }
        if (otherIndex < subevents.length && subevents[otherIndex][1].type === types.content) {
          while (++otherIndex < subevents.length) {
            if (subevents[otherIndex][1].type === types.content) {
              break;
            }
            if (subevents[otherIndex][1].type === types.chunkText) {
              subevents[otherIndex][1]._isInFirstContentOfListItem = true;
              otherIndex++;
            }
          }
        }
      }
      if (event[0] === "enter") {
        if (event[1].contentType) {
          Object.assign(jumps, subcontent(events, index));
          index = jumps[index];
          more = true;
        }
      } else if (event[1]._container) {
        otherIndex = index;
        lineIndex = undefined;
        while (otherIndex--) {
          otherEvent = events.get(otherIndex);
          if (otherEvent[1].type === types.lineEnding || otherEvent[1].type === types.lineEndingBlank) {
            if (otherEvent[0] === "enter") {
              if (lineIndex) {
                events.get(lineIndex)[1].type = types.lineEndingBlank;
              }
              otherEvent[1].type = types.lineEnding;
              lineIndex = otherIndex;
            }
          } else if (otherEvent[1].type === types.linePrefix || otherEvent[1].type === types.listItemIndent) {} else {
            break;
          }
        }
        if (lineIndex) {
          event[1].end = { ...events.get(lineIndex)[1].start };
          parameters = events.slice(lineIndex, index);
          parameters.unshift(event);
          events.splice(lineIndex, index - lineIndex + 1, parameters);
        }
      }
    }
    splice(eventsArray, 0, Number.POSITIVE_INFINITY, events.slice(0));
    return !more;
  }
  function subcontent(events, eventIndex) {
    const token = events.get(eventIndex)[1];
    const context = events.get(eventIndex)[2];
    let startPosition = eventIndex - 1;
    const startPositions = [];
    ok(token.contentType, "expected `contentType` on subtokens");
    let tokenizer = token._tokenizer;
    if (!tokenizer) {
      tokenizer = context.parser[token.contentType](token.start);
      if (token._contentTypeTextTrailing) {
        tokenizer._contentTypeTextTrailing = true;
      }
    }
    const childEvents = tokenizer.events;
    const jumps = [];
    const gaps = {};
    let stream;
    let previous3;
    let index = -1;
    let current = token;
    let adjust = 0;
    let start = 0;
    const breaks = [start];
    while (current) {
      while (events.get(++startPosition)[1] !== current) {}
      ok(!previous3 || current.previous === previous3, "expected previous to match");
      ok(!previous3 || previous3.next === current, "expected next to match");
      startPositions.push(startPosition);
      if (!current._tokenizer) {
        stream = context.sliceStream(current);
        if (!current.next) {
          stream.push(codes.eof);
        }
        if (previous3) {
          tokenizer.defineSkip(current.start);
        }
        if (current._isInFirstContentOfListItem) {
          tokenizer._gfmTasklistFirstContentOfListItem = true;
        }
        tokenizer.write(stream);
        if (current._isInFirstContentOfListItem) {
          tokenizer._gfmTasklistFirstContentOfListItem = undefined;
        }
      }
      previous3 = current;
      current = current.next;
    }
    current = token;
    while (++index < childEvents.length) {
      if (childEvents[index][0] === "exit" && childEvents[index - 1][0] === "enter" && childEvents[index][1].type === childEvents[index - 1][1].type && childEvents[index][1].start.line !== childEvents[index][1].end.line) {
        ok(current, "expected a current token");
        start = index + 1;
        breaks.push(start);
        current._tokenizer = undefined;
        current.previous = undefined;
        current = current.next;
      }
    }
    tokenizer.events = [];
    if (current) {
      current._tokenizer = undefined;
      current.previous = undefined;
      ok(!current.next, "expected no next token");
    } else {
      breaks.pop();
    }
    index = breaks.length;
    while (index--) {
      const slice = childEvents.slice(breaks[index], breaks[index + 1]);
      const start2 = startPositions.pop();
      ok(start2 !== undefined, "expected a start position when splicing");
      jumps.push([start2, start2 + slice.length - 1]);
      events.splice(start2, 2, slice);
    }
    jumps.reverse();
    index = -1;
    while (++index < jumps.length) {
      gaps[adjust + jumps[index][0]] = adjust + jumps[index][1];
      adjust += jumps[index][1] - jumps[index][0] - 1;
    }
    return gaps;
  }

  // node_modules/micromark-core-commonmark/dev/lib/content.js
  var content = { resolve: resolveContent, tokenize: tokenizeContent };
  var continuationConstruct = { partial: true, tokenize: tokenizeContinuation };
  function resolveContent(events) {
    subtokenize(events);
    return events;
  }
  function tokenizeContent(effects, ok3) {
    let previous3;
    return chunkStart;
    function chunkStart(code3) {
      ok(code3 !== codes.eof && !markdownLineEnding(code3), "expected no eof or eol");
      effects.enter(types.content);
      previous3 = effects.enter(types.chunkContent, {
        contentType: constants.contentTypeContent
      });
      return chunkInside(code3);
    }
    function chunkInside(code3) {
      if (code3 === codes.eof) {
        return contentEnd(code3);
      }
      if (markdownLineEnding(code3)) {
        return effects.check(continuationConstruct, contentContinue, contentEnd)(code3);
      }
      effects.consume(code3);
      return chunkInside;
    }
    function contentEnd(code3) {
      effects.exit(types.chunkContent);
      effects.exit(types.content);
      return ok3(code3);
    }
    function contentContinue(code3) {
      ok(markdownLineEnding(code3), "expected eol");
      effects.consume(code3);
      effects.exit(types.chunkContent);
      ok(previous3, "expected previous token");
      previous3.next = effects.enter(types.chunkContent, {
        contentType: constants.contentTypeContent,
        previous: previous3
      });
      previous3 = previous3.next;
      return chunkInside;
    }
  }
  function tokenizeContinuation(effects, ok3, nok) {
    const self = this;
    return startLookahead;
    function startLookahead(code3) {
      ok(markdownLineEnding(code3), "expected a line ending");
      effects.exit(types.chunkContent);
      effects.enter(types.lineEnding);
      effects.consume(code3);
      effects.exit(types.lineEnding);
      return factorySpace(effects, prefixed, types.linePrefix);
    }
    function prefixed(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        return nok(code3);
      }
      ok(self.parser.constructs.disable.null, "expected `disable.null` to be populated");
      const tail = self.events[self.events.length - 1];
      if (!self.parser.constructs.disable.null.includes("codeIndented") && tail && tail[1].type === types.linePrefix && tail[2].sliceSerialize(tail[1], true).length >= constants.tabSize) {
        return ok3(code3);
      }
      return effects.interrupt(self.parser.constructs.flow, nok, ok3)(code3);
    }
  }
  // node_modules/micromark-factory-destination/dev/index.js
  function factoryDestination(effects, ok3, nok, type, literalType, literalMarkerType, rawType, stringType, max) {
    const limit = max || Number.POSITIVE_INFINITY;
    let balance = 0;
    return start;
    function start(code3) {
      if (code3 === codes.lessThan) {
        effects.enter(type);
        effects.enter(literalType);
        effects.enter(literalMarkerType);
        effects.consume(code3);
        effects.exit(literalMarkerType);
        return enclosedBefore;
      }
      if (code3 === codes.eof || code3 === codes.space || code3 === codes.rightParenthesis || asciiControl(code3)) {
        return nok(code3);
      }
      effects.enter(type);
      effects.enter(rawType);
      effects.enter(stringType);
      effects.enter(types.chunkString, { contentType: constants.contentTypeString });
      return raw(code3);
    }
    function enclosedBefore(code3) {
      if (code3 === codes.greaterThan) {
        effects.enter(literalMarkerType);
        effects.consume(code3);
        effects.exit(literalMarkerType);
        effects.exit(literalType);
        effects.exit(type);
        return ok3;
      }
      effects.enter(stringType);
      effects.enter(types.chunkString, { contentType: constants.contentTypeString });
      return enclosed(code3);
    }
    function enclosed(code3) {
      if (code3 === codes.greaterThan) {
        effects.exit(types.chunkString);
        effects.exit(stringType);
        return enclosedBefore(code3);
      }
      if (code3 === codes.eof || code3 === codes.lessThan || markdownLineEnding(code3)) {
        return nok(code3);
      }
      effects.consume(code3);
      return code3 === codes.backslash ? enclosedEscape : enclosed;
    }
    function enclosedEscape(code3) {
      if (code3 === codes.lessThan || code3 === codes.greaterThan || code3 === codes.backslash) {
        effects.consume(code3);
        return enclosed;
      }
      return enclosed(code3);
    }
    function raw(code3) {
      if (!balance && (code3 === codes.eof || code3 === codes.rightParenthesis || markdownLineEndingOrSpace(code3))) {
        effects.exit(types.chunkString);
        effects.exit(stringType);
        effects.exit(rawType);
        effects.exit(type);
        return ok3(code3);
      }
      if (balance < limit && code3 === codes.leftParenthesis) {
        effects.consume(code3);
        balance++;
        return raw;
      }
      if (code3 === codes.rightParenthesis) {
        effects.consume(code3);
        balance--;
        return raw;
      }
      if (code3 === codes.eof || code3 === codes.space || code3 === codes.leftParenthesis || asciiControl(code3)) {
        return nok(code3);
      }
      effects.consume(code3);
      return code3 === codes.backslash ? rawEscape : raw;
    }
    function rawEscape(code3) {
      if (code3 === codes.leftParenthesis || code3 === codes.rightParenthesis || code3 === codes.backslash) {
        effects.consume(code3);
        return raw;
      }
      return raw(code3);
    }
  }

  // node_modules/micromark-factory-label/dev/index.js
  function factoryLabel(effects, ok3, nok, type, markerType, stringType) {
    const self = this;
    let size = 0;
    let seen;
    return start;
    function start(code3) {
      ok(code3 === codes.leftSquareBracket, "expected `[`");
      effects.enter(type);
      effects.enter(markerType);
      effects.consume(code3);
      effects.exit(markerType);
      effects.enter(stringType);
      return atBreak;
    }
    function atBreak(code3) {
      if (size > constants.linkReferenceSizeMax || code3 === codes.eof || code3 === codes.leftSquareBracket || code3 === codes.rightSquareBracket && !seen || code3 === codes.caret && !size && "_hiddenFootnoteSupport" in self.parser.constructs) {
        return nok(code3);
      }
      if (code3 === codes.rightSquareBracket) {
        effects.exit(stringType);
        effects.enter(markerType);
        effects.consume(code3);
        effects.exit(markerType);
        effects.exit(type);
        return ok3;
      }
      if (markdownLineEnding(code3)) {
        effects.enter(types.lineEnding);
        effects.consume(code3);
        effects.exit(types.lineEnding);
        return atBreak;
      }
      effects.enter(types.chunkString, { contentType: constants.contentTypeString });
      return labelInside(code3);
    }
    function labelInside(code3) {
      if (code3 === codes.eof || code3 === codes.leftSquareBracket || code3 === codes.rightSquareBracket || markdownLineEnding(code3) || size++ > constants.linkReferenceSizeMax) {
        effects.exit(types.chunkString);
        return atBreak(code3);
      }
      effects.consume(code3);
      if (!seen)
        seen = !markdownSpace(code3);
      return code3 === codes.backslash ? labelEscape : labelInside;
    }
    function labelEscape(code3) {
      if (code3 === codes.leftSquareBracket || code3 === codes.backslash || code3 === codes.rightSquareBracket) {
        effects.consume(code3);
        size++;
        return labelInside;
      }
      return labelInside(code3);
    }
  }

  // node_modules/micromark-factory-title/dev/index.js
  function factoryTitle(effects, ok3, nok, type, markerType, stringType) {
    let marker;
    return start;
    function start(code3) {
      if (code3 === codes.quotationMark || code3 === codes.apostrophe || code3 === codes.leftParenthesis) {
        effects.enter(type);
        effects.enter(markerType);
        effects.consume(code3);
        effects.exit(markerType);
        marker = code3 === codes.leftParenthesis ? codes.rightParenthesis : code3;
        return begin;
      }
      return nok(code3);
    }
    function begin(code3) {
      if (code3 === marker) {
        effects.enter(markerType);
        effects.consume(code3);
        effects.exit(markerType);
        effects.exit(type);
        return ok3;
      }
      effects.enter(stringType);
      return atBreak(code3);
    }
    function atBreak(code3) {
      if (code3 === marker) {
        effects.exit(stringType);
        return begin(marker);
      }
      if (code3 === codes.eof) {
        return nok(code3);
      }
      if (markdownLineEnding(code3)) {
        effects.enter(types.lineEnding);
        effects.consume(code3);
        effects.exit(types.lineEnding);
        return factorySpace(effects, atBreak, types.linePrefix);
      }
      effects.enter(types.chunkString, { contentType: constants.contentTypeString });
      return inside(code3);
    }
    function inside(code3) {
      if (code3 === marker || code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.chunkString);
        return atBreak(code3);
      }
      effects.consume(code3);
      return code3 === codes.backslash ? escape : inside;
    }
    function escape(code3) {
      if (code3 === marker || code3 === codes.backslash) {
        effects.consume(code3);
        return inside;
      }
      return inside(code3);
    }
  }

  // node_modules/micromark-factory-whitespace/dev/index.js
  function factoryWhitespace(effects, ok3) {
    let seen;
    return start;
    function start(code3) {
      if (markdownLineEnding(code3)) {
        effects.enter(types.lineEnding);
        effects.consume(code3);
        effects.exit(types.lineEnding);
        seen = true;
        return start;
      }
      if (markdownSpace(code3)) {
        return factorySpace(effects, start, seen ? types.linePrefix : types.lineSuffix)(code3);
      }
      return ok3(code3);
    }
  }

  // node_modules/micromark-core-commonmark/dev/lib/definition.js
  var definition2 = { name: "definition", tokenize: tokenizeDefinition };
  var titleBefore = { partial: true, tokenize: tokenizeTitleBefore };
  function tokenizeDefinition(effects, ok3, nok) {
    const self = this;
    let identifier;
    return start;
    function start(code3) {
      effects.enter(types.definition);
      return before(code3);
    }
    function before(code3) {
      ok(code3 === codes.leftSquareBracket, "expected `[`");
      return factoryLabel.call(self, effects, labelAfter, nok, types.definitionLabel, types.definitionLabelMarker, types.definitionLabelString)(code3);
    }
    function labelAfter(code3) {
      identifier = normalizeIdentifier(self.sliceSerialize(self.events[self.events.length - 1][1]).slice(1, -1));
      if (code3 === codes.colon) {
        effects.enter(types.definitionMarker);
        effects.consume(code3);
        effects.exit(types.definitionMarker);
        return markerAfter;
      }
      return nok(code3);
    }
    function markerAfter(code3) {
      return markdownLineEndingOrSpace(code3) ? factoryWhitespace(effects, destinationBefore)(code3) : destinationBefore(code3);
    }
    function destinationBefore(code3) {
      return factoryDestination(effects, destinationAfter, nok, types.definitionDestination, types.definitionDestinationLiteral, types.definitionDestinationLiteralMarker, types.definitionDestinationRaw, types.definitionDestinationString)(code3);
    }
    function destinationAfter(code3) {
      return effects.attempt(titleBefore, after, after)(code3);
    }
    function after(code3) {
      return markdownSpace(code3) ? factorySpace(effects, afterWhitespace, types.whitespace)(code3) : afterWhitespace(code3);
    }
    function afterWhitespace(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.definition);
        self.parser.defined.push(identifier);
        return ok3(code3);
      }
      return nok(code3);
    }
  }
  function tokenizeTitleBefore(effects, ok3, nok) {
    return titleBefore2;
    function titleBefore2(code3) {
      return markdownLineEndingOrSpace(code3) ? factoryWhitespace(effects, beforeMarker)(code3) : nok(code3);
    }
    function beforeMarker(code3) {
      return factoryTitle(effects, titleAfter, nok, types.definitionTitle, types.definitionTitleMarker, types.definitionTitleString)(code3);
    }
    function titleAfter(code3) {
      return markdownSpace(code3) ? factorySpace(effects, titleAfterOptionalWhitespace, types.whitespace)(code3) : titleAfterOptionalWhitespace(code3);
    }
    function titleAfterOptionalWhitespace(code3) {
      return code3 === codes.eof || markdownLineEnding(code3) ? ok3(code3) : nok(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/hard-break-escape.js
  var hardBreakEscape = {
    name: "hardBreakEscape",
    tokenize: tokenizeHardBreakEscape
  };
  function tokenizeHardBreakEscape(effects, ok3, nok) {
    return start;
    function start(code3) {
      ok(code3 === codes.backslash, "expected `\\`");
      effects.enter(types.hardBreakEscape);
      effects.consume(code3);
      return after;
    }
    function after(code3) {
      if (markdownLineEnding(code3)) {
        effects.exit(types.hardBreakEscape);
        return ok3(code3);
      }
      return nok(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/heading-atx.js
  var headingAtx = {
    name: "headingAtx",
    resolve: resolveHeadingAtx,
    tokenize: tokenizeHeadingAtx
  };
  function resolveHeadingAtx(events, context) {
    let contentEnd = events.length - 2;
    let contentStart = 3;
    let content2;
    let text3;
    if (events[contentStart][1].type === types.whitespace) {
      contentStart += 2;
    }
    if (contentEnd - 2 > contentStart && events[contentEnd][1].type === types.whitespace) {
      contentEnd -= 2;
    }
    if (events[contentEnd][1].type === types.atxHeadingSequence && (contentStart === contentEnd - 1 || contentEnd - 4 > contentStart && events[contentEnd - 2][1].type === types.whitespace)) {
      contentEnd -= contentStart + 1 === contentEnd ? 2 : 4;
    }
    if (contentEnd > contentStart) {
      content2 = {
        type: types.atxHeadingText,
        start: events[contentStart][1].start,
        end: events[contentEnd][1].end
      };
      text3 = {
        type: types.chunkText,
        start: events[contentStart][1].start,
        end: events[contentEnd][1].end,
        contentType: constants.contentTypeText
      };
      splice(events, contentStart, contentEnd - contentStart + 1, [
        ["enter", content2, context],
        ["enter", text3, context],
        ["exit", text3, context],
        ["exit", content2, context]
      ]);
    }
    return events;
  }
  function tokenizeHeadingAtx(effects, ok3, nok) {
    let size = 0;
    return start;
    function start(code3) {
      effects.enter(types.atxHeading);
      return before(code3);
    }
    function before(code3) {
      ok(code3 === codes.numberSign, "expected `#`");
      effects.enter(types.atxHeadingSequence);
      return sequenceOpen(code3);
    }
    function sequenceOpen(code3) {
      if (code3 === codes.numberSign && size++ < constants.atxHeadingOpeningFenceSizeMax) {
        effects.consume(code3);
        return sequenceOpen;
      }
      if (code3 === codes.eof || markdownLineEndingOrSpace(code3)) {
        effects.exit(types.atxHeadingSequence);
        return atBreak(code3);
      }
      return nok(code3);
    }
    function atBreak(code3) {
      if (code3 === codes.numberSign) {
        effects.enter(types.atxHeadingSequence);
        return sequenceFurther(code3);
      }
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.atxHeading);
        return ok3(code3);
      }
      if (markdownSpace(code3)) {
        return factorySpace(effects, atBreak, types.whitespace)(code3);
      }
      effects.enter(types.atxHeadingText);
      return data(code3);
    }
    function sequenceFurther(code3) {
      if (code3 === codes.numberSign) {
        effects.consume(code3);
        return sequenceFurther;
      }
      effects.exit(types.atxHeadingSequence);
      return atBreak(code3);
    }
    function data(code3) {
      if (code3 === codes.eof || code3 === codes.numberSign || markdownLineEndingOrSpace(code3)) {
        effects.exit(types.atxHeadingText);
        return atBreak(code3);
      }
      effects.consume(code3);
      return data;
    }
  }
  // node_modules/micromark-util-html-tag-name/index.js
  var htmlBlockNames = [
    "address",
    "article",
    "aside",
    "base",
    "basefont",
    "blockquote",
    "body",
    "caption",
    "center",
    "col",
    "colgroup",
    "dd",
    "details",
    "dialog",
    "dir",
    "div",
    "dl",
    "dt",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "form",
    "frame",
    "frameset",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "head",
    "header",
    "hr",
    "html",
    "iframe",
    "legend",
    "li",
    "link",
    "main",
    "menu",
    "menuitem",
    "nav",
    "noframes",
    "ol",
    "optgroup",
    "option",
    "p",
    "param",
    "search",
    "section",
    "summary",
    "table",
    "tbody",
    "td",
    "tfoot",
    "th",
    "thead",
    "title",
    "tr",
    "track",
    "ul"
  ];
  var htmlRawNames = ["pre", "script", "style", "textarea"];

  // node_modules/micromark-core-commonmark/dev/lib/html-flow.js
  var htmlFlow = {
    concrete: true,
    name: "htmlFlow",
    resolveTo: resolveToHtmlFlow,
    tokenize: tokenizeHtmlFlow
  };
  var blankLineBefore = { partial: true, tokenize: tokenizeBlankLineBefore };
  var nonLazyContinuationStart = {
    partial: true,
    tokenize: tokenizeNonLazyContinuationStart
  };
  function resolveToHtmlFlow(events) {
    let index = events.length;
    while (index--) {
      if (events[index][0] === "enter" && events[index][1].type === types.htmlFlow) {
        break;
      }
    }
    if (index > 1 && events[index - 2][1].type === types.linePrefix) {
      events[index][1].start = events[index - 2][1].start;
      events[index + 1][1].start = events[index - 2][1].start;
      events.splice(index - 2, 2);
    }
    return events;
  }
  function tokenizeHtmlFlow(effects, ok3, nok) {
    const self = this;
    let marker;
    let closingTag;
    let buffer;
    let index;
    let markerB;
    return start;
    function start(code3) {
      return before(code3);
    }
    function before(code3) {
      ok(code3 === codes.lessThan, "expected `<`");
      effects.enter(types.htmlFlow);
      effects.enter(types.htmlFlowData);
      effects.consume(code3);
      return open;
    }
    function open(code3) {
      if (code3 === codes.exclamationMark) {
        effects.consume(code3);
        return declarationOpen;
      }
      if (code3 === codes.slash) {
        effects.consume(code3);
        closingTag = true;
        return tagCloseStart;
      }
      if (code3 === codes.questionMark) {
        effects.consume(code3);
        marker = constants.htmlInstruction;
        return self.interrupt ? ok3 : continuationDeclarationInside;
      }
      if (asciiAlpha(code3)) {
        ok(code3 !== null);
        effects.consume(code3);
        buffer = String.fromCharCode(code3);
        return tagName;
      }
      return nok(code3);
    }
    function declarationOpen(code3) {
      if (code3 === codes.dash) {
        effects.consume(code3);
        marker = constants.htmlComment;
        return commentOpenInside;
      }
      if (code3 === codes.leftSquareBracket) {
        effects.consume(code3);
        marker = constants.htmlCdata;
        index = 0;
        return cdataOpenInside;
      }
      if (asciiAlpha(code3)) {
        effects.consume(code3);
        marker = constants.htmlDeclaration;
        return self.interrupt ? ok3 : continuationDeclarationInside;
      }
      return nok(code3);
    }
    function commentOpenInside(code3) {
      if (code3 === codes.dash) {
        effects.consume(code3);
        return self.interrupt ? ok3 : continuationDeclarationInside;
      }
      return nok(code3);
    }
    function cdataOpenInside(code3) {
      const value = constants.cdataOpeningString;
      if (code3 === value.charCodeAt(index++)) {
        effects.consume(code3);
        if (index === value.length) {
          return self.interrupt ? ok3 : continuation;
        }
        return cdataOpenInside;
      }
      return nok(code3);
    }
    function tagCloseStart(code3) {
      if (asciiAlpha(code3)) {
        ok(code3 !== null);
        effects.consume(code3);
        buffer = String.fromCharCode(code3);
        return tagName;
      }
      return nok(code3);
    }
    function tagName(code3) {
      if (code3 === codes.eof || code3 === codes.slash || code3 === codes.greaterThan || markdownLineEndingOrSpace(code3)) {
        const slash = code3 === codes.slash;
        const name = buffer.toLowerCase();
        if (!slash && !closingTag && htmlRawNames.includes(name)) {
          marker = constants.htmlRaw;
          return self.interrupt ? ok3(code3) : continuation(code3);
        }
        if (htmlBlockNames.includes(buffer.toLowerCase())) {
          marker = constants.htmlBasic;
          if (slash) {
            effects.consume(code3);
            return basicSelfClosing;
          }
          return self.interrupt ? ok3(code3) : continuation(code3);
        }
        marker = constants.htmlComplete;
        return self.interrupt && !self.parser.lazy[self.now().line] ? nok(code3) : closingTag ? completeClosingTagAfter(code3) : completeAttributeNameBefore(code3);
      }
      if (code3 === codes.dash || asciiAlphanumeric(code3)) {
        effects.consume(code3);
        buffer += String.fromCharCode(code3);
        return tagName;
      }
      return nok(code3);
    }
    function basicSelfClosing(code3) {
      if (code3 === codes.greaterThan) {
        effects.consume(code3);
        return self.interrupt ? ok3 : continuation;
      }
      return nok(code3);
    }
    function completeClosingTagAfter(code3) {
      if (markdownSpace(code3)) {
        effects.consume(code3);
        return completeClosingTagAfter;
      }
      return completeEnd(code3);
    }
    function completeAttributeNameBefore(code3) {
      if (code3 === codes.slash) {
        effects.consume(code3);
        return completeEnd;
      }
      if (code3 === codes.colon || code3 === codes.underscore || asciiAlpha(code3)) {
        effects.consume(code3);
        return completeAttributeName;
      }
      if (markdownSpace(code3)) {
        effects.consume(code3);
        return completeAttributeNameBefore;
      }
      return completeEnd(code3);
    }
    function completeAttributeName(code3) {
      if (code3 === codes.dash || code3 === codes.dot || code3 === codes.colon || code3 === codes.underscore || asciiAlphanumeric(code3)) {
        effects.consume(code3);
        return completeAttributeName;
      }
      return completeAttributeNameAfter(code3);
    }
    function completeAttributeNameAfter(code3) {
      if (code3 === codes.equalsTo) {
        effects.consume(code3);
        return completeAttributeValueBefore;
      }
      if (markdownSpace(code3)) {
        effects.consume(code3);
        return completeAttributeNameAfter;
      }
      return completeAttributeNameBefore(code3);
    }
    function completeAttributeValueBefore(code3) {
      if (code3 === codes.eof || code3 === codes.lessThan || code3 === codes.equalsTo || code3 === codes.greaterThan || code3 === codes.graveAccent) {
        return nok(code3);
      }
      if (code3 === codes.quotationMark || code3 === codes.apostrophe) {
        effects.consume(code3);
        markerB = code3;
        return completeAttributeValueQuoted;
      }
      if (markdownSpace(code3)) {
        effects.consume(code3);
        return completeAttributeValueBefore;
      }
      return completeAttributeValueUnquoted(code3);
    }
    function completeAttributeValueQuoted(code3) {
      if (code3 === markerB) {
        effects.consume(code3);
        markerB = null;
        return completeAttributeValueQuotedAfter;
      }
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        return nok(code3);
      }
      effects.consume(code3);
      return completeAttributeValueQuoted;
    }
    function completeAttributeValueUnquoted(code3) {
      if (code3 === codes.eof || code3 === codes.quotationMark || code3 === codes.apostrophe || code3 === codes.slash || code3 === codes.lessThan || code3 === codes.equalsTo || code3 === codes.greaterThan || code3 === codes.graveAccent || markdownLineEndingOrSpace(code3)) {
        return completeAttributeNameAfter(code3);
      }
      effects.consume(code3);
      return completeAttributeValueUnquoted;
    }
    function completeAttributeValueQuotedAfter(code3) {
      if (code3 === codes.slash || code3 === codes.greaterThan || markdownSpace(code3)) {
        return completeAttributeNameBefore(code3);
      }
      return nok(code3);
    }
    function completeEnd(code3) {
      if (code3 === codes.greaterThan) {
        effects.consume(code3);
        return completeAfter;
      }
      return nok(code3);
    }
    function completeAfter(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        return continuation(code3);
      }
      if (markdownSpace(code3)) {
        effects.consume(code3);
        return completeAfter;
      }
      return nok(code3);
    }
    function continuation(code3) {
      if (code3 === codes.dash && marker === constants.htmlComment) {
        effects.consume(code3);
        return continuationCommentInside;
      }
      if (code3 === codes.lessThan && marker === constants.htmlRaw) {
        effects.consume(code3);
        return continuationRawTagOpen;
      }
      if (code3 === codes.greaterThan && marker === constants.htmlDeclaration) {
        effects.consume(code3);
        return continuationClose;
      }
      if (code3 === codes.questionMark && marker === constants.htmlInstruction) {
        effects.consume(code3);
        return continuationDeclarationInside;
      }
      if (code3 === codes.rightSquareBracket && marker === constants.htmlCdata) {
        effects.consume(code3);
        return continuationCdataInside;
      }
      if (markdownLineEnding(code3) && (marker === constants.htmlBasic || marker === constants.htmlComplete)) {
        effects.exit(types.htmlFlowData);
        return effects.check(blankLineBefore, continuationAfter, continuationStart)(code3);
      }
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.htmlFlowData);
        return continuationStart(code3);
      }
      effects.consume(code3);
      return continuation;
    }
    function continuationStart(code3) {
      return effects.check(nonLazyContinuationStart, continuationStartNonLazy, continuationAfter)(code3);
    }
    function continuationStartNonLazy(code3) {
      ok(markdownLineEnding(code3));
      effects.enter(types.lineEnding);
      effects.consume(code3);
      effects.exit(types.lineEnding);
      return continuationBefore;
    }
    function continuationBefore(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        return continuationStart(code3);
      }
      effects.enter(types.htmlFlowData);
      return continuation(code3);
    }
    function continuationCommentInside(code3) {
      if (code3 === codes.dash) {
        effects.consume(code3);
        return continuationDeclarationInside;
      }
      return continuation(code3);
    }
    function continuationRawTagOpen(code3) {
      if (code3 === codes.slash) {
        effects.consume(code3);
        buffer = "";
        return continuationRawEndTag;
      }
      return continuation(code3);
    }
    function continuationRawEndTag(code3) {
      if (code3 === codes.greaterThan) {
        const name = buffer.toLowerCase();
        if (htmlRawNames.includes(name)) {
          effects.consume(code3);
          return continuationClose;
        }
        return continuation(code3);
      }
      if (asciiAlpha(code3) && buffer.length < constants.htmlRawSizeMax) {
        ok(code3 !== null);
        effects.consume(code3);
        buffer += String.fromCharCode(code3);
        return continuationRawEndTag;
      }
      return continuation(code3);
    }
    function continuationCdataInside(code3) {
      if (code3 === codes.rightSquareBracket) {
        effects.consume(code3);
        return continuationDeclarationInside;
      }
      return continuation(code3);
    }
    function continuationDeclarationInside(code3) {
      if (code3 === codes.greaterThan) {
        effects.consume(code3);
        return continuationClose;
      }
      if (code3 === codes.dash && marker === constants.htmlComment) {
        effects.consume(code3);
        return continuationDeclarationInside;
      }
      return continuation(code3);
    }
    function continuationClose(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.htmlFlowData);
        return continuationAfter(code3);
      }
      effects.consume(code3);
      return continuationClose;
    }
    function continuationAfter(code3) {
      effects.exit(types.htmlFlow);
      return ok3(code3);
    }
  }
  function tokenizeNonLazyContinuationStart(effects, ok3, nok) {
    const self = this;
    return start;
    function start(code3) {
      if (markdownLineEnding(code3)) {
        effects.enter(types.lineEnding);
        effects.consume(code3);
        effects.exit(types.lineEnding);
        return after;
      }
      return nok(code3);
    }
    function after(code3) {
      return self.parser.lazy[self.now().line] ? nok(code3) : ok3(code3);
    }
  }
  function tokenizeBlankLineBefore(effects, ok3, nok) {
    return start;
    function start(code3) {
      ok(markdownLineEnding(code3), "expected a line ending");
      effects.enter(types.lineEnding);
      effects.consume(code3);
      effects.exit(types.lineEnding);
      return effects.attempt(blankLine, ok3, nok);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/html-text.js
  var htmlText = { name: "htmlText", tokenize: tokenizeHtmlText };
  function tokenizeHtmlText(effects, ok3, nok) {
    const self = this;
    let marker;
    let index;
    let returnState;
    return start;
    function start(code3) {
      ok(code3 === codes.lessThan, "expected `<`");
      effects.enter(types.htmlText);
      effects.enter(types.htmlTextData);
      effects.consume(code3);
      return open;
    }
    function open(code3) {
      if (code3 === codes.exclamationMark) {
        effects.consume(code3);
        return declarationOpen;
      }
      if (code3 === codes.slash) {
        effects.consume(code3);
        return tagCloseStart;
      }
      if (code3 === codes.questionMark) {
        effects.consume(code3);
        return instruction;
      }
      if (asciiAlpha(code3)) {
        effects.consume(code3);
        return tagOpen;
      }
      return nok(code3);
    }
    function declarationOpen(code3) {
      if (code3 === codes.dash) {
        effects.consume(code3);
        return commentOpenInside;
      }
      if (code3 === codes.leftSquareBracket) {
        effects.consume(code3);
        index = 0;
        return cdataOpenInside;
      }
      if (asciiAlpha(code3)) {
        effects.consume(code3);
        return declaration;
      }
      return nok(code3);
    }
    function commentOpenInside(code3) {
      if (code3 === codes.dash) {
        effects.consume(code3);
        return commentEnd;
      }
      return nok(code3);
    }
    function comment(code3) {
      if (code3 === codes.eof) {
        return nok(code3);
      }
      if (code3 === codes.dash) {
        effects.consume(code3);
        return commentClose;
      }
      if (markdownLineEnding(code3)) {
        returnState = comment;
        return lineEndingBefore(code3);
      }
      effects.consume(code3);
      return comment;
    }
    function commentClose(code3) {
      if (code3 === codes.dash) {
        effects.consume(code3);
        return commentEnd;
      }
      return comment(code3);
    }
    function commentEnd(code3) {
      return code3 === codes.greaterThan ? end(code3) : code3 === codes.dash ? commentClose(code3) : comment(code3);
    }
    function cdataOpenInside(code3) {
      const value = constants.cdataOpeningString;
      if (code3 === value.charCodeAt(index++)) {
        effects.consume(code3);
        return index === value.length ? cdata : cdataOpenInside;
      }
      return nok(code3);
    }
    function cdata(code3) {
      if (code3 === codes.eof) {
        return nok(code3);
      }
      if (code3 === codes.rightSquareBracket) {
        effects.consume(code3);
        return cdataClose;
      }
      if (markdownLineEnding(code3)) {
        returnState = cdata;
        return lineEndingBefore(code3);
      }
      effects.consume(code3);
      return cdata;
    }
    function cdataClose(code3) {
      if (code3 === codes.rightSquareBracket) {
        effects.consume(code3);
        return cdataEnd;
      }
      return cdata(code3);
    }
    function cdataEnd(code3) {
      if (code3 === codes.greaterThan) {
        return end(code3);
      }
      if (code3 === codes.rightSquareBracket) {
        effects.consume(code3);
        return cdataEnd;
      }
      return cdata(code3);
    }
    function declaration(code3) {
      if (code3 === codes.eof || code3 === codes.greaterThan) {
        return end(code3);
      }
      if (markdownLineEnding(code3)) {
        returnState = declaration;
        return lineEndingBefore(code3);
      }
      effects.consume(code3);
      return declaration;
    }
    function instruction(code3) {
      if (code3 === codes.eof) {
        return nok(code3);
      }
      if (code3 === codes.questionMark) {
        effects.consume(code3);
        return instructionClose;
      }
      if (markdownLineEnding(code3)) {
        returnState = instruction;
        return lineEndingBefore(code3);
      }
      effects.consume(code3);
      return instruction;
    }
    function instructionClose(code3) {
      return code3 === codes.greaterThan ? end(code3) : instruction(code3);
    }
    function tagCloseStart(code3) {
      if (asciiAlpha(code3)) {
        effects.consume(code3);
        return tagClose;
      }
      return nok(code3);
    }
    function tagClose(code3) {
      if (code3 === codes.dash || asciiAlphanumeric(code3)) {
        effects.consume(code3);
        return tagClose;
      }
      return tagCloseBetween(code3);
    }
    function tagCloseBetween(code3) {
      if (markdownLineEnding(code3)) {
        returnState = tagCloseBetween;
        return lineEndingBefore(code3);
      }
      if (markdownSpace(code3)) {
        effects.consume(code3);
        return tagCloseBetween;
      }
      return end(code3);
    }
    function tagOpen(code3) {
      if (code3 === codes.dash || asciiAlphanumeric(code3)) {
        effects.consume(code3);
        return tagOpen;
      }
      if (code3 === codes.slash || code3 === codes.greaterThan || markdownLineEndingOrSpace(code3)) {
        return tagOpenBetween(code3);
      }
      return nok(code3);
    }
    function tagOpenBetween(code3) {
      if (code3 === codes.slash) {
        effects.consume(code3);
        return end;
      }
      if (code3 === codes.colon || code3 === codes.underscore || asciiAlpha(code3)) {
        effects.consume(code3);
        return tagOpenAttributeName;
      }
      if (markdownLineEnding(code3)) {
        returnState = tagOpenBetween;
        return lineEndingBefore(code3);
      }
      if (markdownSpace(code3)) {
        effects.consume(code3);
        return tagOpenBetween;
      }
      return end(code3);
    }
    function tagOpenAttributeName(code3) {
      if (code3 === codes.dash || code3 === codes.dot || code3 === codes.colon || code3 === codes.underscore || asciiAlphanumeric(code3)) {
        effects.consume(code3);
        return tagOpenAttributeName;
      }
      return tagOpenAttributeNameAfter(code3);
    }
    function tagOpenAttributeNameAfter(code3) {
      if (code3 === codes.equalsTo) {
        effects.consume(code3);
        return tagOpenAttributeValueBefore;
      }
      if (markdownLineEnding(code3)) {
        returnState = tagOpenAttributeNameAfter;
        return lineEndingBefore(code3);
      }
      if (markdownSpace(code3)) {
        effects.consume(code3);
        return tagOpenAttributeNameAfter;
      }
      return tagOpenBetween(code3);
    }
    function tagOpenAttributeValueBefore(code3) {
      if (code3 === codes.eof || code3 === codes.lessThan || code3 === codes.equalsTo || code3 === codes.greaterThan || code3 === codes.graveAccent) {
        return nok(code3);
      }
      if (code3 === codes.quotationMark || code3 === codes.apostrophe) {
        effects.consume(code3);
        marker = code3;
        return tagOpenAttributeValueQuoted;
      }
      if (markdownLineEnding(code3)) {
        returnState = tagOpenAttributeValueBefore;
        return lineEndingBefore(code3);
      }
      if (markdownSpace(code3)) {
        effects.consume(code3);
        return tagOpenAttributeValueBefore;
      }
      effects.consume(code3);
      return tagOpenAttributeValueUnquoted;
    }
    function tagOpenAttributeValueQuoted(code3) {
      if (code3 === marker) {
        effects.consume(code3);
        marker = undefined;
        return tagOpenAttributeValueQuotedAfter;
      }
      if (code3 === codes.eof) {
        return nok(code3);
      }
      if (markdownLineEnding(code3)) {
        returnState = tagOpenAttributeValueQuoted;
        return lineEndingBefore(code3);
      }
      effects.consume(code3);
      return tagOpenAttributeValueQuoted;
    }
    function tagOpenAttributeValueUnquoted(code3) {
      if (code3 === codes.eof || code3 === codes.quotationMark || code3 === codes.apostrophe || code3 === codes.lessThan || code3 === codes.equalsTo || code3 === codes.graveAccent) {
        return nok(code3);
      }
      if (code3 === codes.slash || code3 === codes.greaterThan || markdownLineEndingOrSpace(code3)) {
        return tagOpenBetween(code3);
      }
      effects.consume(code3);
      return tagOpenAttributeValueUnquoted;
    }
    function tagOpenAttributeValueQuotedAfter(code3) {
      if (code3 === codes.slash || code3 === codes.greaterThan || markdownLineEndingOrSpace(code3)) {
        return tagOpenBetween(code3);
      }
      return nok(code3);
    }
    function end(code3) {
      if (code3 === codes.greaterThan) {
        effects.consume(code3);
        effects.exit(types.htmlTextData);
        effects.exit(types.htmlText);
        return ok3;
      }
      return nok(code3);
    }
    function lineEndingBefore(code3) {
      ok(returnState, "expected return state");
      ok(markdownLineEnding(code3), "expected eol");
      effects.exit(types.htmlTextData);
      effects.enter(types.lineEnding);
      effects.consume(code3);
      effects.exit(types.lineEnding);
      return lineEndingAfter;
    }
    function lineEndingAfter(code3) {
      ok(self.parser.constructs.disable.null, "expected `disable.null` to be populated");
      return markdownSpace(code3) ? factorySpace(effects, lineEndingAfterPrefix, types.linePrefix, self.parser.constructs.disable.null.includes("codeIndented") ? undefined : constants.tabSize)(code3) : lineEndingAfterPrefix(code3);
    }
    function lineEndingAfterPrefix(code3) {
      effects.enter(types.htmlTextData);
      return returnState(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/label-end.js
  var labelEnd = {
    name: "labelEnd",
    resolveAll: resolveAllLabelEnd,
    resolveTo: resolveToLabelEnd,
    tokenize: tokenizeLabelEnd
  };
  var resourceConstruct = { tokenize: tokenizeResource };
  var referenceFullConstruct = { tokenize: tokenizeReferenceFull };
  var referenceCollapsedConstruct = { tokenize: tokenizeReferenceCollapsed };
  function resolveAllLabelEnd(events) {
    let index = -1;
    const newEvents = [];
    while (++index < events.length) {
      const token = events[index][1];
      newEvents.push(events[index]);
      if (token.type === types.labelImage || token.type === types.labelLink || token.type === types.labelEnd) {
        const offset = token.type === types.labelImage ? 4 : 2;
        token.type = types.data;
        index += offset;
      }
    }
    if (events.length !== newEvents.length) {
      splice(events, 0, events.length, newEvents);
    }
    return events;
  }
  function resolveToLabelEnd(events, context) {
    let index = events.length;
    let offset = 0;
    let token;
    let open;
    let close;
    let media;
    while (index--) {
      token = events[index][1];
      if (open) {
        if (token.type === types.link || token.type === types.labelLink && token._inactive) {
          break;
        }
        if (events[index][0] === "enter" && token.type === types.labelLink) {
          token._inactive = true;
        }
      } else if (close) {
        if (events[index][0] === "enter" && (token.type === types.labelImage || token.type === types.labelLink) && !token._balanced) {
          open = index;
          if (token.type !== types.labelLink) {
            offset = 2;
            break;
          }
        }
      } else if (token.type === types.labelEnd) {
        close = index;
      }
    }
    ok(open !== undefined, "`open` is supposed to be found");
    ok(close !== undefined, "`close` is supposed to be found");
    const group = {
      type: events[open][1].type === types.labelLink ? types.link : types.image,
      start: { ...events[open][1].start },
      end: { ...events[events.length - 1][1].end }
    };
    const label = {
      type: types.label,
      start: { ...events[open][1].start },
      end: { ...events[close][1].end }
    };
    const text3 = {
      type: types.labelText,
      start: { ...events[open + offset + 2][1].end },
      end: { ...events[close - 2][1].start }
    };
    media = [
      ["enter", group, context],
      ["enter", label, context]
    ];
    media = push(media, events.slice(open + 1, open + offset + 3));
    media = push(media, [["enter", text3, context]]);
    ok(context.parser.constructs.insideSpan.null, "expected `insideSpan.null` to be populated");
    media = push(media, resolveAll(context.parser.constructs.insideSpan.null, events.slice(open + offset + 4, close - 3), context));
    media = push(media, [
      ["exit", text3, context],
      events[close - 2],
      events[close - 1],
      ["exit", label, context]
    ]);
    media = push(media, events.slice(close + 1));
    media = push(media, [["exit", group, context]]);
    splice(events, open, events.length, media);
    return events;
  }
  function tokenizeLabelEnd(effects, ok3, nok) {
    const self = this;
    let index = self.events.length;
    let labelStart;
    let defined;
    while (index--) {
      if ((self.events[index][1].type === types.labelImage || self.events[index][1].type === types.labelLink) && !self.events[index][1]._balanced) {
        labelStart = self.events[index][1];
        break;
      }
    }
    return start;
    function start(code3) {
      ok(code3 === codes.rightSquareBracket, "expected `]`");
      if (!labelStart) {
        return nok(code3);
      }
      if (labelStart._inactive) {
        return labelEndNok(code3);
      }
      defined = self.parser.defined.includes(normalizeIdentifier(self.sliceSerialize({ start: labelStart.end, end: self.now() })));
      effects.enter(types.labelEnd);
      effects.enter(types.labelMarker);
      effects.consume(code3);
      effects.exit(types.labelMarker);
      effects.exit(types.labelEnd);
      return after;
    }
    function after(code3) {
      if (code3 === codes.leftParenthesis) {
        return effects.attempt(resourceConstruct, labelEndOk, defined ? labelEndOk : labelEndNok)(code3);
      }
      if (code3 === codes.leftSquareBracket) {
        return effects.attempt(referenceFullConstruct, labelEndOk, defined ? referenceNotFull : labelEndNok)(code3);
      }
      return defined ? labelEndOk(code3) : labelEndNok(code3);
    }
    function referenceNotFull(code3) {
      return effects.attempt(referenceCollapsedConstruct, labelEndOk, labelEndNok)(code3);
    }
    function labelEndOk(code3) {
      return ok3(code3);
    }
    function labelEndNok(code3) {
      labelStart._balanced = true;
      return nok(code3);
    }
  }
  function tokenizeResource(effects, ok3, nok) {
    return resourceStart;
    function resourceStart(code3) {
      ok(code3 === codes.leftParenthesis, "expected left paren");
      effects.enter(types.resource);
      effects.enter(types.resourceMarker);
      effects.consume(code3);
      effects.exit(types.resourceMarker);
      return resourceBefore;
    }
    function resourceBefore(code3) {
      return markdownLineEndingOrSpace(code3) ? factoryWhitespace(effects, resourceOpen)(code3) : resourceOpen(code3);
    }
    function resourceOpen(code3) {
      if (code3 === codes.rightParenthesis) {
        return resourceEnd(code3);
      }
      return factoryDestination(effects, resourceDestinationAfter, resourceDestinationMissing, types.resourceDestination, types.resourceDestinationLiteral, types.resourceDestinationLiteralMarker, types.resourceDestinationRaw, types.resourceDestinationString, constants.linkResourceDestinationBalanceMax)(code3);
    }
    function resourceDestinationAfter(code3) {
      return markdownLineEndingOrSpace(code3) ? factoryWhitespace(effects, resourceBetween)(code3) : resourceEnd(code3);
    }
    function resourceDestinationMissing(code3) {
      return nok(code3);
    }
    function resourceBetween(code3) {
      if (code3 === codes.quotationMark || code3 === codes.apostrophe || code3 === codes.leftParenthesis) {
        return factoryTitle(effects, resourceTitleAfter, nok, types.resourceTitle, types.resourceTitleMarker, types.resourceTitleString)(code3);
      }
      return resourceEnd(code3);
    }
    function resourceTitleAfter(code3) {
      return markdownLineEndingOrSpace(code3) ? factoryWhitespace(effects, resourceEnd)(code3) : resourceEnd(code3);
    }
    function resourceEnd(code3) {
      if (code3 === codes.rightParenthesis) {
        effects.enter(types.resourceMarker);
        effects.consume(code3);
        effects.exit(types.resourceMarker);
        effects.exit(types.resource);
        return ok3;
      }
      return nok(code3);
    }
  }
  function tokenizeReferenceFull(effects, ok3, nok) {
    const self = this;
    return referenceFull;
    function referenceFull(code3) {
      ok(code3 === codes.leftSquareBracket, "expected left bracket");
      return factoryLabel.call(self, effects, referenceFullAfter, referenceFullMissing, types.reference, types.referenceMarker, types.referenceString)(code3);
    }
    function referenceFullAfter(code3) {
      return self.parser.defined.includes(normalizeIdentifier(self.sliceSerialize(self.events[self.events.length - 1][1]).slice(1, -1))) ? ok3(code3) : nok(code3);
    }
    function referenceFullMissing(code3) {
      return nok(code3);
    }
  }
  function tokenizeReferenceCollapsed(effects, ok3, nok) {
    return referenceCollapsedStart;
    function referenceCollapsedStart(code3) {
      ok(code3 === codes.leftSquareBracket, "expected left bracket");
      effects.enter(types.reference);
      effects.enter(types.referenceMarker);
      effects.consume(code3);
      effects.exit(types.referenceMarker);
      return referenceCollapsedOpen;
    }
    function referenceCollapsedOpen(code3) {
      if (code3 === codes.rightSquareBracket) {
        effects.enter(types.referenceMarker);
        effects.consume(code3);
        effects.exit(types.referenceMarker);
        effects.exit(types.reference);
        return ok3;
      }
      return nok(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/label-start-image.js
  var labelStartImage = {
    name: "labelStartImage",
    resolveAll: labelEnd.resolveAll,
    tokenize: tokenizeLabelStartImage
  };
  function tokenizeLabelStartImage(effects, ok3, nok) {
    const self = this;
    return start;
    function start(code3) {
      ok(code3 === codes.exclamationMark, "expected `!`");
      effects.enter(types.labelImage);
      effects.enter(types.labelImageMarker);
      effects.consume(code3);
      effects.exit(types.labelImageMarker);
      return open;
    }
    function open(code3) {
      if (code3 === codes.leftSquareBracket) {
        effects.enter(types.labelMarker);
        effects.consume(code3);
        effects.exit(types.labelMarker);
        effects.exit(types.labelImage);
        return after;
      }
      return nok(code3);
    }
    function after(code3) {
      return code3 === codes.caret && "_hiddenFootnoteSupport" in self.parser.constructs ? nok(code3) : ok3(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/label-start-link.js
  var labelStartLink = {
    name: "labelStartLink",
    resolveAll: labelEnd.resolveAll,
    tokenize: tokenizeLabelStartLink
  };
  function tokenizeLabelStartLink(effects, ok3, nok) {
    const self = this;
    return start;
    function start(code3) {
      ok(code3 === codes.leftSquareBracket, "expected `[`");
      effects.enter(types.labelLink);
      effects.enter(types.labelMarker);
      effects.consume(code3);
      effects.exit(types.labelMarker);
      effects.exit(types.labelLink);
      return after;
    }
    function after(code3) {
      return code3 === codes.caret && "_hiddenFootnoteSupport" in self.parser.constructs ? nok(code3) : ok3(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/line-ending.js
  var lineEnding = { name: "lineEnding", tokenize: tokenizeLineEnding };
  function tokenizeLineEnding(effects, ok3) {
    return start;
    function start(code3) {
      ok(markdownLineEnding(code3), "expected eol");
      effects.enter(types.lineEnding);
      effects.consume(code3);
      effects.exit(types.lineEnding);
      return factorySpace(effects, ok3, types.linePrefix);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/thematic-break.js
  var thematicBreak2 = {
    name: "thematicBreak",
    tokenize: tokenizeThematicBreak
  };
  function tokenizeThematicBreak(effects, ok3, nok) {
    let size = 0;
    let marker;
    return start;
    function start(code3) {
      effects.enter(types.thematicBreak);
      return before(code3);
    }
    function before(code3) {
      ok(code3 === codes.asterisk || code3 === codes.dash || code3 === codes.underscore, "expected `*`, `-`, or `_`");
      marker = code3;
      return atBreak(code3);
    }
    function atBreak(code3) {
      if (code3 === marker) {
        effects.enter(types.thematicBreakSequence);
        return sequence(code3);
      }
      if (size >= constants.thematicBreakMarkerCountMin && (code3 === codes.eof || markdownLineEnding(code3))) {
        effects.exit(types.thematicBreak);
        return ok3(code3);
      }
      return nok(code3);
    }
    function sequence(code3) {
      if (code3 === marker) {
        effects.consume(code3);
        size++;
        return sequence;
      }
      effects.exit(types.thematicBreakSequence);
      return markdownSpace(code3) ? factorySpace(effects, atBreak, types.whitespace)(code3) : atBreak(code3);
    }
  }

  // node_modules/micromark-core-commonmark/dev/lib/list.js
  var list2 = {
    continuation: { tokenize: tokenizeListContinuation },
    exit: tokenizeListEnd,
    name: "list",
    tokenize: tokenizeListStart
  };
  var listItemPrefixWhitespaceConstruct = {
    partial: true,
    tokenize: tokenizeListItemPrefixWhitespace
  };
  var indentConstruct = { partial: true, tokenize: tokenizeIndent };
  function tokenizeListStart(effects, ok3, nok) {
    const self = this;
    const tail = self.events[self.events.length - 1];
    let initialSize = tail && tail[1].type === types.linePrefix ? tail[2].sliceSerialize(tail[1], true).length : 0;
    let size = 0;
    return start;
    function start(code3) {
      ok(self.containerState, "expected state");
      const kind = self.containerState.type || (code3 === codes.asterisk || code3 === codes.plusSign || code3 === codes.dash ? types.listUnordered : types.listOrdered);
      if (kind === types.listUnordered ? !self.containerState.marker || code3 === self.containerState.marker : asciiDigit(code3)) {
        if (!self.containerState.type) {
          self.containerState.type = kind;
          effects.enter(kind, { _container: true });
        }
        if (kind === types.listUnordered) {
          effects.enter(types.listItemPrefix);
          return code3 === codes.asterisk || code3 === codes.dash ? effects.check(thematicBreak2, nok, atMarker)(code3) : atMarker(code3);
        }
        if (!self.interrupt || code3 === codes.digit1) {
          effects.enter(types.listItemPrefix);
          effects.enter(types.listItemValue);
          return inside(code3);
        }
      }
      return nok(code3);
    }
    function inside(code3) {
      ok(self.containerState, "expected state");
      if (asciiDigit(code3) && ++size < constants.listItemValueSizeMax) {
        effects.consume(code3);
        return inside;
      }
      if ((!self.interrupt || size < 2) && (self.containerState.marker ? code3 === self.containerState.marker : code3 === codes.rightParenthesis || code3 === codes.dot)) {
        effects.exit(types.listItemValue);
        return atMarker(code3);
      }
      return nok(code3);
    }
    function atMarker(code3) {
      ok(self.containerState, "expected state");
      ok(code3 !== codes.eof, "eof (`null`) is not a marker");
      effects.enter(types.listItemMarker);
      effects.consume(code3);
      effects.exit(types.listItemMarker);
      self.containerState.marker = self.containerState.marker || code3;
      return effects.check(blankLine, self.interrupt ? nok : onBlank, effects.attempt(listItemPrefixWhitespaceConstruct, endOfPrefix, otherPrefix));
    }
    function onBlank(code3) {
      ok(self.containerState, "expected state");
      self.containerState.initialBlankLine = true;
      initialSize++;
      return endOfPrefix(code3);
    }
    function otherPrefix(code3) {
      if (markdownSpace(code3)) {
        effects.enter(types.listItemPrefixWhitespace);
        effects.consume(code3);
        effects.exit(types.listItemPrefixWhitespace);
        return endOfPrefix;
      }
      return nok(code3);
    }
    function endOfPrefix(code3) {
      ok(self.containerState, "expected state");
      self.containerState.size = initialSize + self.sliceSerialize(effects.exit(types.listItemPrefix), true).length;
      return ok3(code3);
    }
  }
  function tokenizeListContinuation(effects, ok3, nok) {
    const self = this;
    ok(self.containerState, "expected state");
    self.containerState._closeFlow = undefined;
    return effects.check(blankLine, onBlank, notBlank);
    function onBlank(code3) {
      ok(self.containerState, "expected state");
      ok(typeof self.containerState.size === "number", "expected size");
      self.containerState.furtherBlankLines = self.containerState.furtherBlankLines || self.containerState.initialBlankLine;
      return factorySpace(effects, ok3, types.listItemIndent, self.containerState.size + 1)(code3);
    }
    function notBlank(code3) {
      ok(self.containerState, "expected state");
      if (self.containerState.furtherBlankLines || !markdownSpace(code3)) {
        self.containerState.furtherBlankLines = undefined;
        self.containerState.initialBlankLine = undefined;
        return notInCurrentItem(code3);
      }
      self.containerState.furtherBlankLines = undefined;
      self.containerState.initialBlankLine = undefined;
      return effects.attempt(indentConstruct, ok3, notInCurrentItem)(code3);
    }
    function notInCurrentItem(code3) {
      ok(self.containerState, "expected state");
      self.containerState._closeFlow = true;
      self.interrupt = undefined;
      ok(self.parser.constructs.disable.null, "expected `disable.null` to be populated");
      return factorySpace(effects, effects.attempt(list2, ok3, nok), types.linePrefix, self.parser.constructs.disable.null.includes("codeIndented") ? undefined : constants.tabSize)(code3);
    }
  }
  function tokenizeIndent(effects, ok3, nok) {
    const self = this;
    ok(self.containerState, "expected state");
    ok(typeof self.containerState.size === "number", "expected size");
    return factorySpace(effects, afterPrefix, types.listItemIndent, self.containerState.size + 1);
    function afterPrefix(code3) {
      ok(self.containerState, "expected state");
      const tail = self.events[self.events.length - 1];
      return tail && tail[1].type === types.listItemIndent && tail[2].sliceSerialize(tail[1], true).length === self.containerState.size ? ok3(code3) : nok(code3);
    }
  }
  function tokenizeListEnd(effects) {
    ok(this.containerState, "expected state");
    ok(typeof this.containerState.type === "string", "expected type");
    effects.exit(this.containerState.type);
  }
  function tokenizeListItemPrefixWhitespace(effects, ok3, nok) {
    const self = this;
    ok(self.parser.constructs.disable.null, "expected `disable.null` to be populated");
    return factorySpace(effects, afterPrefix, types.listItemPrefixWhitespace, self.parser.constructs.disable.null.includes("codeIndented") ? undefined : constants.tabSize + 1);
    function afterPrefix(code3) {
      const tail = self.events[self.events.length - 1];
      return !markdownSpace(code3) && tail && tail[1].type === types.listItemPrefixWhitespace ? ok3(code3) : nok(code3);
    }
  }
  // node_modules/micromark-core-commonmark/dev/lib/setext-underline.js
  var setextUnderline = {
    name: "setextUnderline",
    resolveTo: resolveToSetextUnderline,
    tokenize: tokenizeSetextUnderline
  };
  function resolveToSetextUnderline(events, context) {
    let index = events.length;
    let content2;
    let text3;
    let definition3;
    while (index--) {
      if (events[index][0] === "enter") {
        if (events[index][1].type === types.content) {
          content2 = index;
          break;
        }
        if (events[index][1].type === types.paragraph) {
          text3 = index;
        }
      } else {
        if (events[index][1].type === types.content) {
          events.splice(index, 1);
        }
        if (!definition3 && events[index][1].type === types.definition) {
          definition3 = index;
        }
      }
    }
    ok(text3 !== undefined, "expected a `text` index to be found");
    ok(content2 !== undefined, "expected a `text` index to be found");
    ok(events[content2][2] === context, "enter context should be same");
    ok(events[events.length - 1][2] === context, "enter context should be same");
    const heading2 = {
      type: types.setextHeading,
      start: { ...events[content2][1].start },
      end: { ...events[events.length - 1][1].end }
    };
    events[text3][1].type = types.setextHeadingText;
    if (definition3) {
      events.splice(text3, 0, ["enter", heading2, context]);
      events.splice(definition3 + 1, 0, ["exit", events[content2][1], context]);
      events[content2][1].end = { ...events[definition3][1].end };
    } else {
      events[content2][1] = heading2;
    }
    events.push(["exit", heading2, context]);
    return events;
  }
  function tokenizeSetextUnderline(effects, ok3, nok) {
    const self = this;
    let marker;
    return start;
    function start(code3) {
      let index = self.events.length;
      let paragraph2;
      ok(code3 === codes.dash || code3 === codes.equalsTo, "expected `=` or `-`");
      while (index--) {
        if (self.events[index][1].type !== types.lineEnding && self.events[index][1].type !== types.linePrefix && self.events[index][1].type !== types.content) {
          paragraph2 = self.events[index][1].type === types.paragraph;
          break;
        }
      }
      if (!self.parser.lazy[self.now().line] && (self.interrupt || paragraph2)) {
        effects.enter(types.setextHeadingLine);
        marker = code3;
        return before(code3);
      }
      return nok(code3);
    }
    function before(code3) {
      effects.enter(types.setextHeadingLineSequence);
      return inside(code3);
    }
    function inside(code3) {
      if (code3 === marker) {
        effects.consume(code3);
        return inside;
      }
      effects.exit(types.setextHeadingLineSequence);
      return markdownSpace(code3) ? factorySpace(effects, after, types.lineSuffix)(code3) : after(code3);
    }
    function after(code3) {
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit(types.setextHeadingLine);
        return ok3(code3);
      }
      return nok(code3);
    }
  }
  // node_modules/micromark-extension-gfm-footnote/dev/lib/syntax.js
  var indent = { tokenize: tokenizeIndent2, partial: true };
  function gfmFootnote() {
    return {
      document: {
        [codes.leftSquareBracket]: {
          name: "gfmFootnoteDefinition",
          tokenize: tokenizeDefinitionStart,
          continuation: { tokenize: tokenizeDefinitionContinuation },
          exit: gfmFootnoteDefinitionEnd
        }
      },
      text: {
        [codes.leftSquareBracket]: {
          name: "gfmFootnoteCall",
          tokenize: tokenizeGfmFootnoteCall
        },
        [codes.rightSquareBracket]: {
          name: "gfmPotentialFootnoteCall",
          add: "after",
          tokenize: tokenizePotentialGfmFootnoteCall,
          resolveTo: resolveToPotentialGfmFootnoteCall
        }
      }
    };
  }
  function tokenizePotentialGfmFootnoteCall(effects, ok3, nok) {
    const self = this;
    let index = self.events.length;
    const defined = self.parser.gfmFootnotes || (self.parser.gfmFootnotes = []);
    let labelStart;
    while (index--) {
      const token = self.events[index][1];
      if (token.type === types.labelImage) {
        labelStart = token;
        break;
      }
      if (token.type === "gfmFootnoteCall" || token.type === types.labelLink || token.type === types.label || token.type === types.image || token.type === types.link) {
        break;
      }
    }
    return start;
    function start(code3) {
      ok(code3 === codes.rightSquareBracket, "expected `]`");
      if (!labelStart || !labelStart._balanced) {
        return nok(code3);
      }
      const id = normalizeIdentifier(self.sliceSerialize({ start: labelStart.end, end: self.now() }));
      if (id.codePointAt(0) !== codes.caret || !defined.includes(id.slice(1))) {
        return nok(code3);
      }
      effects.enter("gfmFootnoteCallLabelMarker");
      effects.consume(code3);
      effects.exit("gfmFootnoteCallLabelMarker");
      return ok3(code3);
    }
  }
  function resolveToPotentialGfmFootnoteCall(events, context) {
    let index = events.length;
    let labelStart;
    while (index--) {
      if (events[index][1].type === types.labelImage && events[index][0] === "enter") {
        labelStart = events[index][1];
        break;
      }
    }
    ok(labelStart, "expected `labelStart` to resolve");
    events[index + 1][1].type = types.data;
    events[index + 3][1].type = "gfmFootnoteCallLabelMarker";
    const call = {
      type: "gfmFootnoteCall",
      start: Object.assign({}, events[index + 3][1].start),
      end: Object.assign({}, events[events.length - 1][1].end)
    };
    const marker = {
      type: "gfmFootnoteCallMarker",
      start: Object.assign({}, events[index + 3][1].end),
      end: Object.assign({}, events[index + 3][1].end)
    };
    marker.end.column++;
    marker.end.offset++;
    marker.end._bufferIndex++;
    const string = {
      type: "gfmFootnoteCallString",
      start: Object.assign({}, marker.end),
      end: Object.assign({}, events[events.length - 1][1].start)
    };
    const chunk = {
      type: types.chunkString,
      contentType: "string",
      start: Object.assign({}, string.start),
      end: Object.assign({}, string.end)
    };
    const replacement = [
      events[index + 1],
      events[index + 2],
      ["enter", call, context],
      events[index + 3],
      events[index + 4],
      ["enter", marker, context],
      ["exit", marker, context],
      ["enter", string, context],
      ["enter", chunk, context],
      ["exit", chunk, context],
      ["exit", string, context],
      events[events.length - 2],
      events[events.length - 1],
      ["exit", call, context]
    ];
    events.splice(index, events.length - index + 1, ...replacement);
    return events;
  }
  function tokenizeGfmFootnoteCall(effects, ok3, nok) {
    const self = this;
    const defined = self.parser.gfmFootnotes || (self.parser.gfmFootnotes = []);
    let size = 0;
    let data;
    return start;
    function start(code3) {
      ok(code3 === codes.leftSquareBracket, "expected `[`");
      effects.enter("gfmFootnoteCall");
      effects.enter("gfmFootnoteCallLabelMarker");
      effects.consume(code3);
      effects.exit("gfmFootnoteCallLabelMarker");
      return callStart;
    }
    function callStart(code3) {
      if (code3 !== codes.caret)
        return nok(code3);
      effects.enter("gfmFootnoteCallMarker");
      effects.consume(code3);
      effects.exit("gfmFootnoteCallMarker");
      effects.enter("gfmFootnoteCallString");
      effects.enter("chunkString").contentType = "string";
      return callData;
    }
    function callData(code3) {
      if (size > constants.linkReferenceSizeMax || code3 === codes.rightSquareBracket && !data || code3 === codes.eof || code3 === codes.leftSquareBracket || markdownLineEndingOrSpace(code3)) {
        return nok(code3);
      }
      if (code3 === codes.rightSquareBracket) {
        effects.exit("chunkString");
        const token = effects.exit("gfmFootnoteCallString");
        if (!defined.includes(normalizeIdentifier(self.sliceSerialize(token)))) {
          return nok(code3);
        }
        effects.enter("gfmFootnoteCallLabelMarker");
        effects.consume(code3);
        effects.exit("gfmFootnoteCallLabelMarker");
        effects.exit("gfmFootnoteCall");
        return ok3;
      }
      if (!markdownLineEndingOrSpace(code3)) {
        data = true;
      }
      size++;
      effects.consume(code3);
      return code3 === codes.backslash ? callEscape : callData;
    }
    function callEscape(code3) {
      if (code3 === codes.leftSquareBracket || code3 === codes.backslash || code3 === codes.rightSquareBracket) {
        effects.consume(code3);
        size++;
        return callData;
      }
      return callData(code3);
    }
  }
  function tokenizeDefinitionStart(effects, ok3, nok) {
    const self = this;
    const defined = self.parser.gfmFootnotes || (self.parser.gfmFootnotes = []);
    let identifier;
    let size = 0;
    let data;
    return start;
    function start(code3) {
      ok(code3 === codes.leftSquareBracket, "expected `[`");
      effects.enter("gfmFootnoteDefinition")._container = true;
      effects.enter("gfmFootnoteDefinitionLabel");
      effects.enter("gfmFootnoteDefinitionLabelMarker");
      effects.consume(code3);
      effects.exit("gfmFootnoteDefinitionLabelMarker");
      return labelAtMarker;
    }
    function labelAtMarker(code3) {
      if (code3 === codes.caret) {
        effects.enter("gfmFootnoteDefinitionMarker");
        effects.consume(code3);
        effects.exit("gfmFootnoteDefinitionMarker");
        effects.enter("gfmFootnoteDefinitionLabelString");
        effects.enter("chunkString").contentType = "string";
        return labelInside;
      }
      return nok(code3);
    }
    function labelInside(code3) {
      if (size > constants.linkReferenceSizeMax || code3 === codes.rightSquareBracket && !data || code3 === codes.eof || code3 === codes.leftSquareBracket || markdownLineEndingOrSpace(code3)) {
        return nok(code3);
      }
      if (code3 === codes.rightSquareBracket) {
        effects.exit("chunkString");
        const token = effects.exit("gfmFootnoteDefinitionLabelString");
        identifier = normalizeIdentifier(self.sliceSerialize(token));
        effects.enter("gfmFootnoteDefinitionLabelMarker");
        effects.consume(code3);
        effects.exit("gfmFootnoteDefinitionLabelMarker");
        effects.exit("gfmFootnoteDefinitionLabel");
        return labelAfter;
      }
      if (!markdownLineEndingOrSpace(code3)) {
        data = true;
      }
      size++;
      effects.consume(code3);
      return code3 === codes.backslash ? labelEscape : labelInside;
    }
    function labelEscape(code3) {
      if (code3 === codes.leftSquareBracket || code3 === codes.backslash || code3 === codes.rightSquareBracket) {
        effects.consume(code3);
        size++;
        return labelInside;
      }
      return labelInside(code3);
    }
    function labelAfter(code3) {
      if (code3 === codes.colon) {
        effects.enter("definitionMarker");
        effects.consume(code3);
        effects.exit("definitionMarker");
        if (!defined.includes(identifier)) {
          defined.push(identifier);
        }
        return factorySpace(effects, whitespaceAfter, "gfmFootnoteDefinitionWhitespace");
      }
      return nok(code3);
    }
    function whitespaceAfter(code3) {
      return ok3(code3);
    }
  }
  function tokenizeDefinitionContinuation(effects, ok3, nok) {
    return effects.check(blankLine, ok3, effects.attempt(indent, ok3, nok));
  }
  function gfmFootnoteDefinitionEnd(effects) {
    effects.exit("gfmFootnoteDefinition");
  }
  function tokenizeIndent2(effects, ok3, nok) {
    const self = this;
    return factorySpace(effects, afterPrefix, "gfmFootnoteDefinitionIndent", constants.tabSize + 1);
    function afterPrefix(code3) {
      const tail = self.events[self.events.length - 1];
      return tail && tail[1].type === "gfmFootnoteDefinitionIndent" && tail[2].sliceSerialize(tail[1], true).length === constants.tabSize ? ok3(code3) : nok(code3);
    }
  }
  // node_modules/micromark-extension-gfm-strikethrough/dev/lib/syntax.js
  function gfmStrikethrough(options) {
    const options_ = options || {};
    let single = options_.singleTilde;
    const tokenizer = {
      name: "strikethrough",
      tokenize: tokenizeStrikethrough,
      resolveAll: resolveAllStrikethrough
    };
    if (single === null || single === undefined) {
      single = true;
    }
    return {
      text: { [codes.tilde]: tokenizer },
      insideSpan: { null: [tokenizer] },
      attentionMarkers: { null: [codes.tilde] }
    };
    function resolveAllStrikethrough(events, context) {
      let index = -1;
      while (++index < events.length) {
        if (events[index][0] === "enter" && events[index][1].type === "strikethroughSequenceTemporary" && events[index][1]._close) {
          let open = index;
          while (open--) {
            if (events[open][0] === "exit" && events[open][1].type === "strikethroughSequenceTemporary" && events[open][1]._open && events[index][1].end.offset - events[index][1].start.offset === events[open][1].end.offset - events[open][1].start.offset) {
              events[index][1].type = "strikethroughSequence";
              events[open][1].type = "strikethroughSequence";
              const strikethrough = {
                type: "strikethrough",
                start: Object.assign({}, events[open][1].start),
                end: Object.assign({}, events[index][1].end)
              };
              const text3 = {
                type: "strikethroughText",
                start: Object.assign({}, events[open][1].end),
                end: Object.assign({}, events[index][1].start)
              };
              const nextEvents = [
                ["enter", strikethrough, context],
                ["enter", events[open][1], context],
                ["exit", events[open][1], context],
                ["enter", text3, context]
              ];
              const insideSpan = context.parser.constructs.insideSpan.null;
              if (insideSpan) {
                splice(nextEvents, nextEvents.length, 0, resolveAll(insideSpan, events.slice(open + 1, index), context));
              }
              splice(nextEvents, nextEvents.length, 0, [
                ["exit", text3, context],
                ["enter", events[index][1], context],
                ["exit", events[index][1], context],
                ["exit", strikethrough, context]
              ]);
              splice(events, open - 1, index - open + 3, nextEvents);
              index = open + nextEvents.length - 2;
              break;
            }
          }
        }
      }
      index = -1;
      while (++index < events.length) {
        if (events[index][1].type === "strikethroughSequenceTemporary") {
          events[index][1].type = types.data;
        }
      }
      return events;
    }
    function tokenizeStrikethrough(effects, ok3, nok) {
      const previous3 = this.previous;
      const events = this.events;
      let size = 0;
      return start;
      function start(code3) {
        ok(code3 === codes.tilde, "expected `~`");
        if (previous3 === codes.tilde && events[events.length - 1][1].type !== types.characterEscape) {
          return nok(code3);
        }
        effects.enter("strikethroughSequenceTemporary");
        return more(code3);
      }
      function more(code3) {
        const before = classifyCharacter(previous3);
        if (code3 === codes.tilde) {
          if (size > 1)
            return nok(code3);
          effects.consume(code3);
          size++;
          return more;
        }
        if (size < 2 && !single)
          return nok(code3);
        const token = effects.exit("strikethroughSequenceTemporary");
        const after = classifyCharacter(code3);
        token._open = !after || after === constants.attentionSideAfter && Boolean(before);
        token._close = !before || before === constants.attentionSideAfter && Boolean(after);
        return ok3(code3);
      }
    }
  }
  // node_modules/micromark-extension-gfm-table/dev/lib/edit-map.js
  class EditMap {
    constructor() {
      this.map = [];
    }
    add(index, remove, add) {
      addImplementation(this, index, remove, add);
    }
    consume(events) {
      this.map.sort(function(a, b) {
        return a[0] - b[0];
      });
      if (this.map.length === 0) {
        return;
      }
      let index = this.map.length;
      const vecs = [];
      while (index > 0) {
        index -= 1;
        vecs.push(events.slice(this.map[index][0] + this.map[index][1]), this.map[index][2]);
        events.length = this.map[index][0];
      }
      vecs.push(events.slice());
      events.length = 0;
      let slice = vecs.pop();
      while (slice) {
        for (const element2 of slice) {
          events.push(element2);
        }
        slice = vecs.pop();
      }
      this.map.length = 0;
    }
  }
  function addImplementation(editMap, at, remove, add) {
    let index = 0;
    if (remove === 0 && add.length === 0) {
      return;
    }
    while (index < editMap.map.length) {
      if (editMap.map[index][0] === at) {
        editMap.map[index][1] += remove;
        editMap.map[index][2].push(...add);
        return;
      }
      index += 1;
    }
    editMap.map.push([at, remove, add]);
  }

  // node_modules/micromark-extension-gfm-table/dev/lib/infer.js
  function gfmTableAlign(events, index) {
    ok(events[index][1].type === "table", "expected table");
    let inDelimiterRow = false;
    const align = [];
    while (index < events.length) {
      const event = events[index];
      if (inDelimiterRow) {
        if (event[0] === "enter") {
          if (event[1].type === "tableContent") {
            align.push(events[index + 1][1].type === "tableDelimiterMarker" ? "left" : "none");
          }
        } else if (event[1].type === "tableContent") {
          if (events[index - 1][1].type === "tableDelimiterMarker") {
            const alignIndex = align.length - 1;
            align[alignIndex] = align[alignIndex] === "left" ? "center" : "right";
          }
        } else if (event[1].type === "tableDelimiterRow") {
          break;
        }
      } else if (event[0] === "enter" && event[1].type === "tableDelimiterRow") {
        inDelimiterRow = true;
      }
      index += 1;
    }
    return align;
  }

  // node_modules/micromark-extension-gfm-table/dev/lib/syntax.js
  function gfmTable() {
    return {
      flow: {
        null: { name: "table", tokenize: tokenizeTable, resolveAll: resolveTable }
      }
    };
  }
  function tokenizeTable(effects, ok3, nok) {
    const self = this;
    let size = 0;
    let sizeB = 0;
    let seen;
    return start;
    function start(code3) {
      let index = self.events.length - 1;
      while (index > -1) {
        const type = self.events[index][1].type;
        if (type === types.lineEnding || type === types.linePrefix)
          index--;
        else
          break;
      }
      const tail = index > -1 ? self.events[index][1].type : null;
      const next = tail === "tableHead" || tail === "tableRow" ? bodyRowStart : headRowBefore;
      if (next === bodyRowStart && self.parser.lazy[self.now().line]) {
        return nok(code3);
      }
      return next(code3);
    }
    function headRowBefore(code3) {
      effects.enter("tableHead");
      effects.enter("tableRow");
      return headRowStart(code3);
    }
    function headRowStart(code3) {
      if (code3 === codes.verticalBar) {
        return headRowBreak(code3);
      }
      seen = true;
      sizeB += 1;
      return headRowBreak(code3);
    }
    function headRowBreak(code3) {
      if (code3 === codes.eof) {
        return nok(code3);
      }
      if (markdownLineEnding(code3)) {
        if (sizeB > 1) {
          sizeB = 0;
          self.interrupt = true;
          effects.exit("tableRow");
          effects.enter(types.lineEnding);
          effects.consume(code3);
          effects.exit(types.lineEnding);
          return headDelimiterStart;
        }
        return nok(code3);
      }
      if (markdownSpace(code3)) {
        return factorySpace(effects, headRowBreak, types.whitespace)(code3);
      }
      sizeB += 1;
      if (seen) {
        seen = false;
        size += 1;
      }
      if (code3 === codes.verticalBar) {
        effects.enter("tableCellDivider");
        effects.consume(code3);
        effects.exit("tableCellDivider");
        seen = true;
        return headRowBreak;
      }
      effects.enter(types.data);
      return headRowData(code3);
    }
    function headRowData(code3) {
      if (code3 === codes.eof || code3 === codes.verticalBar || markdownLineEndingOrSpace(code3)) {
        effects.exit(types.data);
        return headRowBreak(code3);
      }
      effects.consume(code3);
      return code3 === codes.backslash ? headRowEscape : headRowData;
    }
    function headRowEscape(code3) {
      if (code3 === codes.backslash || code3 === codes.verticalBar) {
        effects.consume(code3);
        return headRowData;
      }
      return headRowData(code3);
    }
    function headDelimiterStart(code3) {
      self.interrupt = false;
      if (self.parser.lazy[self.now().line]) {
        return nok(code3);
      }
      effects.enter("tableDelimiterRow");
      seen = false;
      if (markdownSpace(code3)) {
        ok(self.parser.constructs.disable.null, "expected `disabled.null`");
        return factorySpace(effects, headDelimiterBefore, types.linePrefix, self.parser.constructs.disable.null.includes("codeIndented") ? undefined : constants.tabSize)(code3);
      }
      return headDelimiterBefore(code3);
    }
    function headDelimiterBefore(code3) {
      if (code3 === codes.dash || code3 === codes.colon) {
        return headDelimiterValueBefore(code3);
      }
      if (code3 === codes.verticalBar) {
        seen = true;
        effects.enter("tableCellDivider");
        effects.consume(code3);
        effects.exit("tableCellDivider");
        return headDelimiterCellBefore;
      }
      return headDelimiterNok(code3);
    }
    function headDelimiterCellBefore(code3) {
      if (markdownSpace(code3)) {
        return factorySpace(effects, headDelimiterValueBefore, types.whitespace)(code3);
      }
      return headDelimiterValueBefore(code3);
    }
    function headDelimiterValueBefore(code3) {
      if (code3 === codes.colon) {
        sizeB += 1;
        seen = true;
        effects.enter("tableDelimiterMarker");
        effects.consume(code3);
        effects.exit("tableDelimiterMarker");
        return headDelimiterLeftAlignmentAfter;
      }
      if (code3 === codes.dash) {
        sizeB += 1;
        return headDelimiterLeftAlignmentAfter(code3);
      }
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        return headDelimiterCellAfter(code3);
      }
      return headDelimiterNok(code3);
    }
    function headDelimiterLeftAlignmentAfter(code3) {
      if (code3 === codes.dash) {
        effects.enter("tableDelimiterFiller");
        return headDelimiterFiller(code3);
      }
      return headDelimiterNok(code3);
    }
    function headDelimiterFiller(code3) {
      if (code3 === codes.dash) {
        effects.consume(code3);
        return headDelimiterFiller;
      }
      if (code3 === codes.colon) {
        seen = true;
        effects.exit("tableDelimiterFiller");
        effects.enter("tableDelimiterMarker");
        effects.consume(code3);
        effects.exit("tableDelimiterMarker");
        return headDelimiterRightAlignmentAfter;
      }
      effects.exit("tableDelimiterFiller");
      return headDelimiterRightAlignmentAfter(code3);
    }
    function headDelimiterRightAlignmentAfter(code3) {
      if (markdownSpace(code3)) {
        return factorySpace(effects, headDelimiterCellAfter, types.whitespace)(code3);
      }
      return headDelimiterCellAfter(code3);
    }
    function headDelimiterCellAfter(code3) {
      if (code3 === codes.verticalBar) {
        return headDelimiterBefore(code3);
      }
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        if (!seen || size !== sizeB) {
          return headDelimiterNok(code3);
        }
        effects.exit("tableDelimiterRow");
        effects.exit("tableHead");
        return ok3(code3);
      }
      return headDelimiterNok(code3);
    }
    function headDelimiterNok(code3) {
      return nok(code3);
    }
    function bodyRowStart(code3) {
      effects.enter("tableRow");
      return bodyRowBreak(code3);
    }
    function bodyRowBreak(code3) {
      if (code3 === codes.verticalBar) {
        effects.enter("tableCellDivider");
        effects.consume(code3);
        effects.exit("tableCellDivider");
        return bodyRowBreak;
      }
      if (code3 === codes.eof || markdownLineEnding(code3)) {
        effects.exit("tableRow");
        return ok3(code3);
      }
      if (markdownSpace(code3)) {
        return factorySpace(effects, bodyRowBreak, types.whitespace)(code3);
      }
      effects.enter(types.data);
      return bodyRowData(code3);
    }
    function bodyRowData(code3) {
      if (code3 === codes.eof || code3 === codes.verticalBar || markdownLineEndingOrSpace(code3)) {
        effects.exit(types.data);
        return bodyRowBreak(code3);
      }
      effects.consume(code3);
      return code3 === codes.backslash ? bodyRowEscape : bodyRowData;
    }
    function bodyRowEscape(code3) {
      if (code3 === codes.backslash || code3 === codes.verticalBar) {
        effects.consume(code3);
        return bodyRowData;
      }
      return bodyRowData(code3);
    }
  }
  function resolveTable(events, context) {
    let index = -1;
    let inFirstCellAwaitingPipe = true;
    let rowKind = 0;
    let lastCell = [0, 0, 0, 0];
    let cell = [0, 0, 0, 0];
    let afterHeadAwaitingFirstBodyRow = false;
    let lastTableEnd = 0;
    let currentTable;
    let currentBody;
    let currentCell;
    const map3 = new EditMap;
    while (++index < events.length) {
      const event = events[index];
      const token = event[1];
      if (event[0] === "enter") {
        if (token.type === "tableHead") {
          afterHeadAwaitingFirstBodyRow = false;
          if (lastTableEnd !== 0) {
            ok(currentTable, "there should be a table opening");
            flushTableEnd(map3, context, lastTableEnd, currentTable, currentBody);
            currentBody = undefined;
            lastTableEnd = 0;
          }
          currentTable = {
            type: "table",
            start: Object.assign({}, token.start),
            end: Object.assign({}, token.end)
          };
          map3.add(index, 0, [["enter", currentTable, context]]);
        } else if (token.type === "tableRow" || token.type === "tableDelimiterRow") {
          inFirstCellAwaitingPipe = true;
          currentCell = undefined;
          lastCell = [0, 0, 0, 0];
          cell = [0, index + 1, 0, 0];
          if (afterHeadAwaitingFirstBodyRow) {
            afterHeadAwaitingFirstBodyRow = false;
            currentBody = {
              type: "tableBody",
              start: Object.assign({}, token.start),
              end: Object.assign({}, token.end)
            };
            map3.add(index, 0, [["enter", currentBody, context]]);
          }
          rowKind = token.type === "tableDelimiterRow" ? 2 : currentBody ? 3 : 1;
        } else if (rowKind && (token.type === types.data || token.type === "tableDelimiterMarker" || token.type === "tableDelimiterFiller")) {
          inFirstCellAwaitingPipe = false;
          if (cell[2] === 0) {
            if (lastCell[1] !== 0) {
              cell[0] = cell[1];
              currentCell = flushCell(map3, context, lastCell, rowKind, undefined, currentCell);
              lastCell = [0, 0, 0, 0];
            }
            cell[2] = index;
          }
        } else if (token.type === "tableCellDivider") {
          if (inFirstCellAwaitingPipe) {
            inFirstCellAwaitingPipe = false;
          } else {
            if (lastCell[1] !== 0) {
              cell[0] = cell[1];
              currentCell = flushCell(map3, context, lastCell, rowKind, undefined, currentCell);
            }
            lastCell = cell;
            cell = [lastCell[1], index, 0, 0];
          }
        }
      } else if (token.type === "tableHead") {
        afterHeadAwaitingFirstBodyRow = true;
        lastTableEnd = index;
      } else if (token.type === "tableRow" || token.type === "tableDelimiterRow") {
        lastTableEnd = index;
        if (lastCell[1] !== 0) {
          cell[0] = cell[1];
          currentCell = flushCell(map3, context, lastCell, rowKind, index, currentCell);
        } else if (cell[1] !== 0) {
          currentCell = flushCell(map3, context, cell, rowKind, index, currentCell);
        }
        rowKind = 0;
      } else if (rowKind && (token.type === types.data || token.type === "tableDelimiterMarker" || token.type === "tableDelimiterFiller")) {
        cell[3] = index;
      }
    }
    if (lastTableEnd !== 0) {
      ok(currentTable, "expected table opening");
      flushTableEnd(map3, context, lastTableEnd, currentTable, currentBody);
    }
    map3.consume(context.events);
    index = -1;
    while (++index < context.events.length) {
      const event = context.events[index];
      if (event[0] === "enter" && event[1].type === "table") {
        event[1]._align = gfmTableAlign(context.events, index);
      }
    }
    return events;
  }
  function flushCell(map3, context, range, rowKind, rowEnd, previousCell) {
    const groupName = rowKind === 1 ? "tableHeader" : rowKind === 2 ? "tableDelimiter" : "tableData";
    const valueName = "tableContent";
    if (range[0] !== 0) {
      ok(previousCell, "expected previous cell enter");
      previousCell.end = Object.assign({}, getPoint(context.events, range[0]));
      map3.add(range[0], 0, [["exit", previousCell, context]]);
    }
    const now = getPoint(context.events, range[1]);
    previousCell = {
      type: groupName,
      start: Object.assign({}, now),
      end: Object.assign({}, now)
    };
    map3.add(range[1], 0, [["enter", previousCell, context]]);
    if (range[2] !== 0) {
      const relatedStart = getPoint(context.events, range[2]);
      const relatedEnd = getPoint(context.events, range[3]);
      const valueToken = {
        type: valueName,
        start: Object.assign({}, relatedStart),
        end: Object.assign({}, relatedEnd)
      };
      map3.add(range[2], 0, [["enter", valueToken, context]]);
      ok(range[3] !== 0);
      if (rowKind !== 2) {
        const start = context.events[range[2]];
        const end = context.events[range[3]];
        start[1].end = Object.assign({}, end[1].end);
        start[1].type = types.chunkText;
        start[1].contentType = constants.contentTypeText;
        if (range[3] > range[2] + 1) {
          const a = range[2] + 1;
          const b = range[3] - range[2] - 1;
          map3.add(a, b, []);
        }
      }
      map3.add(range[3] + 1, 0, [["exit", valueToken, context]]);
    }
    if (rowEnd !== undefined) {
      previousCell.end = Object.assign({}, getPoint(context.events, rowEnd));
      map3.add(rowEnd, 0, [["exit", previousCell, context]]);
      previousCell = undefined;
    }
    return previousCell;
  }
  function flushTableEnd(map3, context, index, table, tableBody) {
    const exits = [];
    const related = getPoint(context.events, index);
    if (tableBody) {
      tableBody.end = Object.assign({}, related);
      exits.push(["exit", tableBody, context]);
    }
    table.end = Object.assign({}, related);
    exits.push(["exit", table, context]);
    map3.add(index + 1, 0, exits);
  }
  function getPoint(events, index) {
    const event = events[index];
    const side = event[0] === "enter" ? "start" : "end";
    return event[1][side];
  }
  // node_modules/micromark-extension-gfm-task-list-item/dev/lib/syntax.js
  var tasklistCheck = { name: "tasklistCheck", tokenize: tokenizeTasklistCheck };
  function gfmTaskListItem() {
    return {
      text: { [codes.leftSquareBracket]: tasklistCheck }
    };
  }
  function tokenizeTasklistCheck(effects, ok3, nok) {
    const self = this;
    return open;
    function open(code3) {
      ok(code3 === codes.leftSquareBracket, "expected `[`");
      if (self.previous !== codes.eof || !self._gfmTasklistFirstContentOfListItem) {
        return nok(code3);
      }
      effects.enter("taskListCheck");
      effects.enter("taskListCheckMarker");
      effects.consume(code3);
      effects.exit("taskListCheckMarker");
      return inside;
    }
    function inside(code3) {
      if (markdownLineEndingOrSpace(code3)) {
        effects.enter("taskListCheckValueUnchecked");
        effects.consume(code3);
        effects.exit("taskListCheckValueUnchecked");
        return close;
      }
      if (code3 === codes.uppercaseX || code3 === codes.lowercaseX) {
        effects.enter("taskListCheckValueChecked");
        effects.consume(code3);
        effects.exit("taskListCheckValueChecked");
        return close;
      }
      return nok(code3);
    }
    function close(code3) {
      if (code3 === codes.rightSquareBracket) {
        effects.enter("taskListCheckMarker");
        effects.consume(code3);
        effects.exit("taskListCheckMarker");
        effects.exit("taskListCheck");
        return after;
      }
      return nok(code3);
    }
    function after(code3) {
      if (markdownLineEnding(code3)) {
        return ok3(code3);
      }
      if (markdownSpace(code3)) {
        return effects.check({ tokenize: spaceThenNonSpace }, ok3, nok)(code3);
      }
      return nok(code3);
    }
  }
  function spaceThenNonSpace(effects, ok3, nok) {
    return factorySpace(effects, after, types.whitespace);
    function after(code3) {
      return code3 === codes.eof ? nok(code3) : ok3(code3);
    }
  }
  // node_modules/micromark-extension-gfm/index.js
  function gfm(options) {
    return combineExtensions([
      gfmAutolinkLiteral(),
      gfmFootnote(),
      gfmStrikethrough(options),
      gfmTable(),
      gfmTaskListItem()
    ]);
  }

  // node_modules/remark-gfm/lib/index.js
  var emptyOptions2 = {};
  function remarkGfm(options) {
    const self = this;
    const settings = options || emptyOptions2;
    const data = self.data();
    const micromarkExtensions = data.micromarkExtensions || (data.micromarkExtensions = []);
    const fromMarkdownExtensions = data.fromMarkdownExtensions || (data.fromMarkdownExtensions = []);
    const toMarkdownExtensions = data.toMarkdownExtensions || (data.toMarkdownExtensions = []);
    micromarkExtensions.push(gfm(settings));
    fromMarkdownExtensions.push(gfmFromMarkdown());
    toMarkdownExtensions.push(gfmToMarkdown(settings));
  }
  // node_modules/micromark-util-decode-numeric-character-reference/dev/index.js
  function decodeNumericCharacterReference(value, base) {
    const code3 = Number.parseInt(value, base);
    if (code3 < codes.ht || code3 === codes.vt || code3 > codes.cr && code3 < codes.space || code3 > codes.tilde && code3 < 160 || code3 > 55295 && code3 < 57344 || code3 > 64975 && code3 < 65008 || (code3 & 65535) === 65535 || (code3 & 65535) === 65534 || code3 > 1114111) {
      return values.replacementCharacter;
    }
    return String.fromCodePoint(code3);
  }

  // node_modules/micromark/dev/lib/initialize/content.js
  var content2 = { tokenize: initializeContent };
  function initializeContent(effects) {
    const contentStart = effects.attempt(this.parser.constructs.contentInitial, afterContentStartConstruct, paragraphInitial);
    let previous3;
    return contentStart;
    function afterContentStartConstruct(code3) {
      ok(code3 === codes.eof || markdownLineEnding(code3), "expected eol or eof");
      if (code3 === codes.eof) {
        effects.consume(code3);
        return;
      }
      effects.enter(types.lineEnding);
      effects.consume(code3);
      effects.exit(types.lineEnding);
      return factorySpace(effects, contentStart, types.linePrefix);
    }
    function paragraphInitial(code3) {
      ok(code3 !== codes.eof && !markdownLineEnding(code3), "expected anything other than a line ending or EOF");
      effects.enter(types.paragraph);
      return lineStart(code3);
    }
    function lineStart(code3) {
      const token = effects.enter(types.chunkText, {
        contentType: constants.contentTypeText,
        previous: previous3
      });
      if (previous3) {
        previous3.next = token;
      }
      previous3 = token;
      return data(code3);
    }
    function data(code3) {
      if (code3 === codes.eof) {
        effects.exit(types.chunkText);
        effects.exit(types.paragraph);
        effects.consume(code3);
        return;
      }
      if (markdownLineEnding(code3)) {
        effects.consume(code3);
        effects.exit(types.chunkText);
        return lineStart;
      }
      effects.consume(code3);
      return data;
    }
  }

  // node_modules/micromark/dev/lib/initialize/document.js
  var document2 = { tokenize: initializeDocument };
  var containerConstruct = { tokenize: tokenizeContainer };
  function initializeDocument(effects) {
    const self = this;
    const stack = [];
    let continued = 0;
    let childFlow;
    let childToken;
    let lineStartOffset;
    return start;
    function start(code3) {
      if (continued < stack.length) {
        const item = stack[continued];
        self.containerState = item[1];
        ok(item[0].continuation, "expected `continuation` to be defined on container construct");
        return effects.attempt(item[0].continuation, documentContinue, checkNewContainers)(code3);
      }
      return checkNewContainers(code3);
    }
    function documentContinue(code3) {
      ok(self.containerState, "expected `containerState` to be defined after continuation");
      continued++;
      if (self.containerState._closeFlow) {
        self.containerState._closeFlow = undefined;
        if (childFlow) {
          closeFlow();
        }
        const indexBeforeExits = self.events.length;
        let indexBeforeFlow = indexBeforeExits;
        let point;
        while (indexBeforeFlow--) {
          if (self.events[indexBeforeFlow][0] === "exit" && self.events[indexBeforeFlow][1].type === types.chunkFlow) {
            point = self.events[indexBeforeFlow][1].end;
            break;
          }
        }
        ok(point, "could not find previous flow chunk");
        exitContainers(continued);
        let index = indexBeforeExits;
        while (index < self.events.length) {
          self.events[index][1].end = { ...point };
          index++;
        }
        splice(self.events, indexBeforeFlow + 1, 0, self.events.slice(indexBeforeExits));
        self.events.length = index;
        return checkNewContainers(code3);
      }
      return start(code3);
    }
    function checkNewContainers(code3) {
      if (continued === stack.length) {
        if (!childFlow) {
          return documentContinued(code3);
        }
        if (childFlow.currentConstruct && childFlow.currentConstruct.concrete) {
          return flowStart(code3);
        }
        self.interrupt = Boolean(childFlow.currentConstruct && !childFlow._gfmTableDynamicInterruptHack);
      }
      self.containerState = {};
      return effects.check(containerConstruct, thereIsANewContainer, thereIsNoNewContainer)(code3);
    }
    function thereIsANewContainer(code3) {
      if (childFlow)
        closeFlow();
      exitContainers(continued);
      return documentContinued(code3);
    }
    function thereIsNoNewContainer(code3) {
      self.parser.lazy[self.now().line] = continued !== stack.length;
      lineStartOffset = self.now().offset;
      return flowStart(code3);
    }
    function documentContinued(code3) {
      self.containerState = {};
      return effects.attempt(containerConstruct, containerContinue, flowStart)(code3);
    }
    function containerContinue(code3) {
      ok(self.currentConstruct, "expected `currentConstruct` to be defined on tokenizer");
      ok(self.containerState, "expected `containerState` to be defined on tokenizer");
      continued++;
      stack.push([self.currentConstruct, self.containerState]);
      return documentContinued(code3);
    }
    function flowStart(code3) {
      if (code3 === codes.eof) {
        if (childFlow)
          closeFlow();
        exitContainers(0);
        effects.consume(code3);
        return;
      }
      childFlow = childFlow || self.parser.flow(self.now());
      effects.enter(types.chunkFlow, {
        _tokenizer: childFlow,
        contentType: constants.contentTypeFlow,
        previous: childToken
      });
      return flowContinue(code3);
    }
    function flowContinue(code3) {
      if (code3 === codes.eof) {
        writeToChild(effects.exit(types.chunkFlow), true);
        exitContainers(0);
        effects.consume(code3);
        return;
      }
      if (markdownLineEnding(code3)) {
        effects.consume(code3);
        writeToChild(effects.exit(types.chunkFlow));
        continued = 0;
        self.interrupt = undefined;
        return start;
      }
      effects.consume(code3);
      return flowContinue;
    }
    function writeToChild(token, endOfFile) {
      ok(childFlow, "expected `childFlow` to be defined when continuing");
      const stream = self.sliceStream(token);
      if (endOfFile)
        stream.push(null);
      token.previous = childToken;
      if (childToken)
        childToken.next = token;
      childToken = token;
      childFlow.defineSkip(token.start);
      childFlow.write(stream);
      if (self.parser.lazy[token.start.line]) {
        let index = childFlow.events.length;
        while (index--) {
          if (childFlow.events[index][1].start.offset < lineStartOffset && (!childFlow.events[index][1].end || childFlow.events[index][1].end.offset > lineStartOffset)) {
            return;
          }
        }
        const indexBeforeExits = self.events.length;
        let indexBeforeFlow = indexBeforeExits;
        let seen;
        let point;
        while (indexBeforeFlow--) {
          if (self.events[indexBeforeFlow][0] === "exit" && self.events[indexBeforeFlow][1].type === types.chunkFlow) {
            if (seen) {
              point = self.events[indexBeforeFlow][1].end;
              break;
            }
            seen = true;
          }
        }
        ok(point, "could not find previous flow chunk");
        exitContainers(continued);
        index = indexBeforeExits;
        while (index < self.events.length) {
          self.events[index][1].end = { ...point };
          index++;
        }
        splice(self.events, indexBeforeFlow + 1, 0, self.events.slice(indexBeforeExits));
        self.events.length = index;
      }
    }
    function exitContainers(size) {
      let index = stack.length;
      while (index-- > size) {
        const entry = stack[index];
        self.containerState = entry[1];
        ok(entry[0].exit, "expected `exit` to be defined on container construct");
        entry[0].exit.call(self, effects);
      }
      stack.length = size;
    }
    function closeFlow() {
      ok(self.containerState, "expected `containerState` to be defined when closing flow");
      ok(childFlow, "expected `childFlow` to be defined when closing it");
      childFlow.write([codes.eof]);
      childToken = undefined;
      childFlow = undefined;
      self.containerState._closeFlow = undefined;
    }
  }
  function tokenizeContainer(effects, ok3, nok) {
    ok(this.parser.constructs.disable.null, "expected `disable.null` to be populated");
    return factorySpace(effects, effects.attempt(this.parser.constructs.document, ok3, nok), types.linePrefix, this.parser.constructs.disable.null.includes("codeIndented") ? undefined : constants.tabSize);
  }

  // node_modules/micromark/dev/lib/initialize/flow.js
  var flow = { tokenize: initializeFlow };
  function initializeFlow(effects) {
    const self = this;
    const initial = effects.attempt(blankLine, atBlankEnding, effects.attempt(this.parser.constructs.flowInitial, afterConstruct, factorySpace(effects, effects.attempt(this.parser.constructs.flow, afterConstruct, effects.attempt(content, afterConstruct)), types.linePrefix)));
    return initial;
    function atBlankEnding(code3) {
      ok(code3 === codes.eof || markdownLineEnding(code3), "expected eol or eof");
      if (code3 === codes.eof) {
        effects.consume(code3);
        return;
      }
      effects.enter(types.lineEndingBlank);
      effects.consume(code3);
      effects.exit(types.lineEndingBlank);
      self.currentConstruct = undefined;
      return initial;
    }
    function afterConstruct(code3) {
      ok(code3 === codes.eof || markdownLineEnding(code3), "expected eol or eof");
      if (code3 === codes.eof) {
        effects.consume(code3);
        return;
      }
      effects.enter(types.lineEnding);
      effects.consume(code3);
      effects.exit(types.lineEnding);
      self.currentConstruct = undefined;
      return initial;
    }
  }

  // node_modules/micromark/dev/lib/initialize/text.js
  var resolver = { resolveAll: createResolver() };
  var string = initializeFactory("string");
  var text3 = initializeFactory("text");
  function initializeFactory(field) {
    return {
      resolveAll: createResolver(field === "text" ? resolveAllLineSuffixes : undefined),
      tokenize: initializeText
    };
    function initializeText(effects) {
      const self = this;
      const constructs2 = this.parser.constructs[field];
      const text4 = effects.attempt(constructs2, start, notText);
      return start;
      function start(code3) {
        return atBreak(code3) ? text4(code3) : notText(code3);
      }
      function notText(code3) {
        if (code3 === codes.eof) {
          effects.consume(code3);
          return;
        }
        effects.enter(types.data);
        effects.consume(code3);
        return data;
      }
      function data(code3) {
        if (atBreak(code3)) {
          effects.exit(types.data);
          return text4(code3);
        }
        effects.consume(code3);
        return data;
      }
      function atBreak(code3) {
        if (code3 === codes.eof) {
          return true;
        }
        const list3 = constructs2[code3];
        let index = -1;
        if (list3) {
          ok(Array.isArray(list3), "expected `disable.null` to be populated");
          while (++index < list3.length) {
            const item = list3[index];
            if (!item.previous || item.previous.call(self, self.previous)) {
              return true;
            }
          }
        }
        return false;
      }
    }
  }
  function createResolver(extraResolver) {
    return resolveAllText;
    function resolveAllText(events, context) {
      let index = -1;
      let enter;
      while (++index <= events.length) {
        if (enter === undefined) {
          if (events[index] && events[index][1].type === types.data) {
            enter = index;
            index++;
          }
        } else if (!events[index] || events[index][1].type !== types.data) {
          if (index !== enter + 2) {
            events[enter][1].end = events[index - 1][1].end;
            events.splice(enter + 2, index - enter - 2);
            index = enter + 2;
          }
          enter = undefined;
        }
      }
      return extraResolver ? extraResolver(events, context) : events;
    }
  }
  function resolveAllLineSuffixes(events, context) {
    let eventIndex = 0;
    while (++eventIndex <= events.length) {
      if ((eventIndex === events.length || events[eventIndex][1].type === types.lineEnding) && events[eventIndex - 1][1].type === types.data) {
        const data = events[eventIndex - 1][1];
        const chunks = context.sliceStream(data);
        let index = chunks.length;
        let bufferIndex = -1;
        let size = 0;
        let tabs;
        while (index--) {
          const chunk = chunks[index];
          if (typeof chunk === "string") {
            bufferIndex = chunk.length;
            while (chunk.charCodeAt(bufferIndex - 1) === codes.space) {
              size++;
              bufferIndex--;
            }
            if (bufferIndex)
              break;
            bufferIndex = -1;
          } else if (chunk === codes.horizontalTab) {
            tabs = true;
            size++;
          } else if (chunk === codes.virtualSpace) {} else {
            index++;
            break;
          }
        }
        if (context._contentTypeTextTrailing && eventIndex === events.length) {
          size = 0;
        }
        if (size) {
          const token = {
            type: eventIndex === events.length || tabs || size < constants.hardBreakPrefixSizeMin ? types.lineSuffix : types.hardBreakTrailing,
            start: {
              _bufferIndex: index ? bufferIndex : data.start._bufferIndex + bufferIndex,
              _index: data.start._index + index,
              line: data.end.line,
              column: data.end.column - size,
              offset: data.end.offset - size
            },
            end: { ...data.end }
          };
          data.end = { ...token.start };
          if (data.start.offset === data.end.offset) {
            Object.assign(data, token);
          } else {
            events.splice(eventIndex, 0, ["enter", token, context], ["exit", token, context]);
            eventIndex += 2;
          }
        }
        eventIndex++;
      }
    }
    return events;
  }

  // node_modules/micromark/dev/lib/constructs.js
  var exports_constructs = {};
  __export(exports_constructs, {
    text: () => text4,
    string: () => string2,
    insideSpan: () => insideSpan,
    flowInitial: () => flowInitial,
    flow: () => flow2,
    document: () => document3,
    disable: () => disable,
    contentInitial: () => contentInitial,
    attentionMarkers: () => attentionMarkers
  });
  var document3 = {
    [codes.asterisk]: list2,
    [codes.plusSign]: list2,
    [codes.dash]: list2,
    [codes.digit0]: list2,
    [codes.digit1]: list2,
    [codes.digit2]: list2,
    [codes.digit3]: list2,
    [codes.digit4]: list2,
    [codes.digit5]: list2,
    [codes.digit6]: list2,
    [codes.digit7]: list2,
    [codes.digit8]: list2,
    [codes.digit9]: list2,
    [codes.greaterThan]: blockQuote
  };
  var contentInitial = {
    [codes.leftSquareBracket]: definition2
  };
  var flowInitial = {
    [codes.horizontalTab]: codeIndented,
    [codes.virtualSpace]: codeIndented,
    [codes.space]: codeIndented
  };
  var flow2 = {
    [codes.numberSign]: headingAtx,
    [codes.asterisk]: thematicBreak2,
    [codes.dash]: [setextUnderline, thematicBreak2],
    [codes.lessThan]: htmlFlow,
    [codes.equalsTo]: setextUnderline,
    [codes.underscore]: thematicBreak2,
    [codes.graveAccent]: codeFenced,
    [codes.tilde]: codeFenced
  };
  var string2 = {
    [codes.ampersand]: characterReference,
    [codes.backslash]: characterEscape
  };
  var text4 = {
    [codes.carriageReturn]: lineEnding,
    [codes.lineFeed]: lineEnding,
    [codes.carriageReturnLineFeed]: lineEnding,
    [codes.exclamationMark]: labelStartImage,
    [codes.ampersand]: characterReference,
    [codes.asterisk]: attention,
    [codes.lessThan]: [autolink, htmlText],
    [codes.leftSquareBracket]: labelStartLink,
    [codes.backslash]: [hardBreakEscape, characterEscape],
    [codes.rightSquareBracket]: labelEnd,
    [codes.underscore]: attention,
    [codes.graveAccent]: codeText
  };
  var insideSpan = { null: [attention, resolver] };
  var attentionMarkers = { null: [codes.asterisk, codes.underscore] };
  var disable = { null: [] };

  // node_modules/micromark/dev/lib/create-tokenizer.js
  var import_debug = __toESM(require_browser(), 1);
  var debug = import_debug.default("micromark");
  function createTokenizer(parser, initialize, from) {
    let point = {
      _bufferIndex: -1,
      _index: 0,
      line: from && from.line || 1,
      column: from && from.column || 1,
      offset: from && from.offset || 0
    };
    const columnStart = {};
    const resolveAllConstructs = [];
    let chunks = [];
    let stack = [];
    let consumed = true;
    const effects = {
      attempt: constructFactory(onsuccessfulconstruct),
      check: constructFactory(onsuccessfulcheck),
      consume,
      enter,
      exit: exit3,
      interrupt: constructFactory(onsuccessfulcheck, { interrupt: true })
    };
    const context = {
      code: codes.eof,
      containerState: {},
      defineSkip,
      events: [],
      now,
      parser,
      previous: codes.eof,
      sliceSerialize,
      sliceStream,
      write
    };
    let state = initialize.tokenize.call(context, effects);
    let expectedCode;
    if (initialize.resolveAll) {
      resolveAllConstructs.push(initialize);
    }
    return context;
    function write(slice) {
      chunks = push(chunks, slice);
      main();
      if (chunks[chunks.length - 1] !== codes.eof) {
        return [];
      }
      addResult(initialize, 0);
      context.events = resolveAll(resolveAllConstructs, context.events, context);
      return context.events;
    }
    function sliceSerialize(token, expandTabs) {
      return serializeChunks(sliceStream(token), expandTabs);
    }
    function sliceStream(token) {
      return sliceChunks(chunks, token);
    }
    function now() {
      const { _bufferIndex, _index, line, column, offset } = point;
      return { _bufferIndex, _index, line, column, offset };
    }
    function defineSkip(value) {
      columnStart[value.line] = value.column;
      accountForPotentialSkip();
      debug("position: define skip: `%j`", point);
    }
    function main() {
      let chunkIndex;
      while (point._index < chunks.length) {
        const chunk = chunks[point._index];
        if (typeof chunk === "string") {
          chunkIndex = point._index;
          if (point._bufferIndex < 0) {
            point._bufferIndex = 0;
          }
          while (point._index === chunkIndex && point._bufferIndex < chunk.length) {
            go(chunk.charCodeAt(point._bufferIndex));
          }
        } else {
          go(chunk);
        }
      }
    }
    function go(code3) {
      ok(consumed === true, "expected character to be consumed");
      consumed = undefined;
      debug("main: passing `%s` to %s", code3, state && state.name);
      expectedCode = code3;
      ok(typeof state === "function", "expected state");
      state = state(code3);
    }
    function consume(code3) {
      ok(code3 === expectedCode, "expected given code to equal expected code");
      debug("consume: `%s`", code3);
      ok(consumed === undefined, "expected code to not have been consumed: this might be because `return x(code)` instead of `return x` was used");
      ok(code3 === null ? context.events.length === 0 || context.events[context.events.length - 1][0] === "exit" : context.events[context.events.length - 1][0] === "enter", "expected last token to be open");
      if (markdownLineEnding(code3)) {
        point.line++;
        point.column = 1;
        point.offset += code3 === codes.carriageReturnLineFeed ? 2 : 1;
        accountForPotentialSkip();
        debug("position: after eol: `%j`", point);
      } else if (code3 !== codes.virtualSpace) {
        point.column++;
        point.offset++;
      }
      if (point._bufferIndex < 0) {
        point._index++;
      } else {
        point._bufferIndex++;
        if (point._bufferIndex === chunks[point._index].length) {
          point._bufferIndex = -1;
          point._index++;
        }
      }
      context.previous = code3;
      consumed = true;
    }
    function enter(type, fields) {
      const token = fields || {};
      token.type = type;
      token.start = now();
      ok(typeof type === "string", "expected string type");
      ok(type.length > 0, "expected non-empty string");
      debug("enter: `%s`", type);
      context.events.push(["enter", token, context]);
      stack.push(token);
      return token;
    }
    function exit3(type) {
      ok(typeof type === "string", "expected string type");
      ok(type.length > 0, "expected non-empty string");
      const token = stack.pop();
      ok(token, "cannot close w/o open tokens");
      token.end = now();
      ok(type === token.type, "expected exit token to match current token");
      ok(!(token.start._index === token.end._index && token.start._bufferIndex === token.end._bufferIndex), "expected non-empty token (`" + type + "`)");
      debug("exit: `%s`", token.type);
      context.events.push(["exit", token, context]);
      return token;
    }
    function onsuccessfulconstruct(construct, info) {
      addResult(construct, info.from);
    }
    function onsuccessfulcheck(_, info) {
      info.restore();
    }
    function constructFactory(onreturn, fields) {
      return hook;
      function hook(constructs2, returnState, bogusState) {
        let listOfConstructs;
        let constructIndex;
        let currentConstruct;
        let info;
        return Array.isArray(constructs2) ? handleListOfConstructs(constructs2) : ("tokenize" in constructs2) ? handleListOfConstructs([constructs2]) : handleMapOfConstructs(constructs2);
        function handleMapOfConstructs(map3) {
          return start;
          function start(code3) {
            const left = code3 !== null && map3[code3];
            const all2 = code3 !== null && map3.null;
            const list3 = [
              ...Array.isArray(left) ? left : left ? [left] : [],
              ...Array.isArray(all2) ? all2 : all2 ? [all2] : []
            ];
            return handleListOfConstructs(list3)(code3);
          }
        }
        function handleListOfConstructs(list3) {
          listOfConstructs = list3;
          constructIndex = 0;
          if (list3.length === 0) {
            ok(bogusState, "expected `bogusState` to be given");
            return bogusState;
          }
          return handleConstruct(list3[constructIndex]);
        }
        function handleConstruct(construct) {
          return start;
          function start(code3) {
            info = store();
            currentConstruct = construct;
            if (!construct.partial) {
              context.currentConstruct = construct;
            }
            ok(context.parser.constructs.disable.null, "expected `disable.null` to be populated");
            if (construct.name && context.parser.constructs.disable.null.includes(construct.name)) {
              return nok(code3);
            }
            return construct.tokenize.call(fields ? Object.assign(Object.create(context), fields) : context, effects, ok3, nok)(code3);
          }
        }
        function ok3(code3) {
          ok(code3 === expectedCode, "expected code");
          consumed = true;
          onreturn(currentConstruct, info);
          return returnState;
        }
        function nok(code3) {
          ok(code3 === expectedCode, "expected code");
          consumed = true;
          info.restore();
          if (++constructIndex < listOfConstructs.length) {
            return handleConstruct(listOfConstructs[constructIndex]);
          }
          return bogusState;
        }
      }
    }
    function addResult(construct, from2) {
      if (construct.resolveAll && !resolveAllConstructs.includes(construct)) {
        resolveAllConstructs.push(construct);
      }
      if (construct.resolve) {
        splice(context.events, from2, context.events.length - from2, construct.resolve(context.events.slice(from2), context));
      }
      if (construct.resolveTo) {
        context.events = construct.resolveTo(context.events, context);
      }
      ok(construct.partial || context.events.length === 0 || context.events[context.events.length - 1][0] === "exit", "expected last token to end");
    }
    function store() {
      const startPoint = now();
      const startPrevious = context.previous;
      const startCurrentConstruct = context.currentConstruct;
      const startEventsIndex = context.events.length;
      const startStack = Array.from(stack);
      return { from: startEventsIndex, restore };
      function restore() {
        point = startPoint;
        context.previous = startPrevious;
        context.currentConstruct = startCurrentConstruct;
        context.events.length = startEventsIndex;
        stack = startStack;
        accountForPotentialSkip();
        debug("position: restore: `%j`", point);
      }
    }
    function accountForPotentialSkip() {
      if (point.line in columnStart && point.column < 2) {
        point.column = columnStart[point.line];
        point.offset += columnStart[point.line] - 1;
      }
    }
  }
  function sliceChunks(chunks, token) {
    const startIndex = token.start._index;
    const startBufferIndex = token.start._bufferIndex;
    const endIndex = token.end._index;
    const endBufferIndex = token.end._bufferIndex;
    let view;
    if (startIndex === endIndex) {
      ok(endBufferIndex > -1, "expected non-negative end buffer index");
      ok(startBufferIndex > -1, "expected non-negative start buffer index");
      view = [chunks[startIndex].slice(startBufferIndex, endBufferIndex)];
    } else {
      view = chunks.slice(startIndex, endIndex);
      if (startBufferIndex > -1) {
        const head = view[0];
        if (typeof head === "string") {
          view[0] = head.slice(startBufferIndex);
        } else {
          ok(startBufferIndex === 0, "expected `startBufferIndex` to be `0`");
          view.shift();
        }
      }
      if (endBufferIndex > 0) {
        view.push(chunks[endIndex].slice(0, endBufferIndex));
      }
    }
    return view;
  }
  function serializeChunks(chunks, expandTabs) {
    let index = -1;
    const result = [];
    let atTab;
    while (++index < chunks.length) {
      const chunk = chunks[index];
      let value;
      if (typeof chunk === "string") {
        value = chunk;
      } else
        switch (chunk) {
          case codes.carriageReturn: {
            value = values.cr;
            break;
          }
          case codes.lineFeed: {
            value = values.lf;
            break;
          }
          case codes.carriageReturnLineFeed: {
            value = values.cr + values.lf;
            break;
          }
          case codes.horizontalTab: {
            value = expandTabs ? values.space : values.ht;
            break;
          }
          case codes.virtualSpace: {
            if (!expandTabs && atTab)
              continue;
            value = values.space;
            break;
          }
          default: {
            ok(typeof chunk === "number", "expected number");
            value = String.fromCharCode(chunk);
          }
        }
      atTab = chunk === codes.horizontalTab;
      result.push(value);
    }
    return result.join("");
  }

  // node_modules/micromark/dev/lib/parse.js
  function parse(options) {
    const settings = options || {};
    const constructs2 = combineExtensions([exports_constructs, ...settings.extensions || []]);
    const parser = {
      constructs: constructs2,
      content: create(content2),
      defined: [],
      document: create(document2),
      flow: create(flow),
      lazy: {},
      string: create(string),
      text: create(text3)
    };
    return parser;
    function create(initial) {
      return creator;
      function creator(from) {
        return createTokenizer(parser, initial, from);
      }
    }
  }

  // node_modules/micromark/dev/lib/postprocess.js
  function postprocess(events) {
    while (!subtokenize(events)) {}
    return events;
  }

  // node_modules/micromark/dev/lib/preprocess.js
  var search = /[\0\t\n\r]/g;
  function preprocess() {
    let column = 1;
    let buffer = "";
    let start = true;
    let atCarriageReturn;
    return preprocessor;
    function preprocessor(value, encoding, end) {
      const chunks = [];
      let match;
      let next;
      let startPosition;
      let endPosition;
      let code3;
      value = buffer + (typeof value === "string" ? value.toString() : new TextDecoder(encoding || undefined).decode(value));
      startPosition = 0;
      buffer = "";
      if (start) {
        if (value.charCodeAt(0) === codes.byteOrderMarker) {
          startPosition++;
        }
        start = undefined;
      }
      while (startPosition < value.length) {
        search.lastIndex = startPosition;
        match = search.exec(value);
        endPosition = match && match.index !== undefined ? match.index : value.length;
        code3 = value.charCodeAt(endPosition);
        if (!match) {
          buffer = value.slice(startPosition);
          break;
        }
        if (code3 === codes.lf && startPosition === endPosition && atCarriageReturn) {
          chunks.push(codes.carriageReturnLineFeed);
          atCarriageReturn = undefined;
        } else {
          if (atCarriageReturn) {
            chunks.push(codes.carriageReturn);
            atCarriageReturn = undefined;
          }
          if (startPosition < endPosition) {
            chunks.push(value.slice(startPosition, endPosition));
            column += endPosition - startPosition;
          }
          switch (code3) {
            case codes.nul: {
              chunks.push(codes.replacementCharacter);
              column++;
              break;
            }
            case codes.ht: {
              next = Math.ceil(column / constants.tabSize) * constants.tabSize;
              chunks.push(codes.horizontalTab);
              while (column++ < next)
                chunks.push(codes.virtualSpace);
              break;
            }
            case codes.lf: {
              chunks.push(codes.lineFeed);
              column = 1;
              break;
            }
            default: {
              atCarriageReturn = true;
              column = 1;
            }
          }
        }
        startPosition = endPosition + 1;
      }
      if (end) {
        if (atCarriageReturn)
          chunks.push(codes.carriageReturn);
        if (buffer)
          chunks.push(buffer);
        chunks.push(codes.eof);
      }
      return chunks;
    }
  }
  // node_modules/micromark-util-decode-string/dev/index.js
  var characterEscapeOrReference = /\\([!-/:-@[-`{-~])|&(#(?:\d{1,7}|x[\da-f]{1,6})|[\da-z]{1,31});/gi;
  function decodeString(value) {
    return value.replace(characterEscapeOrReference, decode);
  }
  function decode($0, $1, $2) {
    if ($1) {
      return $1;
    }
    const head = $2.charCodeAt(0);
    if (head === codes.numberSign) {
      const head2 = $2.charCodeAt(1);
      const hex = head2 === codes.lowercaseX || head2 === codes.uppercaseX;
      return decodeNumericCharacterReference($2.slice(hex ? 2 : 1), hex ? constants.numericBaseHexadecimal : constants.numericBaseDecimal);
    }
    return decodeNamedCharacterReference($2) || $0;
  }

  // node_modules/unist-util-stringify-position/lib/index.js
  function stringifyPosition(value) {
    if (!value || typeof value !== "object") {
      return "";
    }
    if ("position" in value || "type" in value) {
      return position(value.position);
    }
    if ("start" in value || "end" in value) {
      return position(value);
    }
    if ("line" in value || "column" in value) {
      return point(value);
    }
    return "";
  }
  function point(point2) {
    return index(point2 && point2.line) + ":" + index(point2 && point2.column);
  }
  function position(pos) {
    return point(pos && pos.start) + "-" + point(pos && pos.end);
  }
  function index(value) {
    return value && typeof value === "number" ? value : 1;
  }
  // node_modules/mdast-util-from-markdown/dev/lib/index.js
  var own = {}.hasOwnProperty;
  function fromMarkdown(value, encoding, options) {
    if (encoding && typeof encoding === "object") {
      options = encoding;
      encoding = undefined;
    }
    return compiler(options)(postprocess(parse(options).document().write(preprocess()(value, encoding, true))));
  }
  function compiler(options) {
    const config = {
      transforms: [],
      canContainEols: ["emphasis", "fragment", "heading", "paragraph", "strong"],
      enter: {
        autolink: opener(link2),
        autolinkProtocol: onenterdata,
        autolinkEmail: onenterdata,
        atxHeading: opener(heading2),
        blockQuote: opener(blockQuote2),
        characterEscape: onenterdata,
        characterReference: onenterdata,
        codeFenced: opener(codeFlow),
        codeFencedFenceInfo: buffer,
        codeFencedFenceMeta: buffer,
        codeIndented: opener(codeFlow, buffer),
        codeText: opener(codeText2, buffer),
        codeTextData: onenterdata,
        data: onenterdata,
        codeFlowValue: onenterdata,
        definition: opener(definition3),
        definitionDestinationString: buffer,
        definitionLabelString: buffer,
        definitionTitleString: buffer,
        emphasis: opener(emphasis2),
        hardBreakEscape: opener(hardBreak2),
        hardBreakTrailing: opener(hardBreak2),
        htmlFlow: opener(html2, buffer),
        htmlFlowData: onenterdata,
        htmlText: opener(html2, buffer),
        htmlTextData: onenterdata,
        image: opener(image2),
        label: buffer,
        link: opener(link2),
        listItem: opener(listItem2),
        listItemValue: onenterlistitemvalue,
        listOrdered: opener(list3, onenterlistordered),
        listUnordered: opener(list3),
        paragraph: opener(paragraph2),
        reference: onenterreference,
        referenceString: buffer,
        resourceDestinationString: buffer,
        resourceTitleString: buffer,
        setextHeading: opener(heading2),
        strong: opener(strong2),
        thematicBreak: opener(thematicBreak3)
      },
      exit: {
        atxHeading: closer(),
        atxHeadingSequence: onexitatxheadingsequence,
        autolink: closer(),
        autolinkEmail: onexitautolinkemail,
        autolinkProtocol: onexitautolinkprotocol,
        blockQuote: closer(),
        characterEscapeValue: onexitdata,
        characterReferenceMarkerHexadecimal: onexitcharacterreferencemarker,
        characterReferenceMarkerNumeric: onexitcharacterreferencemarker,
        characterReferenceValue: onexitcharacterreferencevalue,
        characterReference: onexitcharacterreference,
        codeFenced: closer(onexitcodefenced),
        codeFencedFence: onexitcodefencedfence,
        codeFencedFenceInfo: onexitcodefencedfenceinfo,
        codeFencedFenceMeta: onexitcodefencedfencemeta,
        codeFlowValue: onexitdata,
        codeIndented: closer(onexitcodeindented),
        codeText: closer(onexitcodetext),
        codeTextData: onexitdata,
        data: onexitdata,
        definition: closer(),
        definitionDestinationString: onexitdefinitiondestinationstring,
        definitionLabelString: onexitdefinitionlabelstring,
        definitionTitleString: onexitdefinitiontitlestring,
        emphasis: closer(),
        hardBreakEscape: closer(onexithardbreak),
        hardBreakTrailing: closer(onexithardbreak),
        htmlFlow: closer(onexithtmlflow),
        htmlFlowData: onexitdata,
        htmlText: closer(onexithtmltext),
        htmlTextData: onexitdata,
        image: closer(onexitimage),
        label: onexitlabel,
        labelText: onexitlabeltext,
        lineEnding: onexitlineending,
        link: closer(onexitlink),
        listItem: closer(),
        listOrdered: closer(),
        listUnordered: closer(),
        paragraph: closer(),
        referenceString: onexitreferencestring,
        resourceDestinationString: onexitresourcedestinationstring,
        resourceTitleString: onexitresourcetitlestring,
        resource: onexitresource,
        setextHeading: closer(onexitsetextheading),
        setextHeadingLineSequence: onexitsetextheadinglinesequence,
        setextHeadingText: onexitsetextheadingtext,
        strong: closer(),
        thematicBreak: closer()
      }
    };
    configure(config, (options || {}).mdastExtensions || []);
    const data = {};
    return compile;
    function compile(events) {
      let tree = { type: "root", children: [] };
      const context = {
        stack: [tree],
        tokenStack: [],
        config,
        enter,
        exit: exit3,
        buffer,
        resume,
        data
      };
      const listStack = [];
      let index2 = -1;
      while (++index2 < events.length) {
        if (events[index2][1].type === types.listOrdered || events[index2][1].type === types.listUnordered) {
          if (events[index2][0] === "enter") {
            listStack.push(index2);
          } else {
            const tail = listStack.pop();
            ok(typeof tail === "number", "expected list to be open");
            index2 = prepareList(events, tail, index2);
          }
        }
      }
      index2 = -1;
      while (++index2 < events.length) {
        const handler = config[events[index2][0]];
        if (own.call(handler, events[index2][1].type)) {
          handler[events[index2][1].type].call(Object.assign({ sliceSerialize: events[index2][2].sliceSerialize }, context), events[index2][1]);
        }
      }
      if (context.tokenStack.length > 0) {
        const tail = context.tokenStack[context.tokenStack.length - 1];
        const handler = tail[1] || defaultOnError;
        handler.call(context, undefined, tail[0]);
      }
      tree.position = {
        start: point2(events.length > 0 ? events[0][1].start : { line: 1, column: 1, offset: 0 }),
        end: point2(events.length > 0 ? events[events.length - 2][1].end : { line: 1, column: 1, offset: 0 })
      };
      index2 = -1;
      while (++index2 < config.transforms.length) {
        tree = config.transforms[index2](tree) || tree;
      }
      return tree;
    }
    function prepareList(events, start, length) {
      let index2 = start - 1;
      let containerBalance = -1;
      let listSpread = false;
      let listItem3;
      let lineIndex;
      let firstBlankLineIndex;
      let atMarker;
      while (++index2 <= length) {
        const event = events[index2];
        switch (event[1].type) {
          case types.listUnordered:
          case types.listOrdered:
          case types.blockQuote: {
            if (event[0] === "enter") {
              containerBalance++;
            } else {
              containerBalance--;
            }
            atMarker = undefined;
            break;
          }
          case types.lineEndingBlank: {
            if (event[0] === "enter") {
              if (listItem3 && !atMarker && !containerBalance && !firstBlankLineIndex) {
                firstBlankLineIndex = index2;
              }
              atMarker = undefined;
            }
            break;
          }
          case types.linePrefix:
          case types.listItemValue:
          case types.listItemMarker:
          case types.listItemPrefix:
          case types.listItemPrefixWhitespace: {
            break;
          }
          default: {
            atMarker = undefined;
          }
        }
        if (!containerBalance && event[0] === "enter" && event[1].type === types.listItemPrefix || containerBalance === -1 && event[0] === "exit" && (event[1].type === types.listUnordered || event[1].type === types.listOrdered)) {
          if (listItem3) {
            let tailIndex = index2;
            lineIndex = undefined;
            while (tailIndex--) {
              const tailEvent = events[tailIndex];
              if (tailEvent[1].type === types.lineEnding || tailEvent[1].type === types.lineEndingBlank) {
                if (tailEvent[0] === "exit")
                  continue;
                if (lineIndex) {
                  events[lineIndex][1].type = types.lineEndingBlank;
                  listSpread = true;
                }
                tailEvent[1].type = types.lineEnding;
                lineIndex = tailIndex;
              } else if (tailEvent[1].type === types.linePrefix || tailEvent[1].type === types.blockQuotePrefix || tailEvent[1].type === types.blockQuotePrefixWhitespace || tailEvent[1].type === types.blockQuoteMarker || tailEvent[1].type === types.listItemIndent) {} else {
                break;
              }
            }
            if (firstBlankLineIndex && (!lineIndex || firstBlankLineIndex < lineIndex)) {
              listItem3._spread = true;
            }
            listItem3.end = Object.assign({}, lineIndex ? events[lineIndex][1].start : event[1].end);
            events.splice(lineIndex || index2, 0, ["exit", listItem3, event[2]]);
            index2++;
            length++;
          }
          if (event[1].type === types.listItemPrefix) {
            const item = {
              type: "listItem",
              _spread: false,
              start: Object.assign({}, event[1].start),
              end: undefined
            };
            listItem3 = item;
            events.splice(index2, 0, ["enter", item, event[2]]);
            index2++;
            length++;
            firstBlankLineIndex = undefined;
            atMarker = true;
          }
        }
      }
      events[start][1]._spread = listSpread;
      return length;
    }
    function opener(create, and) {
      return open;
      function open(token) {
        enter.call(this, create(token), token);
        if (and)
          and.call(this, token);
      }
    }
    function buffer() {
      this.stack.push({ type: "fragment", children: [] });
    }
    function enter(node2, token, errorHandler) {
      const parent = this.stack[this.stack.length - 1];
      ok(parent, "expected `parent`");
      ok("children" in parent, "expected `parent`");
      const siblings = parent.children;
      siblings.push(node2);
      this.stack.push(node2);
      this.tokenStack.push([token, errorHandler || undefined]);
      node2.position = {
        start: point2(token.start),
        end: undefined
      };
    }
    function closer(and) {
      return close;
      function close(token) {
        if (and)
          and.call(this, token);
        exit3.call(this, token);
      }
    }
    function exit3(token, onExitError) {
      const node2 = this.stack.pop();
      ok(node2, "expected `node`");
      const open = this.tokenStack.pop();
      if (!open) {
        throw new Error("Cannot close `" + token.type + "` (" + stringifyPosition({ start: token.start, end: token.end }) + "): it’s not open");
      } else if (open[0].type !== token.type) {
        if (onExitError) {
          onExitError.call(this, token, open[0]);
        } else {
          const handler = open[1] || defaultOnError;
          handler.call(this, token, open[0]);
        }
      }
      ok(node2.type !== "fragment", "unexpected fragment `exit`ed");
      ok(node2.position, "expected `position` to be defined");
      node2.position.end = point2(token.end);
    }
    function resume() {
      return toString(this.stack.pop());
    }
    function onenterlistordered() {
      this.data.expectingFirstListItemValue = true;
    }
    function onenterlistitemvalue(token) {
      if (this.data.expectingFirstListItemValue) {
        const ancestor = this.stack[this.stack.length - 2];
        ok(ancestor, "expected nodes on stack");
        ok(ancestor.type === "list", "expected list on stack");
        ancestor.start = Number.parseInt(this.sliceSerialize(token), constants.numericBaseDecimal);
        this.data.expectingFirstListItemValue = undefined;
      }
    }
    function onexitcodefencedfenceinfo() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "code", "expected code on stack");
      node2.lang = data2;
    }
    function onexitcodefencedfencemeta() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "code", "expected code on stack");
      node2.meta = data2;
    }
    function onexitcodefencedfence() {
      if (this.data.flowCodeInside)
        return;
      this.buffer();
      this.data.flowCodeInside = true;
    }
    function onexitcodefenced() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "code", "expected code on stack");
      node2.value = data2.replace(/^(\r?\n|\r)|(\r?\n|\r)$/g, "");
      this.data.flowCodeInside = undefined;
    }
    function onexitcodeindented() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "code", "expected code on stack");
      node2.value = data2.replace(/(\r?\n|\r)$/g, "");
    }
    function onexitdefinitionlabelstring(token) {
      const label = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "definition", "expected definition on stack");
      node2.label = label;
      node2.identifier = normalizeIdentifier(this.sliceSerialize(token)).toLowerCase();
    }
    function onexitdefinitiontitlestring() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "definition", "expected definition on stack");
      node2.title = data2;
    }
    function onexitdefinitiondestinationstring() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "definition", "expected definition on stack");
      node2.url = data2;
    }
    function onexitatxheadingsequence(token) {
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "heading", "expected heading on stack");
      if (!node2.depth) {
        const depth = this.sliceSerialize(token).length;
        ok(depth === 1 || depth === 2 || depth === 3 || depth === 4 || depth === 5 || depth === 6, "expected `depth` between `1` and `6`");
        node2.depth = depth;
      }
    }
    function onexitsetextheadingtext() {
      this.data.setextHeadingSlurpLineEnding = true;
    }
    function onexitsetextheadinglinesequence(token) {
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "heading", "expected heading on stack");
      node2.depth = this.sliceSerialize(token).codePointAt(0) === codes.equalsTo ? 1 : 2;
    }
    function onexitsetextheading() {
      this.data.setextHeadingSlurpLineEnding = undefined;
    }
    function onenterdata(token) {
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok("children" in node2, "expected parent on stack");
      const siblings = node2.children;
      let tail = siblings[siblings.length - 1];
      if (!tail || tail.type !== "text") {
        tail = text5();
        tail.position = {
          start: point2(token.start),
          end: undefined
        };
        siblings.push(tail);
      }
      this.stack.push(tail);
    }
    function onexitdata(token) {
      const tail = this.stack.pop();
      ok(tail, "expected a `node` to be on the stack");
      ok("value" in tail, "expected a `literal` to be on the stack");
      ok(tail.position, "expected `node` to have an open position");
      tail.value += this.sliceSerialize(token);
      tail.position.end = point2(token.end);
    }
    function onexitlineending(token) {
      const context = this.stack[this.stack.length - 1];
      ok(context, "expected `node`");
      if (this.data.atHardBreak) {
        ok("children" in context, "expected `parent`");
        const tail = context.children[context.children.length - 1];
        ok(tail.position, "expected tail to have a starting position");
        tail.position.end = point2(token.end);
        this.data.atHardBreak = undefined;
        return;
      }
      if (!this.data.setextHeadingSlurpLineEnding && config.canContainEols.includes(context.type)) {
        onenterdata.call(this, token);
        onexitdata.call(this, token);
      }
    }
    function onexithardbreak() {
      this.data.atHardBreak = true;
    }
    function onexithtmlflow() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "html", "expected html on stack");
      node2.value = data2;
    }
    function onexithtmltext() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "html", "expected html on stack");
      node2.value = data2;
    }
    function onexitcodetext() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "inlineCode", "expected inline code on stack");
      node2.value = data2;
    }
    function onexitlink() {
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "link", "expected link on stack");
      if (this.data.inReference) {
        const referenceType = this.data.referenceType || "shortcut";
        node2.type += "Reference";
        node2.referenceType = referenceType;
        delete node2.url;
        delete node2.title;
      } else {
        delete node2.identifier;
        delete node2.label;
      }
      this.data.referenceType = undefined;
    }
    function onexitimage() {
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "image", "expected image on stack");
      if (this.data.inReference) {
        const referenceType = this.data.referenceType || "shortcut";
        node2.type += "Reference";
        node2.referenceType = referenceType;
        delete node2.url;
        delete node2.title;
      } else {
        delete node2.identifier;
        delete node2.label;
      }
      this.data.referenceType = undefined;
    }
    function onexitlabeltext(token) {
      const string3 = this.sliceSerialize(token);
      const ancestor = this.stack[this.stack.length - 2];
      ok(ancestor, "expected ancestor on stack");
      ok(ancestor.type === "image" || ancestor.type === "link", "expected image or link on stack");
      ancestor.label = decodeString(string3);
      ancestor.identifier = normalizeIdentifier(string3).toLowerCase();
    }
    function onexitlabel() {
      const fragment = this.stack[this.stack.length - 1];
      ok(fragment, "expected node on stack");
      ok(fragment.type === "fragment", "expected fragment on stack");
      const value = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "image" || node2.type === "link", "expected image or link on stack");
      this.data.inReference = true;
      if (node2.type === "link") {
        const children = fragment.children;
        node2.children = children;
      } else {
        node2.alt = value;
      }
    }
    function onexitresourcedestinationstring() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "image" || node2.type === "link", "expected image or link on stack");
      node2.url = data2;
    }
    function onexitresourcetitlestring() {
      const data2 = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "image" || node2.type === "link", "expected image or link on stack");
      node2.title = data2;
    }
    function onexitresource() {
      this.data.inReference = undefined;
    }
    function onenterreference() {
      this.data.referenceType = "collapsed";
    }
    function onexitreferencestring(token) {
      const label = this.resume();
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "image" || node2.type === "link", "expected image reference or link reference on stack");
      node2.label = label;
      node2.identifier = normalizeIdentifier(this.sliceSerialize(token)).toLowerCase();
      this.data.referenceType = "full";
    }
    function onexitcharacterreferencemarker(token) {
      ok(token.type === "characterReferenceMarkerNumeric" || token.type === "characterReferenceMarkerHexadecimal");
      this.data.characterReferenceType = token.type;
    }
    function onexitcharacterreferencevalue(token) {
      const data2 = this.sliceSerialize(token);
      const type = this.data.characterReferenceType;
      let value;
      if (type) {
        value = decodeNumericCharacterReference(data2, type === types.characterReferenceMarkerNumeric ? constants.numericBaseDecimal : constants.numericBaseHexadecimal);
        this.data.characterReferenceType = undefined;
      } else {
        const result = decodeNamedCharacterReference(data2);
        ok(result !== false, "expected reference to decode");
        value = result;
      }
      const tail = this.stack[this.stack.length - 1];
      ok(tail, "expected `node`");
      ok("value" in tail, "expected `node.value`");
      tail.value += value;
    }
    function onexitcharacterreference(token) {
      const tail = this.stack.pop();
      ok(tail, "expected `node`");
      ok(tail.position, "expected `node.position`");
      tail.position.end = point2(token.end);
    }
    function onexitautolinkprotocol(token) {
      onexitdata.call(this, token);
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "link", "expected link on stack");
      node2.url = this.sliceSerialize(token);
    }
    function onexitautolinkemail(token) {
      onexitdata.call(this, token);
      const node2 = this.stack[this.stack.length - 1];
      ok(node2, "expected node on stack");
      ok(node2.type === "link", "expected link on stack");
      node2.url = "mailto:" + this.sliceSerialize(token);
    }
    function blockQuote2() {
      return { type: "blockquote", children: [] };
    }
    function codeFlow() {
      return { type: "code", lang: null, meta: null, value: "" };
    }
    function codeText2() {
      return { type: "inlineCode", value: "" };
    }
    function definition3() {
      return {
        type: "definition",
        identifier: "",
        label: null,
        title: null,
        url: ""
      };
    }
    function emphasis2() {
      return { type: "emphasis", children: [] };
    }
    function heading2() {
      return {
        type: "heading",
        depth: 0,
        children: []
      };
    }
    function hardBreak2() {
      return { type: "break" };
    }
    function html2() {
      return { type: "html", value: "" };
    }
    function image2() {
      return { type: "image", title: null, url: "", alt: null };
    }
    function link2() {
      return { type: "link", title: null, url: "", children: [] };
    }
    function list3(token) {
      return {
        type: "list",
        ordered: token.type === "listOrdered",
        start: null,
        spread: token._spread,
        children: []
      };
    }
    function listItem2(token) {
      return {
        type: "listItem",
        spread: token._spread,
        checked: null,
        children: []
      };
    }
    function paragraph2() {
      return { type: "paragraph", children: [] };
    }
    function strong2() {
      return { type: "strong", children: [] };
    }
    function text5() {
      return { type: "text", value: "" };
    }
    function thematicBreak3() {
      return { type: "thematicBreak" };
    }
  }
  function point2(d) {
    return { line: d.line, column: d.column, offset: d.offset };
  }
  function configure(combined, extensions) {
    let index2 = -1;
    while (++index2 < extensions.length) {
      const value = extensions[index2];
      if (Array.isArray(value)) {
        configure(combined, value);
      } else {
        extension(combined, value);
      }
    }
  }
  function extension(combined, extension2) {
    let key;
    for (key in extension2) {
      if (own.call(extension2, key)) {
        switch (key) {
          case "canContainEols": {
            const right = extension2[key];
            if (right) {
              combined[key].push(...right);
            }
            break;
          }
          case "transforms": {
            const right = extension2[key];
            if (right) {
              combined[key].push(...right);
            }
            break;
          }
          case "enter":
          case "exit": {
            const right = extension2[key];
            if (right) {
              Object.assign(combined[key], right);
            }
            break;
          }
        }
      }
    }
  }
  function defaultOnError(left, right) {
    if (left) {
      throw new Error("Cannot close `" + left.type + "` (" + stringifyPosition({ start: left.start, end: left.end }) + "): a different token (`" + right.type + "`, " + stringifyPosition({ start: right.start, end: right.end }) + ") is open");
    } else {
      throw new Error("Cannot close document, a token (`" + right.type + "`, " + stringifyPosition({ start: right.start, end: right.end }) + ") is still open");
    }
  }
  // node_modules/remark-parse/lib/index.js
  function remarkParse(options) {
    const self = this;
    self.parser = parser;
    function parser(doc) {
      return fromMarkdown(doc, {
        ...self.data("settings"),
        ...options,
        extensions: self.data("micromarkExtensions") || [],
        mdastExtensions: self.data("fromMarkdownExtensions") || []
      });
    }
  }
  // node_modules/bail/index.js
  function bail(error) {
    if (error) {
      throw error;
    }
  }

  // node_modules/unified/lib/index.js
  var import_extend = __toESM(require_extend(), 1);

  // node_modules/is-plain-obj/index.js
  function isPlainObject(value) {
    if (typeof value !== "object" || value === null) {
      return false;
    }
    const prototype = Object.getPrototypeOf(value);
    return (prototype === null || prototype === Object.prototype || Object.getPrototypeOf(prototype) === null) && !(Symbol.toStringTag in value) && !(Symbol.iterator in value);
  }

  // node_modules/trough/lib/index.js
  function trough() {
    const fns = [];
    const pipeline = { run, use };
    return pipeline;
    function run(...values2) {
      let middlewareIndex = -1;
      const callback = values2.pop();
      if (typeof callback !== "function") {
        throw new TypeError("Expected function as last argument, not " + callback);
      }
      next(null, ...values2);
      function next(error, ...output) {
        const fn = fns[++middlewareIndex];
        let index2 = -1;
        if (error) {
          callback(error);
          return;
        }
        while (++index2 < values2.length) {
          if (output[index2] === null || output[index2] === undefined) {
            output[index2] = values2[index2];
          }
        }
        values2 = output;
        if (fn) {
          wrap(fn, next)(...output);
        } else {
          callback(null, ...output);
        }
      }
    }
    function use(middelware) {
      if (typeof middelware !== "function") {
        throw new TypeError("Expected `middelware` to be a function, not " + middelware);
      }
      fns.push(middelware);
      return pipeline;
    }
  }
  function wrap(middleware, callback) {
    let called;
    return wrapped;
    function wrapped(...parameters) {
      const fnExpectsCallback = middleware.length > parameters.length;
      let result;
      if (fnExpectsCallback) {
        parameters.push(done);
      }
      try {
        result = middleware.apply(this, parameters);
      } catch (error) {
        const exception = error;
        if (fnExpectsCallback && called) {
          throw exception;
        }
        return done(exception);
      }
      if (!fnExpectsCallback) {
        if (result && result.then && typeof result.then === "function") {
          result.then(then, done);
        } else if (result instanceof Error) {
          done(result);
        } else {
          then(result);
        }
      }
    }
    function done(error, ...output) {
      if (!called) {
        called = true;
        callback(error, ...output);
      }
    }
    function then(value) {
      done(null, value);
    }
  }
  // node_modules/vfile-message/lib/index.js
  class VFileMessage extends Error {
    constructor(causeOrReason, optionsOrParentOrPlace, origin) {
      super();
      if (typeof optionsOrParentOrPlace === "string") {
        origin = optionsOrParentOrPlace;
        optionsOrParentOrPlace = undefined;
      }
      let reason = "";
      let options = {};
      let legacyCause = false;
      if (optionsOrParentOrPlace) {
        if ("line" in optionsOrParentOrPlace && "column" in optionsOrParentOrPlace) {
          options = { place: optionsOrParentOrPlace };
        } else if ("start" in optionsOrParentOrPlace && "end" in optionsOrParentOrPlace) {
          options = { place: optionsOrParentOrPlace };
        } else if ("type" in optionsOrParentOrPlace) {
          options = {
            ancestors: [optionsOrParentOrPlace],
            place: optionsOrParentOrPlace.position
          };
        } else {
          options = { ...optionsOrParentOrPlace };
        }
      }
      if (typeof causeOrReason === "string") {
        reason = causeOrReason;
      } else if (!options.cause && causeOrReason) {
        legacyCause = true;
        reason = causeOrReason.message;
        options.cause = causeOrReason;
      }
      if (!options.ruleId && !options.source && typeof origin === "string") {
        const index2 = origin.indexOf(":");
        if (index2 === -1) {
          options.ruleId = origin;
        } else {
          options.source = origin.slice(0, index2);
          options.ruleId = origin.slice(index2 + 1);
        }
      }
      if (!options.place && options.ancestors && options.ancestors) {
        const parent = options.ancestors[options.ancestors.length - 1];
        if (parent) {
          options.place = parent.position;
        }
      }
      const start = options.place && "start" in options.place ? options.place.start : options.place;
      this.ancestors = options.ancestors || undefined;
      this.cause = options.cause || undefined;
      this.column = start ? start.column : undefined;
      this.fatal = undefined;
      this.file = "";
      this.message = reason;
      this.line = start ? start.line : undefined;
      this.name = stringifyPosition(options.place) || "1:1";
      this.place = options.place || undefined;
      this.reason = this.message;
      this.ruleId = options.ruleId || undefined;
      this.source = options.source || undefined;
      this.stack = legacyCause && options.cause && typeof options.cause.stack === "string" ? options.cause.stack : "";
      this.actual = undefined;
      this.expected = undefined;
      this.note = undefined;
      this.url = undefined;
    }
  }
  VFileMessage.prototype.file = "";
  VFileMessage.prototype.name = "";
  VFileMessage.prototype.reason = "";
  VFileMessage.prototype.message = "";
  VFileMessage.prototype.stack = "";
  VFileMessage.prototype.column = undefined;
  VFileMessage.prototype.line = undefined;
  VFileMessage.prototype.ancestors = undefined;
  VFileMessage.prototype.cause = undefined;
  VFileMessage.prototype.fatal = undefined;
  VFileMessage.prototype.place = undefined;
  VFileMessage.prototype.ruleId = undefined;
  VFileMessage.prototype.source = undefined;
  // node_modules/vfile/lib/minpath.browser.js
  var minpath = { basename, dirname, extname, join, sep: "/" };
  function basename(path2, extname) {
    if (extname !== undefined && typeof extname !== "string") {
      throw new TypeError('"ext" argument must be a string');
    }
    assertPath(path2);
    let start = 0;
    let end = -1;
    let index2 = path2.length;
    let seenNonSlash;
    if (extname === undefined || extname.length === 0 || extname.length > path2.length) {
      while (index2--) {
        if (path2.codePointAt(index2) === 47) {
          if (seenNonSlash) {
            start = index2 + 1;
            break;
          }
        } else if (end < 0) {
          seenNonSlash = true;
          end = index2 + 1;
        }
      }
      return end < 0 ? "" : path2.slice(start, end);
    }
    if (extname === path2) {
      return "";
    }
    let firstNonSlashEnd = -1;
    let extnameIndex = extname.length - 1;
    while (index2--) {
      if (path2.codePointAt(index2) === 47) {
        if (seenNonSlash) {
          start = index2 + 1;
          break;
        }
      } else {
        if (firstNonSlashEnd < 0) {
          seenNonSlash = true;
          firstNonSlashEnd = index2 + 1;
        }
        if (extnameIndex > -1) {
          if (path2.codePointAt(index2) === extname.codePointAt(extnameIndex--)) {
            if (extnameIndex < 0) {
              end = index2;
            }
          } else {
            extnameIndex = -1;
            end = firstNonSlashEnd;
          }
        }
      }
    }
    if (start === end) {
      end = firstNonSlashEnd;
    } else if (end < 0) {
      end = path2.length;
    }
    return path2.slice(start, end);
  }
  function dirname(path2) {
    assertPath(path2);
    if (path2.length === 0) {
      return ".";
    }
    let end = -1;
    let index2 = path2.length;
    let unmatchedSlash;
    while (--index2) {
      if (path2.codePointAt(index2) === 47) {
        if (unmatchedSlash) {
          end = index2;
          break;
        }
      } else if (!unmatchedSlash) {
        unmatchedSlash = true;
      }
    }
    return end < 0 ? path2.codePointAt(0) === 47 ? "/" : "." : end === 1 && path2.codePointAt(0) === 47 ? "//" : path2.slice(0, end);
  }
  function extname(path2) {
    assertPath(path2);
    let index2 = path2.length;
    let end = -1;
    let startPart = 0;
    let startDot = -1;
    let preDotState = 0;
    let unmatchedSlash;
    while (index2--) {
      const code3 = path2.codePointAt(index2);
      if (code3 === 47) {
        if (unmatchedSlash) {
          startPart = index2 + 1;
          break;
        }
        continue;
      }
      if (end < 0) {
        unmatchedSlash = true;
        end = index2 + 1;
      }
      if (code3 === 46) {
        if (startDot < 0) {
          startDot = index2;
        } else if (preDotState !== 1) {
          preDotState = 1;
        }
      } else if (startDot > -1) {
        preDotState = -1;
      }
    }
    if (startDot < 0 || end < 0 || preDotState === 0 || preDotState === 1 && startDot === end - 1 && startDot === startPart + 1) {
      return "";
    }
    return path2.slice(startDot, end);
  }
  function join(...segments) {
    let index2 = -1;
    let joined;
    while (++index2 < segments.length) {
      assertPath(segments[index2]);
      if (segments[index2]) {
        joined = joined === undefined ? segments[index2] : joined + "/" + segments[index2];
      }
    }
    return joined === undefined ? "." : normalize(joined);
  }
  function normalize(path2) {
    assertPath(path2);
    const absolute = path2.codePointAt(0) === 47;
    let value = normalizeString(path2, !absolute);
    if (value.length === 0 && !absolute) {
      value = ".";
    }
    if (value.length > 0 && path2.codePointAt(path2.length - 1) === 47) {
      value += "/";
    }
    return absolute ? "/" + value : value;
  }
  function normalizeString(path2, allowAboveRoot) {
    let result = "";
    let lastSegmentLength = 0;
    let lastSlash = -1;
    let dots = 0;
    let index2 = -1;
    let code3;
    let lastSlashIndex;
    while (++index2 <= path2.length) {
      if (index2 < path2.length) {
        code3 = path2.codePointAt(index2);
      } else if (code3 === 47) {
        break;
      } else {
        code3 = 47;
      }
      if (code3 === 47) {
        if (lastSlash === index2 - 1 || dots === 1) {} else if (lastSlash !== index2 - 1 && dots === 2) {
          if (result.length < 2 || lastSegmentLength !== 2 || result.codePointAt(result.length - 1) !== 46 || result.codePointAt(result.length - 2) !== 46) {
            if (result.length > 2) {
              lastSlashIndex = result.lastIndexOf("/");
              if (lastSlashIndex !== result.length - 1) {
                if (lastSlashIndex < 0) {
                  result = "";
                  lastSegmentLength = 0;
                } else {
                  result = result.slice(0, lastSlashIndex);
                  lastSegmentLength = result.length - 1 - result.lastIndexOf("/");
                }
                lastSlash = index2;
                dots = 0;
                continue;
              }
            } else if (result.length > 0) {
              result = "";
              lastSegmentLength = 0;
              lastSlash = index2;
              dots = 0;
              continue;
            }
          }
          if (allowAboveRoot) {
            result = result.length > 0 ? result + "/.." : "..";
            lastSegmentLength = 2;
          }
        } else {
          if (result.length > 0) {
            result += "/" + path2.slice(lastSlash + 1, index2);
          } else {
            result = path2.slice(lastSlash + 1, index2);
          }
          lastSegmentLength = index2 - lastSlash - 1;
        }
        lastSlash = index2;
        dots = 0;
      } else if (code3 === 46 && dots > -1) {
        dots++;
      } else {
        dots = -1;
      }
    }
    return result;
  }
  function assertPath(path2) {
    if (typeof path2 !== "string") {
      throw new TypeError("Path must be a string. Received " + JSON.stringify(path2));
    }
  }

  // node_modules/vfile/lib/minproc.browser.js
  var minproc = { cwd };
  function cwd() {
    return "/";
  }

  // node_modules/vfile/lib/minurl.shared.js
  function isUrl(fileUrlOrPath) {
    return Boolean(fileUrlOrPath !== null && typeof fileUrlOrPath === "object" && "href" in fileUrlOrPath && fileUrlOrPath.href && "protocol" in fileUrlOrPath && fileUrlOrPath.protocol && fileUrlOrPath.auth === undefined);
  }

  // node_modules/vfile/lib/minurl.browser.js
  function urlToPath(path2) {
    if (typeof path2 === "string") {
      path2 = new URL(path2);
    } else if (!isUrl(path2)) {
      const error = new TypeError('The "path" argument must be of type string or an instance of URL. Received `' + path2 + "`");
      error.code = "ERR_INVALID_ARG_TYPE";
      throw error;
    }
    if (path2.protocol !== "file:") {
      const error = new TypeError("The URL must be of scheme file");
      error.code = "ERR_INVALID_URL_SCHEME";
      throw error;
    }
    return getPathFromURLPosix(path2);
  }
  function getPathFromURLPosix(url) {
    if (url.hostname !== "") {
      const error = new TypeError('File URL host must be "localhost" or empty on darwin');
      error.code = "ERR_INVALID_FILE_URL_HOST";
      throw error;
    }
    const pathname = url.pathname;
    let index2 = -1;
    while (++index2 < pathname.length) {
      if (pathname.codePointAt(index2) === 37 && pathname.codePointAt(index2 + 1) === 50) {
        const third = pathname.codePointAt(index2 + 2);
        if (third === 70 || third === 102) {
          const error = new TypeError("File URL path must not include encoded / characters");
          error.code = "ERR_INVALID_FILE_URL_PATH";
          throw error;
        }
      }
    }
    return decodeURIComponent(pathname);
  }

  // node_modules/vfile/lib/index.js
  var order = [
    "history",
    "path",
    "basename",
    "stem",
    "extname",
    "dirname"
  ];

  class VFile {
    constructor(value) {
      let options;
      if (!value) {
        options = {};
      } else if (isUrl(value)) {
        options = { path: value };
      } else if (typeof value === "string" || isUint8Array(value)) {
        options = { value };
      } else {
        options = value;
      }
      this.cwd = "cwd" in options ? "" : minproc.cwd();
      this.data = {};
      this.history = [];
      this.messages = [];
      this.value;
      this.map;
      this.result;
      this.stored;
      let index2 = -1;
      while (++index2 < order.length) {
        const field2 = order[index2];
        if (field2 in options && options[field2] !== undefined && options[field2] !== null) {
          this[field2] = field2 === "history" ? [...options[field2]] : options[field2];
        }
      }
      let field;
      for (field in options) {
        if (!order.includes(field)) {
          this[field] = options[field];
        }
      }
    }
    get basename() {
      return typeof this.path === "string" ? minpath.basename(this.path) : undefined;
    }
    set basename(basename2) {
      assertNonEmpty(basename2, "basename");
      assertPart(basename2, "basename");
      this.path = minpath.join(this.dirname || "", basename2);
    }
    get dirname() {
      return typeof this.path === "string" ? minpath.dirname(this.path) : undefined;
    }
    set dirname(dirname2) {
      assertPath2(this.basename, "dirname");
      this.path = minpath.join(dirname2 || "", this.basename);
    }
    get extname() {
      return typeof this.path === "string" ? minpath.extname(this.path) : undefined;
    }
    set extname(extname2) {
      assertPart(extname2, "extname");
      assertPath2(this.dirname, "extname");
      if (extname2) {
        if (extname2.codePointAt(0) !== 46) {
          throw new Error("`extname` must start with `.`");
        }
        if (extname2.includes(".", 1)) {
          throw new Error("`extname` cannot contain multiple dots");
        }
      }
      this.path = minpath.join(this.dirname, this.stem + (extname2 || ""));
    }
    get path() {
      return this.history[this.history.length - 1];
    }
    set path(path2) {
      if (isUrl(path2)) {
        path2 = urlToPath(path2);
      }
      assertNonEmpty(path2, "path");
      if (this.path !== path2) {
        this.history.push(path2);
      }
    }
    get stem() {
      return typeof this.path === "string" ? minpath.basename(this.path, this.extname) : undefined;
    }
    set stem(stem) {
      assertNonEmpty(stem, "stem");
      assertPart(stem, "stem");
      this.path = minpath.join(this.dirname || "", stem + (this.extname || ""));
    }
    fail(causeOrReason, optionsOrParentOrPlace, origin) {
      const message = this.message(causeOrReason, optionsOrParentOrPlace, origin);
      message.fatal = true;
      throw message;
    }
    info(causeOrReason, optionsOrParentOrPlace, origin) {
      const message = this.message(causeOrReason, optionsOrParentOrPlace, origin);
      message.fatal = undefined;
      return message;
    }
    message(causeOrReason, optionsOrParentOrPlace, origin) {
      const message = new VFileMessage(causeOrReason, optionsOrParentOrPlace, origin);
      if (this.path) {
        message.name = this.path + ":" + message.name;
        message.file = this.path;
      }
      message.fatal = false;
      this.messages.push(message);
      return message;
    }
    toString(encoding) {
      if (this.value === undefined) {
        return "";
      }
      if (typeof this.value === "string") {
        return this.value;
      }
      const decoder = new TextDecoder(encoding || undefined);
      return decoder.decode(this.value);
    }
  }
  function assertPart(part, name) {
    if (part && part.includes(minpath.sep)) {
      throw new Error("`" + name + "` cannot be a path: did not expect `" + minpath.sep + "`");
    }
  }
  function assertNonEmpty(part, name) {
    if (!part) {
      throw new Error("`" + name + "` cannot be empty");
    }
  }
  function assertPath2(path2, name) {
    if (!path2) {
      throw new Error("Setting `" + name + "` requires `path` to be set too");
    }
  }
  function isUint8Array(value) {
    return Boolean(value && typeof value === "object" && "byteLength" in value && "byteOffset" in value);
  }
  // node_modules/unified/lib/callable-instance.js
  var CallableInstance = function(property) {
    const self = this;
    const constr = self.constructor;
    const proto = constr.prototype;
    const value = proto[property];
    const apply = function() {
      return value.apply(apply, arguments);
    };
    Object.setPrototypeOf(apply, proto);
    return apply;
  };

  // node_modules/unified/lib/index.js
  var own2 = {}.hasOwnProperty;

  class Processor extends CallableInstance {
    constructor() {
      super("copy");
      this.Compiler = undefined;
      this.Parser = undefined;
      this.attachers = [];
      this.compiler = undefined;
      this.freezeIndex = -1;
      this.frozen = undefined;
      this.namespace = {};
      this.parser = undefined;
      this.transformers = trough();
    }
    copy() {
      const destination = new Processor;
      let index2 = -1;
      while (++index2 < this.attachers.length) {
        const attacher = this.attachers[index2];
        destination.use(...attacher);
      }
      destination.data(import_extend.default(true, {}, this.namespace));
      return destination;
    }
    data(key, value) {
      if (typeof key === "string") {
        if (arguments.length === 2) {
          assertUnfrozen("data", this.frozen);
          this.namespace[key] = value;
          return this;
        }
        return own2.call(this.namespace, key) && this.namespace[key] || undefined;
      }
      if (key) {
        assertUnfrozen("data", this.frozen);
        this.namespace = key;
        return this;
      }
      return this.namespace;
    }
    freeze() {
      if (this.frozen) {
        return this;
      }
      const self = this;
      while (++this.freezeIndex < this.attachers.length) {
        const [attacher, ...options] = this.attachers[this.freezeIndex];
        if (options[0] === false) {
          continue;
        }
        if (options[0] === true) {
          options[0] = undefined;
        }
        const transformer = attacher.call(self, ...options);
        if (typeof transformer === "function") {
          this.transformers.use(transformer);
        }
      }
      this.frozen = true;
      this.freezeIndex = Number.POSITIVE_INFINITY;
      return this;
    }
    parse(file) {
      this.freeze();
      const realFile = vfile(file);
      const parser = this.parser || this.Parser;
      assertParser("parse", parser);
      return parser(String(realFile), realFile);
    }
    process(file, done) {
      const self = this;
      this.freeze();
      assertParser("process", this.parser || this.Parser);
      assertCompiler("process", this.compiler || this.Compiler);
      return done ? executor(undefined, done) : new Promise(executor);
      function executor(resolve, reject) {
        const realFile = vfile(file);
        const parseTree = self.parse(realFile);
        self.run(parseTree, realFile, function(error, tree, file2) {
          if (error || !tree || !file2) {
            return realDone(error);
          }
          const compileTree = tree;
          const compileResult = self.stringify(compileTree, file2);
          if (looksLikeAValue(compileResult)) {
            file2.value = compileResult;
          } else {
            file2.result = compileResult;
          }
          realDone(error, file2);
        });
        function realDone(error, file2) {
          if (error || !file2) {
            reject(error);
          } else if (resolve) {
            resolve(file2);
          } else {
            ok(done, "`done` is defined if `resolve` is not");
            done(undefined, file2);
          }
        }
      }
    }
    processSync(file) {
      let complete = false;
      let result;
      this.freeze();
      assertParser("processSync", this.parser || this.Parser);
      assertCompiler("processSync", this.compiler || this.Compiler);
      this.process(file, realDone);
      assertDone("processSync", "process", complete);
      ok(result, "we either bailed on an error or have a tree");
      return result;
      function realDone(error, file2) {
        complete = true;
        bail(error);
        result = file2;
      }
    }
    run(tree, file, done) {
      assertNode(tree);
      this.freeze();
      const transformers = this.transformers;
      if (!done && typeof file === "function") {
        done = file;
        file = undefined;
      }
      return done ? executor(undefined, done) : new Promise(executor);
      function executor(resolve, reject) {
        ok(typeof file !== "function", "`file` can’t be a `done` anymore, we checked");
        const realFile = vfile(file);
        transformers.run(tree, realFile, realDone);
        function realDone(error, outputTree, file2) {
          const resultingTree = outputTree || tree;
          if (error) {
            reject(error);
          } else if (resolve) {
            resolve(resultingTree);
          } else {
            ok(done, "`done` is defined if `resolve` is not");
            done(undefined, resultingTree, file2);
          }
        }
      }
    }
    runSync(tree, file) {
      let complete = false;
      let result;
      this.run(tree, file, realDone);
      assertDone("runSync", "run", complete);
      ok(result, "we either bailed on an error or have a tree");
      return result;
      function realDone(error, tree2) {
        bail(error);
        result = tree2;
        complete = true;
      }
    }
    stringify(tree, file) {
      this.freeze();
      const realFile = vfile(file);
      const compiler2 = this.compiler || this.Compiler;
      assertCompiler("stringify", compiler2);
      assertNode(tree);
      return compiler2(tree, realFile);
    }
    use(value, ...parameters) {
      const attachers = this.attachers;
      const namespace = this.namespace;
      assertUnfrozen("use", this.frozen);
      if (value === null || value === undefined) {} else if (typeof value === "function") {
        addPlugin(value, parameters);
      } else if (typeof value === "object") {
        if (Array.isArray(value)) {
          addList(value);
        } else {
          addPreset(value);
        }
      } else {
        throw new TypeError("Expected usable value, not `" + value + "`");
      }
      return this;
      function add(value2) {
        if (typeof value2 === "function") {
          addPlugin(value2, []);
        } else if (typeof value2 === "object") {
          if (Array.isArray(value2)) {
            const [plugin, ...parameters2] = value2;
            addPlugin(plugin, parameters2);
          } else {
            addPreset(value2);
          }
        } else {
          throw new TypeError("Expected usable value, not `" + value2 + "`");
        }
      }
      function addPreset(result) {
        if (!("plugins" in result) && !("settings" in result)) {
          throw new Error("Expected usable value but received an empty preset, which is probably a mistake: presets typically come with `plugins` and sometimes with `settings`, but this has neither");
        }
        addList(result.plugins);
        if (result.settings) {
          namespace.settings = import_extend.default(true, namespace.settings, result.settings);
        }
      }
      function addList(plugins) {
        let index2 = -1;
        if (plugins === null || plugins === undefined) {} else if (Array.isArray(plugins)) {
          while (++index2 < plugins.length) {
            const thing = plugins[index2];
            add(thing);
          }
        } else {
          throw new TypeError("Expected a list of plugins, not `" + plugins + "`");
        }
      }
      function addPlugin(plugin, parameters2) {
        let index2 = -1;
        let entryIndex = -1;
        while (++index2 < attachers.length) {
          if (attachers[index2][0] === plugin) {
            entryIndex = index2;
            break;
          }
        }
        if (entryIndex === -1) {
          attachers.push([plugin, ...parameters2]);
        } else if (parameters2.length > 0) {
          let [primary, ...rest] = parameters2;
          const currentPrimary = attachers[entryIndex][1];
          if (isPlainObject(currentPrimary) && isPlainObject(primary)) {
            primary = import_extend.default(true, currentPrimary, primary);
          }
          attachers[entryIndex] = [plugin, primary, ...rest];
        }
      }
    }
  }
  var unified = new Processor().freeze();
  function assertParser(name, value) {
    if (typeof value !== "function") {
      throw new TypeError("Cannot `" + name + "` without `parser`");
    }
  }
  function assertCompiler(name, value) {
    if (typeof value !== "function") {
      throw new TypeError("Cannot `" + name + "` without `compiler`");
    }
  }
  function assertUnfrozen(name, frozen) {
    if (frozen) {
      throw new Error("Cannot call `" + name + "` on a frozen processor.\nCreate a new processor first, by calling it: use `processor()` instead of `processor`.");
    }
  }
  function assertNode(node2) {
    if (!isPlainObject(node2) || typeof node2.type !== "string") {
      throw new TypeError("Expected node, got `" + node2 + "`");
    }
  }
  function assertDone(name, asyncName, complete) {
    if (!complete) {
      throw new Error("`" + name + "` finished async. Use `" + asyncName + "` instead");
    }
  }
  function vfile(value) {
    return looksLikeAVFile(value) ? value : new VFile(value);
  }
  function looksLikeAVFile(value) {
    return Boolean(value && typeof value === "object" && "message" in value && "messages" in value);
  }
  function looksLikeAValue(value) {
    return typeof value === "string" || isUint8Array2(value);
  }
  function isUint8Array2(value) {
    return Boolean(value && typeof value === "object" && "byteLength" in value && "byteOffset" in value);
  }
  // src/TestApp/Editor/remark-adapter.ts
  function parseMarkdownWithRemark(markdown) {
    const tree = unified().use(remarkParse).use(remarkGfm).parse(markdown);
    return {
      blocks: tree.children.map((node2) => blockFromMdast(node2))
    };
  }
  function blockFromMdast(node2) {
    if (node2.type === "heading") {
      return headingFromMdast(node2);
    }
    if (node2.type === "paragraph") {
      return paragraphFromMdast(node2);
    }
    if (node2.type === "list") {
      return listFromMdast(node2);
    }
    if (node2.type === "thematicBreak") {
      return {
        type: "horizontalRule"
      };
    }
    throw unsupportedNode(node2.type);
  }
  function headingFromMdast(node2) {
    if (node2.depth !== 1 && node2.depth !== 2 && node2.depth !== 3) {
      throw unsupportedNode(`heading:${node2.depth}`);
    }
    return {
      children: inlineNodesFromMdast(node2.children),
      level: node2.depth,
      type: "heading"
    };
  }
  function paragraphFromMdast(node2) {
    return {
      children: inlineNodesFromMdast(node2.children),
      type: "paragraph"
    };
  }
  function listFromMdast(node2) {
    return {
      items: node2.children.map((item) => listItemInlineNodes(item)),
      ordered: node2.ordered === true,
      type: "list"
    };
  }
  function listItemInlineNodes(item) {
    if (item.children.length !== 1) {
      throw unsupportedNode("listItem:spread");
    }
    const child = item.children[0];
    if (child?.type !== "paragraph") {
      throw unsupportedNode(`listItem:${child?.type ?? "empty"}`);
    }
    return inlineNodesFromMdast(child.children);
  }
  function inlineNodesFromMdast(nodes) {
    return nodes.map((node2) => inlineNodeFromMdast(node2));
  }
  function inlineNodeFromMdast(node2) {
    if (node2.type === "text") {
      return textInlineFromMdast(node2);
    }
    if (node2.type === "strong") {
      return strongInlineFromMdast(node2);
    }
    if (node2.type === "emphasis") {
      return {
        children: inlineNodesFromMdast(node2.children),
        type: "emphasis"
      };
    }
    if (node2.type === "inlineCode") {
      return codeInlineFromMdast(node2);
    }
    if (node2.type === "link") {
      return linkInlineFromMdast(node2);
    }
    throw unsupportedNode(node2.type);
  }
  function textInlineFromMdast(node2) {
    return {
      text: node2.value,
      type: "text"
    };
  }
  function strongInlineFromMdast(node2) {
    return {
      children: inlineNodesFromMdast(node2.children),
      type: "strong"
    };
  }
  function codeInlineFromMdast(node2) {
    return {
      text: node2.value,
      type: "code"
    };
  }
  function linkInlineFromMdast(node2) {
    return {
      children: inlineNodesFromMdast(node2.children),
      type: "link",
      url: node2.url
    };
  }
  function unsupportedNode(type) {
    return new Error(`Unsupported Markdown node for editor subset: ${type}`);
  }

  // src/TestApp/Editor/markdown-parse.ts
  function parseMarkdown(markdown) {
    return parseMarkdownWithRemark(markdown);
  }

  // src/TestApp/Editor/markdown-render.ts
  function renderMarkdown(markdown) {
    return renderEditorDocument(parseMarkdown(markdown));
  }
  function renderEditorDocument(document4) {
    return document4.blocks.map((block) => renderBlock(block)).join("");
  }
  function renderBlock(block) {
    if (block.type === "heading") {
      return `<h${block.level}>${renderInlineNodes(block.children)}</h${block.level}>`;
    }
    if (block.type === "list") {
      const tag = block.ordered ? "ol" : "ul";
      return `<${tag}>${block.items.map((item) => `<li>${renderInlineNodes(item)}</li>`).join("")}</${tag}>`;
    }
    if (block.type === "horizontalRule") {
      return "<hr>";
    }
    return `<p>${renderInlineNodes(block.children)}</p>`;
  }
  function renderInlineNodes(nodes) {
    return nodes.map((node2) => renderInlineNode(node2)).join("");
  }
  function renderInlineNode(node2) {
    if (node2.type === "strong") {
      return `<strong>${renderInlineNodes(node2.children)}</strong>`;
    }
    if (node2.type === "emphasis") {
      return `<em>${renderInlineNodes(node2.children)}</em>`;
    }
    if (node2.type === "code") {
      return `<code>${escapeHtml(node2.text)}</code>`;
    }
    if (node2.type === "link") {
      return `<a href="${escapeHtml(node2.url)}">${renderInlineNodes(node2.children)}</a>`;
    }
    return escapeHtml(node2.text);
  }
  function escapeHtml(value) {
    return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
  }

  // src/TestApp/Editor/markdown-serialise.ts
  function documentFromElements(elements) {
    return {
      blocks: Array.from(elements).map((element2) => blockFromElement(element2))
    };
  }
  function documentToMarkdown(document4) {
    return document4.blocks.map((block) => blockToMarkdown(block)).join(`

`);
  }
  function blockFromElement(block) {
    if (block.tagName === "HR") {
      return {
        type: "horizontalRule"
      };
    }
    if (block.tagName === "H1") {
      return {
        children: inlineNodesFromElement(block),
        level: 1,
        type: "heading"
      };
    }
    if (block.tagName === "H2") {
      return {
        children: inlineNodesFromElement(block),
        level: 2,
        type: "heading"
      };
    }
    if (block.tagName === "H3") {
      return {
        children: inlineNodesFromElement(block),
        level: 3,
        type: "heading"
      };
    }
    if (block.tagName === "UL") {
      return {
        items: Array.from(block.children).map((item) => inlineNodesFromElement(item)),
        ordered: false,
        type: "list"
      };
    }
    if (block.tagName === "OL") {
      return {
        items: Array.from(block.children).map((item) => inlineNodesFromElement(item)),
        ordered: true,
        type: "list"
      };
    }
    return {
      children: inlineNodesFromElement(block),
      type: "paragraph"
    };
  }
  function inlineNodesFromElement(element2) {
    return Array.from(element2.childNodes).flatMap((node2) => inlineNodesFromNode(node2));
  }
  function inlineNodesFromNode(node2) {
    if (node2.nodeType === Node.TEXT_NODE) {
      return textNode(node2.textContent ?? "");
    }
    if (node2.nodeType !== Node.ELEMENT_NODE) {
      return [];
    }
    const element2 = node2;
    if (element2.tagName === "STRONG" || element2.tagName === "B") {
      return [
        {
          children: inlineNodesFromElement(element2),
          type: "strong"
        }
      ];
    }
    if (element2.tagName === "EM" || element2.tagName === "I") {
      return [
        {
          children: inlineNodesFromElement(element2),
          type: "emphasis"
        }
      ];
    }
    if (element2.tagName === "CODE") {
      return [
        {
          text: element2.innerText,
          type: "code"
        }
      ];
    }
    if (element2.tagName === "A") {
      return [
        {
          children: inlineNodesFromElement(element2),
          type: "link",
          url: element2.getAttribute("href") ?? ""
        }
      ];
    }
    return inlineNodesFromElement(element2);
  }
  function blockToMarkdown(block) {
    if (block.type === "horizontalRule") {
      return "---";
    }
    if (block.type === "heading") {
      return `${"#".repeat(block.level)} ${inlineNodesToMarkdown(block.children).trim()}`;
    }
    if (block.type === "list") {
      return block.items.map((item, index2) => {
        const marker = block.ordered ? `${index2 + 1}.` : "-";
        return `${marker} ${inlineNodesToMarkdown(item).trim()}`;
      }).join(`
`);
    }
    return inlineNodesToMarkdown(block.children).trim();
  }
  function inlineNodesToMarkdown(nodes) {
    return nodes.map((node2) => inlineNodeToMarkdown(node2)).join("");
  }
  function inlineNodeToMarkdown(node2) {
    if (node2.type === "strong") {
      return `**${inlineNodesToMarkdown(node2.children)}**`;
    }
    if (node2.type === "emphasis") {
      return `*${inlineNodesToMarkdown(node2.children)}*`;
    }
    if (node2.type === "code") {
      return `\`${node2.text}\``;
    }
    if (node2.type === "link") {
      return `[${inlineNodesToMarkdown(node2.children)}](${node2.url})`;
    }
    return node2.text;
  }
  function textNode(text5) {
    if (text5.length === 0) {
      return [];
    }
    return [
      {
        text: text5,
        type: "text"
      }
    ];
  }

  // src/TestApp/Editor/markdown-editor-element.ts
  class MarkdownEditorElement extends HTMLElement {
    editor = null;
    initialised = false;
    markdown = "";
    mode = "visual";
    panes = null;
    parseError = null;
    preview = null;
    source = null;
    connectedCallback() {
      if (this.initialised) {
        return;
      }
      window.setTimeout(() => {
        this.initialise().catch((error) => {
          console.error(error);
        });
      }, 0);
    }
    async initialise() {
      if (this.initialised) {
        return;
      }
      this.initialised = true;
      this.markdown = await this.loadMarkdown();
      this.mode = this.editorMode();
      this.textContent = "";
      if (this.mode === "source" || this.mode === "split") {
        this.source = document.createElement("textarea");
        this.source.className = "markdown-editor__source";
        this.source.value = this.markdown;
        this.source.addEventListener("input", () => this.handleInput());
      }
      if (this.mode === "visual") {
        this.editor = document.createElement("div");
        this.editor.className = "markdown-editor__surface";
        this.editor.contentEditable = "true";
        this.editor.innerHTML = renderMarkdown(this.markdown);
        this.editor.addEventListener("input", () => this.handleInput());
      }
      this.preview = document.createElement("div");
      this.preview.className = "markdown-editor__preview";
      this.preview.setAttribute("aria-live", "polite");
      this.parseError = document.createElement("div");
      this.parseError.className = "markdown-editor__error";
      this.parseError.setAttribute("role", "alert");
      this.parseError.hidden = true;
      if (this.mode === "split") {
        this.panes = document.createElement("div");
        this.panes.className = "markdown-editor__split";
        this.panes.append(this.sourceElement(), this.preview);
        this.append(this.panes, this.parseError);
      } else {
        this.append(this.source ?? this.editorElement(), this.preview, this.parseError);
      }
      this.updatePreview();
      this.configureFormSubmission();
    }
    editorMode() {
      const mode = this.getAttribute("mode");
      if (mode === "source" || mode === "split") {
        return mode;
      }
      return "visual";
    }
    async loadMarkdown() {
      const src = this.getAttribute("src");
      if (!src) {
        return this.textContent.trim();
      }
      const response = await fetch(src, {
        headers: {
          Accept: "text/markdown"
        }
      });
      if (!response.ok) {
        throw new Error(`Failed to load Markdown document: ${response.status}`);
      }
      return response.text();
    }
    toMarkdown() {
      if (this.source) {
        return this.source.value;
      }
      if (!this.editor) {
        return this.markdown;
      }
      return documentToMarkdown(documentFromElements(this.editor.children));
    }
    updatePreview() {
      if (!this.preview) {
        return true;
      }
      try {
        this.preview.innerHTML = renderMarkdown(this.toMarkdown());
        this.hideParseError();
        return true;
      } catch (error) {
        this.preview.innerHTML = "";
        this.showParseError(errorMessage(error));
        return false;
      }
    }
    handleInput() {
      const markdown = this.toMarkdown();
      if (!this.updatePreview()) {
        return;
      }
      this.dispatchEvent(new CustomEvent("editor:changed", {
        bubbles: true,
        detail: {
          markdown
        }
      }));
    }
    configureFormSubmission() {
      const form = this.closest("form");
      const field = document.getElementById("markdown-field");
      if (!(form instanceof HTMLFormElement) || !(field instanceof HTMLInputElement)) {
        return;
      }
      form.addEventListener("htmx:configRequest", (event) => {
        const markdown = this.toMarkdown();
        const htmxEvent = event;
        field.value = markdown;
        htmxEvent.detail.parameters["markdown"] = markdown;
      });
    }
    showParseError(message) {
      if (!this.parseError) {
        return;
      }
      this.parseError.textContent = message;
      this.parseError.hidden = false;
    }
    hideParseError() {
      if (!this.parseError) {
        return;
      }
      this.parseError.textContent = "";
      this.parseError.hidden = true;
    }
    editorElement() {
      if (!this.editor) {
        throw new Error("Markdown editor surface was not created.");
      }
      return this.editor;
    }
    sourceElement() {
      if (!this.source) {
        throw new Error("Markdown source textarea was not created.");
      }
      return this.source;
    }
  }
  function errorMessage(error) {
    if (error instanceof Error) {
      return error.message;
    }
    return "Markdown could not be parsed.";
  }

  // src/TestApp/Editor/index.ts
  if (!customElements.get("markdown-editor")) {
    customElements.define("markdown-editor", MarkdownEditorElement);
  }
})();
