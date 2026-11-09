-- ripgrep pipeline for SeekPop plus the pure helpers it is built from.
local M = {}

local RG_MISSING = "ripgrep not found. Install it with brew install ripgrep."
local HEAD_BYTES = 16384
local HEADING_LINES = 40
local SNIPPET_CHARS = 300
local SETTLE_SECONDS = 0.05
local MARKDOWN = { md = true, markdown = true, mdx = true }
-- rg prints match events in this field order; a path with quotes or backslashes, or any other layout, is fully decoded instead.
local MATCH_HEAD = '^{"type":"match","data":{"path":{"text":"([^"\\]*)"},.-},"line_number":(%d+),'

-- hs.task converts arguments to decomposed Unicode, so terms go to rg as ASCII-only patterns and no file path
-- is ever passed back as an argument (returned paths would change form). stdin is avoided: writing it to a run
-- that was just cancelled raises SIGPIPE and kills Hammerspoon.
local FLAGS = {
  list = { "--files", "--hidden", "--null", "--sortr", "modified", "--no-messages" },
  content = { "--json", "-i", "--max-count", "1", "--hidden", "--sortr", "modified", "--no-messages" },
}

local function push(t, ...)
  for _, v in ipairs({ ... }) do t[#t + 1] = v end
  return t
end

function M.parseTerms(query)
  local terms, seen = {}, {}
  for word in query:gmatch("%S+") do
    local term = word:lower()
    if not seen[term] then
      seen[term] = true
      terms[#terms + 1] = term
    end
  end
  return terms
end

function M.nameMatches(name, terms)
  local lower = name:lower()
  for _, term in ipairs(terms) do
    if not lower:find(term, 1, true) then return false end
  end
  return true
end

function M.abbreviate(path, home)
  if not home or home == "" then return path end
  if path == home then return "~" end
  if path:sub(1, #home + 1) == home .. "/" then return "~" .. path:sub(#home + 1) end
  return path
end

-- Fixed-string term as a regex: ASCII letters and digits stay, every other character becomes \x{codepoint}.
function M.pattern(term)
  local out = {}
  for _, cp in utf8.codes(term) do
    local ch = cp < 128 and string.char(cp)
    out[#out + 1] = ch and ch:match("%w") or ("\\x{%X}"):format(cp)
  end
  return table.concat(out)
end

function M.buildArgs(kind, roots, opts, term)
  local args = table.move(FLAGS[kind], 1, #FLAGS[kind], 1, {})
  if kind == "content" then push(args, "--max-filesize", opts.maxFileSize) end
  for _, ex in ipairs(opts.exclude) do push(args, "-g", "!" .. ex) end
  if term then push(args, "-e", M.pattern(term)) end
  push(args, "--")
  return table.move(roots, 1, #roots, #args + 1, args)
end

function M.splitNull(out)
  local paths = {}
  for p in out:gmatch("[^\0]+") do paths[#paths + 1] = p end
  return paths
end

local function decodeMatch(line)
  local ok, event = pcall(hs.json.decode, line)
  return ok and type(event) == "table" and event.type == "match" and event.data or nil
end

-- First match per path from rg --json, in output order, as {path, line, raw}. Decoding every event costs ~35 ms
-- for 400 files, so only path and line are read here. Paths that are not UTF-8 only carry .bytes and are skipped.
function M.parseRgJson(out)
  local hits, seen = {}, {}
  for line in out:gmatch("[^\n]+") do
    local path, n = line:match(MATCH_HEAD)
    if not path and line:find('"type":"match"', 1, true) then
      local data = decodeMatch(line)
      path, n = data and data.path and data.path.text, data and data.line_number
    end
    if path and n and not seen[path] then
      seen[path] = true
      hits[#hits + 1] = { path = path, line = tonumber(n), raw = line }
    end
  end
  return hits
end

-- Matched line text and 1-based byte column of its first submatch; nil when rg could only give the line as bytes.
function M.matchText(raw)
  local data = decodeMatch(raw)
  local text = data and data.lines and data.lines.text
  local sub = text and data.submatches and data.submatches[1]
  return text, sub and sub.start and sub.start + 1
end

-- AND across terms: a path survives when every term's run hit it, and keeps the earliest matching line.
-- Returns the surviving paths in the first run's order plus a path -> hit map.
function M.intersect(runs)
  local maps = {}
  for i = 2, #runs do
    maps[i] = {}
    for _, hit in ipairs(runs[i]) do maps[i][hit.path] = hit end
  end
  local paths, hits = {}, {}
  for _, first in ipairs(runs[1]) do
    local best = first
    for i = 2, #runs do
      local hit = maps[i][first.path]
      if not hit then
        best = nil
        break
      end
      if hit.line < best.line then best = hit end
    end
    if best then
      paths[#paths + 1] = first.path
      hits[first.path] = best
    end
  end
  return paths, hits
end

-- rg --json ignores --max-columns, so long lines are cut here, starting shortly before byte col when the match sits deep.
function M.snippet(text, col)
  if not text or not utf8.len(text) then return nil end
  local prefix = ""
  if col and col > 120 then
    local start = col - 60
    while (text:byte(start) or 0) & 0xC0 == 0x80 do start = start - 1 end
    text, prefix = text:sub(start), "…"
  end
  text = text:match("^%s*(.-)%s*$")
  if text == "" then return nil end
  text = prefix .. text
  local cut = utf8.offset(text, SNIPPET_CHARS + 1)
  if cut then text = text:sub(1, cut - 1) end
  return text
end

local function lines(head, limit)
  local out = {}
  for line in (head .. "\n"):gmatch("(.-)\n") do
    if #out == limit then break end
    out[#out + 1] = line
  end
  return out
end

function M.titleFromHead(head, name)
  local ext = name:match("%.([^.]+)$")
  if head and ext and MARKDOWN[ext:lower()] then
    for _, line in ipairs(lines(head, HEADING_LINES)) do
      local heading = line:match("^%s*#+%s+(.-)%s*$")
      if heading and heading ~= "" then return M.snippet(heading) or name end
    end
  end
  return name
end

function M.firstLine(head)
  for _, line in ipairs(lines(head or "", HEADING_LINES)) do
    if line:find("%S") then return M.snippet(line) end
  end
end

-- Drops a trailing partial UTF-8 sequence left by a byte limit; nil when the text is invalid elsewhere.
function M.validPrefix(data)
  if utf8.len(data) then return data end
  local lead = #data
  while lead > #data - 3 and lead > 1 and data:byte(lead) & 0xC0 == 0x80 do lead = lead - 1 end
  local b = data:byte(lead) or 0
  local s = b >= 0xC2 and b <= 0xF4 and data:sub(1, lead - 1)
  if s and utf8.len(s) then return s end
end

-- Up to limit bytes as valid UTF-8 text plus a truncated flag, or nil for unreadable, binary or non-UTF-8 files.
function M.readText(path, limit)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read(limit + 1) or ""
  f:close()
  if data:find("\0", 1, true) then return nil end
  local truncated = #data > limit
  data = truncated and M.validPrefix(data:sub(1, limit)) or data
  if not data or not utf8.len(data) then return nil end
  return data, truncated
end

-- Every list is newest-first, so the overall newest n are among the first n unseen paths of each.
local function newest(lists, n)
  local seen, picked, attrs = {}, {}, {}
  for _, list in ipairs(lists) do
    local taken = 0
    for _, path in ipairs(list) do
      if taken >= n then break end
      if not seen[path] then
        seen[path] = true
        taken = taken + 1
        local attr = utf8.len(path) and hs.fs.attributes(path)
        if attr then
          attrs[path] = attr
          picked[#picked + 1] = path
        end
      end
    end
  end
  table.sort(picked, function(a, b)
    local ma, mb = attrs[a].modification, attrs[b].modification
    if ma ~= mb then return ma > mb end
    return a < b
  end)
  for i = #picked, n + 1, -1 do picked[i] = nil end
  return picked, attrs
end

local function buildItem(path, attr, hit, home)
  local name = path:match("[^/]*$")
  local head = M.readText(path, HEAD_BYTES)
  local snippet
  if hit then
    snippet = M.snippet(M.matchText(hit.raw))
  else
    snippet = M.firstLine(head)
  end
  return {
    path = path,
    name = name,
    title = M.titleFromHead(head, name),
    dir = M.abbreviate(path:match("^(.*)/") or "/", home),
    line = hit and hit.line,
    snippet = snippet,
    mtime = math.floor(attr.modification),
    size = attr.size,
  }
end

local Run = {}
Run.__index = Run

local live

function Run:cancel()
  self.cancelled = true
  for _, task in ipairs(self.tasks) do
    if task:isRunning() then task:terminate() end
  end
  if live == self then live = nil end
end

function Run:warn(message)
  if self.warned[message] then return end
  self.warned[message] = true
  self.warnings[#self.warnings + 1] = message
end

-- Output is streamed because hs.task without a stream callback stalls once the 64 KB pipe buffer fills.
-- hs.task can deliver the last chunk after the exit callback, so a run ends at rg's --json summary line,
-- or SETTLE_SECONDS after exit for --files output, which has no end marker.
function Run:rg(args, done)
  local chunks, tail, code, settle, finished = {}, "", nil, nil, false
  local function finish()
    if finished or self.cancelled then return end
    finished = true
    if settle then settle:stop() end
    if code == 2 then
      self:warn("Some files could not be searched")
    elseif code ~= 0 and code ~= 1 then
      self:warn(("ripgrep exited with code %d"):format(code))
    end
    done(table.concat(chunks))
  end
  local function receive(out)
    if out and out ~= "" then
      chunks[#chunks + 1] = out
      tail = (tail .. out):sub(-64)
    end
    if code and tail:find('"type":"summary"}%s*$') then finish() end
  end
  local task = hs.task.new(self.opts.rgPath, function(exitCode, out)
    code = exitCode
    receive(out)
    if not finished then settle = hs.timer.doAfter(SETTLE_SECONDS, finish) end
  end, function(_, out)
    receive(out)
    return true
  end, args)
  self.tasks[#self.tasks + 1] = task
  if not (task and task:start()) then
    self:warn("Could not start ripgrep")
    return done("")
  end
end

local nextId = 0

-- cb gets {items, elapsedMs, warnings} or {error}. A new run cancels the previous one, whose callbacks then do nothing.
function M.run(query, roots, opts, cb)
  if live then live:cancel() end
  nextId = nextId + 1
  local h = setmetatable({ id = nextId, tasks = {}, cancelled = false, opts = opts, warnings = {}, warned = {} }, Run)
  live = h
  local started = hs.timer.absoluteTime()

  if not (opts.rgPath and hs.fs.attributes(opts.rgPath, "mode") == "file") then
    cb({ error = RG_MISSING })
    return h
  end

  local function finish(paths, attrs, hits)
    if h.cancelled then return end
    local items = {}
    for _, path in ipairs(paths) do items[#items + 1] = buildItem(path, attrs[path], hits[path], opts.home) end
    if live == h then live = nil end
    cb({ items = items, elapsedMs = math.floor((hs.timer.absoluteTime() - started) / 1e6), warnings = h.warnings })
  end

  local dirs = {}
  for _, root in ipairs(roots) do
    if hs.fs.attributes(root, "mode") == "directory" then
      dirs[#dirs + 1] = root
    else
      h:warn("Missing folder: " .. M.abbreviate(root, opts.home))
    end
  end
  if #dirs == 0 then
    finish({}, {}, {})
    return h
  end

  local terms = M.parseTerms(query)
  if #terms == 0 then
    h:rg(M.buildArgs("list", dirs, opts), function(out)
      local paths, attrs = newest({ M.splitNull(out) }, opts.maxResults)
      finish(paths, attrs, {})
    end)
    return h
  end

  local runs, names, pending = {}, {}, #terms + 1
  local function join()
    pending = pending - 1
    if pending > 0 then return end
    local content, hits = M.intersect(runs)
    local paths, attrs = newest({ content, names }, opts.maxResults)
    finish(paths, attrs, hits)
  end
  for i, term in ipairs(terms) do
    h:rg(M.buildArgs("content", dirs, opts, term), function(out)
      runs[i] = M.parseRgJson(out)
      join()
    end)
  end
  h:rg(M.buildArgs("list", dirs, opts), function(out)
    for _, p in ipairs(M.splitNull(out)) do
      if M.nameMatches(p:match("[^/]*$"), terms) then names[#names + 1] = p end
    end
    join()
  end)
  return h
end

return M
