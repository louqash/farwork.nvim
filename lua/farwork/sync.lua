-- Recover buffers whose native LSP on_lines subscription stopped during a
-- disconnect. Full-text synchronization also avoids stale incremental baselines.
local M = {}

function M.recover(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if vim.lsp.util.buf_versions[buf] == tick then return end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "remote_clangd" })) do
    if client.initialized and not client:is_stopped() and client.flags.allow_incremental_sync == false then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local ending = vim.bo[buf].fileformat == "dos" and "\r\n"
        or (vim.bo[buf].fileformat == "mac" and "\r" or "\n")
      local text = table.concat(lines, ending) .. (vim.bo[buf].eol and ending or "")
      if client:notify("textDocument/didChange", {
        textDocument = { uri = vim.uri_from_bufnr(buf), version = tick },
        contentChanges = { { text = text } },
      }) then
        vim.lsp.util.buf_versions[buf] = tick
      end
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("RemoteWorkspaceRemoteSync", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "BufWritePost", "BufEnter" }, {
    group = group,
    callback = function(event) M.recover(event.buf) end,
  })
end

return M
