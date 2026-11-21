-- Run from the project root: nvim --headless -u NONE -l tests/run.lua
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.o.columns = 150
vim.o.lines = 45
vim.o.swapfile = false
vim.o.hidden = true
vim.g.mapleader = " "
vim.cmd("runtime plugin/confly.lua")

local git = require("confly.git")
local parser = require("confly.conflicts")
local confly = require("confly")
local uv = vim.uv or vim.loop
local count = 0
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")

local function check(value, message)
  if not value then error(message, 0) end
  count = count + 1
  print("ok " .. count .. " - " .. message)
end

local function eq(actual, expected, message)
  check(vim.deep_equal(actual, expected), message .. (vim.deep_equal(actual, expected) and ""
    or ("\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))))
end

local function write(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(uv.fs_open(path, "w", 438))
  assert(uv.fs_write(fd, data, 0))
  uv.fs_close(fd)
end

local function command(dir, args, allowed)
  local argv = { "git", "-C", dir }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  if not allowed and result.code ~= 0 then error(result.stderr, 0) end
  return result.stdout, result.code
end

local serial = 0
local function fixture(files, operation)
  serial = serial + 1
  local dir = temp .. "/repo-" .. serial
  vim.fn.mkdir(dir, "p")
  command(dir, { "init", "-b", "main" })
  command(dir, { "config", "user.email", "test@confly.local" })
  command(dir, { "config", "user.name", "Confly tests" })
  command(dir, { "config", "core.autocrlf", "false" })
  command(dir, { "config", "commit.gpgsign", "false" })
  for name, versions in pairs(files) do
    if versions[1] then write(dir .. "/" .. name, versions[1]) end
  end
  -- Ensure add/add-only fixtures still have a common ancestor.
  write(dir .. "/.fixture", "base\n")
  command(dir, { "add", "." })
  command(dir, { "commit", "-m", "base" })
  command(dir, { "checkout", "-b", "incoming" })
  for name, versions in pairs(files) do
    if versions[3] then write(dir .. "/" .. name, versions[3])
    else uv.fs_unlink(dir .. "/" .. name) end
  end
  command(dir, { "add", "-A" })
  command(dir, { "commit", "-m", "incoming" })
  command(dir, { "checkout", "main" })
  for name, versions in pairs(files) do
    if versions[2] then write(dir .. "/" .. name, versions[2])
    else uv.fs_unlink(dir .. "/" .. name) end
  end
  command(dir, { "add", "-A" })
  command(dir, { "commit", "-m", "current" })
  local _, code
  if operation == "rebase" then
    _, code = command(dir, { "rebase", "incoming" }, true)
  elseif operation == "cherry-pick" then
    _, code = command(dir, { "cherry-pick", "incoming" }, true)
  else
    _, code = command(dir, { "merge", "incoming" }, true)
  end
  check(code ~= 0, "fixture creates a real " .. (operation or "merge") .. " conflict")
  return dir
end

local function wait(expected_error)
  check(vim.wait(20000, function() return not confly.status().busy end, 10), "async operation completes")
  local err = confly.status().error
  if expected_error then
    check(err and err:find(expected_error, 1, true), "rejects " .. expected_error)
  elseif err then
    error(err, 0)
  end
  return confly.status().session
end

local function open(dir)
  if confly.status().session then confly.close() end
  vim.cmd("enew")
  vim.cmd.cd(vim.fn.fnameescape(dir))
  confly.open()
  return wait()
end

local function entry(s, name)
  for _, e in ipairs(s.entries) do
    if e.path == name then return e end
  end
  error("Entry not found: " .. name)
end

local function unmerged(dir)
  return command(dir, { "ls-files", "-u" })
end

local function tests()
  local h, p = parser.parse({
    "before", "<<<<<<< ours", "left", "||||||| base", "base", "=======", "right", ">>>>>>> theirs", "after",
  })
  eq(#h, 1, "parse diff3 conflict")
  eq(h[1].base, { "base" }, "retain base section")
  eq(p.left, { "before", "left", "after" }, "project left without markers")
  eq(p.right, { "before", "right", "after" }, "project right without markers")
  eq({ h[1].start, h[1].finish }, { 1, 8 }, "half-open result range")
  h = parser.parse({ "<<<<<<<<<< ours", "==========", "right", ">>>>>>>>>> theirs" })
  eq(h[1].left, {}, "custom-width markers and empty side")
  local malformed, err = parser.parse({ "<<<<<<< ours", "left" })
  check(not malformed and err:find("Incomplete"), "reject malformed markers")
  eq(parser.lines("one\r\ntwo\r\n"), { "one", "two" }, "parse CRLF content")
  eq(parser.lines("one\ntwo"), { "one", "two" }, "parse no final newline")
  local repeats = { "same", "same", "incoming-only", "context", "same", "same" }
  local repeated_hunks = { { left_start = 1, left_end = 2 }, { left_start = 4, left_end = 5 } }
  parser.align(repeated_hunks, repeats, { "same", "same", "context", "same", "same" }, "left")
  eq(repeated_hunks[1].left_range, { 1, 2 }, "alignment keeps first repeated block")
  eq(repeated_hunks[2].left_range, { 3, 4 }, "alignment accounts for non-conflicting incoming insertion")

  local base = "start\nold-one\ncontext1\ncontext2\ncontext3\ncontext4\ncontext5\ncontext6\ncontext7\nold-two\nend\n"
  local left = base:gsub("old%-one", "left-one"):gsub("old%-two", "left-two")
  local right = base:gsub("old%-one", "right-one"):gsub("old%-two", "right-two")
  local dir = fixture({
    ["src/sample.lua"] = { base, left, right },
    ["space ü [x].txt"] = { "base\n", "ours\n", "theirs\n" },
  })
  local s = open(dir)
  eq(#s.entries, 2, "picker discovers exact conflicted paths")
  check(vim.api.nvim_buf_get_lines(s.file_buf, 0, -1, false)[2]:find("C O N F L Y"), "file picker renders")
  eq(vim.api.nvim_buf_get_lines(s.file_buf, 4, 5, false)[1],
    "  " .. vim.fs.basename(dir) .. "  ·  merge", "picker displays repository name without host directories")
  local e = entry(s, "src/sample.lua")
  local result_buf = vim.fn.bufadd(dir .. "/src/sample.lua")
  vim.fn.bufload(result_buf)
  vim.keymap.set("n", "<leader>c1", "<cmd>echo 'original'<CR>", { buffer = result_buf, desc = "Original user map" })
  confly.open_file(e)
  s = wait()
  local m = s.merge
  eq(#m.wins, 3, "opens three panes")
  eq(#m.hunks, 2, "tracks separate conflicts")
  check(not vim.bo[m.bufs[1]].modifiable and not vim.bo[m.bufs[3]].modifiable, "source panes are read-only")
  eq(vim.api.nvim_buf_get_lines(m.bufs[1], 0, -1, false), parser.lines(left), "left pane shows full index version")
  eq(m.hunks[2].left_range, { 9, 10 }, "second conflict maps to correct source line")
  confly.choose("left")
  eq(m.hunks[1].state, "left", "accept left resolves active conflict")
  confly.undo()
  eq(m.hunks[1].state, "unresolved", "undo restores conflict decision")
  check(parser.has_markers(vim.api.nvim_buf_get_lines(m.buf, 0, -1, false)), "undo restores markers")
  vim.api.nvim_buf_call(m.buf, function() vim.cmd("silent redo") end)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = m.buf })
  eq(m.hunks[1].state, "left", "native redo restores decision status")
  vim.api.nvim_buf_call(m.buf, function() vim.cmd("silent undo") end)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = m.buf })
  eq(m.hunks[1].state, "unresolved", "native undo invalidates accepted decision")
  confly.choose("left")
  local maps = vim.api.nvim_buf_get_keymap(m.bufs[1], "n")
  for _, mapping in ipairs(maps) do if mapping.lhs == "j" then mapping.callback() end end
  eq(m.active, 2, "j navigates to next conflict")
  eq(vim.api.nvim_win_get_cursor(m.wins[3])[1], 10, "navigation synchronizes source panes")
  confly.resolve()
  wait("Resolve or manually confirm every conflict")
  confly.choose("right")
  confly.resolve()
  s = wait()
  eq(git.read(dir .. "/src/sample.lua"), left:gsub("left%-two", "right-two"), "mixed resolution saves correct merged file")
  check(e.resolved, "successful staging marks file resolved")
  check(vim.iter(vim.api.nvim_buf_get_keymap(result_buf, "n")):any(function(map)
    return map.desc == "Original user map"
  end), "leaving editor restores original buffer-local mappings")
  check(not vim.iter(vim.api.nvim_buf_get_keymap(result_buf, "n")):any(function(map)
    return map.desc and map.desc:match("^Confly:")
  end), "leaving editor removes Confly result mappings")
  check(not unmerged(dir):find("src/sample.lua", 1, true), "resolved path leaves unmerged index")
  check(unmerged(dir):find("space", 1, true), "other conflicted path is untouched")
  local green = vim.api.nvim_buf_get_extmarks(s.file_buf, require("confly.ui").ns, 0, -1, { details = true })
  check(vim.iter(green):any(function(mark) return mark[4].hl_group == "ConflyResolved" end), "picker adds green resolved highlight")
  local other = entry(s, "space ü [x].txt")
  confly.accept_file(other, 3)
  wait()
  eq(git.read(dir .. "/space ü [x].txt"), "theirs\n", "whole-file right handles Unicode, spaces and pathspec characters")
  eq(unmerged(dir), "", "all files resolved in index")

  dir = fixture({ ["a.txt"] = { "base\n", "left\n", "right\n" } })
  s = open(dir)
  e = s.entries[1]
  write(dir .. "/a.txt", "external edit\n")
  confly.accept_file(e, 2)
  wait("The file changed on disk")
  eq(git.read(dir .. "/a.txt"), "external edit\n", "stale picker preserves external changes")
  confly.files()
  s = wait()
  confly.open_file(s.entries[1])
  s = wait()
  m = s.merge
  confly.confirm()
  eq(m.hunks[1].state, "manual", "marker-free existing result requires manual confirmation")
  confly.resolve()
  wait()
  eq(git.read(dir .. "/a.txt"), "external edit\n", "manually resolved result is preserved")

  dir = fixture({ ["a.txt"] = { "base\n", "left\n", "right\n" } })
  local old_buf = vim.fn.bufadd(dir .. "/a.txt")
  vim.fn.bufload(old_buf)
  write(dir .. "/a.txt", "externally resolved result\n")
  s = open(dir)
  confly.open_file(s.entries[1])
  s = wait()
  eq(vim.api.nvim_buf_get_lines(s.merge.buf, 0, -1, false), { "externally resolved result" },
    "opening refreshes stale unmodified buffers from disk")
  confly.confirm()
  confly.undo()
  eq(s.merge.hunks[1].state, "unresolved", "undo manual confirmation restores unresolved status")
  confly.confirm()
  confly.resolve()
  wait()

  dir = fixture({ ["a.txt"] = { "base\n", "left\n", "right\n" } })
  s = open(dir)
  e = s.entries[1]
  local buf = vim.fn.bufadd(dir .. "/a.txt")
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved edit" })
  confly.accept_file(e, 3)
  wait("This file has unsaved edits")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "unsaved edit" }, "whole-file selection preserves modified buffer")
  confly.open_file(e)
  s = wait()
  eq(s.merge.buf, buf, "editor reuses existing modified buffer")
  confly.confirm()
  confly.resolve()
  wait()

  dir = fixture({ ["a.txt"] = { "base\n", "left\n", "right\n" } })
  s = open(dir)
  confly.open_file(s.entries[1])
  s = wait()
  confly.choose("both")
  vim.api.nvim_buf_call(s.merge.buf, function() vim.cmd("silent write") end)
  confly.resolve()
  wait()
  eq(git.read(dir .. "/a.txt"), "left\nright\n", "combine both uses left-then-right order")

  dir = fixture({ ["a.txt"] = { "base\r\n", "left\r\n", "right\r\n" } })
  s = open(dir)
  confly.open_file(s.entries[1])
  s = wait()
  eq(vim.bo[s.merge.buf].fileformat, "dos", "result detects CRLF format")
  confly.choose("right")
  confly.resolve()
  wait()
  eq(git.read(dir .. "/a.txt"), "right\r\n", "resolution preserves CRLF")

  dir = fixture({ ["a.txt"] = { "base", "left", "right" } })
  s = open(dir)
  confly.accept_file(s.entries[1], 2)
  wait()
  eq(git.read(dir .. "/a.txt"), "left", "whole-file acceptance preserves missing final newline")

  dir = fixture({ ["a.txt"] = { "base", "left", "right" } })
  s = open(dir)
  confly.open_file(s.entries[1])
  s = wait()
  confly.choose("right")
  confly.resolve()
  wait()
  eq(git.read(dir .. "/a.txt"), "right", "pane acceptance preserves selected side's missing final newline")

  dir = fixture({ ["a.txt"] = { "base\n", "left\n", "right\n" } })
  s = open(dir)
  confly.open_file(s.entries[1])
  s = wait()
  confly.choose("left")
  write(dir .. "/.git/index.lock", "")
  confly.resolve()
  wait("index.lock")
  check(not s.entries[1].resolved, "failed staging never marks a file resolved")
  check(unmerged(dir) ~= "", "failed staging leaves unmerged index entries")
  uv.fs_unlink(dir .. "/.git/index.lock")
  confly.resolve()
  wait()

  dir = fixture({ ["a.txt"] = { "base\n", "left\n", "right\n" } })
  s = open(dir)
  command(dir, { "reset", "HEAD", "--", "a.txt" })
  local unchanged = git.read(dir .. "/a.txt")
  confly.accept_file(s.entries[1], 2)
  wait("The Git index changed")
  eq(git.read(dir .. "/a.txt"), unchanged, "stale index prevents worktree replacement")

  dir = fixture({ ["a.bin"] = { "base\0data", "left\0data", "right\0data" } })
  s = open(dir)
  confly.open_file(s.entries[1])
  wait("Binary conflict")
  confly.accept_file(s.entries[1], 3)
  wait()
  eq(git.read(dir .. "/a.bin"), "right\0data", "whole-file binary resolution preserves exact bytes")

  dir = fixture({ ["a.txt"] = { "base\n", false, "right\n" } })
  s = open(dir)
  check(not s.entries[1].stages[2], "modify/delete fixture has absent left stage")
  confly.accept_file(s.entries[1], 2)
  wait()
  check(not uv.fs_stat(dir .. "/a.txt"), "accepting missing side deletes the file")
  eq(unmerged(dir), "", "deletion is staged")

  dir = fixture({ ["a.txt"] = { false, "left\n", "right\n" } })
  s = open(dir)
  check(not s.entries[1].stages[1], "add/add conflict has no base")
  confly.accept_file(s.entries[1], 2)
  wait()
  eq(git.read(dir .. "/a.txt"), "left\n", "add/add resolves")

  dir = fixture({ ["a.txt"] = { "base\n", "feature\n", "upstream\n" } }, "rebase")
  s = open(dir)
  eq(s.context.operation, "rebase", "detect rebase operation")
  check(s.context.left:find("Rebased onto") and s.context.right:find("Replayed commit"), "rebase-aware pane labels")
  confly.open_file(s.entries[1])
  s = wait()
  eq(s.merge.left, { "upstream" }, "rebase left is rebased-onto version")
  eq(s.merge.right, { "feature" }, "rebase right is replayed commit")
  confly.close()
  check(not confly.status().session, "close releases session")

  -- No-conflict repositories are a normal, useful empty state.
  command(dir, { "rebase", "--abort" })
  s = open(dir)
  eq(#s.entries, 0, "empty picker handles repository without conflicts")
  confly.close()

  dir = fixture({ ["a.txt"] = { "base\n", "current\n", "picked\n" } }, "cherry-pick")
  s = open(dir)
  eq(s.context.operation, "cherry-pick", "detect cherry-pick operation")
  confly.accept_file(s.entries[1], 3)
  wait()
  eq(git.read(dir .. "/a.txt"), "picked\n", "cherry-pick right accepts picked commit")
  confly.close()

  dir = fixture({ ["a.txt"] = { "base\n", "current\n", "incoming\n" } })
  local linked = temp .. "/linked-worktree"
  command(dir, { "worktree", "add", "--detach", linked, "main" })
  command(linked, { "merge", "incoming" }, true)
  s = open(linked)
  eq(#s.entries, 1, "discover conflicts in linked worktree with .git file")
  confly.accept_file(s.entries[1], 2)
  wait()
  eq(unmerged(linked), "", "stage resolution in correct worktree")
  check(unmerged(dir) ~= "", "main worktree index is unaffected")
  confly.close()
  check(vim.fn.exists(":Confly") == 2 and vim.fn.exists(":ConflyResolve") == 2, "plugin registers commands")
end

local ok, err = xpcall(tests, debug.traceback)
vim.cmd.cd(vim.fn.fnameescape(root))
if ok then
  vim.fn.delete(temp, "rf")
  print("\nPASS: " .. count .. " checks")
  vim.cmd("qa!")
else
  io.stderr:write("\nFAIL: " .. err .. "\nFixtures retained at " .. temp .. "\n")
  vim.cmd("cquit 1")
end
