--- === SeekPop ===
---
--- A glass palette that finds files by content inside chosen folders, hidden folders included.
local obj = {}
obj.__index = obj

obj.name = "SeekPop"
obj.version = "0.1.0"
obj.author = "duarbdhks"
obj.homepage = "https://github.com/duarbdhks/seekpop"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- SeekPop.rgPath
--- Variable
--- Absolute path of ripgrep. nil uses the first of /opt/homebrew/bin/rg and /usr/local/bin/rg that exists.
obj.rgPath = nil

--- SeekPop.maxResults
--- Variable
--- Number of files listed per query.
obj.maxResults = 50

--- SeekPop.maxFileSize
--- Variable
--- Larger files are skipped by content search (ripgrep --max-filesize syntax).
obj.maxFileSize = "2M"

--- SeekPop.exclude
--- Variable
--- File and folder names that are never searched.
obj.exclude = { ".git", "node_modules", "dist", "build", ".next", ".DS_Store" }

local DIR = hs.spoons.scriptPath()
local search = dofile(DIR .. "search.lua")
local HOME = os.getenv("HOME")
local ROOTS_KEY = "SeekPop.roots"
local SHORTCUT_KEY = "SeekPop.shortcut"
local SHORTCUT_MODS = { "alt", "ctrl", "cmd", "shift" }
local ESCAPE_KEY = 0x35
local PALETTE_KEYS = {
  cmd = { [0x08] = true, [0x24] = true, [0x2b] = true, [0x4c] = true, c = true, [","] = true },
  ["cmd+shift"] = { [0x08] = true, c = true },
  ctrl = { [0x2d] = true, [0x23] = true, n = true, p = true },
}
local RG_CANDIDATES = { "/opt/homebrew/bin/rg", "/usr/local/bin/rg" }
local PREVIEW_BYTES = 256 * 1024
local CLOSE_FALLBACK_SECONDS = 0.3
local BACKDROP_WIDTH = 320
local PANEL_HEIGHT = 580
local SCREEN_RECORDING_PANE = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

local function savedRoots()
  return hs.settings.get(ROOTS_KEY) or {}
end

local transitions = {
  hidden = { show = "shown" },
  shown = { hide = "closing" },
  closing = { show = "shown", closed = "hidden" },
}

local enter = {}

function enter.shown(self, from)
  local wv = self._wv
  if self._closeTimer then self._closeTimer:stop() end
  if from == "closing" then
    -- Still on screen mid-fade: keep its place and backdrop, since a new snapshot would capture the palette itself.
    wv:show()
    return self:_send({ type = "show", theme = self._dark and "dark" or "light", blur = self._blur })
  end
  self._previousApp = hs.application.frontmostApplication()
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f, full = screen:frame(), screen:fullFrame()
  local w, h = math.min(760, math.floor(f.w * 0.70)), PANEL_HEIGHT
  local x, y = f.x + (f.w - w) / 2, f.y + math.floor(f.h * 0.18)
  local snap = { x = x - full.x - 40, y = y - full.y - 40, w = w + 80, h = h + 80 }
  local shot = hs.screenRecordingState() and screen:snapshot(snap) or nil
  -- Encoded before the page opens, so the first visible frame is already frosted and the fade runs on a free main thread.
  local backdrop = shot and shot:copy():size({ w = BACKDROP_WIDTH, h = math.floor(BACKDROP_WIDTH * snap.h / snap.w) }, true):encodeAsURLString(true, "JPEG")
  self._blur = backdrop ~= nil
  wv:frame({ x = x - 72, y = y - 72, w = w + 144, h = h + 144 })
  local dark = hs.host.interfaceStyle() == "Dark"
  if dark ~= self._dark then
    wv:darkMode(dark)
    self._dark = dark
  end
  wv:show()
  self:_send({ type = "show", theme = dark and "dark" or "light", blur = self._blur, backdrop = backdrop })
  self:_sendFolders()
