local M = {}

function M.switch_source_header(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local selected
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.initialized and not client:is_stopped() then
      if client.name == "remote_clangd" then selected = client; break end
      if client.name == "clangd" and not require("farwork.remote").owns_lsp_buffer(bufnr) then selected = client end
    end
  end
  if not selected then
    vim.notify("Farwork: No clangd attached to this buffer", vim.log.levels.WARN)
    return
  end
  return selected:request("textDocument/switchSourceHeader",
    vim.lsp.util.make_text_document_params(bufnr), function(err, uri)
      if err then
        vim.notify(err.message, vim.log.levels.ERROR)
      elseif uri and uri ~= "" then
        vim.cmd.edit(vim.fn.fnameescape(vim.uri_to_fname(uri)))
      end
    end, bufnr)
end

function M.setup(opts)
  local group = vim.api.nvim_create_augroup("FarworkLspKeymaps", { clear = true })
  if not opts.keymaps then return end
  local function attach(client, bufnr)
    if not client or (client.name ~= "clangd" and client.name ~= "remote_clangd") then return end
    vim.keymap.set("n", "<leader>ch", function() M.switch_source_header(bufnr) end,
      { buffer = bufnr, desc = "Switch C/C++ header/source" })
  end
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args) attach(vim.lsp.get_client_by_id(args.data.client_id), args.buf) end,
  })
  for _, client in ipairs(vim.lsp.get_clients()) do
    for bufnr in pairs(client.attached_buffers) do attach(client, bufnr) end
  end
end

return M
