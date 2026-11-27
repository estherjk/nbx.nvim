-- Conversion between the .ipynb JSON document and the lines shown in a buffer.
--
-- A notebook is shown as one Python buffer in the "percent" layout:
--
--   # %%                 a code cell
--   # %% [markdown]      a markdown cell; its text is kept as `# ` comments
--   # %% [raw]           a raw cell, also kept as comments
--
-- Everything that is not source text (outputs, metadata, ids, attachments)
-- stays in a per-cell state table and is written back untouched.
local json = require("nbx.json")

local M = {}

M.MARKER = {
  code = "# %%",
  markdown = "# %% [markdown]",
  raw = "# %% [raw]",
}

-- Mime types nbformat stores as a list of lines rather than one string.
local SPLIT_MIMES = { ["application/javascript"] = true, ["image/svg+xml"] = true }

---@param line string
---@return "code"|"markdown"|"raw"|nil
function M.parse_marker(line)
  local rest = line:match("^# %%%%(.*)$")
  if not rest then
    return nil
  end
  rest = vim.trim(rest):lower()
  if rest:find("^%[markdown%]") or rest:find("^%[md%]") then
    return "markdown"
  elseif rest:find("^%[raw%]") then
    return "raw"
  end
  return "code"
end

--- A multi-line string field is either a string or a list of strings.
---@param value string|string[]|nil
---@return string
function M.text(value)
  if type(value) == "table" then
    return table.concat(value)
  end
  return value or ""
end

--- Split like Python's str.splitlines(True), on "\n" only.
---@param s string
---@return string[]
function M.split_keepends(s)
  local lines = {}
  local pos = 1
  while pos <= #s do
    local nl = s:find("\n", pos, true)
    if not nl then
      lines[#lines + 1] = s:sub(pos)
      break
    end
    lines[#lines + 1] = s:sub(pos, nl)
    pos = nl + 1
  end
  return lines
end

---@param line string
function M.comment(line)
  return line == "" and "#" or ("# " .. line)
end

---@param line string
function M.uncomment(line)
  return line:match("^# ?(.*)$") or line
end

--- Lines shown in the buffer for a cell body.
---@param cell_type string
---@param source string
---@return string[]
function M.body_lines(cell_type, source)
  local lines = vim.split(source, "\n", { plain = true })
  if cell_type ~= "code" then
    for i, line in ipairs(lines) do
      lines[i] = M.comment(line)
    end
  end
  return lines
end

--- Source text for the buffer lines of a cell body.
---@param cell_type string
---@param lines string[]
---@return string
function M.body_source(cell_type, lines)
  if cell_type == "code" then
    return table.concat(lines, "\n")
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = M.uncomment(line)
  end
  return table.concat(out, "\n")
end

local function new_id()
  return string.format("%08x", math.random(0, 0x7fffffff))
end

--- State for a cell that was just typed into the buffer.
---@param nb table
---@param cell_type string
function M.new_cell(nb, cell_type)
  local raw = { cell_type = cell_type, metadata = vim.empty_dict(), source = {} }
  if M.wants_ids(nb) then
    raw.id = new_id()
  end
  return { cell_type = cell_type, raw = raw, outputs = {}, execution_count = vim.NIL }
end

function M.wants_ids(nb)
  return (nb.nbformat or 4) > 4 or ((nb.nbformat or 4) == 4 and (nb.nbformat_minor or 0) >= 5)
end

function M.new_notebook()
  return {
    cells = {},
    metadata = {
      kernelspec = { display_name = "Python 3", language = "python", name = "python3" },
      language_info = { name = "python" },
    },
    nbformat = 4,
    nbformat_minor = 5,
  }
end

---@param text string file contents
---@return table? notebook, string? error
function M.decode(text)
  if vim.trim(text) == "" then
    return M.new_notebook()
  end
  local ok, nb = pcall(json.decode, text)
  if not ok then
    return nil, "not valid JSON: " .. tostring(nb)
  end
  if type(nb) ~= "table" or type(nb.cells) ~= "table" then
    return nil, "not a notebook (no cells)"
  end
  if nb.nbformat ~= 4 then
    return nil, "only nbformat 4 notebooks are supported (found " .. tostring(nb.nbformat) .. ")"
  end
  return nb
end

--- Turn a decoded notebook into buffer lines.
---@param nb table
---@return string[] lines, {row: integer, state: table}[] cells
function M.to_buffer(nb)
  local lines, cells = {}, {}
  for _, raw in ipairs(nb.cells) do
    local cell_type = raw.cell_type
    if cell_type ~= "markdown" and cell_type ~= "raw" then
      cell_type = "code"
    end
    local state = { cell_type = cell_type, raw = raw }
    if cell_type == "code" then
      state.outputs = raw.outputs or {}
      state.execution_count = raw.execution_count == nil and vim.NIL or raw.execution_count
    end
    cells[#cells + 1] = { row = #lines, state = state }
    lines[#lines + 1] = M.MARKER[cell_type]
    vim.list_extend(lines, M.body_lines(cell_type, M.text(raw.source)))
  end
  if #cells == 0 then
    cells[1] = { row = 0, state = M.new_cell(nb, "code") }
    lines = { M.MARKER.code, "" }
  end
  return lines, cells
end

--- Put an output into the shape nbformat writes to disk.
function M.normalize_output(output)
  if output.output_type == "stream" then
    if type(output.text) == "string" then
      output.text = M.split_keepends(output.text)
    end
  elseif type(output.data) == "table" then
    for mime, value in pairs(output.data) do
      if type(value) == "string" and (mime:find("^text/") or SPLIT_MIMES[mime]) then
        output.data[mime] = M.split_keepends(value)
      end
    end
  end
  if output.metadata ~= nil and type(output.metadata) == "table" and next(output.metadata) == nil then
    output.metadata = vim.empty_dict()
  end
  return output
end

--- Build the notebook document for the current buffer contents.
---@param nb table the notebook as loaded; top-level fields are kept
---@param cells {state: table, lines: string[]}[]
---@return table
function M.from_buffer(nb, cells)
  local out = {}
  for key, value in pairs(nb) do
    out[key] = value
  end
  out.cells = {}
  for _, cell in ipairs(cells) do
    local state = cell.state
    local raw = {}
    for key, value in pairs(state.raw or {}) do
      raw[key] = value
    end
    raw.cell_type = state.cell_type
    raw.metadata = raw.metadata or vim.empty_dict()
    raw.source = M.split_keepends(M.body_source(state.cell_type, cell.lines))
    if state.cell_type == "code" then
      local outputs = {}
      for i, output in ipairs(state.outputs or {}) do
        outputs[i] = M.normalize_output(output)
      end
      raw.outputs = outputs
      raw.execution_count = state.execution_count == nil and vim.NIL or state.execution_count
    else
      raw.outputs = nil
      raw.execution_count = nil
    end
    if raw.id == nil and M.wants_ids(nb) then
      raw.id = new_id()
      state.raw = state.raw or {}
      state.raw.id = raw.id
    end
    out.cells[#out.cells + 1] = raw
  end
  return out
end

---@param nb table
---@return string
function M.encode(nb)
  return json.encode(nb) .. "\n"
end

return M