end

function enter.closing(self)
  self:_endShortcutCapture()
  self:_send({ type = "hide" })
  self._closeTimer = hs.timer.doAfter(CLOSE_FALLBACK_SECONDS, function() self:_fire("closed") end)
end

function enter.hidden(self)
  if self._closeTimer then self._closeTimer:stop() end
  if self._run then self._run:cancel() end
  self._wv:hide()
  -- Hand focus back unless the user already moved to another app (a click elsewhere, or a file just opened).
  local front = hs.application.frontmostApplication()
  if self._previousApp and front and front:pid() == hs.processInfo.processID then self._previousApp:activate() end
end

function obj:_fire(event)
  local from = self._state
  local nextState = self._wv and transitions[from][event]
  if not nextState then return end
  self._state = nextState
  enter[nextState](self, from)
end

function obj:_send(msg)
  if not self._wv then return end
  if not self._ready then
    self._queue[#self._queue + 1] = msg
    return
  end
  self._wv:evaluateJavaScript("SeekPop.receive(" .. hs.json.encode(msg) .. ")")
end

function obj:_sendFolders()
  local roots = {}
  for i, path in ipairs(savedRoots()) do
    roots[i] = { path = path, display = search.abbreviate(path, HOME), missing = hs.fs.attributes(path, "mode") ~= "directory" }
  end
  self:_send({ type = "folders", roots = roots, screenRecording = hs.screenRecordingState() })
end

local function shortcutFromFlags(flags, keycode)
  if not (flags.alt or flags.ctrl or flags.cmd) then return end
  -- Carbon's virtual keycodes 0x36 through 0x3f are the modifier keys.
  if type(keycode) ~= "number" or keycode % 1 ~= 0 or keycode < 0 or keycode > 0x7f
    or (keycode >= ESCAPE_KEY and keycode <= 0x3f) then return end
  local mods = {}
  for _, mod in ipairs(SHORTCUT_MODS) do
    if flags[mod] then mods[#mods + 1] = mod end
  end
  return { mods = mods, keycode = keycode }
end

local function validateSavedShortcut(value)
  if type(value) ~= "table" or type(value.mods) ~= "table" then return end
  local flags, count = {}, 0
  for i, mod in pairs(value.mods) do
    if type(i) ~= "number" or i % 1 ~= 0 or i < 1 or i > #SHORTCUT_MODS
      or not (mod == "alt" or mod == "ctrl" or mod == "cmd" or mod == "shift") or flags[mod] then return end
    flags[mod], count = true, count + 1
  end
  for i = 1, count do
    if value.mods[i] == nil then return end
  end
  return shortcutFromFlags(flags, value.keycode)
end

function obj:_sendShortcut(status)
  self:_send({
    type = "shortcut",
    chord = self._hotkey and self._hotkey.idx or "Not set",
    recording = self._capture ~= nil,
    status = status or (self._capture and "Press a new shortcut or Esc to cancel.") or self._shortcutStatus or "",
  })
end

function obj:_endShortcutCapture(status)
  local capture = self._capture
  if not capture then return end
  self._capture = nil
  if capture.finishTimer then
    capture.finishTimer:stop()
    capture.finishTimer = nil
  end
  if capture.tap then
    capture.tap:stop()
    capture.tap = nil
  end
  self:_sendShortcut(status)
end

local function registerShortcut(self, mods, key, source, message)
  local candidate
  local failure = "Could not register the shortcut."
  local ok, bound, reason = pcall(function()
    local keycode = key
    if type(key) == "string" then
      keycode = key:sub(1, 1) == "#" and tonumber(key:sub(2)) or hs.keycodes.map[key:lower()]
    end
    local chord
    candidate = hs.hotkey.new(mods, keycode, function()
      if self._capture then
        -- Carbon can deliver the registered opener before the tap sees it.
        self._capture.currentKeycode = keycode
        return
      end
      if type(message) == "string" then
        hs.alert.show(chord .. (message == "" and "" or ": " .. message), hs.hotkey.alertDuration or 0)
      end
      self:toggle()
    end, function()
      local capture = self._capture
      if capture and capture.currentKeycode == keycode then self:_endShortcutCapture() end
    end)
    chord = candidate.idx
    if source then
      -- Enabling a matching .idx silently shadows a Hammerspoon binding.
      for _, active in ipairs(hs.hotkey.getHotkeys()) do
        if active.idx == candidate.idx then
          if active == self._hotkey then return true end
          return false, "This shortcut is already used by Hammerspoon."
        end
      end
      local reserved = PALETTE_KEYS[table.concat(mods, "+")]
      if reserved and (reserved[keycode] or reserved[hs.keycodes.map[keycode]]) then
        return false, "This shortcut is already used inside SeekPop."
      end
      local assigned = hs.hotkey.systemAssigned(mods, keycode)
      if assigned == nil then return false, "Could not check macOS shortcuts." end
      if assigned and assigned.enabled then return false, "This shortcut is already used by macOS." end
    end
    if not candidate:enable() then return false, failure end
    if source == "recorded" then
      failure = "Could not save the shortcut."
      hs.settings.set(SHORTCUT_KEY, { mods = mods, keycode = keycode })
    end
    if self._hotkey then self._hotkey:delete() end
    self._hotkey, candidate = candidate, nil
    self._usingSavedShortcut = source ~= nil
    if source then self._shortcutStatus = nil end
    return true
  end)
  if candidate then candidate:delete() end
  if not ok then return false, failure end
  return bound, reason
end

function obj:_restoreShortcut()
  self._shortcutStatus = nil
  local value = hs.settings.get(SHORTCUT_KEY)
  if value ~= nil then
    local saved = validateSavedShortcut(value)
    local bound, reason
    if saved then bound, reason = registerShortcut(self, saved.mods, saved.keycode, "saved") end
    if bound then
      self._usingSavedShortcut = true
      return
    end
    self._shortcutStatus = "Saved shortcut unavailable. " .. (reason or "The saved combination is invalid.")
  end
  local fallback = self._fallbackShortcut
  if fallback then
    local bound, reason = registerShortcut(self, fallback[1], fallback[2], nil, fallback.message)
    if not bound and not self._shortcutStatus then self._shortcutStatus = reason end
  end
end

function obj:_rgPath()
  if self.rgPath then return self.rgPath end
  for _, path in ipairs(RG_CANDIDATES) do
    if hs.fs.attributes(path, "mode") == "file" then return path end
  end
end

local function reveal(self, path, reply)
  self._revealTask = hs.task.new("/usr/bin/open", function(code) reply(code == 0) end, { "-R", path })
  if not self._revealTask:start() then reply(false) end
end

local actions = {
  open = { run = function(_, path, reply) reply(hs.open(path)) end, ok = "Opened %s", fail = "Could not open %s" },
  reveal = { run = reveal, ok = "Showed %s in Finder", fail = "Could not show %s in Finder" },
  copy = {
    run = function(_, path, reply) reply(hs.pasteboard.writeObjects({ url = hs.fs.urlFromPath(path) })) end,
    ok = "Copied %s",
    fail = "Could not copy %s",
  },
  copyPath = { run = function(_, path, reply) reply(hs.pasteboard.setContents(path)) end, ok = "Path copied", fail = "Could not copy the path" },
}

local handlers = {}

function handlers.ready(self)
  self._ready = true
  local queued = self._queue
  self._queue = {}
  for _, msg in ipairs(queued) do self:_send(msg) end
  self:_sendFolders()
  self:_sendShortcut()
end

function handlers.shortcut(self, msg)
  if msg.action == "cancel" then return self:_endShortcutCapture() end
  if msg.action ~= "begin" or self._state ~= "shown" or self._pickingFolder or self._capture then return end
  if hs.eventtap.isSecureInputEnabled() then
    return self:_sendShortcut("Turn off Secure Input in the active app to record a shortcut.")
  end

  local capture = {}
  local types = hs.eventtap.event.types
  self._capture = capture
  local ok, enabled = pcall(function()
    capture.tap = hs.eventtap.new({ types.keyDown, types.keyUp }, function(event)
      if self._capture ~= capture then return false end
      if capture.finishTimer then return true end
      local keycode = event:getKeyCode()
      if event:getType() == types.keyDown then
        if event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) ~= 0 then return true end
        if keycode == ESCAPE_KEY then
          capture.pending = { keycode = keycode }
        elseif not (capture.pending or capture.currentKeycode) then
          capture.pending = shortcutFromFlags(event:getFlags(), keycode)
          if not capture.pending then self:_sendShortcut("Use Command, Option, or Control with another key.") end
        end
      elseif keycode == capture.currentKeycode or (capture.pending and keycode == capture.pending.keycode) then
        local shortcut = capture.pending
        -- Finish outside the tap callback so native registration cannot hold up keyboard events.
        capture.finishTimer = hs.timer.doAfter(0, function()
          if self._capture ~= capture then return end
          local _, reason
          if shortcut and shortcut.mods and not capture.currentKeycode then
            _, reason = registerShortcut(self, shortcut.mods, shortcut.keycode, "recorded")
          end
          self:_endShortcutCapture(reason)
        end)
      end
      return true
    end)
    capture.tap:start()
    return capture.tap:isEnabled()
  end)
  if not ok or not enabled then return self:_endShortcutCapture("Could not start recording. Check Hammerspoon’s Accessibility access.") end
  self:_sendShortcut()
end

function handlers.query(self, msg)
  if type(msg.q) ~= "string" then return end
  local opts = { rgPath = self:_rgPath(), maxResults = self.maxResults, maxFileSize = self.maxFileSize, exclude = self.exclude, home = HOME }
  self._run = search.run(msg.q, savedRoots(), opts, function(result)
    if result.error then return self:_send({ type = "error", message = result.error }) end
    self._items = {}
    for _, item in ipairs(result.items) do self._items[item.path] = item end
    self:_send({ type = "results", id = msg.id, items = result.items, elapsedMs = result.elapsedMs, warnings = result.warnings })
  end)
end

-- The page may only act on files it was just shown; any other path from the port is ignored.
function handlers.select(self, msg)
  local item = self._items[msg.path]
  if not item then return end
  local text, truncated = search.readText(item.path, PREVIEW_BYTES)
  if text then
    self:_send({ type = "preview", path = item.path, text = text, line = item.line, truncated = truncated })
  else
    self:_send({ type = "preview", path = item.path, error = "Preview unavailable" })
  end
end

for name, action in pairs(actions) do
  handlers[name] = function(self, msg)
    local item = self._items[msg.path]
    if not item then return end
    action.run(self, item.path, function(ok)
      self:_send({ type = "done", action = name, ok = ok == true, message = (ok and action.ok or action.fail):format(item.name) })
    end)
  end
end

function handlers.close(self)
  self:_fire("hide")
end

function handlers.closed(self)
  self:_fire("closed")
end

function handlers.addFolder(self)
  self:_endShortcutCapture()
  self._pickingFolder = true
  -- The panel never activates Hammerspoon, but the modal folder picker needs it active to take keys.
  hs.focus()
  local chosen = hs.dialog.chooseFileOrFolder("Choose folders to search", "~", false, true, true)
  self._pickingFolder = false
  local picked = {}
  for key, path in pairs(chosen or {}) do picked[tonumber(key)] = path end
  local roots, seen = savedRoots(), {}
  for _, root in ipairs(roots) do seen[root] = true end
  for _, path in ipairs(picked) do
    if path:sub(1, 1) == "~" then path = HOME .. path:sub(2) end
    path = path:gsub("(.)/+$", "%1")
    if not seen[path] and hs.fs.attributes(path, "mode") == "directory" then
      seen[path] = true
      roots[#roots + 1] = path
    end
  end
  hs.settings.set(ROOTS_KEY, roots)
  if self._wv then self._wv:show() end
  self:_sendFolders()
end

function handlers.removeFolder(self, msg)
  local roots = {}
  for _, root in ipairs(savedRoots()) do
    if root ~= msg.path then roots[#roots + 1] = root end
  end
  hs.settings.set(ROOTS_KEY, roots)
  self:_sendFolders()
end

function handlers.enableBlur(self)
  self:_endShortcutCapture()
  hs.screenRecordingState(true)
  hs.urlevent.openURL(SCREEN_RECORDING_PANE)
end

function obj:_receive(msg)
  local handler = type(msg) == "table" and handlers[msg.type]
  if handler then handler(self, msg) end
end

--- SeekPop:bindHotkeys(mapping) -> self
--- Method
--- Configures the fallback opener, e.g. { toggle = { { "alt" }, "space" } }.
function obj:bindHotkeys(mapping)
  if mapping.toggle then
    self._fallbackShortcut = mapping.toggle
    if self._wv and not self._usingSavedShortcut then
      self:_restoreShortcut()
      self:_sendShortcut()
    end
  end
  return self
end

--- SeekPop:start() -> self
--- Method
--- Creates the hidden palette window and loads its page.
function obj:start()
  if self._wv then return self end
  local file = assert(io.open(DIR .. "ui.html", "rb"))
  local html = file:read("a")
  file:close()
  local uc = hs.webview.usercontent.new("seekpop")
  uc:setCallback(function(message) self:_receive(message.body) end)
  self._uc, self._state, self._ready, self._queue, self._items, self._dark = uc, "hidden", false, {}, {}, nil
  -- Created at its final height: the page folds by 100vh, and a first-open resize from 10 pt flashed the full panel.
  self._wv = hs.webview.new({ x = 0, y = 0, w = 10, h = PANEL_HEIGHT + 144 }, {}, uc)
    -- Non-activating, like Spotlight: the panel takes keys while the app behind stays active and keeps its look.
    :windowStyle({ "borderless", "nonactivating" })
    :transparent(true)
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.modalPanel)
    :behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary" })
    :windowCallback(function(action, _, focused)
      if action == "closing" then self:_endShortcutCapture() end
      if action == "focusChange" and focused == false and not self._pickingFolder then self:_fire("hide") end
    end)
    :html(html)
  hs.urlevent.bind("seekpop", function() self:show() end)
  self:_restoreShortcut()
  return self
end

--- SeekPop:stop() -> self
--- Method
--- Cancels any search and deletes the palette window.
function obj:stop()
  if not self._wv then return self end
  self:_endShortcutCapture()
  if self._hotkey then self._hotkey:delete() end
  self._hotkey, self._usingSavedShortcut = nil, nil
  hs.urlevent.bind("seekpop", nil)
  if self._run then self._run:cancel() end
  if self._closeTimer then self._closeTimer:stop() end
  self._wv:delete()
  self._wv, self._uc, self._run, self._state = nil, nil, nil, "hidden"
  return self
end

--- SeekPop:show() -> self
--- Method
--- Opens the palette on the screen under the mouse.
function obj:show()
  self:_fire("show")
  return self
end

--- SeekPop:hide() -> self
--- Method
--- Plays the closing animation and hides the palette.
function obj:hide()
  self:_fire("hide")
  return self
end

--- SeekPop:toggle() -> self
--- Method
--- Hides the palette when it is open, otherwise shows it.
function obj:toggle()
  self:_fire(self._state == "shown" and "hide" or "show")
  return self
end

return obj
