local M = {}
local git = require("confly.git")
local conflicts = require("confly.conflicts")
local ui = require("confly.ui")
local anchors = vim.api.nvim_create_namespace("confly.ranges")
local session
local busy = false
local last_error

local defaults = {
  icons = true,
  ctrl_numbers = true,
  keys = {
    j = "j", k = "k", open = "<CR>", left = "l", right = "r",
    refresh = "R", close = "q", accept = "c", discard = "d", both = "b",
    source_undo = "u", undo = "<leader>cu", confirm = "<leader>cc",
    next = "]x", prev = "[x", files = "<leader>cf", resolve = "<leader>cs",
    pane1 = "<leader>c1", pane2 = "<leader>c2", pane3 = "<leader>c3",
    help = "?",
  },
}
local config = vim.deepcopy(defaults)

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Confly" })
end

local function run(fn)
  if busy then
    notify("A Git operation is still running.", vim.log.levels.WARN)
    return
  end
  busy, last_error = true, nil
  require("confly.async").run(fn, function(ok, err)
    busy = false
    if not ok then
      last_error = err
      notify(tostring(err):match("^[^\n]+"), vim.log.levels.ERROR)
    end
  end)
end

local function valid()
  return session and vim.api.nvim_tabpage_is_valid(session.tab)
end

local function path(entry)
  return session.root .. "/" .. entry.path
end

local function range(merge, h)
  local mark = vim.api.nvim_buf_get_extmark_by_id(merge.buf, anchors, h.mark, { details = true })
  if #mark == 0 then
    error("Conflict range was lost. Reopen this file.", 0)
  end
  return mark[1], mark[3].end_row
end

local function contents(merge, h)
  local first, last = range(merge, h)
  return vim.api.nvim_buf_get_lines(merge.buf, first, last, false)
end

local function equal(a, b)
  return vim.deep_equal(a, b)
end

local function update_states(merge)
  for _, h in ipairs(merge.hunks) do
    local current = contents(merge, h)
    h.state = "unresolved"
    for i = #(h.choices or {}), 1, -1 do
      local choice = h.choices[i]
      if equal(current, choice.lines) and not conflicts.has_markers(current) then
        h.state = choice.decision
        local _, last = range(merge, h)
        if last == vim.api.nvim_buf_line_count(merge.buf) and choice.eol ~= nil then
          vim.bo[merge.buf].endofline = choice.eol
        end
        break
      end
    end
  end
  if equal(vim.api.nvim_buf_get_lines(merge.buf, 0, -1, false), merge.initial_lines) then
    vim.bo[merge.buf].endofline = merge.initial_eol
  end
end

local function render()
  local merge = valid() and session.merge
  if not merge or not merge.bufs then
    return
  end
  update_states(merge)
  local remaining = 0
  for _, buf in ipairs(merge.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ui.ns, 0, -1)
    end
  end
  local function highlight(buf, first, last, group)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local count = vim.api.nvim_buf_line_count(buf)
    first = math.max(0, math.min(count - 1, first))
    last = math.max(first + 1, math.min(count, last))
    vim.api.nvim_buf_set_extmark(buf, ui.ns, first, 0, {
      end_row = last, end_col = 0, hl_group = group, hl_eol = true, priority = 110,
    })
  end
  for i, h in ipairs(merge.hunks) do
    if h.state == "unresolved" then
      remaining = remaining + 1
      local group = i == merge.active and "ConflyActive" or "ConflyConflict"
      highlight(merge.bufs[1], h.left_range[1], h.left_range[2], group)
      highlight(merge.bufs[3], h.right_range[1], h.right_range[2], group)
      local first, last = range(merge, h)
      highlight(merge.buf, first, last, group)
    end
  end
  if vim.api.nvim_win_is_valid(merge.wins[2]) then
    vim.wo[merge.wins[2]].winbar = "%#ConflyTitle# 2  Result · "
      .. ui.display_path(merge.entry.path):gsub("%%", "%%%%")
      .. "  %=" .. remaining .. " unresolved "
  end
end

