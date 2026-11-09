-- Run inside Hammerspoon: hs -c "dofile('/path/to/seekpop/tests/search_test.lua')"
local repo = debug.getinfo(1, "S").source:match("^@(.*)/tests/[^/]*$")
local search = dofile(repo .. "/SeekPop.spoon/search.lua")
local checks = 0

local function eq(actual, expected, label)
  checks = checks + 1
  assert(actual == expected, ("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
end

local function same(actual, expected, label)
  eq(#actual, #expected, label .. " length")
  for i = 1, #expected do eq(actual[i], expected[i], label .. " [" .. i .. "]") end
end

local function indexOf(list, value)
  for i, v in ipairs(list) do
    if v == value then return i end
  end
end

same(search.parseTerms("  최종  검증 Plan plan  "), { "최종", "검증", "plan" }, "terms split, lowercased, deduped")
same(search.parseTerms(" \t "), {}, "blank query has no terms")

eq(search.nameMatches("Release-PLAN.md", { "plan", "release" }), true, "name matches every term")
eq(search.nameMatches("PLAN.md", { "plan", "release" }), false, "name needs every term")
eq(search.nameMatches("a.b.md", { "." }), true, "name terms are plain text, not patterns")

eq(search.titleFromHead("# 제목\n본문", "PLAN.md"), "제목", "korean # heading")
eq(search.titleFromHead("intro\n\n## 요약  \r\nbody", "notes.markdown"), "요약", "## heading after text, CRLF")
eq(search.titleFromHead("no heading here\n#tag is not a heading", "PLAN.md"), "PLAN.md", "no heading falls back to name")
eq(search.titleFromHead("# Title", "script.sh"), "script.sh", "non-markdown keeps name")
eq(search.titleFromHead(nil, "PLAN.mdx"), "PLAN.mdx", "unreadable head keeps name")
eq(search.titleFromHead(("x\n"):rep(40) .. "# Late", "PLAN.md"), "PLAN.md", "heading past line 40 is ignored")
eq(search.firstLine("\n  \n  first words  \nsecond"), "first words", "first non-empty line, trimmed")

local rgJson = table.concat({
  [[{"type":"begin","data":{"path":{"text":"/tmp/a b/계획: 1.md"}}}]],
  [[{"type":"match","data":{"path":{"text":"/tmp/a b/계획: 1.md"},"lines":{"text":"  최종 검증 단계\n"},"line_number":12,"absolute_offset":0,"submatches":[{"match":{"text":"최종"},"start":2,"end":8}]}}]],
  [[{"type":"match","data":{"path":{"text":"/tmp/a b/계획: 1.md"},"lines":{"text":"later\n"},"line_number":30,"absolute_offset":9,"submatches":[]}}]],
  [[{"type":"match","data":{"path":{"text":"/tmp/bin.md"},"lines":{"bytes":"/w=="},"line_number":3,"absolute_offset":0,"submatches":[]}}]],
  [[{"type":"match","data":{"path":{"bytes":"L3RtcC//"},"lines":{"text":"x\n"},"line_number":1,"absolute_offset":0,"submatches":[]}}]],
  [[{"type":"match","data":{"path":{"text":"/tmp/q\"x\\y.md"},"lines":{"text":"},\"line_number\":99,\n"},"line_number":5,"absolute_offset":0,"submatches":[{"match":{"text":"y"},"start":0,"end":1}]}}]],
  [[{"type":"end","data":{"path":{"text":"/tmp/a b/계획: 1.md"}}}]],
  [[{"data":{"elapsed_total":{"secs":0}},"type":"summary"}]],
}, "\n")
local hits = search.parseRgJson(rgJson)
eq(#hits, 3, "one hit per text path; bytes-only path skipped")
local hit = hits[1]
eq(hit.path, "/tmp/a b/계획: 1.md", "path with space, korean and colon")
eq(hit.line, 12, "first match line kept for path with space, korean and colon")
local text, col = search.matchText(hit.raw)
eq(text, "  최종 검증 단계\n", "match line text")
eq(col, 3, "submatch byte offset becomes 1-based")
eq(search.snippet(text, col), "최종 검증 단계", "snippet trimmed")
eq(hits[2].path, "/tmp/bin.md", "file whose matched line is not UTF-8 still counts as a match")
eq(hits[2].line, 3, "its line number kept")
eq(search.matchText(hits[2].raw), nil, "its snippet text omitted")
eq(hits[3].path, '/tmp/q"x\\y.md', "escaped path decoded through the fallback")
eq(hits[3].line, 5, "fallback line number, not the look-alike inside the text")

local function h(path, line) return { path = path, line = line } end
local paths, byPath = search.intersect({
  { h("/new", 9), h("/mid", 2), h("/old", 1) },
  { h("/old", 3), h("/new", 4) },
})
same(paths, { "/new", "/old" }, "AND keeps paths every term hit, in first-term order")
eq(byPath["/new"].line, 4, "earliest line across terms wins")
eq(byPath["/old"].line, 1, "first term line kept when earlier")
eq(byPath["/mid"], nil, "path missing a term dropped")
same(search.intersect({ { h("/a", 1) }, {} }), {}, "absent second term matches nothing")

local long = ("가"):rep(400) .. " needle tail"
local s = search.snippet(long, #("가"):rep(400) + 2)
eq(utf8.len(s) <= 300, true, "long snippet capped at 300 chars")
eq(s:sub(1, 3), "…", "deep match gets an ellipsis prefix")
eq(s:find("needle", 1, true) ~= nil, true, "deep match stays visible")
eq(utf8.len(s) ~= nil, true, "cut lands on a character boundary")
eq(search.snippet("ok \xff\xfe bad"), nil, "invalid UTF-8 snippet omitted")
eq(search.snippet("   "), nil, "blank snippet omitted")
eq(search.titleFromHead("# bad \xff title", "PLAN.md"), "PLAN.md", "invalid UTF-8 title falls back to name")

local opts = { maxFileSize = "2M", exclude = { ".git", "node_modules" } }
local roots = { "/r one", "-dash root" }
eq(search.pattern("결제"), "\\x{ACB0}\\x{C81C}", "korean term becomes code point escapes")
eq(search.pattern("a.b-1(x)"), "a\\x{2E}b\\x{2D}1\\x{28}x\\x{29}", "punctuation escaped, letters and digits kept")
eq(search.pattern("최종:Plan"):find("[\128-\255]"), nil, "pattern is ASCII only")
local content = search.buildArgs("content", roots, opts, "-foo")
local dd = indexOf(content, "--")
eq(dd, #content - 2, "-- sits right before the roots")
eq(content[dd + 1], "/r one", "first root after --")
eq(content[dd + 2], "-dash root", "dash root is after --")
eq(content[indexOf(content, "!.git") - 1], "-g", "exclude passed as -g !x")
eq(indexOf(content, "!node_modules") < dd, true, "every exclude before --")
eq(content[indexOf(content, "--max-filesize") + 1], "2M", "max file size passed")
eq(content[indexOf(content, "-e") + 1], "\\x{2D}foo", "term passed escaped with -e")
eq(indexOf(content, "-F"), nil, "escaped patterns are regexes, not fixed strings")
eq(content[indexOf(content, "--max-count") + 1], "1", "one json match per file")
eq(indexOf(content, "--hidden") ~= nil and indexOf(content, "--json") ~= nil, true, "hidden folders searched as json")
local list = search.buildArgs("list", { "/r" }, opts)
eq(indexOf(list, "--files") ~= nil and indexOf(list, "!.git") ~= nil, true, "list walks with excludes")
eq(indexOf(list, "--max-filesize"), nil, "name listing keeps large files")
eq(indexOf(list, "-e"), nil, "name listing has no pattern")
eq(list[#list - 1], "--", "list root after --")

same(search.splitNull("/a b/x.md\0/c:d.md\0"), { "/a b/x.md", "/c:d.md" }, "NUL separated output")

eq(search.abbreviate("/Users/me/.codex/plans", "/Users/me"), "~/.codex/plans", "home abbreviated")
eq(search.abbreviate("/Users/me", "/Users/me"), "~", "home itself")
eq(search.abbreviate("/Users/meow/x", "/Users/me"), "/Users/meow/x", "sibling prefix untouched")

eq(search.validPrefix("ab" .. ("한"):sub(1, 2)), "ab", "partial trailing character dropped")
eq(search.validPrefix("a\xffb"), nil, "invalid middle byte rejected")

local tmp = os.tmpname()
local function write(data)
  local f = assert(io.open(tmp, "wb"))
  f:write(data)
  f:close()
end
write("가나다")
local text, truncated = search.readText(tmp, 4)
eq(text, "가", "byte limit cut inside a character keeps whole characters")
eq(truncated, true, "truncation reported")
write("plain\n")
text, truncated = search.readText(tmp, 100)
eq(text, "plain\n", "small file read whole")
eq(truncated, false, "no truncation")
write("bin\0ary")
eq(search.readText(tmp, 100), nil, "binary file rejected")
write("bad \xc3\x28 utf8")
eq(search.readText(tmp, 100), nil, "invalid UTF-8 file rejected")
os.remove(tmp)
eq(search.readText(tmp, 100), nil, "missing file rejected")

print(("search_test ok: %d checks"):format(checks))
