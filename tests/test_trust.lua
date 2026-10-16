vim.opt.rtp:prepend(vim.fn.getcwd())
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. '/project/src', 'p')
vim.fn.mkdir(tmp .. '/state', 'p')
vim.fn.mkdir(tmp .. '/empty', 'p')
tmp = vim.uv.fs_realpath(tmp)
local root, path = tmp .. '/project', tmp .. '/project/.farwork.json'
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'state' and tmp .. '/state' or stdpath(kind) end
local contents = vim.json.encode({ host = 'fixture', remote = '/workspace', lsp = false })
vim.fn.writefile({ contents }, path)
require('farwork').setup({ state_dir = tmp .. '/state' })
local projects = require('farwork.projects')
vim.notify = function() end
vim.cmd.cd(vim.fn.fnameescape(root .. '/src'))
vim.ui.select = function(_, _, callback) callback('Cancel') end
vim.cmd.FarworkTrust()
assert(vim.fn.filereadable(tmp .. '/state/trust') == 0, 'Cancel must not grant trust')
vim.ui.select = function(_, _, callback) callback('Trust this config') end
vim.cmd.FarworkTrust()
assert(projects.read(root).host == 'fixture')
vim.cmd.FarworkTrust({ bang = true })
local prompts = 0
vim.fn.confirm = function() prompts = prompts + 1; return 1 end
assert(not pcall(projects.read, root) and prompts == 1, 'Revocation must require review')
vim.secure.trust({ action = 'deny', path = path })
vim.cmd.FarworkTrust()
assert(projects.read(root).host == 'fixture', 'Explicit review can reconsider a denial')
projects.remember(root)
local roots = vim.json.decode(table.concat(vim.fn.readfile(tmp .. '/state/project-roots.json'), '\n'))
assert(#roots == 1 and roots[1] == root, 'Remember paths only')
vim.fn.writefile({ vim.json.encode({ host = 'changed', remote = '/workspace', lsp = false }) }, path)
vim.cmd.enew()
vim.cmd.cd(vim.fn.fnameescape(tmp .. '/empty'))
vim.system = function() error('Must not connect using changed untrusted contents') end
vim.ui.select = function(items, opts, callback)
  assert(#items == 1 and items[1] == root)
  assert(opts.format_item(root):find('.farwork.json', 1, true))
  callback(root)
end
vim.cmd.FarworkProjects()
assert(prompts == 2 and not require('farwork').status().connecting)
assert(vim.fn.getcwd() == tmp .. '/empty', 'Rejected config must preserve cwd')
vim.fn.delete(path)
assert(next(projects.known_roots()) == nil, 'Removed marker hides stale registry entry')
vim.cmd.cd('/')
vim.fn.delete(tmp, 'rf')
print('PASS: trust approval/cancel/revoke/denial and changed config from outside project')
vim.cmd('qa!')