local function navigate(delta)
  local merge = valid() and session.merge
  if not merge or #merge.hunks == 0 then
    return
  end
  merge.active = ((merge.active - 1 + delta) % #merge.hunks) + 1
  local h = merge.hunks[merge.active]
  local first = range(merge, h)
  local rows = { h.left_range[1], first, h.right_range[1] }
  for i, win in ipairs(merge.wins) do
    if vim.api.nvim_win_is_valid(win) then
      local count = vim.api.nvim_buf_line_count(merge.bufs[i])
      vim.api.nvim_win_set_cursor(win, { math.min(count, rows[i] + 1), 0 })
      vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
    end
  end
  render()
end

local function cleanup_merge()
  local merge = session and session.merge
  if not merge then
    return
  end
  if merge.autocmd then
    pcall(vim.api.nvim_del_autocmd, merge.autocmd)
  end
  if vim.api.nvim_buf_is_valid(merge.buf) then
    vim.api.nvim_buf_clear_namespace(merge.buf, anchors, 0, -1)
    vim.api.nvim_buf_clear_namespace(merge.buf, ui.ns, 0, -1)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(merge.buf, "n")) do
      if map.desc and map.desc:match("^Confly:") then
        pcall(vim.api.nvim_buf_del_keymap, merge.buf, "n", map.lhs)
      end
    end
    vim.api.nvim_buf_call(merge.buf, function()
      for _, map in ipairs(merge.original_maps or {}) do
        vim.fn.mapset("n", false, map)
      end
    end)
  end
  session.merge = nil
end

local function callbacks()
  return {
    open = M.open_file, accept = M.accept_file, refresh = M.files, close = M.close,
    move = navigate, choose = M.choose, undo = M.undo, confirm = M.confirm,
    files = M.files, resolve = M.resolve,
  }
end

local function refresh()
  local entries, present = git.entries(session.root)
  local context = git.context(session.root)
  if not valid() then
    error("Confly tab was closed.", 0)
  end
  session.context = context
  for _, entry in ipairs(session.entries) do
    if entry.resolved and not present[entry.path] then
      entries[#entries + 1] = entry
    end
  end
  for _, entry in ipairs(entries) do
    if not entry.resolved then
      local ok, data = pcall(git.read, path(entry))
      entry.disk = ok and data or nil
      entry.read_error = not ok and data or nil
    end
  end
  table.sort(entries, function(a, b) return a.path < b.path end)
  session.entries = entries
end

local function show_files()
  cleanup_merge()
  ui.files(session, callbacks(), config)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  ui.highlights()
  local group = vim.api.nvim_create_augroup("Confly", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ui.highlights })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      vim.schedule(function()
        if session and not vim.api.nvim_tabpage_is_valid(session.tab) then
          cleanup_merge()
          session = nil
        end
      end)
    end,
  })
end

function M.open()
  if valid() then
    return M.files()
  end
  if vim.fn.has("nvim-0.10.4") ~= 1 then
    notify("Confly requires Neovim 0.10.4 or newer.", vim.log.levels.ERROR)
    return
  end
  local current = vim.api.nvim_buf_get_name(0)
  local cwd = vim.fn.getcwd()
  local start = current ~= "" and vim.bo.buftype == "" and vim.fs.dirname(current) or cwd
  run(function()
    local ok, root = pcall(git.root, start)
    if not ok then
      root = git.root(cwd)
    end
    local context = git.context(root)
    vim.cmd("tabnew")
    session = { root = root, context = context, tab = vim.api.nvim_get_current_tabpage(), entries = {} }
    refresh()
    show_files()
  end)
end

function M.files()
  if not valid() then
    return M.open()
  end
  run(function()
    refresh()
    show_files()
  end)
end

local function check_entry(entry, check_disk)
  if not entry or entry.resolved then
    error("Select an unresolved file.", 0)
  end
  local supported, reason = git.supported(entry)
  if not supported then
    error(reason, 0)
  end
  if entry.read_error then
    error(entry.read_error, 0)
  end
  local _, present = git.entries(session.root)
  local fresh = present[entry.path]
  if not fresh or git.signature(entry) ~= git.signature(fresh) then
    error("The Git index changed. Refresh the file list before continuing.", 0)
  end
  if check_disk and git.read(path(entry)) ~= entry.disk then
    error("The file changed on disk. Refresh the file list before continuing.", 0)
  end
end

