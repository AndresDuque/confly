local M = {}
local uv = vim.uv or vim.loop

function M.call(root, args, allow_failure)
  local argv = { "git", "--literal-pathspecs", "-C", root }
  vim.list_extend(argv, args)
  local result = require("confly.async").system(argv, { timeout = 15000 })
  if result.code ~= 0 and not allow_failure then
    error(vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr)
      or ("git " .. table.concat(args, " ") .. " failed (" .. result.code .. ")"), 0)
  end
  return result.stdout or "", result.code
end

function M.root(path)
  local output = M.call(path, { "rev-parse", "--show-toplevel" })
  return vim.fs.normalize((output:gsub("[\r\n]+$", "")))
end

function M.entries(root)
  local output = M.call(root, { "ls-files", "--unmerged", "-z" })
  local entries, by_path = {}, {}
  for record in output:gmatch("([^%z]+)%z") do
    local mode, oid, stage, path = record:match("^(%d+) (%x+) (%d)\t(.*)$")
    if not path then
      error("Cannot parse Git's unmerged index entry", 0)
    end
    local entry = by_path[path]
    if not entry then
      entry = { path = path, stages = {} }
      by_path[path] = entry
      entries[#entries + 1] = entry
    end
    entry.stages[tonumber(stage)] = { mode = mode, oid = oid }
  end
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries, by_path
end

function M.signature(entry)
  local parts = {}
  for i = 1, 3 do
    local stage = entry.stages[i]
    parts[i] = stage and (stage.mode .. ":" .. stage.oid) or "-"
  end
  return table.concat(parts, "|")
end

function M.supported(entry)
  local mode
  for _, stage in pairs(entry.stages) do
    if stage.mode ~= "100644" and stage.mode ~= "100755" then
      return false, "Symlink and submodule conflicts require Git's own resolution tools."
    end
    if mode and mode ~= stage.mode then
      return false, "Conflicting executable modes require Git's own resolution tools."
    end
    mode = stage.mode
  end
  return true
end

function M.blob(root, stage)
  if not stage then
    return nil
  end
  return M.call(root, { "cat-file", "blob", stage.oid })
end

function M.read(path)
  local stat = uv.fs_lstat(path)
  if not stat then
    return nil
  end
  if stat.type ~= "file" then
    error("Not a regular file: " .. path, 0)
  end
  local fd, err = uv.fs_open(path, "r", 438)
  if not fd then
    error(err, 0)
  end
  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then
    error(read_err, 0)
  end
  return data
end

function M.context(root)
  local function exists(name)
    local path = M.call(root, { "rev-parse", "--git-path", name }):gsub("[\r\n]+$", "")
    if not vim.fs.is_absolute or not vim.fs.is_absolute(path) then
      if not path:match("^[/\\]") and not path:match("^%a:") then
        path = root .. "/" .. path
      end
    end
    return uv.fs_stat(path) ~= nil
  end
  local branch = M.call(root, { "symbolic-ref", "--short", "-q", "HEAD" }, true):gsub("[\r\n]+$", "")
  local head = M.call(root, { "rev-parse", "--short", "HEAD" }):gsub("[\r\n]+$", "")
  if exists("rebase-merge") or exists("rebase-apply") then
    local replay = M.call(root, { "rev-parse", "--short", "REBASE_HEAD" }, true):gsub("[\r\n]+$", "")
    return { operation = "rebase", left = "Rebased onto · " .. head, right = "Replayed commit · " .. replay }
  end
  local operation = exists("CHERRY_PICK_HEAD") and "cherry-pick" or "merge"
  local incoming = M.call(root, { "rev-parse", "--short", operation == "merge" and "MERGE_HEAD" or "CHERRY_PICK_HEAD" }, true)
  incoming = incoming:gsub("[\r\n]+$", "")
  return {
    operation = operation,
    left = "Current · " .. (branch ~= "" and branch or head),
    right = "Incoming · " .. (incoming:match("^%x+$") and incoming or "theirs"),
  }
end

return M
