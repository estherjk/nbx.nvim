-- Client for the Python sidecar (python/nbx_kernel.py), plus kernel discovery.
local config = require("nbx.config")

local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local LAUNCH = { "-m", "ipykernel_launcher", "-f", "{connection_file}" }

---@return string[]
function M.sidecar_cmd()
  local cmd = config.options.kernel.sidecar_cmd
  if type(cmd) == "function" then
    cmd = cmd()
  end
  if cmd then
    return cmd
  end
  local script = M.root .. "/python/nbx_kernel.py"
  if vim.fn.executable("uv") == 1 then
    return { "uv", "run", "--quiet", "--script", script }
  end
  return { "python3", script }
end

-- Discovery ----------------------------------------------------------------

---@class nbx.KernelChoice
---@field kind "venv"|"python"|"spec"|"uv"
---@field label string
---@field cwd? string uv only: the project directory whose environment to use
---@field python? string
---@field name? string

local function python_in(prefix)
  local python = prefix .. "/bin/python"
  if vim.fn.executable(python) == 1 then
    return python
  end
end

local PROJECT_FILES = { "pyproject.toml", "uv.lock" }

--- The Python environment a notebook in `dir` belongs to: the nearest
--- virtualenv, or the nearest uv project that has not been synced yet. The
--- search stops at the repository root and never leaves the home directory,
--- so an unrelated environment further up is not picked up by accident.
---@param dir string
---@return nbx.KernelChoice?
function M.find_env(dir)
  local dirs = { dir }
  for parent in vim.fs.parents(dir) do
    dirs[#dirs + 1] = parent
  end
  local home = vim.uv.os_homedir()
  local has_uv = vim.fn.executable("uv") == 1
  for _, d in ipairs(dirs) do
    if d == home then
      break
    end
    local name = vim.fn.fnamemodify(d, ":t")
    for _, venv in ipairs({ ".venv", "venv" }) do
      local python = python_in(d .. "/" .. venv)
      if python then
        return { kind = "venv", python = python, label = name .. "/" .. venv }
      end
    end
    if has_uv then
      for _, file in ipairs(PROJECT_FILES) do
        if vim.uv.fs_stat(d .. "/" .. file) then
          return { kind = "uv", cwd = d, label = "uv (" .. name .. " project)" }
        end
      end
    end
    if vim.uv.fs_stat(d .. "/.git") then
      break
    end
  end
end

---@param dir string
---@param specs? table<string, {display_name: string}>
---@return nbx.KernelChoice[]
function M.candidates(dir, specs)
  local list, seen = {}, {}
  local function add(choice)
    local key = choice.python or (choice.kind .. ":" .. (choice.name or choice.cwd or ""))
    if choice and not seen[key] then
      seen[key] = true
      list[#list + 1] = choice
    end
  end
  local env = M.find_env(dir)
  if env then
    add(env)
  end
  for _, var in ipairs({ "VIRTUAL_ENV", "CONDA_PREFIX" }) do
    local prefix = vim.env[var]
    local python = prefix and python_in(prefix)
    if python then
      add({ kind = "venv", python = python, label = vim.fn.fnamemodify(prefix, ":~") .. " ($" .. var .. ")" })
    end
  end
  local names = vim.tbl_keys(specs or {})
  table.sort(names)
  for _, name in ipairs(names) do
    add({ kind = "spec", name = name, label = specs[name].display_name .. " (kernelspec " .. name .. ")" })
  end
  if vim.fn.executable("uv") == 1 then
    add({ kind = "uv", label = "uv (temporary environment with ipykernel)" })
  end
  local system = vim.fn.exepath("python3")
  if system ~= "" then
    add({ kind = "python", python = system, label = vim.fn.fnamemodify(system, ":~") })
  end
  return list
end

--- The kernel to use when the user has not picked one.
---@param dir string
---@param metadata_name? string kernelspec name stored in the notebook
---@param specs? table
---@return nbx.KernelChoice?
function M.default_choice(dir, metadata_name, specs)
  local env = M.find_env(dir)
  if env then
    return env
  end
  if metadata_name and specs and specs[metadata_name] then
    return { kind = "spec", name = metadata_name, label = specs[metadata_name].display_name }
  end
  local list = M.candidates(dir, specs)
  for _, kind in ipairs({ "venv", "uv", "spec", "python" }) do
    for _, choice in ipairs(list) do
      if choice.kind == kind then
        return choice
      end
    end
  end
end

--- Remembered choices, keyed by notebook path.
local function store_path()
  return vim.fn.stdpath("state") .. "/nbx/kernels.json"
end

function M.load_choice(path)
  local f = io.open(store_path(), "r")
  if not f then
    return nil
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  local choice = ok and type(data) == "table" and data[path] or nil
  if type(choice) ~= "table" or not choice.kind then
    return nil
  end
  if choice.python and vim.fn.executable(choice.python) ~= 1 then
    return nil
  end
  return choice
end

function M.save_choice(path, choice)
  local data = {}
  local f = io.open(store_path(), "r")
  if f then
    local ok, decoded = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(decoded) == "table" then
      data = decoded
    end
  end
  data[path] = choice
  vim.fn.mkdir(vim.fn.fnamemodify(store_path(), ":h"), "p")
  f = io.open(store_path(), "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end
end

---@param choice nbx.KernelChoice
---@return table params for the sidecar's start request
function M.start_params(choice, cwd)
  local params = { cwd = cwd, display_name = choice.label, timeout = config.options.kernel.timeout }
  local path = vim.env.PATH or ""
  if choice.kind == "spec" then
    params.name = choice.name
    params.env = { PATH = path }
  elseif choice.kind == "uv" then
    -- Runs in the notebook's directory; --project points uv at the environment.
    local uv_run = { "uv", "run" }
    if choice.cwd then
      vim.list_extend(uv_run, { "--project", choice.cwd })
    end
    params.argv = vim.list_extend(vim.list_extend(uv_run, { "--with", "ipykernel", "python" }), LAUNCH)
    params.env = { PATH = path }
    params.unset = { "VIRTUAL_ENV" }
  else
    local bin = vim.fn.fnamemodify(choice.python, ":h")
    params.argv = vim.list_extend({ choice.python }, LAUNCH)
    params.env = { PATH = bin .. ":" .. path }
    if choice.kind == "venv" then
      params.env.VIRTUAL_ENV = vim.fn.fnamemodify(bin, ":h")
    else
      params.unset = { "VIRTUAL_ENV" }
    end
  end
  return params
end

--- Does this interpreter have ipykernel?
---@param python string
---@param cb fun(ok: boolean)
function M.has_ipykernel(python, cb)
  vim.system({ python, "-c", "import ipykernel" }, { text = true }, function(result)
    vim.schedule(function()
      cb(result.code == 0)
    end)
  end)
end

---@param python string
---@param cb fun(ok: boolean, output: string)
function M.install_ipykernel(python, cb)
  local cmd
  if vim.fn.executable("uv") == 1 then
    cmd = { "uv", "pip", "install", "--python", python, "ipykernel" }
  else
    cmd = { python, "-m", "pip", "install", "ipykernel" }
  end
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      cb(result.code == 0, (result.stderr or "") .. (result.stdout or ""))
    end)
  end)
end

-- Sidecar process ------------------------------------------------------------

---@class nbx.Kernel
---@field proc? vim.SystemObj
---@field ready boolean a kernel is up and accepting code
---@field starting boolean
---@field status string
---@field choice? nbx.KernelChoice
---@field log_path string
local Kernel = {}
Kernel.__index = Kernel

---@param opts {name: string, cwd: string, on_event: fun(ev: table), on_exit: fun(code: integer)}
---@return nbx.Kernel
function M.new(opts)
  local dir = vim.fn.stdpath("log") .. "/nbx"
  vim.fn.mkdir(dir, "p")
  local self = setmetatable({
    opts = opts,
    ready = false,
    starting = false,
    status = "none",
    pending = {},
    seq = 0,
    exec_seq = 0,
    partial = "",
    log_path = dir .. "/" .. opts.name:gsub("[^%w%.%-_]", "_") .. ".log",
  }, Kernel)
  return self
end

function Kernel:log(text)
  local f = io.open(self.log_path, "a")
  if f then
    f:write(text)
    f:close()
  end
end

function Kernel:alive()
  return self.proc ~= nil and not self.exited
end

function Kernel:spawn()
  if self:alive() then
    return true
  end
  local cmd = M.sidecar_cmd()
  self.exited = false
  self.partial = ""
  self:log(("\n--- %s  sidecar: %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), table.concat(cmd, " ")))
  local ok, proc = pcall(vim.system, cmd, {
    stdin = true,
    text = true,
    cwd = self.opts.cwd,
    stdout = function(_, data)
      if data then
        self:_on_stdout(data)
      end
    end,
    stderr = function(_, data)
      if data then
        self:log(data)
      end
    end,
  }, function(result)
    self.exited = true
    self.ready = false
    self.starting = false
    self.status = "dead"
    vim.schedule(function()
      for id, cb in pairs(self.pending) do
        self.pending[id] = nil
        cb("the kernel sidecar exited")
      end
      self.opts.on_exit(result.code)
    end)
  end)
  if not ok then
    self.exited = true
    return false, tostring(proc)
  end
  self.proc = proc
  return true
end

function Kernel:_on_stdout(data)
  local text = self.partial .. data
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      break
    end
    local line = text:sub(start, nl - 1)
    start = nl + 1
    if line ~= "" then
      vim.schedule(function()
        local ok, msg = pcall(vim.json.decode, line)
        if ok and type(msg) == "table" then
          self:_dispatch(msg)
        else
          self:log("[nbx] unreadable line from sidecar: " .. line:sub(1, 200) .. "\n")
        end
      end)
    end
  end
  self.partial = text:sub(start)
end

function Kernel:_dispatch(msg)
  if msg.event then
    if msg.event == "status" and type(msg.state) == "string" then
      self.status = msg.state
    end
    self.opts.on_event(msg)
    return
  end
  local cb = msg.id and self.pending[msg.id]
  if cb then
    self.pending[msg.id] = nil
    local err = msg.error
    if err == vim.NIL then
      err = nil
    end
    cb(err, msg.result)
  end
end

---@param method string
---@param params? table
---@param cb? fun(err?: string, result?: any)
function Kernel:request(method, params, cb)
  if not self:alive() then
    if cb then
      cb("the kernel sidecar is not running")
    end
    return
  end
  self.seq = self.seq + 1
  self.pending[self.seq] = cb or function() end
  if params == nil or next(params) == nil then
    params = vim.empty_dict()
  end
  self.proc:write(vim.json.encode({ id = self.seq, method = method, params = params }) .. "\n")
end

--- Start (or replace) the kernel behind this sidecar.
---@param choice nbx.KernelChoice
---@param cb fun(err?: string, info?: table)
function Kernel:start(choice, cb)
  local ok, err = self:spawn()
  if not ok then
    return cb("could not start the sidecar: " .. tostring(err))
  end
  self.ready = false
  self.starting = true
  self.status = "starting"
  self.choice = choice
  self:log(("[nbx] starting kernel: %s\n"):format(choice.label))
  self:request("start", M.start_params(choice, self.opts.cwd), function(e, info)
    self.starting = false
    self.ready = e == nil
    if e then
      self.status = "dead"
    end
    cb(e, info)
  end)
end

---@param code string
---@return string exec_id
function Kernel:execute(code)
  self.exec_seq = self.exec_seq + 1
  local id = tostring(self.exec_seq)
  self:request("execute", { code = code, exec_id = id })
  return id
end

--- Shut the kernel down and let the sidecar exit.
function Kernel:stop()
  self.ready = false
  local proc = self.proc
  if not proc or self.exited then
    return
  end
  pcall(proc.write, proc, nil) -- closing stdin tells the sidecar to clean up
  local timer = vim.uv.new_timer()
  if timer then
    timer:start(3000, 0, function()
      timer:close()
      if not self.exited then
        pcall(proc.kill, proc, 15)
      end
    end)
  end
end

return M