function M.open_file(entry)
  run(function()
    check_entry(entry, true)
    if vim.o.columns < 90 then
      error("The three-pane editor needs at least 90 terminal columns.", 0)
    end
    local left_data = git.blob(session.root, entry.stages[2])
    local right_data = git.blob(session.root, entry.stages[3])
    if not valid() or git.read(path(entry)) ~= entry.disk then
      error("The file changed while loading. Refresh the file list.", 0)
    end
    if (left_data or ""):find("\0", 1, true) or (right_data or ""):find("\0", 1, true)
      or (entry.disk or ""):find("\0", 1, true) then
      error("Binary conflict: use l or r in the file picker to choose a whole file.", 0)
    end
    local buf = vim.fn.bufadd(path(entry))
    local already_loaded = vim.api.nvim_buf_is_loaded(buf)
    vim.fn.bufload(buf)
    if already_loaded and not vim.bo[buf].modified then
      -- A clean buffer may predate the picker's disk snapshot (external editor
      -- or Git operation). Reload it; never reload over unsaved edits.
      vim.api.nvim_buf_call(buf, function() vim.cmd("silent edit") end)
    end
    vim.bo[buf].buflisted = true
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local hunks, projections = conflicts.parse(lines)
    if not hunks then
      error(projections, 0)
    end
    local merge = {
      entry = entry, buf = buf, left = conflicts.lines(left_data), right = conflicts.lines(right_data),
      hunks = hunks, active = 1, history = {}, original_maps = vim.api.nvim_buf_get_keymap(buf, "n"),
      initial_lines = vim.deepcopy(lines), initial_eol = vim.bo[buf].endofline,
      left_eol = left_data and left_data:sub(-1) == "\n" or false,
      right_eol = right_data and right_data:sub(-1) == "\n" or false,
    }
    if #hunks == 0 then
      hunks[1] = {
        start = 0, finish = #lines, left = merge.left, right = merge.right,
        left_range = { 0, #merge.left }, right_range = { 0, #merge.right },
        state = "unresolved", whole = true,
      }
    else
      conflicts.align(hunks, projections.left, merge.left, "left")
      conflicts.align(hunks, projections.right, merge.right, "right")
    end
    cleanup_merge()
    for _, h in ipairs(hunks) do
      h.mark = vim.api.nvim_buf_set_extmark(buf, anchors, h.start, 0, {
        end_row = h.finish, end_col = 0, right_gravity = false, end_right_gravity = true,
      })
    end
    session.merge = merge
    ui.merge(session, merge, callbacks(), config)
    merge.autocmd = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
      buffer = buf,
      callback = function(event)
        if valid() and session.merge == merge then
          if event.event == "BufWritePost" then
            merge.entry.disk = git.read(path(merge.entry))
          end
          render()
        end
      end,
    })
    navigate(0)
  end)
end

