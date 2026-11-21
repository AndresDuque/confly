local M = {}

function M.lines(data)
  if not data or data == "" then
    return {}
  end
  data = data:gsub("\r\n", "\n")
  if data:sub(-1) == "\n" then
    data = data:sub(1, -2)
  end
  return vim.split(data, "\n", { plain = true })
end

local function marker(line, char, width)
  local run = line:match("^(" .. char .. "+)")
  return run and #run == width and (#line == width or line:sub(width + 1, width + 1) == " ")
end

-- Half-open, zero-based ranges throughout, matching the Neovim buffer API.
function M.parse(lines)
  local hunks, left, right = {}, {}, {}
  local i = 1
  while i <= #lines do
    local run = lines[i]:match("^(<+)")
    if run and #run >= 7 and marker(lines[i], "<", #run) then
      local h = { start = i - 1, left = {}, right = {}, base = {}, state = "unresolved" }
      local width, phase = #run, "left"
      h.left_start, h.right_start = #left, #right
      i = i + 1
      local closed = false
      while i <= #lines do
        local line = lines[i]
        if phase == "left" and marker(line, "|", width) then
          phase = "base"
        elseif (phase == "left" or phase == "base") and line == string.rep("=", width) then
          phase = "right"
        elseif phase == "right" and marker(line, ">", width) then
          closed = true
          h.finish = i
          break
        elseif marker(line, "<", width) then
          return nil, "Nested conflict markers; resolve or repair this region manually."
        else
          h[phase][#h[phase] + 1] = line
        end
        i = i + 1
      end
      if not closed then
        return nil, "Incomplete conflict markers; resolve or repair this region manually."
      end
      vim.list_extend(left, h.left)
      vim.list_extend(right, h.right)
      h.left_end, h.right_end = #left, #right
      hunks[#hunks + 1] = h
    else
      left[#left + 1], right[#right + 1] = lines[i], lines[i]
    end
    i = i + 1
  end
  return hunks, { left = left, right = right }
end

function M.has_markers(lines)
  for _, line in ipairs(lines) do
    if line:match("^<<<<<<<") or line:match("^>>>>>>>") or line:match("^|||||||") or line:match("^=======$") then
      return true
    end
  end
  return false
end

-- Map a reconstructed side to its full index blob via ordered diff ranges.
-- Unlike substring matching, this works with repeated identical conflict text.
function M.align(hunks, projection, source, side)
  local function text(lines)
    return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
  end
  local diffs = vim.diff(text(projection), text(source), { result_type = "indices", algorithm = "histogram" })
  local function boundary(pos, ending)
    local delta = 0
    for _, diff in ipairs(diffs) do
      local a, an, b, bn = unpack(diff)
      local a0, b0 = a - (an > 0 and 1 or 0), b - (bn > 0 and 1 or 0)
      if pos < a0 or (pos == a0 and not ending) then
        break
      end
      if pos < a0 + an then
        return ending and (b0 + bn) or b0
      end
      delta = b0 + bn - a0 - an
    end
    return math.max(0, math.min(#source, pos + delta))
  end
  for _, h in ipairs(hunks) do
    h[side .. "_range"] = {
      boundary(h[side .. "_start"], false),
      boundary(h[side .. "_end"], true),
    }
  end
end

return M
