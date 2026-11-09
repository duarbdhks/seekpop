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
local RG_CANDIDATES = { "/opt/homebrew/bin/rg", "/usr/local/bin/rg" }
local PREVIEW_BYTES = 256 * 1024
local CLOSE_FALLBACK_SECONDS = 0.23
local BACKDROP_WIDTH = 640
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
    wv:hswindow():focus()
    return self:_send({ type = "show", theme = self._dark and "dark" or "light", blur = self._blur })
  end
  self._previousApp = hs.application.frontmostApplication()
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f, full = screen:frame(), screen:fullFrame()
  local w, h = math.min(1000, math.floor(f.w * 0.70)), 580
  local x, y = f.x + (f.w - w) / 2, f.y + math.floor(f.h * 0.18)
  local snap = { x = x - full.x - 40, y = y - full.y - 40, w = w + 80, h = h + 80 }
  local shot = hs.screenRecordingState() and screen:snapshot(snap) or nil
  self._blur = shot ~= nil
  wv:frame({ x = x - 72, y = y - 72, w = w + 144, h = h + 144 })
  local dark = hs.host.interfaceStyle() == "Dark"
  if dark ~= self._dark then
    wv:darkMode(dark)
    self._dark = dark
  end
  wv:show()
  wv:hswindow():focus()
  self:_send({ type = "show", theme = dark and "dark" or "light", blur = self._blur })
  self:_sendFolders()
  if shot then
    self._backdropTimer = hs.timer.doAfter(0, function()
      local size = { w = BACKDROP_WIDTH, h = math.floor(BACKDROP_WIDTH * snap.h / snap.w) }
      self:_send({ type = "backdrop", url = shot:copy():size(size, true):encodeAsURLString(true, "JPEG") })
    end)
  end
end

function enter.closing(self)
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
  self._pickingFolder = true
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
  if self._wv then self._wv:hswindow():focus() end
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

function handlers.enableBlur()
  hs.screenRecordingState(true)
  hs.urlevent.openURL(SCREEN_RECORDING_PANE)
end

function obj:_receive(msg)
  local handler = type(msg) == "table" and handlers[msg.type]
  if handler then handler(self, msg) end
end

--- SeekPop:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys, e.g. { toggle = { { "alt" }, "space" } }.
function obj:bindHotkeys(mapping)
  hs.spoons.bindHotkeysToSpec({ toggle = hs.fnutils.partial(self.toggle, self) }, mapping)
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
  self._wv = hs.webview.new({ x = 0, y = 0, w = 10, h = 10 }, {}, uc)
    :windowStyle({ "borderless" })
    :transparent(true)
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.modalPanel)
    :behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary" })
    :windowCallback(function(action, _, focused)
      if action == "focusChange" and focused == false and not self._pickingFolder then self:_fire("hide") end
    end)
    :html(html)
  return self
end

--- SeekPop:stop() -> self
--- Method
--- Cancels any search and deletes the palette window.
function obj:stop()
  if not self._wv then return self end
  if self._run then self._run:cancel() end
  if self._closeTimer then self._closeTimer:stop() end
  if self._backdropTimer then self._backdropTimer:stop() end
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
