.PHONY: test lint format deps

PLENARY := .deps/plenary.nvim

deps:
	@test -d $(PLENARY) || test -d "$${PLENARY_DIR:-$$HOME/.local/share/nvim/lazy/plenary.nvim}" || \
		git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 300000 }"

lint:
	stylua --check lua plugin tests rex
	ruff check python
	ruff format --check python

format:
	stylua lua plugin tests rex
	ruff format python
