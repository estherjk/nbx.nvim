local M = {}

local initialized = false

---@param opts? nbx.Config
function M.setup(opts)
  require("nbx.config").setup(opts)
end

---@type {[1]: string, [2]: string, [3]: fun(st: table, arg?: string)}[]
local function action_list()
  local nb = require("nbx.notebook")
  return {
    { "run", "Run cell", nb.run_cell },
    { "run_cell", "Run cell", nb.run_cell },
    { "run_and_next", "Run cell and move to the next", nb.run_and_next },
    { "run_all", "Run all cells", nb.run_all },
    { "run_above", "Run cells above", nb.run_above },
    { "run_below", "Run this cell and those below", nb.run_below },
    {
      "add_below",
      "Add code cell below",
      function(st)
        nb.add_cell(st, "below", "code")
      end,
    },
    {
      "add_above",
      "Add code cell above",
      function(st)
        nb.add_cell(st, "above", "code")
      end,
    },
    {
      "add_markdown",
      "Add markdown cell below",
      function(st)
        nb.add_cell(st, "below", "markdown")
      end,
    },
    {
      "toggle_type",
      "Toggle cell between code and markdown",
      function(st, arg)
        nb.set_type(st, arg)
      end,
    },
    { "delete", "Delete cell", nb.delete_cell },
    {
      "move_down",
      "Move cell down",
      function(st)
        nb.move_cell(st, 1)
      end,
    },
    {
      "move_up",
      "Move cell up",
      function(st)
        nb.move_cell(st, -1)
      end,
    },
    { "split", "Split cell at cursor", nb.split_cell },
    { "merge", "Merge with cell below", nb.merge_cell },
    { "open_output", "Open full cell output", nb.open_output },
    { "clear", "Clear cell output", nb.clear },
    { "clear_all", "Clear all outputs", nb.clear_all },
    { "interrupt", "Interrupt kernel", nb.interrupt },
    {
      "restart",
      "Restart kernel",
      function(st)
        nb.restart(st)
      end,
    },
    { "restart_run_all", "Restart kernel and run all cells", nb.restart_and_run_all },
    { "shutdown", "Shut down kernel", nb.shutdown },
    { "kernel", "Select kernel", nb.select_kernel },
    { "log", "Show kernel log", nb.show_log },
    { "redraw", "Redraw outputs and images", nb.redraw },
    {
      "next_cell",
      "Next cell",
      function(st)
        nb.goto_cell(st, 1)
      end,
    },
    {
      "prev_cell",
      "Previous cell",
      function(st)
        nb.goto_cell(st, -1)
      end,
    },
    {
      "inner_cell",
      "Cell contents",
      function(st)
        nb.select_cell(st, false)
      end,
    },
    {
      "around_cell",
      "Cell",
      function(st)
        nb.select_cell(st, true)
      end,
    },
  }
end

local actions

---@return table<string, {desc: string, fn: function}>
function M.actions()
  if not actions then
    actions = {}
    for _, item in ipairs(action_list()) do
      actions[item[1]] = { desc = item[2], fn = item[3] }
    end
  end
  return actions
end

--- Run an action by name on a notebook buffer.
---@param name string
---@param buf? integer
---@param arg? string
---@return boolean ok, string? err
function M.run(name, buf, arg)
  local nb = require("nbx.notebook")
  name = name:gsub("-", "_")
  local action = M.actions()[name]
  if not action then
    return false, "unknown action: " .. name
  end
  local st = nb.get(buf)
  if not st then
    return false, "not a notebook buffer"
  end
  action.fn(st, arg)
  return true
end

--- Buffer-local keymaps (called for each notebook buffer).
function M.attach(buf)
  local keys = require("nbx.config").options.keys or {}
  for name, spec in pairs(keys) do
    local action = M.actions()[name]
    if spec and action then
      local lhs = type(spec) == "table" and spec[1] or spec
      local mode = type(spec) == "table" and spec.mode or "n"
      vim.keymap.set(mode, lhs, function()
        if vim.fn.mode() == "i" then
          vim.cmd.stopinsert()
        end
        M.run(name, buf)
      end, { buffer = buf, desc = action.desc, silent = true })
    end
  end
  local ok, wk = pcall(require, "which-key")
  if ok and wk.add then
    pcall(wk.add, { { "<localleader>r", group = "run", buffer = buf } })
  end
end

--- Kernel summary for a statusline; empty outside notebooks.
function M.status()
  return require("nbx.notebook").status()
end

function M.is_notebook(buf)
  return require("nbx.notebook").get(buf) ~= nil
end

--- One-time setup shared by all notebooks; runs when the first one is opened.
function M.init()
  if initialized then
    return
  end
  initialized = true
  math.randomseed(vim.uv.hrtime() % 0x7fffffff)
  local render = require("nbx.render")
  render.setup_hl()
  local group = vim.api.nvim_create_augroup("nbx.global", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      require("nbx.ansi").reset()
      render.setup_hl()
      local nb = require("nbx.notebook")
      for _, st in pairs(nb.states) do
        nb.redraw(st)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      require("nbx.image").reset_cell_size()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      local nb = require("nbx.notebook")
      for buf in pairs(nb.states) do
        nb.close(buf)
      end
      require("nbx.remote").unregister()
    end,
  })
  require("nbx.remote").register()
end

return M