function M.choose(side)
  if busy or not valid() or not session.merge then
    return
  end
  local merge = session.merge
  local h = merge.hunks[merge.active]
  if (side == "left" and not merge.entry.stages[2]) or (side == "right" and not merge.entry.stages[3]) then
    notify("That side deletes this file. Use l / r in the file picker.", vim.log.levels.WARN)
    return
  end
  local replacement = side == "both" and vim.list_extend(vim.deepcopy(h.left), h.right) or h[side]
  if not replacement then
    return
  end
  local first, last = range(merge, h)
  merge.history[#merge.history + 1] = {
    lines = vim.api.nvim_buf_get_lines(merge.buf, 0, -1, false),
    hunks = vim.tbl_map(function(item)
      local a, b = range(merge, item)
      return { first = a, last = b }
    end, merge.hunks),
  }
  -- Reset undo synchronization so one keypress is one native undo step too.
  vim.api.nvim_buf_call(merge.buf, function()
    vim.cmd("let &undolevels = &undolevels")
    vim.api.nvim_buf_set_lines(merge.buf, first, last, false, replacement)
  end)
  vim.api.nvim_buf_set_extmark(merge.buf, anchors, first, 0, {
    id = h.mark, end_row = first + #replacement, end_col = 0,
    right_gravity = false, end_right_gravity = true,
  })
  local eol
  if first + #replacement == vim.api.nvim_buf_line_count(merge.buf) then
    local final_side = side == "both" and (#h.right > 0 and "right" or "left") or side
    eol = merge[final_side .. "_eol"]
  end
  h.choices = h.choices or {}
  h.choices[#h.choices + 1] = { lines = vim.deepcopy(replacement), decision = side, eol = eol }
  render()
end

function M.confirm()
  if busy or not valid() or not session.merge then
    return
  end
  local merge = session.merge
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local h = merge.hunks[merge.active]
  if vim.api.nvim_get_current_buf() == merge.buf then
    for i, candidate in ipairs(merge.hunks) do
      local first, last = range(merge, candidate)
      if row >= first and row <= math.max(first, last - 1) then
        h, merge.active = candidate, i
        break
      end
    end
  end
  local lines = contents(merge, h)
  if conflicts.has_markers(lines) then
    notify("Remove conflict markers before confirming a manual resolution.", vim.log.levels.WARN)
    return
  end
  h.choices = h.choices or {}
  merge.history[#merge.history + 1] = { confirmation = h, choices = vim.deepcopy(h.choices) }
  h.choices[#h.choices + 1] = { lines = lines, decision = "manual", eol = vim.bo[merge.buf].endofline }
  render()
end

function M.undo()
  if busy or not valid() or not session.merge then
    return
  end
  local merge = session.merge
  local history = table.remove(merge.history)
  if not history then
    vim.api.nvim_buf_call(merge.buf, function() vim.cmd("silent undo") end)
    render()
    return
  end
  if history.confirmation then
    history.confirmation.choices = history.choices
    render()
    return
  end
  -- Native undo preserves manual edits made since a decision. Never restore a
  -- full-buffer snapshot over those edits.
  local original = vim.api.nvim_buf_get_lines(merge.buf, 0, -1, false)
  vim.api.nvim_buf_call(merge.buf, function() vim.cmd("silent undo") end)
  local undone = vim.api.nvim_buf_get_lines(merge.buf, 0, -1, false)
  if equal(undone, history.lines) then
    for i, saved in ipairs(history.hunks) do
      local h = merge.hunks[i]
      vim.api.nvim_buf_set_extmark(merge.buf, anchors, saved.first, 0, {
        id = h.mark, end_row = saved.last, end_col = 0,
        right_gravity = false, end_right_gravity = true,
      })
    end
  elseif not equal(original, undone) then
    merge.history[#merge.history + 1] = history
  end
  render()
end

local function verify_resolved(entry)
  local _, present = git.entries(session.root)
  if present[entry.path] then
    error("Git still reports this file as unmerged.", 0)
  end
  entry.resolved = true
  entry.disk = git.read(path(entry))
end

function M.resolve()
  if not valid() or not session.merge then
    notify("Open a conflicted file first.", vim.log.levels.WARN)
    return
  end
  run(function()
    local merge = session.merge
    check_entry(merge.entry, true)
    update_states(merge)
    for _, h in ipairs(merge.hunks) do
      if h.state == "unresolved" then
        error("Resolve or manually confirm every conflict before staging.", 0)
      end
    end
    if conflicts.has_markers(vim.api.nvim_buf_get_lines(merge.buf, 0, -1, false)) then
      error("Conflict markers remain in the result.", 0)
    end
    local fix = vim.bo[merge.buf].fixendofline
    vim.bo[merge.buf].fixendofline = false
    local ok, err = pcall(vim.api.nvim_buf_call, merge.buf, function() vim.cmd("silent write") end)
    vim.bo[merge.buf].fixendofline = fix
    if not ok then
      error(err, 0)
    end
    merge.entry.disk = git.read(path(merge.entry))
    update_states(merge)
    for _, h in ipairs(merge.hunks) do
      if h.state == "unresolved" then
        error("A write hook changed a resolved conflict. Review and confirm it again.", 0)
      end
    end
    if conflicts.has_markers(vim.api.nvim_buf_get_lines(merge.buf, 0, -1, false)) then
      error("A write hook left conflict markers in the result.", 0)
    end
    git.call(session.root, { "add", "--", merge.entry.path })
    verify_resolved(merge.entry)
    show_files()
    notify("Resolved and staged: " .. ui.display_path(merge.entry.path))
  end)
end

function M.accept_file(entry, stage)
  run(function()
    check_entry(entry, true)
    if stage ~= 2 and stage ~= 3 then
      error("Expected left (2) or right (3).", 0)
    end
    local existing = vim.fn.bufnr(path(entry))
    if existing ~= -1 and vim.bo[existing].modified then
      error("This file has unsaved edits. Save them or use the merge editor.", 0)
    end
    if entry.stages[stage] then
      git.call(session.root, { "checkout", stage == 2 and "--ours" or "--theirs", "--", entry.path })
      entry.disk = git.read(path(entry))
      git.call(session.root, { "add", "--", entry.path })
    else
      git.call(session.root, { "rm", "-f", "--", entry.path })
    end
    verify_resolved(entry)
    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
      if entry.stages[stage] then
        vim.api.nvim_buf_call(existing, function() vim.cmd("silent checktime") end)
      else
        vim.api.nvim_buf_call(existing, function()
          vim.api.nvim_buf_set_lines(existing, 0, -1, false, { "" })
          vim.bo[existing].modified = false
        end)
      end
    end
    show_files()
  end)
end

function M.close()
  if busy then
    notify("Wait for the current Git operation to finish.", vim.log.levels.WARN)
    return
  end
  if valid() then
    cleanup_merge()
    local tab = session.tab
    session = nil
    vim.api.nvim_set_current_tabpage(tab)
    -- :hide preserves modified result buffers even with 'hidden' disabled.
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("hide tabclose")
    else
      local wins = vim.api.nvim_tabpage_list_wins(tab)
      for i = 2, #wins do
        vim.api.nvim_win_close(wins[i], true)
      end
      vim.cmd("hide enew")
    end
  end
end

-- Small introspection surface for integration tests and UI capture.
function M.status()
  return { busy = busy, error = last_error, session = session }
end

M.setup()
return M
