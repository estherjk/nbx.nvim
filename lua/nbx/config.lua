local M = {}

---@class nbx.Config
M.defaults = {
  kernel = {
    -- Command that starts the sidecar. nil picks `uv run --script` when uv is
    -- installed and `python3` (which then needs jupyter_client) otherwise.
    sidecar_cmd = nil,
    -- Seconds to wait for a kernel to come up.
    timeout = 60,
    -- Start a kernel as soon as a notebook is opened instead of on first run.
    autostart = false,
  },
  output = {
    -- Lines of text shown under a cell before the rest is folded away.
    max_lines = 30,
  },
  images = {
    -- "auto" enables inline images in terminals known to speak the kitty
    -- graphics protocol with unicode placeholders (Rex, Ghostty, kitty).
    enabled = "auto",
    max_width = 80, -- columns
    max_height = 24, -- rows
  },
  -- Buffer-local mappings. Set an entry to false to drop it, or `keys = false`
  -- to define none at all.
  keys = {
    run_and_next = { "<S-CR>", mode = { "n", "i" } },
    run = { "<C-CR>", mode = { "n", "i" } },
    run_cell = "<localleader>rr",
    run_all = "<localleader>ra",
    run_above = "<localleader>rk",
    run_below = "<localleader>rj",
    add_below = "<localleader>a",
    add_above = "<localleader>A",
    add_markdown = "<localleader>M",
    toggle_type = "<localleader>m",
    delete = "<localleader>d",
    move_down = "<localleader>J",
    move_up = "<localleader>K",
    split = "<localleader>s",
    merge = "<localleader>j",
    open_output = "<localleader>o",
    clear = "<localleader>c",
    clear_all = "<localleader>C",
    interrupt = "<localleader>i",
    restart = "<localleader>R",
    kernel = "<localleader>k",
    log = "<localleader>l",
    next_cell = "]c",
    prev_cell = "[c",
    inner_cell = { "ic", mode = { "o", "x" } },
    around_cell = { "ac", mode = { "o", "x" } },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if opts.keys == false then
    M.options.keys = {}
  end
  return M.options
end

return M
