local fn = vim.fn
local uv = vim.loop
local tinsert = table.insert
local Task = require('neopm.task')
local Git = require('neopm.git')
local UpdateView = require('neopm.updateview')

---@type NeopmState
local state = require('neopm.state')

local Impl = {}

--- Finds plugin patches
local function get_patches()
  -- reset current patches
  for _, plug in ipairs(state.by_order) do
    plug.patch = nil
  end

  local dir = uv.fs_opendir(state.patch_dir, nil, 64)
  if not dir then return end
  while true do
    local ents = dir:readdir()
    if not ents then
      dir:closedir()
      break
    end

    for _, ent in ipairs(ents) do
      if ent.type == 'file' then
        local base = ent.name:match('^(.*)%.diff$')
        if base then
          local plug = state.by_dir[base]
          if plug then
            plug.patch = state.patch_dir..'/'..ent.name
          end
        end
      end
    end
  end
end

--- Install plugin task
---@param plug NeopmPlug
---@param buf NeopmUpdateView
---@return nil|string err
local function task_install(plug, buf)
  buf:set(plug, 'clone...')
  if Git.clone(plug, function(status)
    buf:set(plug, 'clone: '..status)
  end) ~= 0 then
    return 'clone: FAIL (non-zero exit code)'
  end

  return Git.patch(plug)
end

--- Update plugin task
---@param plug NeopmPlug
---@param buf NeopmUpdateView
---@return nil|string err
local function task_update(plug, buf)
  local err = Git.patch_revert(plug)
  if err then return err end

  buf:set(plug, 'fetch...')
  if Git.fetch(plug, function(status)
    buf:set(plug, 'fetch: '..status)
  end) ~= 0 then
    return 'fetch: FAIL (non-zero exit code)'
  end

  buf:set(plug, 'merge...')
  local branch = Git.origin_branch(plug.path)
  if not branch then
    return 'merge: FAIL (could not get origin branch)'
  end

  if Git.checkout(plug, branch) ~= 0 then
    return 'merge: FAIL (checkout: non-zero exit code)'
  end

  if Git.merge(plug, 'origin/'..branch) ~= 0 then
    return 'merge: FAIL (merge: non-zero exit code)'
  end

  err = Git.patch(plug)
  if err then return err end

  local log = Git.log(plug, 'HEAD@{1}..')
  if log then
    local new = #log
    if new == 0 then
      return 'Up to date'
    elseif new == 1 then
      return 'New 1 commit'
    else
      return 'New '..new..' commits'
    end
  end
end

--- Start install/update
---@param update boolean  true for update, or false for install only
---@return boolean success
local function start(update)
  local buf = UpdateView.new()
  if update then
    buf:global('Update...')
  else
    buf:global('Install...')
  end

  -- get git version
  if not Git.version() then
    buf:global('Error: git executable not found')
    return false
  end

  do -- create installation directory
    local stat = uv.fs_stat(state.install_dir)
    if not stat then
      if fn.mkdir(state.install_dir, 'p') == 0 then
        buf:global('Error: failed to create install_dir directory')
        return false
      end
    elseif stat.type ~= 'directory' then
      buf:global('Error: install_dir is not a directory')
      return false
    end
  end

  -- get patches
  get_patches()

  -- reset tasks
  Task.reset()

  -- create tasks
  local tasks = {}
  for _, plug in ipairs(state.by_order) do
    if not plug.ext then
      local stat = uv.fs_stat(plug.path)
      if not stat then
        buf:set(plug, 'Install...')
        tinsert(tasks, { plug, Task.new(task_install, function(err)
          buf:set(plug, err or 'Installed')
        end) })
      elseif stat.type == 'directory' then
        if update then
          buf:set(plug, 'Update...')
          tinsert(tasks, { plug, Task.new(task_update, function(err)
            buf:set(plug, err or 'Updated')
          end) })
        else
          buf:set(plug, 'Already installed')
        end
      else
        buf:set(plug, 'Conflicting file: '..plug.path)
      end
    end
  end

  -- flush buffer to render initial states
  buf:flush(true)

  -- start tasks
  for _, task in ipairs(tasks) do
    task[2]:resume(task[1], buf)
  end

  -- wait for tasks
  -- TODO: configurable timeout
  local interrupt = false
  vim.wait(60000, function()
    if not pcall(fn.getchar, 0) then
      interrupt = true
      return true
    end
    buf:flush()
    return Task.done()
  end)

  if interrupt then
    Task.cancel()
    vim.api.nvim_echo({{'Neopm: Keyboard interrupt', 'ErrorMsg'}}, true, {})
    return false
  end

  buf:global('Generating help tags...')
  Impl.helptags()

  buf:global('Done')
  return true
end

--- Install plugins
---@return boolean success
function Impl.install()
  return start(false)
end

--- Update plugins
---@return boolean success
function Impl.update()
  return start(true)
end

--- Generate help tags
function Impl.helptags()
  for _, plug in ipairs(state.by_order) do
    local path = plug.path..'/doc'
    local stat = uv.fs_stat(path)
    if stat and stat.type == 'directory' then
      vim.cmd('silent! helptags '..path:gsub(' ', '\\ '))
    end
  end
end

return Impl
