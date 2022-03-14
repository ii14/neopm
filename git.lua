local fn = vim.fn
local uv = vim.loop
local tinsert = table.insert
local Task = require('neopm.task')

---@type NeopmState
local state = require('neopm.state')

local Git = {}

local GIT_ENV = {
  GIT_TERMINAL_PROMPT = 0,
  GIT_CONFIG_NOSYSTEM = 1,
  GIT_CONFIG_GLOBAL = '/dev/null',
}

-- TODO: capture stderr and display errors

do
  local git_version
  --- Get git version, synchronous
  ---@return number[]
  function Git.version()
    if git_version then return git_version end

    local ok, res = pcall(fn.systemlist, { state.git_command, '--version' })
    if not ok or not res or not res[1] then return end

    res = res[1]:match('^git version ([%d%.]+)$')
    if not res then return end

    res = vim.split(res, '.', { plain = true })
    if not res then return end

    for i, num in ipairs(res) do
      res[i] = tonumber(num)
      if not res[i] then return end
    end

    git_version = res
    return res
  end
end

---@param line string
---@return string line
local function get_last_line(line)
  line = line:match('^(.-)[\r\n]*$') or line
  line = line:match('[\r\n]([^\r\n]-)$') or line
  line = line:match('^%s*(.-)%s*$')
  if line and line ~= '' then
    return line
  end
end

--- Run git command, asynchronous
---@param args string[]
---@param cwd string
---@param on_update? fun(data: string)
---@param capture_stdout? boolean
---@return number status
---@return NeopmTaskExecResults results
function Git.run(args, cwd, on_update, capture_stdout)
  local opts = {
    cwd = cwd or state.install_dir,
    env = GIT_ENV,
  }

  if on_update then
    function opts.on_stderr(data)
      local line = get_last_line(data)
      if line then on_update(line) end
    end
  end

  if capture_stdout then
    opts.capture_stdout = true
  end

  return Task.current():exec(state.git_command, args, opts)
end

--- git clone, asynchronous
---@param plug NeopmPlug
---@param on_progress fun(data: string)
---@return number status
function Git.clone(plug, on_progress)
  -- TODO: should ".git" suffix be stripped for output directory?
  local uri = plug.uri:find(':') and plug.uri or
    string.format('https://git::@github.com/%s.git', plug.uri)
  local args = {
    'clone',
    uri,
    plug.path,
    '--origin', 'origin',
    '--depth', '1',
    '--no-single-branch',
  }
  if on_progress then
    tinsert(args, '--progress')
  end
  local status = Git.run(args, nil, on_progress)
  return status
end

--- git fetch, asynchronous
---@param plug NeopmPlug
---@param on_progress fun(data: string)
---@return number status
function Git.fetch(plug, on_progress)
  -- TODO: revert previous patch if necessary
  local args = {'fetch'}
  if on_progress then
    tinsert(args, '--progress')
  end
  -- if Task.current():stat(plug.path..'/.git/shallow') then
  --   tinsert(args, '--depth')
  --   tinsert(args, '99999999')
  -- end
  local status = Git.run(args, plug.path, on_progress)
  return status
end

--- git checkout, asynchronous
---@param plug NeopmPlug
---@param branch string
---@return number status
function Git.checkout(plug, branch)
  local status = Git.run({'checkout', '-q', branch}, plug.path)
  return status
end

--- git merge, asynchronous
---@param plug NeopmPlug
---@param branch string
---@return number status
function Git.merge(plug, branch)
  local status = Git.run({'merge', '--ff-only', branch}, plug.path)
  return status
end

--- git patch, asynchronous
---@param plug NeopmPlug
---@return string? err
function Git.patch(plug)
  -- TODO: revert previous patch if necessary
  if not plug.patch then return end
  local task = Task.current()

  if Git.run({'apply', plug.patch}, plug.path) ~= 0 then
    return 'patch: FAIL (non-zero exit code)'
  end

  if not task:copyfile(plug.patch, plug.path..'/.git/plug.diff') then
    return 'patch: FAIL (failed to copy patch file)'
  end
end

--- git patch -R, asynchronous
---@param plug NeopmPlug
---@return string? err
function Git.patch_revert(plug)
  local task = Task.current()

  local patch = plug.path..'/.git/plug.diff'
  if not task:stat(patch) then return end

  if Git.run({'apply', '-R', patch}, plug.path) ~= 0 then
    return 'patch revert: FAIL (non-zero exit code)'
  end

  if not task:unlink(patch) then
    return 'patch revert: FAIL (failed to remove old patch file)'
  end
end

--- git log, asynchronous
---@param plug NeopmPlug
function Git.log(plug, rev)
  local status, results = Git.run({
    'log',
    '--graph',
    '--color=never',
    '--no-show-signature',
    '--pretty=format:%x01%h%x01%d%x01%s%x01%cr',
    rev,
  }, plug.path, nil, true)

  if status == 0 then
    local stdout = {}
    for _, line in ipairs(results.stdout) do
      if line:match('%S') then
        tinsert(stdout, vim.split(line, '\1', { plain = true }))
      end
    end
    return stdout
  end
end

--- Get revision, asynchronous
---@param dir string
---@return string? rev
function Git.revision(dir)
  local task = Task.current()
  dir = dir..'/.git/'

  local lines = task:readfile(dir..'HEAD', 1)
  if not lines or not lines[1] then return end
  local ref = lines[1]:match('^ref: (.*)$')
  if not ref or ref == '' then return end

  lines = task:readfile(dir..ref, 1)
  if lines and lines[1] then return lines[1] end

  lines = task:readfile(dir..'packed-refs')
  if not lines then return end
  local last = -#ref
  for _, line in ipairs(lines) do
    if line:sub(last) == ref then
      local match = line:match('^([0-9a-f]+)%s')
      if match then return match end
    end
  end
end

--- Get origin branch, asynchronous
---@param dir string
---@return string? branch
function Git.origin_branch(dir)
  local task = Task.current()

  local lines = task:readfile(dir..'/.git/refs/remotes/origin/HEAD', 1)
  if lines and lines[1] then
    return lines[1]:match('^ref: refs/remotes/origin/(.+)$')
  end

  local status, results = task:exec('git', {
    'symbolic-ref', '--short', 'HEAD',
  }, { capture_stdout = true })
  if status == 0 and results.stdout[1] then
    return results.stdout[1]:match('%S[^\n]*')
  end
end

--- Check if patch exists, synchronous (unused)
---@param plug NeopmPlug
---@return boolean
function Git.is_patched(plug)
  local patch = plug.path..'/.git/plug.diff'
  return uv.fs_stat(patch) ~= nil
end

return Git
