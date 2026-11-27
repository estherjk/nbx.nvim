if vim.g.loaded_nbx then
  return
end
vim.g.loaded_nbx = true

-- Notebooks are edited as Python, so language servers and treesitter treat
-- them as such.
vim.filetype.add({ extension = { ipynb = "python" } })

local group = vim.api.nvim_create_augroup("nbx", { clear = true })

vim.api.nvim_create_autocmd({ "BufReadCmd", "BufNewFile" }, {
  group = group,
  pattern = "*.ipynb",
  nested = true,
  callback = function(ev)
    if ev.event == "BufNewFile" and require("nbx.notebook").states[ev.buf] then
      return
    end
    require("nbx.notebook").read(ev.buf, ev.match)
  end,
})

vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = group,
  pattern = "*.ipynb",
  nested = true,
  callback = function(ev)
    require("nbx.notebook").write(ev.buf, ev.match)
  end,
})

vim.api.nvim_create_user_command("Nbx", function(cmd)
  local name = cmd.fargs[1] or "status"
  if name == "status" then
    local status = require("nbx").status()
    vim.notify(status ~= "" and status or "Not a notebook buffer.", vim.log.levels.INFO, { title = "nbx" })
    return
  end
  local ok, err = require("nbx").run(name, nil, cmd.fargs[2])
  if not ok then
    vim.notify(err, vim.log.levels.ERROR, { title = "nbx" })
  end
end, {
  nargs = "*",
  desc = "Notebook commands",
  complete = function(lead, line)
    if #vim.split(line, "%s+") > 2 then
      return vim.tbl_filter(function(kind)
        return kind:find(lead, 1, true) == 1
      end, { "code", "markdown", "raw" })
    end
    local names = vim.tbl_keys(require("nbx").actions())
    names[#names + 1] = "status"
    table.sort(names)
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, names)
  end,
})
