-- Inline images over the kitty graphics protocol, using unicode placeholders
-- so that an image can live inside virtual lines and scroll with the buffer.
-- https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders
local config = require("nbx.config")

local M = {}

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)
-- Row/column diacritics from the protocol specification.
local DIACRITICS = vim.split(
  "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1",
  ","
)
local MAX_CELLS = #DIACRITICS

local diacritic = setmetatable({}, {
  __index = function(t, i)
    t[i] = vim.fn.nr2char(tonumber(DIACRITICS[i], 16))
    return t[i]
  end,
})

-- Ids are carried in a 24-bit foreground colour. Start high to stay clear of
-- other plugins that count up from one.
local next_id = 0x6e0000 + (vim.uv.os_getpid() % 0x4000) * 4
local cache = setmetatable({}, { __mode = "k" })
local cell_size

local function write(data)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
  else
    io.stdout:write(data)
  end
end

---@return boolean
function M.supported()
  local enabled = config.options.images.enabled
  if enabled == true or enabled == false then
    return enabled
  end
  if #vim.api.nvim_list_uis() == 0 or vim.env.TMUX or vim.env.SSH_CONNECTION then
    return false
  end
  local program = (vim.env.TERM_PROGRAM or ""):lower()
  local term = (vim.env.TERM or ""):lower()
  return program == "rex"
    or program == "ghostty"
    or program == "kitty"
    or vim.env.KITTY_WINDOW_ID ~= nil
    or term:find("kitty", 1, true) ~= nil
    or term:find("ghostty", 1, true) ~= nil
    or term:find("rex", 1, true) ~= nil
end

--- Pixel size of one terminal cell.
---@return number width, number height
function M.cell_size()
  if cell_size then
    return cell_size[1], cell_size[2]
  end
  cell_size = { 9, 18 }
  pcall(function()
    local ffi = require("ffi")
    pcall(
      ffi.cdef,
      [[
      typedef struct { unsigned short row, col, xpixel, ypixel; } nbx_winsize;
      int ioctl(int, unsigned long, ...);
    ]]
    )
    local request = vim.fn.has("linux") == 1 and 0x5413 or 0x40087468
    local size = ffi.new("nbx_winsize")
    for fd = 0, 2 do
      if ffi.C.ioctl(fd, request, size) == 0 and size.col > 0 and size.xpixel > 0 then
        cell_size = { size.xpixel / size.col, size.ypixel / size.row }
        return
      end
    end
  end)
  return cell_size[1], cell_size[2]
end

function M.reset_cell_size()
  cell_size = nil
end

local function png_size(b64)
  local ok, head = pcall(vim.base64.decode, b64:sub(1, 32))
  if not ok or #head < 24 or head:sub(2, 4) ~= "PNG" then
    return nil
  end
  local function u32(offset)
    local a, b, c, d = head:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

--- Convert anything ImageMagick understands into base64 PNG.
local function to_png(bytes, ext)
  local magick = vim.fn.executable("magick") == 1 and "magick" or (vim.fn.executable("convert") == 1 and "convert")
  if not magick then
    return nil
  end
  local src = vim.fn.tempname() .. "." .. ext
  local f = io.open(src, "wb")
  if not f then
    return nil
  end
  f:write(bytes)
  f:close()
  local result = vim.system({ magick, src, "png:-" }, { text = false }):wait(10000)
  os.remove(src)
  if result.code ~= 0 or not result.stdout or result.stdout == "" then
    return nil
  end
  return vim.base64.encode(result.stdout)
end

local function fit(width, height, max_cols)
  local cw, ch = M.cell_size()
  -- Treat an image pixel as one point on a hi-dpi display, like snacks.image.
  local scale = math.max(1, cw / 8)
  local cols = math.ceil(width * scale / cw)
  local opts = config.options.images
  local limit = math.max(4, math.min(opts.max_width, max_cols or opts.max_width, MAX_CELLS))
  cols = math.max(1, math.min(cols, limit))
  local rows = math.max(1, math.ceil(cols * cw * height / width / ch))
  local max_rows = math.min(opts.max_height, MAX_CELLS)
  if rows > max_rows then
    rows = max_rows
    cols = math.max(1, math.floor(rows * ch * width / height / cw))
  end
  return cols, rows
end

local function transmit(image)
  local data = image.png
  local first = true
  local pos = 1
  while pos <= #data do
    local chunk = data:sub(pos, pos + 4095)
    pos = pos + 4096
    local more = pos <= #data and 1 or 0
    if first then
      write(
        ("\27_Ga=T,U=1,q=2,f=100,t=d,i=%d,c=%d,r=%d,m=%d;%s\27\\"):format(image.id, image.cols, image.rows, more, chunk)
      )
      first = false
    else
      write(("\27_Gm=%d;%s\27\\"):format(more, chunk))
    end
  end
end

--- Find the best image in a mime bundle.
---@param data table<string, any>
---@return string? mime
function M.pick(data)
  for _, mime in ipairs({ "image/png", "image/jpeg", "image/gif", "image/svg+xml" }) do
    if data[mime] ~= nil then
      return mime
    end
  end
end

--- Prepare an image for display and send it to the terminal.
---@param key table table that owns the image; the result is cached on it
---@param mime string
---@param value string|string[]
---@param max_cols? integer
---@return {id: integer, cols: integer, rows: integer, hl: string}?
function M.get(key, mime, value, max_cols)
  local cached = cache[key]
  if cached ~= nil then
    return cached or nil
  end
  cache[key] = false
  local text = type(value) == "table" and table.concat(value) or value
  local png
  if mime == "image/png" then
    png = text:gsub("%s+", "")
  elseif mime == "image/svg+xml" then
    png = to_png(text, "svg")
  else
    local ok, bytes = pcall(vim.base64.decode, (text:gsub("%s+", "")))
    png = ok and to_png(bytes, mime == "image/gif" and "gif[0]" or "jpg") or nil
  end
  if not png then
    return nil
  end
  local width, height = png_size(png)
  if not width or width == 0 or height == 0 then
    return nil
  end
  local cols, rows = fit(width, height, max_cols)
  next_id = next_id + 1
  local image = { id = next_id, cols = cols, rows = rows, png = png, hl = "NbxImage" .. next_id }
  vim.api.nvim_set_hl(0, image.hl, { fg = image.id, nocombine = true })
  transmit(image)
  cache[key] = image
  return image
end

--- Virtual-text chunks, one per row of the image.
---@param image table
---@return string[] rows
function M.rows(image)
  local rows = {}
  for r = 1, image.rows do
    local cells = {}
    for c = 1, image.cols do
      cells[c] = PLACEHOLDER .. diacritic[r] .. diacritic[c]
    end
    rows[r] = table.concat(cells)
  end
  return rows
end

--- Free the terminal's copy of an image.
---@param key table
function M.free(key)
  local image = cache[key]
  if image then
    write(("\27_Ga=d,d=I,q=2,i=%d\27\\"):format(image.id))
  end
  cache[key] = nil
end

--- Send every live image again, for when the terminal has lost them.
function M.retransmit()
  for _, image in pairs(cache) do
    if image then
      vim.api.nvim_set_hl(0, image.hl, { fg = image.id, nocombine = true })
      transmit(image)
    end
  end
end

return M
