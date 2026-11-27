-- A notebook buffer: loading and saving, the cell layout, cell editing
-- commands and execution.
local config = require("nbx.config")
local image = require("nbx.image")
local ipynb = require("nbx.ipynb")
local kernel = require("nbx.kernel")
local render = require("nbx.render")

local api = vim.api
local uv = vim.uv

local M = {}

---@type table<integer, table>
M.states = {}
M.last_buf = nil

local ns_cell = api.nvim_create_namespace("nbx.cell")
M.ns_cell = ns_cell

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "nbx" })
end
M.notify = notify

---@param buf? integer
function M.get(buf)
  if buf == nil or buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  return M.states[buf]
end

-- Layout -----------------------------------------------------------------------

--- Tie a cell state to the marker line at `row`.
local function attach(st, row, state)
  if state.mark then
    pcall(api.nvim_buf_del_extmark, st.buf, ns_cell, state.mark)
    st.cells[state.mark] = nil
  end
  local line = api.nvim_buf_get_lines(st.buf, row, row + 1, false)[1] or ""
  state.mark = api.nvim_buf_set_extmark(st.buf, ns_cell, row, 0, {
    end_row = row,
    end_col = #line,
    invalidate = true,
  })
  st.cells[state.mark] = state
end

local function free_images(state)
  for _, output in ipairs(state.outputs or {}) do
    image.free(output)
  end
end

local function clear_state(state)
  free_images(state)
  state.outputs = {}
  state.execution_count = vim.NIL
  state.result = nil
  state.duration = nil
  state.clear_pending = nil
  state.dirty = true
end

--- Work out where the cells are from the marker lines in the buffer, then
--- redraw. Cheap enough to run after every change.
function M.sync(st)
  local buf = st.buf
  if not api.nvim_buf_is_loaded(buf) then
    return
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local by_row = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns_cell, 0, -1, { details = true })) do
    local id, row, details = m[1], m[2], m[4]
    if not details.invalid and st.cells[id] and by_row[row] == nil then
      by_row[row] = id
    end
  end

  local layout = {}
  local cur
  local function close(stop)
    if cur then
      cur.stop = stop
      layout[#layout + 1] = cur
    end
  end
  for i, line in ipairs(lines) do
    local kind = line:byte(1) == 35 and ipynb.parse_marker(line) or nil
    if kind then
      close(i - 2)
      local row = i - 1
      local state = by_row[row] and st.cells[by_row[row]]
      if not state then
        state = ipynb.new_cell(st.nb, kind)
        attach(st, row, state)
      elseif state.cell_type ~= kind then
        state.cell_type = kind
        clear_state(state)
      end
      cur = { start = row, type = kind, state = state }
    elseif i == 1 then
      -- Text above the first marker is an implicit code cell.
      st.head = st.head or ipynb.new_cell(st.nb, "code")
      cur = { start = -1, type = "code", state = st.head }
    end
  end
  close(#lines - 1)

  st.lines = lines
  st.layout = layout
  render.decorate(st)
  render.outputs(st)
end

--- Sync soon; collapses bursts of changes and output into one redraw.
function M.refresh(st, delay)
  if st.refresh_pending then
    return
  end
  st.refresh_pending = true
  vim.defer_fn(function()
    st.refresh_pending = false
    if M.states[st.buf] == st and api.nvim_buf_is_valid(st.buf) then
      M.sync(st)
    end
  end, delay or 0)
end

---@return string[] body lines of a cell
function M.body(st, cell)
  local body = {}
  for row = cell.start + 1, cell.stop do
    body[#body + 1] = st.lines[row + 1]
  end
  return body
end

---@return table? cell, integer? index
function M.cell_at(st, row)
  for i, cell in ipairs(st.layout) do
    if row >= cell.start and row <= cell.stop then
      return cell, i
    end
  end
  return st.layout[#st.layout], #st.layout
end

local function cursor_row(st)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= st.buf then
    win = vim.fn.bufwinid(st.buf)
  end
  if win == -1 then
    return 0, nil
  end
  return api.nvim_win_get_cursor(win)[1] - 1, win
end

--- Fresh layout plus the cell under the cursor.
local function current(st)
  M.sync(st)
  local row, win = cursor_row(st)
  local cell, index = M.cell_at(st, row)
  return cell, index, row, win
end

local function set_cursor(st, row, col)
  local win = vim.fn.bufwinid(st.buf)
  if win ~= -1 then
    local last = api.nvim_buf_line_count(st.buf)
    api.nvim_win_set_cursor(win, { math.max(1, math.min(row + 1, last)), col or 0 })
  end
end

--- Give the implicit first cell a real marker so it can be edited like the rest.
local function materialize(st)
  local first = st.layout[1]
  if first and first.start == -1 then
    api.nvim_buf_set_lines(st.buf, 0, 0, false, { ipynb.MARKER.code })
    attach(st, 0, st.head)
    st.head = nil
    M.sync(st)
  end
end

-- Loading and saving -----------------------------------------------------------

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

--- Absolute path with symlinks in the directory part resolved, so the same
--- file always compares equal.
function M.normalize(path)
  path = vim.fn.fnamemodify(path, ":p")
  local dir = uv.fs_realpath(vim.fn.fnamemodify(path, ":h"))
  return dir and (dir .. "/" .. vim.fn.fnamemodify(path, ":t")) or path
end

local function stat_key(path)
  local s = uv.fs_stat(path)
  return s and (s.mtime.sec .. "." .. s.mtime.nsec .. "." .. s.size) or nil
end

local function window_options(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    api.nvim_set_option_value("conceallevel", 2, { scope = "local", win = win })
    api.nvim_set_option_value("concealcursor", "nc", { scope = "local", win = win })
  end
end

local function setup_buffer(st)
  local buf = st.buf
  local group = api.nvim_create_augroup("nbx.buf." .. buf, { clear = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.refresh(st)
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      window_options(buf)
      M.refresh(st)
    end,
  })
  api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    callback = function()
      M.last_buf = buf
      M.check_disk(st)
    end,
  })
  api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if api.nvim_get_current_buf() == buf then
        M.check_disk(st)
      end
    end,
  })
  api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if vim.fn.bufwinid(buf) ~= -1 then
        M.refresh(st, 50)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.close(buf)
    end,
  })
  -- Formatters see a .ipynb name and expect JSON, so leave formatting on save off.
  vim.b[buf].autoformat = false
  vim.bo[buf].formatoptions = vim.bo[buf].formatoptions:gsub("[ro]", "") .. "ro"
  require("nbx").attach(buf)
