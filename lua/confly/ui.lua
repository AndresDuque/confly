local M = {}
M.ns = vim.api.nvim_create_namespace("confly")

function M.highlights()
  local groups = {
    ConflyTitle = { fg = "#82aaff", bold = true },
    ConflyMuted = { fg = "#8994b0" },
    ConflyConflict = { bg = "#332d40" },
    ConflyActive = { bg = "#414568", bold = true },
    ConflyResolved = { fg = "#9ece6a" },
    ConflyPending = { fg = "#e0af68" },
    ConflyLeft = { fg = "#7dcfff", bold = true },
    ConflyRight = { fg = "#bb9af7", bold = true },
  }
  for name, value in pairs(groups) do
    value.default = true
    vim.api.nvim_set_hl(0, name, value)
  end
end

function M.scratch(name, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "confly://" .. name .. "/" .. buf)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buf].modifiable = false
  return buf
end

function M.window(win, title, group)
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldenable = false
  vim.wo[win].cursorline = true
  vim.wo[win].winbar = "%#" .. (group or "ConflyTitle") .. "# " .. title:gsub("%%", "%%%%")
  vim.wo[win].statusline = " %f %m%=%l:%c "
end

function M.map(buf, key, fn, desc)
  if key and key ~= "" and key ~= false then
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true, desc = "Confly: " .. desc })
  end
end

function M.one_window(session)
  vim.api.nvim_set_current_tabpage(session.tab)
  local wins = vim.api.nvim_tabpage_list_wins(session.tab)
  local keep = wins[1]
  for i = 2, #wins do
    vim.api.nvim_win_close(wins[i], true)
  end
  vim.api.nvim_set_current_win(keep)
  return keep
end

function M.display_path(path)
  return path:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

function M.files(session, callbacks, config)
  local win = M.one_window(session)
  session.merge = nil
  local lines = {
    "",
    "  C O N F L Y",
    "  Resolve with confidence.",
    "",
    "  " .. M.display_path(vim.fs.basename(session.root)) .. "  ·  " .. session.context.operation,
    "",
    "  CONFLICTED FILES",
    "",
  }
  local row_map, pending, solved = {}, 0, 0
  for _, entry in ipairs(session.entries) do
    local icon = entry.resolved and (config.icons and "✓" or "[ok]") or (config.icons and "●" or "[!]")
    local kind = not entry.stages[2] and "deleted on left"
      or not entry.stages[3] and "deleted on right"
      or not entry.stages[1] and "added on both" or "content"
    if entry.resolved then
      solved = solved + 1
    else
      pending = pending + 1
    end
    lines[#lines + 1] = "  " .. icon .. "  " .. M.display_path(entry.path) .. "    " .. (entry.resolved and "resolved · staged" or kind)
    row_map[#lines] = entry
  end
  if #session.entries == 0 then
    lines[#lines + 1] = "  No conflicted files. You're all clear."
  end
  vim.list_extend(lines, {
    "",
    string.format("  %d unresolved   ·   %d resolved", pending, solved),
    "",
    "  Enter  open merge editor",
    "  l / r  accept entire left / right file and stage",
    "  j / k  select file     R  refresh     q  close",
  })
  local buf = M.scratch("files", lines)
  session.file_buf = buf
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].filetype = "confly"
  M.window(win, "confly / files")
  vim.wo[win].number = false
  for row, entry in pairs(row_map) do
    vim.api.nvim_buf_add_highlight(buf, M.ns, entry.resolved and "ConflyResolved" or "ConflyPending", row - 1, 0, -1)
  end
  vim.api.nvim_buf_add_highlight(buf, M.ns, "ConflyTitle", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, M.ns, "ConflyMuted", 4, 0, -1)
  local function selected()
    return row_map[vim.api.nvim_win_get_cursor(win)[1]]
  end
  local function move(delta)
    if #session.entries > 0 then
      local row = vim.api.nvim_win_get_cursor(win)[1]
      vim.api.nvim_win_set_cursor(win, { math.max(9, math.min(8 + #session.entries, row + delta)), 0 })
    end
  end
  for key, delta in pairs({ j = 1, k = -1 }) do
    M.map(buf, config.keys[key], function() move(delta) end, "select file")
  end
  M.map(buf, config.keys.open, function() callbacks.open(selected()) end, "open file")
  M.map(buf, config.keys.left, function() callbacks.accept(selected(), 2) end, "accept left file")
  M.map(buf, config.keys.right, function() callbacks.accept(selected(), 3) end, "accept right file")
  M.map(buf, config.keys.refresh, callbacks.refresh, "refresh")
  M.map(buf, config.keys.close, callbacks.close, "close")
  if #session.entries > 0 then
    vim.api.nvim_win_set_cursor(win, { 9, 0 })
  end
end

function M.merge(session, merge, callbacks, config)
  local left_win = M.one_window(session)
  local left = M.scratch("left", merge.left)
  vim.api.nvim_win_set_buf(left_win, left)
  vim.cmd("rightbelow vsplit")
  local result_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(result_win, merge.buf)
  vim.cmd("rightbelow vsplit")
  local right_win = vim.api.nvim_get_current_win()
  local right = M.scratch("right", merge.right)
  vim.api.nvim_win_set_buf(right_win, right)
  merge.wins = { left_win, result_win, right_win }
  merge.bufs = { left, merge.buf, right }
  vim.bo[left].filetype = vim.bo[merge.buf].filetype
  vim.bo[right].filetype = vim.bo[merge.buf].filetype
  M.window(left_win, "1  " .. session.context.left, "ConflyLeft")
  M.window(result_win, "2  Result · " .. M.display_path(merge.entry.path))
  M.window(right_win, "3  " .. session.context.right, "ConflyRight")
  vim.cmd("wincmd =")
  for index, buf in ipairs(merge.bufs) do
    for target = 1, 3 do
      local focus = function()
        if vim.api.nvim_win_is_valid(merge.wins[target]) then
          vim.api.nvim_set_current_win(merge.wins[target])
        end
      end
      -- Some terminal protocols cannot encode Ctrl+number.
      if config.ctrl_numbers then
        pcall(M.map, buf, "<C-" .. target .. ">", focus, "focus pane " .. target)
      end
      M.map(buf, config.keys["pane" .. target], focus, "focus pane " .. target)
    end
    M.map(buf, config.keys.next, function() callbacks.move(1) end, "next conflict")
    M.map(buf, config.keys.prev, function() callbacks.move(-1) end, "previous conflict")
    M.map(buf, config.keys.files, callbacks.files, "files")
    M.map(buf, config.keys.resolve, callbacks.resolve, "save and stage")
    M.map(buf, config.keys.undo, callbacks.undo, "undo decision")
    if index ~= 2 then
      local side = index == 1 and "left" or "right"
      M.map(buf, config.keys.j, function() callbacks.move(1) end, "next conflict")
      M.map(buf, config.keys.k, function() callbacks.move(-1) end, "previous conflict")
      M.map(buf, config.keys.accept, function() callbacks.choose(side) end, "accept side")
      M.map(buf, config.keys.discard, function() callbacks.choose(side == "left" and "right" or "left") end, "use opposite side")
      M.map(buf, config.keys.both, function() callbacks.choose("both") end, "include both")
      M.map(buf, config.keys.source_undo, callbacks.undo, "undo decision")
    else
      M.map(buf, config.keys.confirm, callbacks.confirm, "confirm manual conflict")
    end
  end
  vim.api.nvim_set_current_win(left_win)
end

return M
