vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("farwork")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = vim.uv.fs_realpath(tmp)
plugin.setup({ cache_dir = tmp })
assert(vim.fn.exists(":FarworkCheck") == 2)
local checker = require("farwork.check")
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, tmp .. "/code.cpp")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved edit" })
local applied, callback, output_buf = false, nil, nil
local killed = false
vim.system = function(cmd, opts, done)
  if cmd[3] == "apply" then
    applied = true
    return { wait = function() return { code = 1, stderr = "Local file differs\nDetails on another line\n" } end }
  end
  assert(cmd[3] == "run")
  output_buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[output_buf].buftype == "nofile", "Split must open before starting the process")
  local directory = cmd[7]
  vim.fn.writefile({ vim.json.encode({ code = 1, output = "formatted\nsecond line\n", changes = {{ path = "code.cpp" }} }) }, directory .. "/result.json")
  callback = done
  opts.stderr(nil, "hook running…\n")
  return { kill = function() killed = true end }
end
checker.start(tmp, { host = "test", environment = "" }, false)
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n"):find("hook running", 1, true)
end), "Live progress must display before completion")
callback({ code = 0 })
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n"):find("Fixes were NOT applied", 1, true)
end))
assert(not applied and vim.bo[buf].modified)
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved edit")
vim.bo[buf].modified = false
checker.start(tmp, { host = "test", environment = "" }, false)
callback({ code = 0 })
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n"):find("Details on another line", 1, true)
end), "Multiline apply failures must render without crashing")
assert(applied)
applied = false
checker.start(tmp, { host = "test", environment = "" }, false)
vim.cmd.FarworkCheckStop()
assert(killed)
callback({ code = 0 })
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n"):find("Check cancelled", 1, true)
end))
assert(not applied, "Cancelled check must not apply even a successful late result")
vim.fn.delete(tmp, "rf")
print("PASS: immediate split, live progress, unsaved buffers, multiline error regression")
vim.cmd("qa!")
