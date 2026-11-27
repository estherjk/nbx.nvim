local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")
local nb = require("nbx.notebook")
local ipynb = require("nbx.ipynb")

local function source(cell)
  return ipynb.text(cell.source)
end

describe("ipynb", function()
  it("recognises cell markers", function()
    assert.equals("code", ipynb.parse_marker("# %%"))
    assert.equals("code", ipynb.parse_marker("# %% a title"))
    assert.equals("markdown", ipynb.parse_marker("# %% [markdown]"))
    assert.equals("markdown", ipynb.parse_marker("# %% [md]"))
    assert.equals("raw", ipynb.parse_marker("# %% [raw]"))
    assert.is_nil(ipynb.parse_marker("#%%"))
    assert.is_nil(ipynb.parse_marker("x = 1  # %%"))
  end)

  it("splits lines the way nbformat does", function()
    assert.same({}, ipynb.split_keepends(""))
    assert.same({ "a\n", "b" }, ipynb.split_keepends("a\nb"))
    assert.same({ "a\n", "\n" }, ipynb.split_keepends("a\n\n"))
  end)

  it("comments markdown without losing text", function()
    for _, line in ipairs({ "", "text", "# heading", "  indented", "#" }) do
      assert.equals(line, ipynb.uncomment(ipynb.comment(line)))
    end
  end)
end)

