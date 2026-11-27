-- Turns text with ANSI colour codes into virtual-text chunks.
local M = {}

local BASE = {
  [0] = "#45475a",
  "#f38ba8",
  "#a6e3a1",
  "#f9e2af",
  "#89b4fa",
  "#f5c2e7",
  "#94e2d5",
  "#bac2de",
  "#585b70",
  "#f38ba8",
  "#a6e3a1",
  "#f9e2af",
  "#89b4fa",
  "#f5c2e7",
  "#94e2d5",
  "#a6adc8",
}

local groups = {}

local function color(n)
  if n < 16 then
    return vim.g["terminal_color_" .. n] or BASE[n]
  elseif n < 232 then
    n = n - 16
    local function level(v)
      return v == 0 and 0 or 55 + v * 40
    end
    return string.format("#%02x%02x%02x", level(math.floor(n / 36)), level(math.floor(n / 6) % 6), level(n % 6))
  end
  local v = 8 + (n - 232) * 10
  return string.format("#%02x%02x%02x", v, v, v)
end

local function group(style)
  local key = table.concat({
    style.fg or "",
    style.bg or "",
    style.bold and "b" or "",
    style.italic and "i" or "",
    style.underline and "u" or "",
  }, "|")
  if key == "||||" then
    return nil
  end
  local name = groups[key]
  if not name then
    name = "NbxAnsi" .. (vim.tbl_count(groups) + 1)
    groups[key] = name
    vim.api.nvim_set_hl(0, name, {
      fg = style.fg,
      bg = style.bg,
      bold = style.bold,
      italic = style.italic,
      underline = style.underline,
    })
  end
  return name
end

--- Forget generated groups, e.g. after a colorscheme change wiped them.
function M.reset()
  groups = {}
end

local function apply(style, params)
  local codes = {}
  for code in (params .. ";"):gmatch("([^;]*);") do
    codes[#codes + 1] = tonumber(code) or 0
  end
  local i = 1
  while i <= #codes do
    local c = codes[i]
    if c == 0 then
      for k in pairs(style) do
        style[k] = nil
      end
    elseif c == 1 then
      style.bold = true
    elseif c == 3 then
      style.italic = true
    elseif c == 4 then
      style.underline = true
    elseif c == 22 then
      style.bold = nil
    elseif c == 23 then
      style.italic = nil
    elseif c == 24 then
      style.underline = nil
    elseif c >= 30 and c <= 37 then
      style.fg = color(c - 30)
    elseif c >= 90 and c <= 97 then
      style.fg = color(c - 90 + 8)
    elseif c == 39 then
      style.fg = nil
    elseif c >= 40 and c <= 47 then
      style.bg = color(c - 40)
    elseif c >= 100 and c <= 107 then
      style.bg = color(c - 100 + 8)
    elseif c == 49 then
      style.bg = nil
    elseif c == 38 or c == 48 then
      local key = c == 38 and "fg" or "bg"
      if codes[i + 1] == 5 and codes[i + 2] then
        style[key] = color(math.min(codes[i + 2], 255))
        i = i + 2
      elseif codes[i + 1] == 2 and codes[i + 4] then
        style[key] = string.format("#%02x%02x%02x", codes[i + 2] % 256, codes[i + 3] % 256, codes[i + 4] % 256)
        i = i + 4
      end
    end
    i = i + 1
  end
end

---@class nbx.AnsiParser
---@field style table
---@field default string
local Parser = {}
Parser.__index = Parser

--- A parser keeps its colour state from one line to the next.
---@param default_hl string highlight for uncoloured text
function M.new(default_hl)
  return setmetatable({ style = {}, default = default_hl }, Parser)
end

---@param line string
---@return table[] chunks
function Parser:feed(line)
  local chunks = {}
  local pos = 1
  local function push(text)
    if text == "" then
      return
    end
    local name = group(self.style)
    chunks[#chunks + 1] = { text, name and { self.default, name } or self.default }
  end
  while pos <= #line do
    local s, e, params, final = line:find("\27%[([%d;:?]*)([@-~])", pos)
    local os_, oe = line:find("\27%][^\7\27]*[\7]?\27?\\?", pos)
    if os_ and (not s or os_ < s) then
      push(line:sub(pos, os_ - 1))
      pos = oe + 1
    elseif s then
      push(line:sub(pos, s - 1))
      if final == "m" then
        apply(self.style, params)
      end
      pos = e + 1
    else
      push(line:sub(pos))
      break
    end
  end
  return chunks
end

--- Remove escape sequences.
---@param text string
function M.strip(text)
  return (text:gsub("\27%[[%d;:?]*[@-~]", ""):gsub("\27%][^\7\27]*[\7]?\27?\\?", ""))
end

--- Resolve carriage returns the way a terminal would: text after a "\r"
--- overwrites the start of the line. Good enough for progress bars.
---@param text string
---@return string[] lines
function M.lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    if line:find("\r", 1, true) then
      line = line:gsub("\r+$", "")
      local last = line:match(".*\r(.*)$")
      lines[i] = last or line
    end
    if lines[i]:find("\8", 1, true) then
      lines[i] = lines[i]:gsub("\8", "")
    end
  end
  return lines
end

return M
