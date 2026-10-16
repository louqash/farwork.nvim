local M = {}

function M.run(command, opts, callback, timeout)
  timeout = timeout or require("farwork.config").options.operation_timeout
  opts = vim.tbl_extend("force", opts or {}, {
    timeout = (timeout + 5) * 1000,
    env = { FARWORK_TIMEOUT = tostring(timeout) },
  })
  return vim.system(command, opts, callback)
end

return M
