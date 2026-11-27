-- Everything drawn on top of the buffer: cell borders, markdown styling and
-- cell outputs (as virtual lines below each code cell).
local ansi = require("nbx.ansi")
local config = require("nbx.config")
local image = require("nbx.image")
local ipynb = require("nbx.ipynb")

local api = vim.api
local M = {}

M.ns_ui = api.nvim_create_namespace("nbx.ui")
M.ns_out = api.nvim_create_namespace("nbx.out")

local RULE = string.rep("─", 400)
local has_overflow = vim.fn.has("nvim-0.11") == 1

function M.setup_hl()
  local function def(name, opts)
    opts.default = true
    api.nvim_set_hl(0, name, opts)
  end
  def("NbxCellBorder", { link = "LineNr" })
  def("NbxCellLabel", { link = "Special" })
  def("NbxCellType", { link = "Comment" })
  def("NbxRunning", { link = "DiagnosticWarn" })
  def("NbxQueued", { link = "DiagnosticInfo" })
  def("NbxOk", { link = "DiagnosticOk" })
  def("NbxError", { link = "DiagnosticError" })
  def("NbxOutput", { link = "Normal" })
  def("NbxStderr", { link = "WarningMsg" })
  def("NbxOutputBorder", { link = "NonText" })
  def("NbxOutputMore", { link = "Comment" })
  for level = 1, 6 do
    def("NbxMdH" .. level, { link = "@markup.heading." .. level .. ".markdown" })
  end
  def("NbxMdBold", { bold = true })
  def("NbxMdItalic", { italic = true })
  def("NbxMdCode", { link = "@markup.raw.markdown_inline" })
  def("NbxMdFence", { link = "@markup.raw.block.markdown" })
  def("NbxMdLink", { link = "@markup.link.url" })
  def("NbxMdBullet", { link = "@markup.list" })
  def("NbxMdQuote", { link = "@markup.quote" })
  -- Markdown text sits in Python comments; paint it like ordinary text.
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  api.nvim_set_hl(0, "NbxMarkdown", { fg = normal.fg, nocombine = true, default = true })
end

-- Cell chrome ----------------------------------------------------------------

local function format_duration(seconds)
  if seconds < 1 then
    return ("%dms"):format(math.floor(seconds * 1000 + 0.5))
  elseif seconds < 60 then
    return ("%.1fs"):format(seconds)
  end
  return ("%dm %ds"):format(math.floor(seconds / 60), math.floor(seconds % 60))
end

