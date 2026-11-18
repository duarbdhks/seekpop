local repo = debug.getinfo(1, "S").source:match("^@(.*)/tests/[^/]*$")
local prefKey = "SeekPop.shortcut"
local prefs, active, timers = {}, {}, {}
local bridge, windowEvent, url, tap, encoded, shown
local failSave, failEnable, failTap, secureInput, systemShortcut, alert
local checks = 0

local function eq(actual, expected, label)
  checks = checks + 1
  assert(actual == expected, ("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
end

local function chain()
  return setmetatable({}, { __index = function() return function(self) return self end end })
end

local view = chain()
function view:windowCallback(fn) windowEvent = fn; return self end
function view:evaluateJavaScript() if encoded.type == "shortcut" then shown = encoded end end

local keycodes = { space = 49, [49] = "SPACE", [8] = "C", [37] = "L", [40] = "K", [43] = "," }
local function newHotkey(mods, key, pressed, released)
  if type(mods) == "table" then mods = table.concat(mods) end
  local prefix = mods:lower():gsub("option", "alt"):gsub("command", "cmd"):gsub("cmd", "⌘"):gsub("alt", "⌥")
  local hk = { idx = prefix .. keycodes[key], pressed = pressed, released = released }
  function hk:enable()
    if failEnable == self.idx then return nil end
    active[self.idx] = self
    return self
  end
  function hk:delete() if active[self.idx] == self then active[self.idx] = nil end end
  return hk
end

local function newTap(_, callback)
  return {
    start = function() if not failTap then tap = callback end end,
    isEnabled = function() return tap == callback end,
    stop = function() if tap == callback then tap = nil end end,
  }
end

local screen = {
  frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
  fullFrame = function() return { x = 0, y = 0 } end,
}
local env = setmetatable({ hs = {
  spoons = { scriptPath = function() return repo .. "/SeekPop.spoon/" end },
  settings = {
    get = function(key) return prefs[key] end,
    set = function(key, value)
      if key == prefKey and failSave then error("test save failure") end
      prefs[key] = value
    end,
  },
  hotkey = {
    new = newHotkey,
    getHotkeys = function()
      local keys = {}
      for _, hk in pairs(active) do keys[#keys + 1] = hk end
      return keys
    end,
    systemAssigned = function(_, key) return key == systemShortcut and { enabled = true } or false end,
  },
  keycodes = { map = keycodes },
  alert = { show = function(message) alert = message end },
  eventtap = {
    new = newTap,
    isSecureInputEnabled = function() return secureInput end,
    event = { types = { keyDown = 10, keyUp = 11 }, properties = { keyboardEventAutorepeat = 8 } },
  },
  timer = { doAfter = function(_, fn)
    local stopped = false
    timers[#timers + 1] = function() if not stopped then fn() end end
    return { stop = function() stopped = true end }
  end },
  webview = {
    new = function() return view end,
    usercontent = { new = function() return { setCallback = function(_, fn) bridge = fn end } end },
  },
  drawing = { windowLevels = { modalPanel = 1 } },
  json = { encode = function(msg) encoded = msg; return "{}" end },
  urlevent = { bind = function(_, fn) url = fn end },
  application = { frontmostApplication = function() end },
  mouse = { getCurrentScreen = function() return screen end },
  host = { interfaceStyle = function() return "Dark" end },
  screenRecordingState = function() return false end,
  focus = function() end,
  dialog = { chooseFileOrFolder = function() eq(tap, nil, "folder picker has the keyboard") end },
} }, { __index = _G })
function env.dofile(path) return assert(loadfile(path, "t", env))() end

local function post(kind, action)
  bridge({ body = { type = kind, action = action } })
end

local function key(kind, code, flags, repeatKey)
  eq(tap({
    getType = function() return kind end, getKeyCode = function() return code end,
    getFlags = function() return flags or {} end, getProperty = function() return repeatKey and 1 or 0 end,
  }), true, "recording key is suppressed")
end

local function finish()
  table.remove(timers, 1)()
end

local function record(code)
  post("shortcut", "begin")
  key(10, code, { cmd = true })
  key(11, code)
  finish()
end

local path = repo .. "/SeekPop.spoon/init.lua"
local fallback = { toggle = { "Option", "SPACE", message = "Open SeekPop" } }
local previousBinding = newHotkey("Option", 49, function() end):enable()
local spoon = env.dofile(path)
eq(spoon:bindHotkeys(fallback):start(), spoon, "chainable start")
post("ready")
eq(shown.chord, "⌥SPACE", "legacy opener shown")
eq(active["⌥SPACE"] ~= previousBinding, true, "explicit legacy mapping takes priority")
active["⌥SPACE"].pressed()
eq(alert, "⌥SPACE: Open SeekPop", "legacy message retained")
post("shortcut", "begin")
active["⌥SPACE"].pressed()
active["⌥SPACE"].released()
eq(tap, nil, "Carbon opener release finishes recording")
eq(prefs[prefKey], nil, "same opener writes nothing")
post("shortcut", "begin")
eq(shown.recording, true, "Carbon opener kept palette open")
key(10, 37, { cmd = true }, true)
key(10, 40, { cmd = true })
eq(shown.chord, "⌥SPACE", "keydown keeps the old opener")
eq(prefs[prefKey], nil, "keydown does not write")
key(11, 40)
finish()
local saved = prefs[prefKey]
eq(shown.chord, "⌘K", "new opener shown")
eq(saved.keycode, 40, "physical keycode saved")
eq(table.concat(saved.mods, ","), "cmd", "canonical modifiers saved")
eq(active["⌥SPACE"], nil, "old opener released after commit")
local opener = assert(active["⌘K"])
record(40)
eq(active["⌘K"], opener, "recording the active opener is a no-op")
eq(prefs[prefKey], saved, "recording the active opener does not rewrite preferences")

local function rejected(code, message)
  record(code)
  eq(shown.status:find(message, 1, true) ~= nil, true, "rejection explained")
  eq(shown.chord, "⌘K", "rejection preserves displayed opener")
  eq(active["⌘K"], opener, "rejection preserves active opener")
  eq(prefs[prefKey], saved, "rejection preserves saved opener")
end

rejected(43, "inside SeekPop")
local other = newHotkey("cmd", 37):enable()
rejected(37, "used by Hammerspoon")
eq(active["⌘L"], other, "other Hammerspoon hotkey remains active")
other:delete()
systemShortcut = 37
rejected(37, "used by macOS")
systemShortcut, failEnable = nil, "⌘L"
rejected(37, "Could not register")
failEnable, failSave = nil, true
rejected(37, "Could not save")
eq(active["⌘L"], nil, "failed save releases the candidate")
failSave = false

post("shortcut", "begin")
key(10, 53)
key(11, 53)
finish()
eq(tap, nil, "Escape releases the tap")
eq(prefs[prefKey], saved, "Escape leaves the saved opener")
post("shortcut", "begin")
post("shortcut", "cancel")
eq(tap, nil, "settings exit releases the tap")
post("shortcut", "begin")
post("addFolder")
post("shortcut", "begin")
key(10, 37, { cmd = true })
key(11, 37)
windowEvent("focusChange", view, false)
eq(tap, nil, "focus loss releases the tap")
finish()
eq(prefs[prefKey], saved, "focus loss cancels the pending replacement")
eq(active["⌘K"], opener, "focus loss keeps the old opener")
spoon:stop()
eq(active["⌘K"], nil, "stop releases the active opener")

spoon = env.dofile(path):start():bindHotkeys(fallback)
post("ready")
eq(shown.chord, "⌘K", "fresh start restores the saved opener before legacy mapping")
eq(prefs[prefKey], saved, "restoring does not rewrite preferences")
url()
secureInput = true
post("shortcut", "begin")
eq(shown.status:find("Secure Input", 1, true) ~= nil, true, "Secure Input explained")
secureInput, failTap = false, true
post("shortcut", "begin")
eq(shown.recording, false, "native tap startup failure clears recording")
eq(shown.status:find("Could not start", 1, true) ~= nil, true, "tap startup failure explained")
failTap = false
post("shortcut", "begin")
spoon:stop()
eq(tap, nil, "stop releases the recording tap")

failEnable = "⌘K"
spoon = env.dofile(path):start()
post("ready")
eq(shown.chord, "Not set", "unavailable saved opener without fallback")
spoon:bindHotkeys(fallback)
eq(shown.chord, "⌥SPACE", "late fallback becomes the active opener")
eq(shown.status:find("Saved shortcut unavailable", 1, true) ~= nil, true, "saved failure remains visible")
eq(prefs[prefKey], saved, "failed restoration retains stored opener")
spoon:stop()

local malformed = { mods = { [1] = "cmd", [3] = "shift" }, keycode = 40 }
prefs[prefKey] = malformed
spoon = env.dofile(path):bindHotkeys(fallback):start()
post("ready")
eq(shown.chord, "⌥SPACE", "malformed preference falls back to legacy binding")
eq(shown.status:find("invalid", 1, true) ~= nil, true, "malformed preference explained")
eq(prefs[prefKey], malformed, "malformed preference is preserved")
spoon:stop()

print(("shortcut_test ok: %d checks"):format(checks))
