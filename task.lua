local uv = vim.loop
local ccreate, cresume, cyield, crunning =
  coroutine.create, coroutine.resume, coroutine.yield, coroutine.running
local tinsert, tconcat = table.insert, table.concat


local CHUNK_SIZE = 1024 -- bytes per chunk when reading a file
local ENTRIES_SIZE = 64 -- entries per callback when scanning a directory


-- INTERNAL STATE --

--- Lookup table of coroutine to Task
---@type table<thread,NeopmTask>
local tasks = {}
--- Active tasks
local active = 0
--- Running jobs (uv_process_t)
---@type table<userdata[],boolean>
local jobs = {}
--- Open pipes (uv_pipe_t)
---@type table<userdata,boolean>
local pipes = {}
--- Cancelled flag
local cancelled = false

--- Packs results to a table
---     local n, res = pack(...)
---     return unpack(res, 1, n)
---@return number n   Number of results
---@return any[] res  Results
local function pack(...)
  return select('#', ...), {...}
end

--- Discard first value
local function discard_first(_, ...)
  return ...
end


-- TASK API --

---@class NeopmTask
---@field coro thread             Coroutine
---@field cb? fun(err?: string)   Called when task finishes
---@field data? any               User assignable data
local Task = {}
Task.__index = Task

--- Task function wrapper
---@param func function   Task function
---@vararg any            Arguments
local function task_wrap(func, ...)
  local task = Task.current()
  -- keep count of active tasks
  active = active + 1
  -- tasks return nil on success and message something
  -- on failure, so pcall status can be discarded
  local n, res = pack(discard_first(pcall(func, ...)))
  -- make sure we are not in a fast event after task is done
  if vim.in_fast_event() then
    task:reenter()
  end
  -- remove from active and run callback
  active = active - 1
  if not cancelled and task.cb then
    pcall(task.cb, unpack(res, 1, n))
  end
end

--- Creates a new task
---@param func function         Task function
---@param cb fun(err?: string)  Called when task finishes
---@return NeopmTask
function Task.new(func, cb)
  assert(type(func) == 'function')
  assert(cb == nil or type(cb) == 'function')

  local coro = ccreate(function(...)
    return task_wrap(func, ...)
  end)

  local task = { coro = coro, cb = cb }
  setmetatable(task, Task)
  tasks[coro] = task
  return task
end

--- Reinitializes context
function Task.reset()
  tasks = {}
  active = 0
  jobs = {}
  pipes = {}
  cancelled = false
end

--- Gets current task
--- Throws when called outside of a running task
---@return NeopmTask
function Task.current()
  return assert(tasks[assert(crunning())])
end

--- Yields from a task
---@return ...
function Task.yield()
  local n, res = pack(cyield())
  if cancelled then error('cancelled') end
  return unpack(res, 1, n)
end

--- Returns true if all tasks are done
---@return boolean
function Task.done()
  return active == 0 or cancelled
end

--- Cancels all tasks
function Task.cancel()
  cancelled = true

  for job in pairs(jobs) do
    if not job:is_closing() then
      job:kill('SIGTERM')
    end
  end
  jobs = {}

  for pipe in pairs(pipes) do
    if not pipe:is_closing() then
      pipe:close()
    end
  end
  pipes = {}
end

--- Waits until all tasks are done
---@param time number       Timeout in ms
---@return boolean done
---@return nil|'"timeout"'|'"interrupt"'|'"unknown"' reason
function Task.wait(time)
  local done, reason = vim.wait(time, Task.done)
  if done then
    return true
  elseif reason == -1 then
    return false, 'timeout'
  elseif reason == -2 then
    return false, 'interrupt'
  else
    return false, 'unknown'
  end
end

--- Resumes task
---@vararg any  Arguments passed to start or resume the task
function Task:resume(...)
  cresume(self.coro, ...)
end

--- Reenters current coroutine
--- For getting out of fast event
function Task:reenter()
  vim.schedule(function()
    self:resume()
  end)
  Task.yield()
end


-- ASYNC OPERATIONS --

---@param cb fun(data: string)  On output callback
---@param capture boolean Capture output
---@return userdata pipe uv_pipe_t
---@return fun(err?: string, data: string)|nil callback
---@return string[] output
local function new_pipe(cb, capture)
  local pipe = uv.new_pipe()
  pipes[pipe] = true
  if not cb and not capture then
    return pipe
  end
  local callback, output

  if capture and cb then
    output = {}
    function callback(err, data)
      assert(not err, err)
      if data then
        cb(data)
        tinsert(output, data)
      end
    end
  elseif capture then
    output = {}
    function callback(err, data)
      assert(not err, err)
      if data then
        tinsert(output, data)
      end
    end
  elseif cb then
    function callback(err, data)
      assert(not err, err)
      if data then
        cb(data)
      end
    end
  end

  return pipe, callback, output
end

---@class NeopmTaskExecOpts
---@field cwd? string
---@field env? table<string,string>
---@field capture_stdout? boolean
---@field capture_stderr? boolean
---@field on_stdout? fun(data: string)
---@field on_stderr? fun(data: string)

---@class NeopmTaskExecResults
---@field signal number
---@field stdout string[]
---@field stderr string[]