end

--- Fill a buffer from a notebook file (BufReadCmd / BufNewFile).
---@param buf integer
---@param path string
function M.read(buf, path)
  require("nbx").init()
  path = M.normalize(path)
  local text = read_file(path) or ""
  local nb, err = ipynb.decode(text)
  if not nb then
    -- Not something we can show as cells; fall back to the raw JSON.
    M.close(buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.bo[buf].modified = false
    vim.bo[buf].filetype = "json"
    notify(vim.fn.fnamemodify(path, ":t") .. ": " .. err, vim.log.levels.WARN)
    return
  end

  local st = M.states[buf]
  local fresh = st == nil
  if fresh then
    -- BufReadCmd replaces the normal read, so the events around it never
    -- fire. Plugins that load on them (LSP, treesitter, ...) still expect
    -- them, so fire them by hand: this one now, BufReadPost at the end.
    api.nvim_exec_autocmds("BufReadPre", { buffer = buf, modeline = false })
    st = { buf = buf, execs = {}, displays = {}, waiters = {} }
    M.states[buf] = st
  else
    for _, state in pairs(st.cells) do
      free_images(state)
    end
  end
  st.path = path
  st.nb = nb
  st.cells = {}
  st.head = nil
  st.layout = {}
  st.execs = {}
  st.displays = {}
  st.disk = stat_key(path)
  st.choice = st.choice or kernel.load_choice(path)

  local lines, cells = ipynb.to_buffer(nb)
  nb.cells = nil -- cells now live in the buffer
  api.nvim_buf_clear_namespace(buf, ns_cell, 0, -1)
  api.nvim_buf_clear_namespace(buf, render.ns_out, 0, -1)
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
  vim.bo[buf].modified = false
  for _, cell in ipairs(cells) do
    attach(st, cell.row, cell.state)
  end

  if fresh then
    setup_buffer(st)
  end
  if vim.bo[buf].filetype ~= "python" then
    vim.bo[buf].filetype = "python"
  end
  window_options(buf)
  M.last_buf = buf
  M.sync(st)
  if fresh then
    api.nvim_exec_autocmds("BufReadPost", { buffer = buf, modeline = false })
    if config.options.kernel.autostart then
      M.ensure_kernel(st, function() end)
    end
  end
end

--- Write the notebook (BufWriteCmd).
---@param buf integer
---@param path string
function M.write(buf, path)
  local st = M.states[buf]
  if not st then
    -- Raw JSON fallback buffer: write it as it is.
    vim.fn.writefile(api.nvim_buf_get_lines(buf, 0, -1, false), path)
    vim.bo[buf].modified = false
    return
  end
  path = M.normalize(path)
  M.sync(st)
  local cells = {}
  for _, cell in ipairs(st.layout) do
    local body = M.body(st, cell)
    local empty_head = cell.start == -1 and #st.layout > 1 and vim.trim(table.concat(body, "\n")) == ""
    if not empty_head then
      cells[#cells + 1] = { state = cell.state, lines = body }
    end
  end
  local text = ipynb.encode(ipynb.from_buffer(st.nb, cells))
  local tmp = path .. ".nbx-tmp"
  local f, err = io.open(tmp, "wb")
  if not f then
    return notify("cannot write " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
  f:write(text)
  f:close()
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return notify("cannot write " .. path .. ": " .. tostring(rename_err), vim.log.levels.ERROR)
  end
  if path == st.path then
    st.disk = stat_key(path)
    vim.bo[buf].modified = false
  end
  local name = vim.fn.fnamemodify(path, ":~:.")
  api.nvim_echo({ { ('"%s" %d cells written'):format(name, #cells) } }, false, {})
  api.nvim_exec_autocmds("BufWritePost", { buffer = buf, modeline = false })
end

--- Notice when the file changed underneath us (git checkout, Jupyter, ...).
function M.check_disk(st)
  local now = stat_key(st.path)
  if now == nil or now == st.disk then
    return
  end
  st.disk = now
  if vim.bo[st.buf].modified then
    notify(
      vim.fn.fnamemodify(st.path, ":t") .. " changed on disk. :e! loads it, :w overwrites it.",
      vim.log.levels.WARN
    )
  else
    local view = vim.fn.bufwinid(st.buf) ~= -1 and vim.fn.winsaveview() or nil
    M.read(st.buf, st.path)
    if view and api.nvim_get_current_buf() == st.buf then
      vim.fn.winrestview(view)
    end
  end
end

function M.close(buf)
  local st = M.states[buf]
  if not st then
    return
  end
  M.states[buf] = nil
  if st.kernel then
    st.kernel:stop()
  end
  for _, state in pairs(st.cells) do
    free_images(state)
  end
  pcall(api.nvim_del_augroup_by_name, "nbx.buf." .. buf)
  if M.last_buf == buf then
    M.last_buf = nil
  end
end

-- Kernel -----------------------------------------------------------------------

local function mark_modified(st)
  if api.nvim_buf_is_valid(st.buf) then
    vim.bo[st.buf].modified = true
  end
end

--- Forget everything that was queued or running.
local function reset_running(st, result)
  for _, state in pairs(st.execs) do
    state.status = nil
    state.exec_id = nil
    if result and state.result == nil then
      state.result = result
    end
  end
  st.execs = {}
  for _, cell in ipairs(st.layout or {}) do
    if cell.state.status then
      cell.state.status = nil
    end
  end
end

local function append_output(st, state, output, display_id)
  if state.clear_pending then
    free_images(state)
    state.outputs = {}
    state.clear_pending = nil
  end
  local outputs = state.outputs
  local last = outputs[#outputs]
  if output.output_type == "stream" and last and last.output_type == "stream" and last.name == output.name then
    last.text = ipynb.text(last.text) .. ipynb.text(output.text)
  else
    outputs[#outputs + 1] = output
    if type(display_id) == "string" then
      st.displays[display_id] = st.displays[display_id] or {}
      table.insert(st.displays[display_id], { state = state, output = output })
    end
  end
  state.dirty = true
end

local function on_event(st, ev)
  local kind = ev.event
  local state = ev.exec_id and st.execs[ev.exec_id]
  if kind == "status" then
    if ev.state == "dead" and st.kernel then
      st.kernel.ready = false
      reset_running(st, "aborted")
      M.refresh(st)
    end
    vim.cmd.redrawstatus()
  elseif kind == "update_display" then
    for _, entry in ipairs(type(ev.display_id) == "string" and st.displays[ev.display_id] or {}) do
      image.free(entry.output)
      entry.output.data = ev.data
      entry.output.metadata = ev.metadata
      entry.state.dirty = true
    end
    M.refresh(st, 50)
  elseif kind == "input_request" then
    local prompt = (type(ev.prompt) == "string" and ev.prompt ~= "") and ev.prompt or "Input: "
    local function reply(value)
      if st.kernel then
        st.kernel:request("input_reply", { value = value or "" })
      end
    end
    if ev.password == true then
      reply(vim.fn.inputsecret(prompt))
    else
      vim.ui.input({ prompt = prompt }, reply)
    end
  elseif not state then
    return
  elseif kind == "execute_input" then
    state.status = "running"
    state.started = uv.hrtime()
    if type(ev.execution_count) == "number" then
      state.execution_count = ev.execution_count
    end
    M.refresh(st)
  elseif kind == "output" then
    append_output(st, state, ev.output, ev.display_id)
    mark_modified(st)
    M.refresh(st, 50)
  elseif kind == "clear_output" then
    if ev.wait == true then
      state.clear_pending = true
    else
      free_images(state)
      state.outputs = {}
      state.dirty = true
      M.refresh(st, 50)
    end
  elseif kind == "done" then
    st.execs[ev.exec_id] = nil
    state.exec_id = nil
    state.status = nil
    state.result = type(ev.status) == "string" and ev.status or "ok"
    if type(ev.execution_count) == "number" then
      state.execution_count = ev.execution_count
    end
    if state.started then
      state.duration = (uv.hrtime() - state.started) / 1e9
      state.started = nil
    end
    for _, page in ipairs(type(ev.pages) == "table" and ev.pages or {}) do
      append_output(st, state, { output_type = "stream", name = "stdout", text = page })
    end
    mark_modified(st)
    M.refresh(st)
  end
end

local function new_kernel(st)
  return kernel.new({
    name = vim.fn.fnamemodify(st.path, ":t:r"),
    cwd = vim.fn.fnamemodify(st.path, ":h"),
    on_event = function(ev)
      if M.states[st.buf] == st then
        on_event(st, ev)
      end
    end,
    on_exit = function(code)
      if M.states[st.buf] ~= st then
        return
      end
      reset_running(st, "aborted")
      M.refresh(st)
      vim.cmd.redrawstatus()
      if code ~= 0 then
        notify("The kernel sidecar exited (code " .. code .. "). See :Nbx log.", vim.log.levels.ERROR)
      end
    end,
  })
end

local function sidecar(st)
  if not st.kernel or not st.kernel:alive() then
    st.kernel = new_kernel(st)
  end
  return st.kernel
end

--- Make sure the chosen interpreter can run a kernel, offering to fix it.
local function check_choice(st, choice, cb)
  if choice.kind ~= "venv" and choice.kind ~= "python" then
    return cb(choice)
  end
  kernel.has_ipykernel(choice.python, function(ok)
    if ok then
      return cb(choice)
    end
    local options = { "Install ipykernel into " .. choice.label }
    local has_uv = vim.fn.executable("uv") == 1
    if has_uv then
      options[#options + 1] = "Use a temporary uv kernel instead"
    end
    options[#options + 1] = "Cancel"
    vim.ui.select(options, { prompt = choice.label .. " has no ipykernel" }, function(_, index)
      if index == 1 then
        notify("Installing ipykernel into " .. choice.label .. "…")
        kernel.install_ipykernel(choice.python, function(installed, output)
          if installed then
            cb(choice)
          else
            notify("Could not install ipykernel:\n" .. output, vim.log.levels.ERROR)
            cb(nil)
          end
        end)
      elseif has_uv and index == 2 then
        cb({ kind = "uv", label = "uv (temporary ipykernel)" })
      else
        cb(nil)
      end
    end)
  end)
end

local function start_kernel(st, choice)
  local k = sidecar(st)
  st.starting = true
  vim.cmd.redrawstatus()
  k:start(choice, function(err)
    st.starting = false
    local waiters = st.waiters
    st.waiters = {}
    if err then
      reset_running(st)
      M.refresh(st)
      notify("Kernel failed to start: " .. err .. "\nSee :Nbx log for details.", vim.log.levels.ERROR)
    end
    vim.cmd.redrawstatus()
    for _, cb in ipairs(waiters) do
      cb(not err and k or nil)
    end
  end)
end

--- Call back with a running kernel, starting one if needed.
---@param cb fun(k?: table)
function M.ensure_kernel(st, cb)
  if st.kernel and st.kernel.ready and st.kernel:alive() then
    return cb(st.kernel)
  end
  table.insert(st.waiters, cb)
  if st.starting then
    return
  end
  st.starting = true
  local function fail()
    st.starting = false
    local waiters = st.waiters
    st.waiters = {}
    reset_running(st)
    M.refresh(st)
    for _, waiter in ipairs(waiters) do
      waiter(nil)
    end
  end
  local function go(choice)
    if not choice then
      notify("No Python found to run a kernel with. Pick one with :Nbx kernel.", vim.log.levels.ERROR)
      return fail()
    end
    check_choice(st, choice, function(checked)
      if not checked then
        return fail()
      end
      start_kernel(st, checked)
    end)
  end
  if st.choice then
    return go(st.choice)
  end
  local dir = vim.fn.fnamemodify(st.path, ":h")
  local venv = kernel.find_venv(dir)
  if venv then
    return go(venv)
  end
  -- No virtualenv nearby: look at the installed kernelspecs before deciding.
  local k = sidecar(st)
  local ok, err = k:spawn()
  if not ok then
    notify("Could not start the kernel sidecar: " .. tostring(err), vim.log.levels.ERROR)
    return fail()
  end
  k:request("kernelspecs", nil, function(_, specs)
    local wanted = vim.tbl_get(st.nb, "metadata", "kernelspec", "name")
    go(kernel.default_choice(dir, wanted, type(specs) == "table" and specs or nil))
  end)
end

--- Queue cells for execution.
function M.run_cells(st, cells)
  local todo = {}
  for _, cell in ipairs(cells) do
    if cell.type == "code" and not cell.state.status then
      local code = table.concat(M.body(st, cell), "\n")
      if vim.trim(code) ~= "" then
        todo[#todo + 1] = { state = cell.state, code = code }
        cell.state.status = "queued"
      end
    end
  end
  if #todo == 0 then
    return
  end
  M.refresh(st)
  M.ensure_kernel(st, function(k)
    if not k then
      for _, item in ipairs(todo) do
        item.state.status = nil
      end
      return M.refresh(st)
    end
    for _, item in ipairs(todo) do
      local state = item.state
      clear_state(state)
      state.status = "queued"
      state.exec_id = k:execute(item.code)
      st.execs[state.exec_id] = state
    end
    mark_modified(st)
    M.refresh(st)
  end)
end

function M.run_cell(st)
  local cell = current(st)
  if cell then
    M.run_cells(st, { cell })
  end
end

function M.run_and_next(st)
  local cell, index = current(st)
  if not cell then
    return
  end
  M.run_cells(st, { cell })
  local next_cell = st.layout[index + 1]
  if next_cell then
    set_cursor(st, math.min(next_cell.start + 1, next_cell.stop))
  else
    M.add_cell(st, "below", "code")
  end
end

function M.run_all(st)
  M.sync(st)
  M.run_cells(st, st.layout)
end

function M.run_above(st)
  local _, index = current(st)
  M.run_cells(st, vim.list_slice(st.layout, 1, (index or 1) - 1))
end

function M.run_below(st)
  local _, index = current(st)
  M.run_cells(st, vim.list_slice(st.layout, index or 1))
end

function M.interrupt(st)
  if not (st.kernel and st.kernel.ready) then
    return notify("No kernel is running.")
  end
  st.kernel:request("interrupt", nil, function(err)
    if err then
      notify("Interrupt failed: " .. err, vim.log.levels.ERROR)
    end
  end)
end

--- Restart the kernel, or start one if there is none.
---@param cb? fun(ok: boolean)
function M.restart(st, cb)
  cb = cb or function() end
  if st.starting then
    notify("The kernel is still starting.")
    return cb(false)
  end
  if not (st.kernel and st.kernel.ready and st.kernel:alive()) then
    return M.ensure_kernel(st, function(k)
      if k then
        notify("Kernel started: " .. k.choice.label)
      end
      cb(k ~= nil)
    end)
  end
  reset_running(st, "aborted")
  M.refresh(st)
  st.starting = true
  st.kernel:request("restart", { timeout = config.options.kernel.timeout }, function(err)
    st.starting = false
    vim.cmd.redrawstatus()
    if err then
      st.kernel.ready = false
      notify("Restart failed: " .. err, vim.log.levels.ERROR)
      return cb(false)
    end
    notify("Kernel restarted.")
    cb(true)
  end)
end

function M.restart_and_run_all(st)
  M.restart(st, function(ok)
    if ok then
      M.clear_all(st)
      M.run_all(st)
    end
  end)
end

function M.shutdown(st)
  if st.kernel then
    st.kernel:stop()
    reset_running(st, "aborted")
    M.refresh(st)
    notify("Kernel shut down.")
  end
end

--- Pick the interpreter or kernelspec this notebook runs on.
function M.select_kernel(st)
  local k = sidecar(st)
  local ok, err = k:spawn()
  if not ok then
    return notify("Could not start the kernel sidecar: " .. tostring(err), vim.log.levels.ERROR)
  end
  k:request("kernelspecs", nil, function(_, specs)
    local dir = vim.fn.fnamemodify(st.path, ":h")
    local choices = kernel.candidates(dir, type(specs) == "table" and specs or nil)
    vim.ui.select(choices, {
      prompt = "Kernel for " .. vim.fn.fnamemodify(st.path, ":t"),
      format_item = function(choice)
        local active = st.kernel and st.kernel.ready and st.kernel.choice
        local same = active
          and active.kind == choice.kind
          and active.python == choice.python
          and active.name == choice.name
        return (same and "● " or "  ") .. choice.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      check_choice(st, choice, function(checked)
        if not checked then
          return
        end
        st.choice = checked
        kernel.save_choice(st.path, checked)
        reset_running(st, "aborted")
        M.refresh(st)
        table.insert(st.waiters, function(started)
          if started then
            notify("Kernel started: " .. checked.label)
          end
        end)
        start_kernel(st, checked)
      end)
    end)
  end)
end

function M.show_log(st)
  local k = sidecar(st)
  local path = k.log_path
  if vim.fn.filereadable(path) == 0 then
    k:log("")
  end
  if vim.env.REX_BLOCK and vim.fn.executable("rex") == 1 then
    vim.system({
      "rex",
      "run",
      "--split=below",
      "--ratio",
      "30",
      "--focus=false",
      "--label",
      "nbx kernel log",
      "--",
      "tail",
      "-n",
      "200",
      "-f",
      path,
    })
  else
    vim.cmd("botright 12split " .. vim.fn.fnameescape(path))
    vim.bo.autoread = true
    vim.cmd("normal! G")
  end
end

--- One-line kernel summary for a statusline.
---@return string
function M.status(buf)
  local st = M.get(buf)
  if not st then
    return ""
  end
  local k = st.kernel
  if st.starting then
    return "kernel: starting…"
  elseif not k or not k.ready then
    return "kernel: off"
  end
  local name = k.choice and k.choice.label:gsub("%s*%(.*$", "") or "kernel"
  return name .. ": " .. (k.status == "busy" and "busy" or "idle")
end

-- Cell commands ----------------------------------------------------------------

function M.clear(st)
  local cell = current(st)
  if cell and cell.type == "code" then
    clear_state(cell.state)
    mark_modified(st)
    M.sync(st)
  end
end

function M.clear_all(st)
  M.sync(st)
  for _, cell in ipairs(st.layout) do
    if cell.type == "code" then
      clear_state(cell.state)
    end
  end
  mark_modified(st)
  M.sync(st)
end

---@param where "above"|"below"
---@param kind "code"|"markdown"|"raw"
function M.add_cell(st, where, kind)
  current(st)
  materialize(st)
  local cell = current(st)
  local at = where == "above" and cell.start or cell.stop + 1
  local body = kind == "code" and "" or "# "
  api.nvim_buf_set_lines(st.buf, at, at, false, { ipynb.MARKER[kind], body })
  M.sync(st)
  set_cursor(st, at + 1, #body)
end

function M.delete_cell(st)
  local cell = current(st)
  if not cell then
    return
  end
  if #st.layout == 1 then
    api.nvim_buf_set_lines(st.buf, 0, -1, false, { ipynb.MARKER.code, "" })
    M.sync(st)
    return set_cursor(st, 1)
  end
  local first = math.max(cell.start, 0)
  vim.cmd(("silent %d,%ddelete"):format(first + 1, cell.stop + 1))
  M.sync(st)
  local landed = M.cell_at(st, math.min(first, api.nvim_buf_line_count(st.buf) - 1))
  if landed then
    set_cursor(st, math.min(landed.start + 1, landed.stop))
  end
end

---@param dir 1|-1
function M.move_cell(st, dir)
  current(st)
  materialize(st)
  local cell, index, row = current(st)
  local other = st.layout[index + dir]
  if not other then
    return
  end
  local above, below = cell, other
  if dir < 0 then
    above, below = other, cell
  end
  local top = api.nvim_buf_get_lines(st.buf, above.start, above.stop + 1, false)
  local bottom = api.nvim_buf_get_lines(st.buf, below.start, below.stop + 1, false)
  local offset = row - cell.start
  local col = api.nvim_win_get_cursor(0)[2]
  local lines = vim.list_extend(vim.list_extend({}, bottom), top)
  api.nvim_buf_set_lines(st.buf, above.start, below.stop + 1, false, lines)
  attach(st, above.start, below.state)
  attach(st, above.start + #bottom, above.state)
  M.sync(st)
  local new_start = dir < 0 and above.start or above.start + #bottom
  set_cursor(st, new_start + offset, col)
end

function M.split_cell(st)
  local cell, _, row = current(st)
  if not cell or row <= cell.start then
    return
  end
  api.nvim_buf_set_lines(st.buf, row, row, false, { ipynb.MARKER[cell.type] })
  M.sync(st)
  set_cursor(st, row + 1, api.nvim_win_get_cursor(0)[2])
end

function M.merge_cell(st)
  local cell, index = current(st)
  local below = st.layout[index + 1]
  if not below then
    return
  end
  if below.type ~= cell.type then
    return notify("Only cells of the same type can be merged.", vim.log.levels.WARN)
  end
  api.nvim_buf_set_lines(st.buf, below.start, below.start + 1, false, {})
  M.sync(st)
end

---@param kind? "code"|"markdown"|"raw" defaults to flipping code <-> markdown
function M.set_type(st, kind)
  current(st)
  materialize(st)
  local cell = current(st)
  kind = kind or (cell.type == "code" and "markdown" or "code")
  if kind == cell.type then
    return
  end
  local body = M.body(st, cell)
  local source = ipynb.body_source(cell.type, body)
  local marker = st.lines[cell.start + 1]
  if #body > 0 then
    api.nvim_buf_set_lines(st.buf, cell.start + 1, cell.stop + 1, false, ipynb.body_lines(kind, source))
  end
  -- Rewrite only the tail of the marker so the cell keeps its identity.
  api.nvim_buf_set_text(st.buf, cell.start, 4, cell.start, #marker, { ipynb.MARKER[kind]:sub(5) })
  M.sync(st)
end

---@param dir 1|-1
function M.goto_cell(st, dir)
  local _, index, row = current(st)
  local target
  if dir < 0 and row > math.max(st.layout[index].start + 1, 0) then
    target = st.layout[index]
  else
    target = st.layout[index + dir]
  end
  if target then
    vim.cmd("normal! m'")
    set_cursor(st, math.min(target.start + 1, target.stop))
  end
end

---@param around boolean include the marker line
function M.select_cell(st, around)
  local cell = current(st)
  if not cell then
    return
  end
  local first = math.max(around and cell.start or cell.start + 1, 0)
  if cell.stop < first then
    return
  end
  if vim.fn.mode():find("^[vV\22]") then
    vim.cmd("normal! \27")
  end
  vim.cmd(("normal! %dGV%dG"):format(first + 1, cell.stop + 1))
end

--- Show the whole output of the current cell in a split.
function M.open_output(st)
  local cell = current(st)
  if not cell or cell.type ~= "code" then
    return
  end
  local text = render.plain(cell.state)
  if text == "" then
    return notify("This cell has no text output.")
  end
  local count = select(2, text:gsub("\n", "\n")) + 1
  vim.cmd(("botright %dsplit"):format(math.max(3, math.min(count + 1, math.floor(vim.o.lines / 2)))))
  local buf = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(0, buf)
  vim.bo[buf].bufhidden = "wipe"
  local chan = api.nvim_open_term(buf, {})
  api.nvim_chan_send(chan, (text:gsub("\r?\n", "\r\n")))
  pcall(api.nvim_buf_set_name, buf, "nbx://output/" .. buf)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, desc = "Close output" })
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
end

--- Send images to the terminal again and redraw every output.
function M.redraw(st)
  image.reset_cell_size()
  image.retransmit()
  for _, state in pairs(st.cells) do
    state.dirty = true
  end
  M.sync(st)
end

return M
