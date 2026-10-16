.PHONY: test

test:
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_transport.py
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_remote_git.py
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_remote_check.py
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_remote_recovery.py
	nvim --headless -n -u NONE -i NONE -l tests/test_setup.lua
	nvim --headless -n -u NONE -i NONE -l tests/test_lsp.lua
	nvim --headless -n -u NONE -i NONE -l tests/test_check.lua
	nvim --headless -n -u NONE -i NONE -l tests/test_recovery.lua
	nvim --headless -n -u NONE -i NONE -l tests/test_projects.lua
	nvim --headless -n -u NONE -i NONE -l tests/test_remote_projects.lua
	nvim --headless -n -u NONE -i NONE -l tests/test_upload.lua
	nvim --headless -n -u NONE -i NONE -l tests/test_remote.lua