--- Spawns a subprocess
---@param path string         Executable
---@param args string[]       Arguments
---@param opts? NeopmTaskExecOpts  Options
---@return number status
---@return NeopmTaskExecResults results
function Task:exec(path, args, opts)
  opts = opts or {}

  local stdout_pipe, stdout_cb, stdout_output =
    new_pipe(opts.on_stdout, opts.capture_stdout)
  local stderr_pipe, stderr_cb, stderr_output =
    new_pipe(opts.on_stderr, opts.capture_stderr)

  local handle
  handle = uv.spawn(path, {
    args = args,
    cwd = opts.cwd,
    env = opts.env,
    stdio = { nil, stdout_pipe, stderr_pipe },
  }, function(status, signal)
    handle:close()
    if stdout_pipe then
      stdout_pipe:close()
      pipes[stdout_pipe] = nil
    end
    if stderr_pipe then
      stderr_pipe:close()
      pipes[stderr_pipe] = nil
    end

    -- remove from active jobs
    jobs[handle] = nil

    -- split output to lines
    if stdout_output then
      stdout_output = vim.split(tconcat(stdout_output), '\n', { plain = true })
    end
    if stderr_output then
      stderr_output = vim.split(tconcat(stderr_output), '\n', { plain = true })
    end

    -- resume thread
    self:resume(status, {
      signal = signal,
      stdout = stdout_output,
      stderr = stderr_output,
    })
  end)

  if not handle then
    if stdout_pipe then
      stdout_pipe:close()
      pipes[stdout_pipe] = nil
    end
    if stderr_pipe then
      stderr_pipe:close()
      pipes[stderr_pipe] = nil
    end
    error('failed to spawn process: '..path..' '..tconcat(args, ' '))
  end

  -- TODO: check errors
  if stdout_pipe and stdout_cb then
    stdout_pipe:read_start(stdout_cb)
  end
  if stderr_pipe and stderr_cb then
    stderr_pipe:read_start(stderr_cb)
  end

  jobs[handle] = true
  return Task.yield()
end

--- Scans a directory (uv.fs_opendir, uv.fs_readdir)
---@param path string     Path to directory
---@return {name: string, type: string}[]|nil entries
---@return nil|string err
function Task:scandir(path)
  local entries = {}
  uv.fs_opendir(path, function(err, dir)
    if err then return self:resume(err) end

    local function cb(err2, ents)
      if err2 then
        dir:closedir()
        return self:resume(err2)
      elseif not ents then
        dir:closedir()
        return self:resume()
      end

      for _, ent in ipairs(ents) do
        tinsert(entries, ent)
      end
      dir:readdir(cb)
    end
    dir:readdir(cb)
  end, ENTRIES_SIZE)

  local err = Task.yield()
  if err then return nil, err end
  return entries
end

--- Reads a file (uv.fs_open, uv.fs_read)
---@param path string     Path to file
---@param max? number     Max lines to read
---@return string[]|nil lines
---@return nil|string err
function Task:readfile(path, max)
  -- TODO: if there is no max lines check file
  -- size with uv.fs_stat and read it in one go
  -- TODO: replace max argument with just option
  -- to get the first line. that's the only use
  -- case we need it for
  if max and max < 1 then
    return {}
  end

  local chunks = {}
  local lines = 1

  uv.fs_open(path, 'r', 438, function(err1, fd)
    if err1 then return self:resume(err1) end
    local function cb(err2, data)
      if err2 then
        uv.fs_close(fd)
        return self:resume(err2)
      elseif data == nil or data == '' then
        uv.fs_close(fd)
        return self:resume()
      end

      if max then
        -- find new lines
        local idx = 1
        while true do
          idx = data:find('\n', idx, true)
          if not idx then break end
          idx = idx + 1
          lines = lines + 1
        end

        tinsert(chunks, data)
        if lines >= max then
          uv.fs_close(fd)
          return self:resume()
        end
      else
        tinsert(chunks, data)
      end

      uv.fs_read(fd, CHUNK_SIZE, nil, cb)
    end
    uv.fs_read(fd, CHUNK_SIZE, 0, cb)
  end)

  local err = Task.yield()
  if err then return nil, err end

  -- convert chunks to lines
  chunks = vim.split(tconcat(chunks), '\n', { plain = true })
  if max then
    -- trim lines exceeding max parameter
    for i = max + 1, #chunks do
      chunks[i] = nil
    end
  end
  return chunks
end

--- uv.fs_stat
---@param path string     Path to file
---@return table|nil stat
---@return nil|string err
function Task:stat(path)
  uv.fs_stat(path, function(err, stat)
    if err then
      return self:resume(nil, err)
    else
      self:resume(stat)
    end
  end)
  return Task.yield()
end

--- uv.fs_unlink
---@param path string     Path to file
---@return boolean|nil success
---@return nil|string err
function Task:unlink(path)
  uv.fs_unlink(path, function(err, success)
    if err then
      return self:resume(nil, err)
    else
      self:resume(success)
    end
  end)
  return Task.yield()
end

--- uv.fs_copyfile
---@param path string         Source path
---@param new_path string     Target path
---@param flags? table|number Flags
---@return boolean|nil success
---@return nil|string err
function Task:copyfile(path, new_path, flags)
  uv.fs_copyfile(path, new_path, flags, function(err, success)
    if err then
      return self:resume(nil, err)
    else
      self:resume(success)
    end
  end)
  return Task.yield()
end

return Task
