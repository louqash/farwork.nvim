.PHONY: test

test:
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_remote_git.py
	nvim --headless -u NONE -i NONE -l tests/test_setup.lua
	nvim --headless -u NONE -i NONE -l tests/test_upload.lua
	nvim --headless -u NONE -i NONE -l tests/test_remote.lua
