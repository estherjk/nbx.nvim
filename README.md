# nbx.nvim

Jupyter notebooks in Neovim, without the browser. Open an `.ipynb` file, edit
cells, run them, and see the output (plots included) under each cell.

The name is "notebook" + [Rex](https://www.superlogical.com/rex): kernel
controls are also exposed as Rex actions, so you can restart or interrupt a
kernel from Rex's command palette or a Rex shortcut. Rex is optional; the
plugin works in any terminal.

```
── markdown ───────────────────────────────────────────
# Sine waves
A short note about what follows.
── [1] ✓ 230ms ────────────────────────────────────────
import numpy as np
np.sin(np.pi / 2)
│ np.float64(1.0)
── [*] ● running ──────────────────────────────────────
train(model)
│ epoch 3/10  loss 0.412
```

## Features

- **Edits the `.ipynb` file itself.** No conversion step and no paired file.
  Outputs, metadata and cell ids are kept, and the file is written the way
  Jupyter writes it, so a notebook you did not change produces no git diff.
- **One Python buffer.** Your language server, completion, treesitter and
  motions work across cells. Markdown cells are stored as comments with the
  `# ` hidden and markdown styling applied.
- **Output under each cell**: streamed stdout/stderr, results, coloured
  tracebacks, progress bars, `input()` prompts, and inline images in terminals
  that speak the kitty graphics protocol (Rex, Ghostty, kitty).
- **Kernels without setup.** Uses the nearest `.venv`, offers to install
  `ipykernel` if it is missing, and can fall back to a temporary kernel through
  `uv`. Installed kernelspecs work too.
- **Rex actions** for restart, interrupt, run all, kernel picker and kernel log.

Scope: Python kernels, local only. No ipywidgets, no remote Jupyter servers.

## Requirements

- Neovim 0.10+ (0.11+ recommended)
- [uv](https://docs.astral.sh/uv/) (recommended), or Python 3.9+ with
  `jupyter_client` installed
- Optional: ImageMagick for JPEG, GIF and SVG outputs (PNG needs nothing)

Run `:checkhealth nbx` to see what was found.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "estherjk/nbx.nvim",
  lazy = false, -- only registers the *.ipynb handlers; the rest loads on demand
  opts = {},
}
```

To show the kernel in lualine:

```lua
{
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, {
      function() return require("nbx").status() end,
      cond = function() return package.loaded["nbx.notebook"] ~= nil and require("nbx").is_notebook() end,
    })
  end,
}
```

## Usage

Open any `.ipynb` file. A new file name gives you an empty notebook.

| Key | Action |
| --- | --- |
| `<S-CR>` | Run cell and move to the next (adds one at the end) |
| `<C-CR>` | Run cell |
| `<localleader>rr` / `ra` / `rk` / `rj` | Run cell / all / above / this and below |
| `<localleader>a` / `A` | Add code cell below / above |
| `<localleader>M` | Add markdown cell below |
| `<localleader>m` | Toggle cell between code and markdown |
| `<localleader>d` | Delete cell |
| `<localleader>J` / `K` | Move cell down / up |
| `<localleader>s` / `j` | Split cell at cursor / merge with the cell below |
| `<localleader>o` | Open the full output in a split |
| `<localleader>c` / `C` | Clear output of cell / all cells |
| `<localleader>i` | Interrupt kernel |
| `<localleader>R` | Restart kernel |
| `<localleader>k` | Select kernel |
| `<localleader>l` | Show kernel log |
| `]c` / `[c` | Next / previous cell |
| `ic` / `ac` | Text objects: cell contents / whole cell |

Everything is also available as `:Nbx <action>` (`:Nbx <Tab>` lists them),
including `restart_run_all`, `shutdown` and `redraw`.

Cells are separated by marker lines, drawn as borders:

```python
# %%                 code cell
# %% [markdown]      markdown cell
# %% [raw]           raw cell
```

You can type a marker yourself to start a new cell, and ordinary edits (`dd`,
`p`, undo, visual moves) work on cells like on any text. The cell commands
above keep a cell's outputs attached when moving it.

`:w` saves source and outputs. If the file changes on disk (a `git checkout`,
say) it is reloaded when the buffer has no unsaved changes.

### Kernels

The first time you run a cell, nbx picks, in order: the kernel you chose
earlier for this notebook, the nearest `.venv` or `venv` at or above the
notebook, the kernelspec named in the notebook if it is installed, a temporary
`uv` kernel, then `python3`. `<localleader>k` lists all of them.

The kernel's working directory is the notebook's directory. The kernel stops
when the buffer is closed or Neovim exits.

## Rex

Add to `~/.config/rex/init.lua`, then run `rex config reload`:

```lua
local nbx = dofile(os.getenv("HOME") .. "/.local/share/nvim/lazy/nbx.nvim/rex/nbx.lua")
nbx.setup({
  keys = {
    ["ctrl+alt+r"] = "restart",
    ["ctrl+alt+shift+r"] = "restart_run_all",
    ["ctrl+alt+i"] = "interrupt",
    ["ctrl+alt+k"] = "kernel",
    ["ctrl+alt+l"] = "log",
  },
})
```

This adds "Notebook: …" actions to the command palette: restart, restart and
run all, interrupt, run all, run cell, clear all outputs, select kernel, show
kernel log, shut down, status. They act on the Neovim in the focused pane. The
kernel log opens in a Rex split below the editor.

The same actions work from a shell through `bin/nbx`:

```sh
nbx restart            # the Neovim in this Rex pane, or the most recent one
nbx interrupt --block "$REX_BLOCK"
nbx status
```

## Configuration

Defaults:

```lua
require("nbx").setup({
  kernel = {
    sidecar_cmd = nil, -- e.g. { "python3", "/path/to/nbx_kernel.py" }
    timeout = 60,      -- seconds to wait for a kernel to start
    autostart = false, -- start a kernel when a notebook is opened
  },
  output = {
    max_lines = 30,    -- text lines shown per cell; the rest is one keypress away
  },
  images = {
    enabled = "auto",  -- true / false / "auto"
    max_width = 80,    -- columns
    max_height = 24,   -- rows
  },
  keys = {
    run_and_next = { "<S-CR>", mode = { "n", "i" } },
    run = { "<C-CR>", mode = { "n", "i" } },
    restart = "<localleader>R",
    -- ... one entry per action; set an entry to false to drop it,
    -- or `keys = false` to define none.
  },
})
```

Highlight groups start with `Nbx` (`NbxCellBorder`, `NbxCellLabel`,
`NbxOutput`, `NbxStderr`, `NbxMarkdown`, `NbxMdH1`, …) and link to standard
groups by default.

## Good to know

- Formatting on save is turned off for notebook buffers, because formatters
  see the `.ipynb` name and expect JSON.
- Linters do not know the buffer is a notebook, so expect notes such as
  "useless expression" on a cell's last line.
- A code line that starts with `# %%` begins a new cell.
- Images are sent to the terminal directly. They do not work inside tmux or
  over ssh. After the terminal loses them (a detach, for example), run
  `:Nbx redraw`.
- Whole-number floats inside JSON outputs or metadata (`1.0`) are written back
  as integers (`1`).

## Development

```sh
make test     # needs plenary.nvim (cloned into .deps if not found) and uv
make lint     # stylua + ruff
```

Layout: `lua/nbx/` is the plugin, `python/nbx_kernel.py` is the kernel sidecar
(JSON lines over stdio, run through `uv run --script`), `rex/nbx.lua` defines
the Rex actions and `bin/nbx` is the CLI they call.

## License

MIT
