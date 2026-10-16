vim.opt.rtp:prepend(vim.fn.getcwd())
local tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
require('farwork').setup({ cache_dir = tmp, state_dir = tmp })
assert(vim.fn.exists(':RemoteDoctor') == 2)
local recovery = require('farwork.recovery')
local upload = require('farwork.upload')
local releases, applies, held = {}, 0, false
upload.hold = function()
  assert(not held); held = true
  return function(resume) held = false; table.insert(releases, resume) end
end
local report = { current={head='old',branch='topic'}, target={head='new',branch='topic'},
 paths={{path='source',state='pending_upload'}}, reasons={}, allowed=true, aligned=false }
vim.system = function(cmd, _, cb)
  assert(held, 'Uploads must remain held for both inspection and repair')
  if cmd[3] == 'apply' then applies = applies + 1; cb({code=0,stdout=vim.json.encode({backup='refs/test'})})
  else cb({code=0,stdout=vim.json.encode(report)}) end
  return {}
end
vim.ui.select = function(items,_,callback) callback(items[1]) end
recovery.start(tmp,{host='test',remote='/remote'})
assert(vim.wait(1000,function() return #releases==1 end))
assert(releases[1]==false and applies==0, 'Cancel must not repair or resume')
vim.ui.select = function(items,_,callback) callback(items[2]) end
recovery.start(tmp,{host='test',remote='/remote'})
assert(vim.wait(1000,function() return #releases==2 end))
assert(releases[2]==true and applies==1, 'Confirmed repair resumes only after success')
report.allowed=false; report.reasons={'Conflicting remote edit\nKeep this file'}
vim.ui.select = function() error('Blocked recovery must not offer an action') end
recovery.start(tmp,{host='test',remote='/remote'})
assert(vim.wait(1000,function() return #releases==3 end))
assert(releases[3]==false and applies==1)
report.allowed=true; report.reasons={}
vim.ui.select = function(items,_,callback) callback(items[2]) end
vim.system = function(cmd,_,cb)
  if cmd[3]=='apply' then cb({code=1,stderr='Remote changed during review\nRun doctor again'})
  else cb({code=0,stdout=vim.json.encode(report)}) end
  return {}
end
recovery.start(tmp,{host='test',remote='/remote'})
assert(vim.wait(1000,function() return #releases==4 end))
assert(releases[4]==false and not held, 'Repair failure must keep queue stopped but release review lock')
vim.fn.delete(tmp,'rf')
print('PASS: recovery command, cancellation, confirmation, blocking, queue hold')
vim.cmd('qa!')
