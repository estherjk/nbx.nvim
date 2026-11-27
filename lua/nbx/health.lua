local M = {}

function M.check()
  local health = vim.health
  health.start("nbx")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end

  local kernel = require("nbx.kernel")
  local cmd = kernel.sidecar_cmd()
  if vim.fn.executable(cmd[1]) == 1 then
    health.ok("sidecar command: " .. table.concat(cmd, " "))
    if cmd[1] ~= "uv" then
      local result = vim.system({ cmd[1], "-c", "import jupyter_client" }):wait(10000)
      if result.code == 0 then
        health.ok("jupyter_client is importable")
      else
        health.error("jupyter_client is missing for " .. cmd[1], {
          "Install uv (https://docs.astral.sh/uv/) and nbx will manage it for you,",
          "or run: " .. cmd[1] .. " -m pip install jupyter_client",
        })
      end
    end
  else
    health.error("cannot run the sidecar: `" .. cmd[1] .. "` not found", {
      "Install uv (https://docs.astral.sh/uv/) or Python 3.9+ with jupyter_client.",
    })
  end

  local dir = vim.fn.expand("%:p:h")
  local choice = kernel.default_choice(dir ~= "" and dir or vim.fn.getcwd())
  if choice then
    health.info("default kernel from here: " .. choice.label)
    if choice.python then
      local result = vim.system({ choice.python, "-c", "import ipykernel" }):wait(10000)
      if result.code == 0 then
        health.ok("ipykernel is installed in " .. choice.python)
      else
        health.warn("ipykernel is not installed in " .. choice.python, {
          "nbx offers to install it the first time you run a cell.",
        })
      end
    end
  else
    health.warn("no Python interpreter found for kernels")
  end

  local image = require("nbx.image")
  if image.supported() then
    local w, h = image.cell_size()
    health.ok(("inline images enabled (cell size %dx%d px)"):format(w, h))
  else
    health.info(
      "inline images are off: needs Rex, Ghostty or kitty (not tmux or ssh). Force with images.enabled = true."
    )
  end
  if vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1 then
    health.ok("ImageMagick found (JPEG, GIF and SVG outputs)")
  else
    health.info("ImageMagick not found: only PNG outputs are shown inline")
  end

  if vim.env.REX_BLOCK then
    health.ok("running inside Rex (" .. vim.env.REX_BLOCK .. ")")
  else
    health.info("not running inside Rex; Rex actions are unavailable, everything else works")
  end
end

return M