local function border(cell)
  local state = cell.state
  local chunks = { { "── ", "NbxCellBorder" } }
  if cell.type ~= "code" then
    chunks[#chunks + 1] = { cell.type, "NbxCellType" }
  else
    local count = state.execution_count
    local label = type(count) == "number" and tostring(count) or " "
    if state.status == "running" then
      label = "*"
    end
    chunks[#chunks + 1] = { "[" .. label .. "]", "NbxCellLabel" }
    if state.status == "running" then
      chunks[#chunks + 1] = { " ● running", "NbxRunning" }
    elseif state.status == "queued" then
      chunks[#chunks + 1] = { " ◌ queued", "NbxQueued" }
    elseif state.result == "ok" then
      local took = state.duration and (" " .. format_duration(state.duration)) or ""
      chunks[#chunks + 1] = { " ✓" .. took, "NbxOk" }
    elseif state.result == "error" then
      chunks[#chunks + 1] = { " ✗ error", "NbxError" }
    elseif state.result == "aborted" then
      chunks[#chunks + 1] = { " ◌ skipped", "NbxQueued" }
    end
  end
  chunks[#chunks + 1] = { " " .. RULE, "NbxCellBorder" }
  return chunks
end

local function mark(buf, row, col, opts)
  opts.strict = false
  pcall(api.nvim_buf_set_extmark, buf, M.ns_ui, row, col, opts)
end

local INLINE = {
  { "()`[^`]+`()", "NbxMdCode" },
  { "()%*%*[^*]+%*%*()", "NbxMdBold" },
  { "()__[^_]+__()", "NbxMdBold" },
  { "()%[[^%]]+%]%([^)]+%)()", "NbxMdLink" },
}

local function markdown_line(buf, row, line, ctx, styled)
  local prefix = (line:sub(1, 2) == "# " and 2) or (line == "#" and 1) or 0
  if prefix > 0 then
    mark(buf, row, 0, { end_col = prefix, conceal = "" })
  end
  if #line > prefix then
    mark(buf, row, prefix, { end_col = #line, hl_group = "NbxMarkdown", priority = 150 })
  end
  if not styled then
    return
  end
  local text = line:sub(prefix + 1)
  local function hl(s, e, group)
    mark(buf, row, prefix + s - 1, { end_col = prefix + e - 1, hl_group = group, priority = 160 })
  end
  if text:find("^%s*```") or text:find("^%s*~~~") then
    ctx.fence = not ctx.fence
    hl(1, #text + 1, "NbxMdFence")
    return
  end
  if ctx.fence then
    hl(1, #text + 1, "NbxMdFence")
    return
  end
  local hashes = text:match("^(#+)%s")
  if hashes and #hashes <= 6 then
    hl(1, #text + 1, "NbxMdH" .. #hashes)
    return
  end
  if text:find("^%s*>") then
    hl(1, #text + 1, "NbxMdQuote")
  end
  local bs, be = text:find("^%s*[-*+]%s")
  if not bs then
    bs, be = text:find("^%s*%d+[.)]%s")
  end
  if bs then
    hl(bs, be, "NbxMdBullet")
  end
  for _, rule in ipairs(INLINE) do
    for s, e in text:gmatch(rule[1]) do
      hl(s, e, rule[2])
    end
  end
  for s, e in text:gmatch("()%*[^*%s][^*]-%*()") do
    if text:sub(s - 1, s - 1) ~= "*" and text:sub(e, e) ~= "*" then
      hl(s, e, "NbxMdItalic")
    end
  end
end

--- Redraw cell borders and markdown styling.
function M.decorate(st)
  local buf = st.buf
  api.nvim_buf_clear_namespace(buf, M.ns_ui, 0, -1)
  for _, cell in ipairs(st.layout) do
    if cell.start >= 0 then
      mark(buf, cell.start, 0, {
        virt_text = border(cell),
        virt_text_pos = "overlay",
        hl_mode = "combine",
        priority = 200,
      })
    end
    if cell.type ~= "code" then
      local ctx = {}
      for row = cell.start + 1, cell.stop do
        markdown_line(buf, row, st.lines[row + 1], ctx, cell.type == "markdown")
      end
    end
  end
end

-- Outputs --------------------------------------------------------------------

local PAD = { "│ ", "NbxOutputBorder" }

local function strip_html(html)
  local text = html:gsub("<style.->.-</style>", ""):gsub("<script.->.-</script>", ""):gsub("<br%s*/?>", "\n")
  text = text:gsub("</t[dh]>", "\t"):gsub("</tr>", "\n"):gsub("</p>", "\n"):gsub("<[^>]+>", "")
  text = text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&nbsp;", " "):gsub("&amp;", "&")
  return (text:gsub("\n%s*\n+", "\n"))
end

--- The text to show for a mime bundle that has no usable image.
local function bundle_text(data)
  for _, mime in ipairs({ "text/plain", "text/markdown", "text/latex" }) do
    if data[mime] ~= nil then
      return ipynb.text(data[mime])
    end
  end
  if data["text/html"] ~= nil then
    return strip_html(ipynb.text(data["text/html"]))
  end
  if data["application/json"] ~= nil then
    return vim.inspect(data["application/json"])
  end
  local mimes = vim.tbl_keys(data)
  table.sort(mimes)
  return #mimes > 0 and ("[" .. table.concat(mimes, ", ") .. "]") or ""
end

--- Walk the outputs of a cell, calling back for each block of text or image.
---@param state table
---@param on_text fun(text: string, hl: string)
---@param on_image fun(output: table, mime: string, data: table): boolean?
local function each_output(state, on_text, on_image)
  for _, output in ipairs(state.outputs or {}) do
    local kind = output.output_type
    if kind == "stream" then
      on_text(ipynb.text(output.text), output.name == "stderr" and "NbxStderr" or "NbxOutput")
    elseif kind == "error" then
      local trace = type(output.traceback) == "table" and table.concat(output.traceback, "\n") or ""
      if trace == "" then
        trace = tostring(output.ename or "Error") .. ": " .. tostring(output.evalue or "")
      end
      on_text(trace, "NbxOutput")
    elseif kind == "display_data" or kind == "execute_result" then
      local data = type(output.data) == "table" and output.data or {}
      local mime = image.pick(data)
      local shown = mime and on_image(output, mime, data)
      if not shown then
        local text = bundle_text(data)
        if mime and data["text/plain"] == nil then
          text = "[" .. mime .. "]"
        end
        on_text(text, "NbxOutput")
      end
    end
  end
end

--- Virtual lines for the outputs of one cell.
---@param state table cell state
---@param max_cols integer
---@return table[] virt_lines
function M.build(state, max_cols)
  local max_lines = config.options.output.max_lines
  local lines, shown, hidden = {}, 0, 0
  local show_images = image.supported()

  each_output(state, function(text, hl)
    local parser = ansi.new(hl)
    local rows = ansi.lines(text)
    if rows[#rows] == "" then
      rows[#rows] = nil
    end
    for _, row in ipairs(rows) do
      if shown < max_lines then
        local chunks = parser:feed((row:gsub("\t", "    ")))
        table.insert(chunks, 1, PAD)
        lines[#lines + 1] = chunks
        shown = shown + 1
      else
        hidden = hidden + 1
      end
    end
  end, function(output, mime, data)
    if not show_images then
      return false
    end
    local img = image.get(output, mime, data[mime], max_cols)
    if not img then
      return false
    end
    for _, row in ipairs(image.rows(img)) do
      lines[#lines + 1] = { PAD, { row, img.hl } }
    end
    return true
  end)

  if hidden > 0 then
    lines[#lines + 1] = {
      PAD,
      {
        ("… %d more line%s (open the full output to see them)"):format(hidden, hidden == 1 and "" or "s"),
        "NbxOutputMore",
      },
    }
  end
  return lines
end

--- The complete output of a cell as text, ANSI colours included.
---@param state table
---@return string
function M.plain(state)
  local parts = {}
  each_output(state, function(text)
    local rows = ansi.lines(text)
    if rows[#rows] == "" then
      rows[#rows] = nil
    end
    parts[#parts + 1] = table.concat(rows, "\n")
  end, function()
    return false
  end)
  return table.concat(parts, "\n")
end

local function text_width(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return 80
  end
  local info = vim.fn.getwininfo(win)[1]
  return math.max(20, info.width - info.textoff)
end

local function drop(buf, state)
  if state.out_mark then
    pcall(api.nvim_buf_del_extmark, buf, M.ns_out, state.out_mark)
    state.out_mark = nil
  end
end

--- Place the outputs of every cell under its last line.
function M.outputs(st)
  local buf = st.buf
  local width = text_width(buf)
  local seen = {}
  for _, cell in ipairs(st.layout) do
    local state = cell.state
    seen[state] = true
    if cell.type ~= "code" then
      drop(buf, state)
    else
      local rebuilt = false
      if state.dirty or not state.virt then
        state.virt = M.build(state, width - 4)
        state.dirty = false
        rebuilt = true
      end
      if #state.virt == 0 then
        drop(buf, state)
      else
        local pos = state.out_mark and api.nvim_buf_get_extmark_by_id(buf, M.ns_out, state.out_mark, {})
        if rebuilt or not pos or pos[1] ~= cell.stop then
          local row = math.max(cell.stop, 0)
          state.out_mark = api.nvim_buf_set_extmark(buf, M.ns_out, row, 0, {
            id = state.out_mark,
            virt_lines = state.virt,
            virt_lines_overflow = has_overflow and "scroll" or nil,
          })
        end
      end
    end
  end
  for _, state in pairs(st.cells) do
    if not seen[state] then
      drop(buf, state)
    end
  end
  if st.head and not seen[st.head] then
    drop(buf, st.head)
  end
end

return M
