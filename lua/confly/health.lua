local M = {}

function M.check()
  vim.health.start("confly")
  if vim.fn.has("nvim-0.10.4") == 1 then
    vim.health.ok("Neovim 0.10.4+")
  else
    vim.health.error("Neovim 0.10.4 or newer is required")
  end
  if vim.fn.executable("git") == 1 then
    vim.health.ok("Git is on PATH")
  else
    vim.health.error("Install Git and add it to PATH")
  end
  vim.health.info("Ctrl+number depends on your terminal. Use <leader>c1/c2/c3 as fallbacks.")
end

return M
