-- Rex actions for nbx.nvim.
--
-- Adds notebook commands (restart kernel, interrupt, run all, ...) to Rex's
-- command palette and lets you bind keys to them. Each action talks to the
-- Neovim running in the focused pane through the `nbx` CLI.
--
-- In ~/.config/rex/init.lua:
--
--   local nbx = dofile(os.getenv("HOME") .. "/.local/share/nvim/lazy/nbx.nvim/rex/nbx.lua")
--   nbx.setup{
--     keys = {
--       ["ctrl+alt+r"] = "restart",
--       ["ctrl+alt+i"] = "interrupt",
--     },
--   }
--
-- Then run `rex config reload`.
local M = {}

local here = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]*$")

M.actions = {
  { "restart", "Restart Kernel" },
  { "restart_run_all", "Restart Kernel and Run All Cells" },
  { "interrupt", "Interrupt Kernel" },
  { "run_all", "Run All Cells" },
  { "run", "Run Cell" },
  { "clear_all", "Clear All Outputs" },
  { "kernel", "Select Kernel…" },
  { "log", "Show Kernel Log" },
  { "shutdown", "Shut Down Kernel" },
  { "status", "Kernel Status" },
}

---@param opts? { bin?: string, keys?: table<string, string>, path?: string }
---  bin   path to the `nbx` script (default: ../bin/nbx next to this file)
---  keys  map of Rex key -> action name, e.g. { ["ctrl+alt+r"] = "restart" }
---  path  PATH used to find `nvim`, if Rex's own environment lacks it
function M.setup(opts)
  opts = opts or {}
  local bin = opts.bin or (here and (here .. "/../bin/nbx")) or "nbx"
  local known = {}

  for _, spec in ipairs(M.actions) do
    local name, title = spec[1], spec[2]
    known[name] = true
    rex.action({
      name = "nbx_" .. name,
      title = "Notebook: " .. title,
      category = "Notebook",
      keywords = "jupyter nbx kernel ipynb",
      run = function(ctx)
        local argv = { bin, name }
        if ctx.block_id then
          argv[#argv + 1] = "--block"
          argv[#argv + 1] = ctx.block_id
        end
        local r, err = rex.exec(argv, { timeout = 10, env = opts.path and { PATH = opts.path } or nil })
        if r == nil then
          error(err, 0)
        end
        local out = ((r.ok and r.stdout or r.stderr) or ""):gsub("%s+$", "")
        if not r.ok then
          error(out ~= "" and out or "nbx failed", 0)
        end
        return out
      end,
    })
  end

  for key, name in pairs(opts.keys or {}) do
    name = name:gsub("-", "_")
    if not known[name] then
      error("nbx: unknown action in keys: " .. name, 0)
    end
    rex.bind(key, "nbx_" .. name)
  end
end

return M
