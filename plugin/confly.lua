if vim.g.loaded_confly then
  return
end
vim.g.loaded_confly = true

for name, method in pairs({
  Confly = "open",
  ConflyFiles = "files",
  ConflyResolve = "resolve",
  ConflyClose = "close",
}) do
  vim.api.nvim_create_user_command(name, function()
    require("confly")[method]()
  end, { desc = "Confly: " .. method })
end
