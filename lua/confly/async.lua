local M = {}

-- Git subprocesses yield; UI rendering and buffer mutations run on the main loop.
function M.run(fn, done)
  local thread = coroutine.create(fn)
  local function resume(...)
    local ok, value = coroutine.resume(thread, ...)
    if not ok then
      done(false, debug.traceback(thread, tostring(value)))
    elseif coroutine.status(thread) == "dead" then
      done(true, value)
    else
      value(resume)
    end
  end
  resume()
end

function M.system(argv, opts)
  return coroutine.yield(function(resume)
    local ok, err = pcall(vim.system, argv, opts, function(result)
      vim.schedule(function()
        resume(result)
      end)
    end)
    if not ok then
      vim.schedule(function()
        resume({ code = -1, stderr = tostring(err), stdout = "" })
      end)
    end
  end)
end

return M
