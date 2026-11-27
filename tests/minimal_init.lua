-- Minimal config for the test suite: this plugin plus plenary.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local plenary = vim.env.PLENARY_DIR
if not plenary or plenary == "" then
  for _, dir in ipairs({
    root .. "/.deps/plenary.nvim",
    vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  }) do
    if vim.fn.isdirectory(dir) == 1 then
      plenary = dir
      break
    end
  end
end
if plenary then
  vim.opt.runtimepath:append(plenary)
end
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/nbx.lua")
require("nbx").setup({ images = { enabled = false } })
