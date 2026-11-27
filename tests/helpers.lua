local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
M.fixture = M.root .. "/tests/fixtures/sample.ipynb"

function M.read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

--- Copy the fixture somewhere writable and open it.
---@return string path, table state
function M.open(source)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/nb.ipynb"
  local f = assert(io.open(path, "wb"))
  f:write(M.read(source or M.fixture))
  f:close()
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  return path, require("nbx.notebook").get()
end

function M.lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

function M.close()
  vim.cmd("silent! bwipeout!")
end

--- Decode a notebook from disk.
function M.load(path)
  return vim.json.decode(M.read(path))
end

return M
