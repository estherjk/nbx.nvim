-- End-to-end: start a real kernel and run code. Needs uv (which provides
-- ipykernel on the fly); skipped otherwise.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")
local nb = require("nbx.notebook")
local ipynb = require("nbx.ipynb")

local has_uv = vim.fn.executable("uv") == 1
local run = (has_uv and vim.env.NBX_SKIP_KERNEL ~= "1") and it or pending

local function wait(what, cond, timeout)
  assert(vim.wait(timeout or 120000, cond, 50), "timed out waiting for " .. what)
end

local function idle(st)
  return next(st.execs) == nil and not st.starting
end

describe("kernel", function()
  after_each(h.close)

  run("runs cells and stores their output", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/run.ipynb"
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    local st = nb.get()
    st.choice = { kind = "uv", label = "uv" }
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "# %%",
      "import sys",
      "x = 20 + 1",
      "print('out')",
      "print('err', file=sys.stderr)",
      "x * 2",
      "# %% [markdown]",
      "# not code",
      "# %%",
      "from IPython.display import display, Markdown",
      "display(Markdown('**md**'))",
      "raise ValueError('boom')",
      "# %%",
      "x",
    })
    nb.run_all(st)
    wait("the kernel to start", function()
      return st.kernel ~= nil and st.kernel.ready
    end)
    wait("cells to finish", function()
      return idle(st)
    end)

    local first, third, fourth = st.layout[1].state, st.layout[3].state, st.layout[4].state
    assert.equals("ok", first.result)
    assert.equals(1, first.execution_count)
    assert.same(
      { "stream", "stream", "execute_result" },
      vim.tbl_map(function(o)
        return o.output_type
      end, first.outputs)
    )
    assert.equals("out\n", ipynb.text(first.outputs[1].text))
    assert.equals("stderr", first.outputs[2].name)
    assert.equals("42", ipynb.text(first.outputs[3].data["text/plain"]))
    assert.equals("error", third.result)
    assert.equals("ValueError", third.outputs[2].ename)
    -- The kernel stops at the first error, so the last cell never ran.
    assert.equals("aborted", fourth.result)
    assert.is_true(vim.bo.modified)

    vim.cmd("silent write")
    local doc = h.load(path)
    assert.equals(4, #doc.cells)
    assert.same({ "out\n" }, doc.cells[1].outputs[1].text)
    assert.equals(1, doc.cells[1].execution_count)
    assert.equals("display_data", doc.cells[3].outputs[1].output_type)

    -- State survives between cells, and a restart clears it.
    vim.api.nvim_win_set_cursor(0, { 14, 0 })
    nb.run_cell(st)
    wait("the rerun", function()
      return idle(st) and fourth.result == "ok"
    end)
    assert.equals("21", ipynb.text(fourth.outputs[1].data["text/plain"]))

    local restarted
    nb.restart(st, function(ok)
      restarted = ok
    end)
    wait("the restart", function()
      return restarted ~= nil
    end)
    assert.is_true(restarted)
    nb.run_cell(st)
    wait("the run after restart", function()
      return idle(st) and fourth.result == "error"
    end)
    assert.equals("NameError", fourth.outputs[1].ename)
  end)

  run("interrupts a running cell", function()
    local path = vim.fn.tempname() .. ".ipynb"
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    local st = nb.get()
    st.choice = { kind = "uv", label = "uv" }
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# %%", "import time", "time.sleep(60)" })
    nb.run_all(st)
    local state = st.layout[1].state
    wait("the cell to start", function()
      return state.status == "running"
    end)
    nb.interrupt(st)
    wait("the interrupt", function()
      return idle(st)
    end, 20000)
    assert.equals("error", state.result)
    assert.equals("KeyboardInterrupt", state.outputs[1].ename)
  end)
end)