describe("notebook buffer", function()
  after_each(h.close)

  it("shows cells as a python buffer", function()
    local _, st = h.open()
    assert.equals("python", vim.bo.filetype)
    assert.is_false(vim.bo.modified)
    assert.equals(6, #st.layout)
    local lines = h.lines()
    assert.equals("# %% [markdown]", lines[1])
    assert.equals("# # Title", lines[2])
    assert.equals("#", lines[3])
    assert.equals("import math", lines[7])
    assert.same(
      { "markdown", "code", "code", "code", "raw", "code" },
      vim.tbl_map(function(c)
        return c.type
      end, st.layout)
    )
  end)

  it("writes back exactly what Jupyter wrote", function()
    local path = h.open()
    vim.bo.modified = true
    vim.cmd("silent write")
    assert.is_false(vim.bo.modified)
    assert.equals(h.read(h.fixture), h.read(path))
  end)

  it("keeps outputs and metadata when source is edited", function()
    local path = h.open()
    vim.api.nvim_buf_set_lines(0, 7, 8, false, { "print('hello')", "# a comment" })
    vim.cmd("silent write")
    local doc = h.load(path)
    assert.equals("import math\nprint('hello')\n# a comment\nmath.pi", source(doc.cells[2]))
    assert.equals(2, #doc.cells[2].outputs)
    assert.same({ "keep" }, doc.cells[2].metadata.tags)
    assert.equals("cell0001", doc.cells[2].id)
    assert.equals("# Title\n\nSome *text* with `code` and **bold**.\n- item ünïcode ✓", source(doc.cells[1]))
  end)

  it("picks up cells typed by hand", function()
    local path, st = h.open()
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "# %%", "y = 2", "# %% [markdown]", "# note" })
    nb.sync(st)
    assert.equals(8, #st.layout)
    vim.cmd("silent write")
    local doc = h.load(path)
    assert.equals("y = 2", source(doc.cells[7]))
    assert.equals("code", doc.cells[7].cell_type)
    assert.same({}, doc.cells[7].outputs)
    assert.is_string(doc.cells[7].id)
    assert.equals("note", source(doc.cells[8]))
    assert.equals("markdown", doc.cells[8].cell_type)
    assert.is_nil(doc.cells[8].outputs)
  end)

  it("restores a deleted cell on undo, outputs included", function()
    local path, st = h.open()
    vim.o.undolevels = 1000
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    vim.cmd("normal! i ")
    vim.cmd("normal! x")
    nb.delete_cell(st)
    assert.equals(5, #st.layout)
    vim.cmd("silent undo")
    nb.sync(st)
    assert.equals(6, #st.layout)
    vim.cmd("silent write")
    assert.equals(2, #h.load(path).cells[2].outputs)
  end)

  it("moves cells with their outputs", function()
    local path, st = h.open()
    vim.api.nvim_win_set_cursor(0, { 8, 0 }) -- in the `import math` cell
    nb.move_cell(st, -1)
    assert.equals("# %%", h.lines()[1])
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
    nb.move_cell(st, 1)
    nb.move_cell(st, 1)
    vim.cmd("silent write")
    local doc = h.load(path)
    assert.equals("markdown", doc.cells[1].cell_type)
    assert.equals("", source(doc.cells[2]))
    assert.equals("cell0001", doc.cells[3].id)
    assert.equals(2, #doc.cells[3].outputs)
  end)

  it("adds, splits, merges and deletes cells", function()
    local path, st = h.open()
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    nb.split_cell(st) -- before print('hi')
    assert.equals(7, #st.layout)
    assert.equals("# %%", h.lines()[8])
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    nb.merge_cell(st)
    assert.equals(6, #st.layout)
    nb.add_cell(st, "below", "markdown")
    assert.equals(7, #st.layout)
    assert.equals("# %% [markdown]", h.lines()[10])
    assert.equals(11, vim.api.nvim_win_get_cursor(0)[1])
    nb.delete_cell(st)
    assert.equals(6, #st.layout)
    vim.cmd("silent write")
    assert.equals(h.read(h.fixture), h.read(path))
  end)

  it("toggles a cell between code and markdown", function()
    local path, st = h.open()
    vim.api.nvim_win_set_cursor(0, { 13, 0 }) -- the `1/0` cell
    nb.set_type(st)
    assert.equals("# %% [markdown]", h.lines()[12])
    assert.equals("# 1/0", h.lines()[13])
    vim.cmd("silent write")
    local doc = h.load(path)
    assert.equals("markdown", doc.cells[4].cell_type)
    assert.equals("1/0", source(doc.cells[4]))
    assert.is_nil(doc.cells[4].outputs)
    assert.equals("cell0003", doc.cells[4].id)
    nb.set_type(st)
    assert.equals("1/0", h.lines()[13])
  end)

  it("treats text above the first marker as a cell", function()
    local path, st = h.open()
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "first = 1" })
    nb.sync(st)
    assert.equals(7, #st.layout)
    vim.cmd("silent write")
    assert.equals("first = 1", source(h.load(path).cells[1]))
  end)

  it("creates an empty notebook for a new file", function()
    local path = vim.fn.tempname() .. ".ipynb"
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    assert.same({ "# %%", "" }, h.lines())
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "print(1)" })
    vim.cmd("silent write")
    local doc = h.load(path)
    assert.equals(4, doc.nbformat)
    assert.equals("print(1)", source(doc.cells[1]))
    assert.equals("python3", doc.metadata.kernelspec.name)
  end)

  it("falls back to JSON for files it cannot read as a notebook", function()
    local path = vim.fn.tempname() .. ".ipynb"
    vim.fn.writefile({ '{"nbformat": 3, "worksheets": []}' }, path)
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    assert.equals("json", vim.bo.filetype)
    assert.is_nil(nb.get())
  end)

  it("reloads when the file changes on disk", function()
    local path, st = h.open()
    local doc = h.load(path)
    doc.cells = { doc.cells[2] }
    vim.fn.writefile({ vim.json.encode(doc) }, path)
    nb.check_disk(st)
    assert.equals(1, #nb.get().layout)
    assert.equals("import math", h.lines()[2])
  end)
end)

describe("rendering", function()
  after_each(h.close)

  it("draws outputs under their cells", function()
    local _, st = h.open()
    local render = require("nbx.render")
    local marks = vim.api.nvim_buf_get_extmarks(0, render.ns_out, 0, -1, { details = true })
    assert.equals(3, #marks)
    assert.equals(8, marks[1][2]) -- last line of the `import math` cell
    local text = {}
    for _, line in ipairs(marks[1][4].virt_lines) do
      local row = {}
      for _, chunk in ipairs(line) do
        row[#row + 1] = chunk[1]
      end
      text[#text + 1] = table.concat(row)
    end
    assert.same({ "│ hi", "│ 3.141592653589793" }, text)
    assert.equals("hi\n3.141592653589793", render.plain(st.layout[2].state))
  end)

  it("folds long output", function()
    local render = require("nbx.render")
    local rows = {}
    for i = 1, 100 do
      rows[i] = "line " .. i
    end
    local state = { outputs = { { output_type = "stream", name = "stdout", text = table.concat(rows, "\n") .. "\n" } } }
    local lines = render.build(state, 80)
    assert.equals(31, #lines)
    assert.truthy(lines[31][2][1]:find("70 more lines", 1, true))
  end)

  it("resolves carriage returns and colours", function()
    local ansi = require("nbx.ansi")
    assert.same({ "50%", "100%", "" }, ansi.lines("10%\r50%\n100%\r\n"))
    assert.equals("red plain", ansi.strip("\27[31mred\27[0m plain"))
    local chunks = ansi.new("Base"):feed("a\27[1;32mb\27[0mc")
    assert.equals(3, #chunks)
    assert.equals("Base", chunks[1][2])
    assert.equals("Base", chunks[2][2][1])
  end)
end)
