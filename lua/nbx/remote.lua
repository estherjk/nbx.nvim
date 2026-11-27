-- Lets the outside world (the `nbx` CLI, and through it Rex actions) drive the
-- notebook in a running Neovim.
--
-- Each Neovim with a notebook open records its server address in
-- $XDG_STATE_HOME/nbx/servers/<key>, where <key> is the Rex pane it runs in
-- (or its pid outside Rex). The CLI looks the address up and calls M.call.
local M = {}

local registered

local function dir()
  return (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/nbx/servers"
end

local function key()
  local block = vim.env.REX_BLOCK
  if block and block ~= "" then
    return (block:gsub("[^%w%-]", "_"))
  end
  return "pid-" .. vim.uv.os_getpid()
end

function M.register()
  local server = vim.v.servername
  if registered or not server or server == "" then
    return
  end
  vim.fn.mkdir(dir(), "p")
  local path = dir() .. "/" .. key()
  local f = io.open(path, "w")
  if f then
    -- Second line: this Neovim binary, so the CLI works without nvim on PATH.
    f:write(server .. "\n" .. vim.v.progpath .. "\n")
    f:close()
    registered = path
  end
end

function M.unregister()
  if registered then
    os.remove(registered)
    registered = nil
  end
end

--- Entry point for `nvim --server ADDR --remote-expr`.
---@param name string action name, or "status"
---@return string
function M.call(name)
  local nb = require("nbx.notebook")
  local buf = vim.api.nvim_get_current_buf()
  if not nb.states[buf] then
    buf = nb.last_buf
  end
  local st = buf and nb.states[buf]
  if not st then
    return "error: no notebook is open in this Neovim"
  end
  local file = vim.fn.fnamemodify(st.path, ":t")
  if name == "status" then
    return file .. " — " .. nb.status(buf)
  end
  -- Reply first, act afterwards: actions may prompt or take a while.
  local nbx = require("nbx")
  if not nbx.actions()[(name:gsub("-", "_"))] then
    return "error: unknown action: " .. name
  end
  vim.schedule(function()
    nbx.run(name, buf)
  end)
  return "ok: " .. name .. " (" .. file .. ")"
end

return M
