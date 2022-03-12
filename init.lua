local fn = vim.fn
local api = vim.api
local uv = vim.loop
local vcmd = vim.cmd
local fmt = string.format
local tinsert, tremove, tconcat, tsort =
  table.insert, table.remove, table.concat, table.sort


---@alias Neopm fun(uri: string): fun(opts: NeopmPlugOpts)

---@class NeopmPlug
---@field uri string              Plugin URI
---@field path? string            Full path to plugin (updated by prepare())
---@field ext? boolean            True if external, unmanaged plugin
---@field as? string              Directory name, nil if external
---@field on? string[]            Load on commands
---@field ft? string[]            Load on filetypes
---@field run? string|function    Post install hook (not implemented)
---@field setup? string|function  Post load hook
---@field depends? string[]       Plugin dependencies
---@field order? number           Order (updated by prepare())
---@field lazy? boolean           true if not loaded yet, false if loaded
---@field loaded? boolean         true if plugin was loaded
---@field patch? string           Path to patch (updated by plug.impl.get_patches())

---@class NeopmPlugOpts
---@field as? string                Directory name
---@field on? string|string[]       Load on command(s)
---@field ft? string|string[]       Load on filetype(s)
---@field run? string|function      Post install hook
---@field setup? string|function    Post load hook
---@field depends? string|string[]  Plugin dependencies

---@class NeopmConfig
---@field install_dir? string   Path to installation directory
---@field patch_dir? string     Path to directory with patches
---@field git_command? string   Git command

---@class NeopmStats
---@field total number        Total plugin count
---@field external number     External plugin count
---@field installed number    Installed plugin count
---@field uninstalled number  Uninstalled plugin count


-- TODO: option for lazy loading plugins only when something else
--       depends on it, probably with option `lazy = true`
-- TODO: when loading a plugin, make sure dependencies are loaded before
-- TODO: option to manually load lazy plugins


--- Default options
local DEFAULT_OPTIONS = {
  install_dir = fn.stdpath('data')..'/neopm',
  patch_dir   = fn.stdpath('config')..'/patches',
  git_command = 'git',
}

--- Global state
---@class NeopmState
local state = {
  --- Plugin lookup by definition order
  ---@type NeopmPlug[]
  by_order = {},
  --- Plugin lookup by URI
  ---@type NeopmPlug[]
  by_uri = {},
  --- Plugin lookup by "as" property, updated by prepare()
  ---@type NeopmPlug[]?
  by_dir = {},

  --- Option: Path to installation directory
  ---@type string
  install_dir = DEFAULT_OPTIONS.install_dir,
  --- Option: Path to directory with patches
  ---@type string
  patch_dir = DEFAULT_OPTIONS.patch_dir,
  --- Option: Git command
  ---@type string
  git_command = DEFAULT_OPTIONS.git_command,
}

--- Plugins loaded on filetype
---@type table<string,NeopmPlug[]>
local lazy_fts = {}
--- Plugins loaded on command
---@type table<string,NeopmPlug[]>
local lazy_cmds = {}
--- Plugins loaded on key mapping
---@type table<string,NeopmPlug[]>
-- local lazy_maps = {}

--- Changed state flag, for prepare()
local changed = false

local HOME = vim.env.HOME

---@type Neopm
local Neopm = {}


--- Find value in a table
---@param t table   array
---@param v any     value
---@return number   index
local function tfind(t, v)
  for i, item in ipairs(t) do
    if item == v then
      return i
    end
  end
end

--- Validate string
---@param v any
---@return string|nil res, string? err
local function validate_s(v)
  if type(v) == 'string' then
    return v
  else
    return nil, 'expected string'
  end
end

--- Validate string or table of strings
---@param v any
---@return string[]|nil res, string? err
local function validate_st(v)
  if type(v) == 'string' then
    return { v }
  elseif type(v) == 'table' then
    -- TODO: make a copy
    for _, item in ipairs(v) do
      if type(item) ~= 'string' then
        return nil, 'expected string or array of strings'
      end
    end
    return v
  else
    return nil, 'expected string or array of strings'
  end
end

--- Validate string or function
---@param v any
---@return string|function|nil res, string? err
local function validate_sf(v)
  local t = type(v)
  if t == 'string' or t == 'function' then
    return v
  else
    return nil, 'expected string or function'
  end
end

-- --- Validate boolean
-- ---@param v any
-- ---@return boolean|nil res, string? err
-- local function validate_b(v)
--   if type(v) == 'boolean' then
--     return v
--   else
--     return nil, 'expected boolean'
--   end
-- end

local VALIDATE_OPTS = {
  as = validate_s,
  on = validate_st,
  ft = validate_st,
  run = validate_sf,
  setup = validate_sf,
  depends = validate_st,
}


--- New plugin
---@param uri string        Plugin URI
---@param idx number        Insert plugin at index
---@return NeopmPlug plugin Plugin
---@return boolean cached   true if plugin already existed
local function newplugin(uri, idx)
  local plug = state.by_uri[uri]
  if plug then return plug, true end

  if type(uri) ~= 'string' then
    error('Invalid plugin URI, expected string', 3)
  end

  local ext, as
  if uri:match('^[/~]') then
    ext = true
  else
    as = uri:match('^.+/([^/]+)$')
    if not as then
      error('Invalid plugin URI: '..uri, 3)
    end
  end

  changed = true
  plug = { uri = uri, as = as, ext = ext }
  state.by_uri[uri] = plug
  if idx then
    tinsert(state.by_order, idx, plug)
  else
    tinsert(state.by_order, plug)
  end
  return plug, false
end

--- Set options for a plugin
---@param plug NeopmPlug     Plugin instance
---@param opts NeopmPlugOpts Options table
local function setopts(plug, opts)
  changed = true
  for k, v in pairs(opts) do
    local validate = VALIDATE_OPTS[k]
    if not validate then
      error('Invalid option for plugin '..plug.uri..': '..tostring(k), 3)
    end
    local opt, err = validate(v)
    if opt == nil then
      error('Invalid value "'..k..'" for plugin '..plug.uri..': '..err, 3)
    end
    if plug.ext and k == 'as' then
      error('Option "as" not supported for unmanaged plugin '..plug.uri, 3)
    end
    plug[k] = opt
  end

  if plug.depends then
    local idx = assert(tfind(state.by_order, plug))
    for _, ruri in ipairs(plug.depends) do
      -- add dependencies before the plugins that depend on them
      local rplug, cached = newplugin(ruri, idx)
      if cached then
        local ridx = assert(tfind(state.by_order, rplug))
        if ridx > idx then
          tremove(state.by_order, ridx)
          tinsert(state.by_order, idx, rplug)
        end
      end
      idx = idx + 1
    end
  end
end

--- Add plugin
---@param uri string Plugin URI
---@return fun(opts: NeopmPlugOpts)
local function addplugin(_, uri)
  local plug = newplugin(uri)
  return function(opts)
    setopts(plug, opts)
  end
end


--- Update internal state
local function prepare()
  if not changed then return end
  changed = false
  state.by_dir = {}
  for i, plug in ipairs(state.by_order) do
    plug.order = i
    local as = plug.as
    if as then
      plug.path = state.install_dir..'/'..as
      if state.by_dir[as] then
        error('Conflicting plugin name: '..as, 3)
      end
      state.by_dir[as] = plug
    elseif plug.ext then
      local uri = plug.uri
      if uri:sub(1,2) == '~/' or uri == '~' then
        plug.path = assert(HOME)..uri:sub(2)
      else
        plug.path = uri
      end
    end
  end
end

--- Update runtimepath
---@return NeopmPlug[] setup_plugs
local function update_rtp()
  local setup_plugs = {}
  local paths = {}
  local after = {}

  for _, plug in ipairs(state.by_order) do
    -- exclude unloaded lazy plugins
    if not plug.lazy or plug.loaded then
      -- save plugins that were just loaded and need to run setup option
      if plug.setup and not plug.loaded then
        tinsert(setup_plugs, plug)
      end

      plug.loaded = true
      tinsert(paths, plug.path)

      local afterdir = plug.path..'/after'
      local stat = vim.loop.fs_stat(afterdir)
      if stat and stat.type == 'directory' then
        tinsert(after, afterdir)
      end
    end
  end

  if #paths > 0 or #after > 0 then
    local final = {}

    local rtp = vim.split(api.nvim_get_option('runtimepath'), ',')
    local fst = tremove(rtp, 1) -- first entry, ~/.config/nvim
    local lst = tremove(rtp)    -- last entry, ~/.config/nvim/after

    -- remember visited paths, to remove duplicate entries
    local seen = { [fst] = true, [lst] = true }

    -- TODO: escape with gsub('[ ,]', '\\%1')
    if fst then
      tinsert(final, fst)
    end
    for _, path in ipairs(paths) do
      if not seen[path] then
        seen[path] = true
        tinsert(final, path)
      end
    end
    for _, path in ipairs(rtp) do
      if not seen[path] then
        seen[path] = true
        tinsert(final, path)
      end
    end
    for _, path in ipairs(after) do
      if not seen[path] then
        seen[path] = true
        tinsert(final, path)
      end
    end
    if lst then
      tinsert(final, lst)
    end

    final = tconcat(final, ',')
    api.nvim_set_option('runtimepath', final)
  end

  return setup_plugs
end


--- Find paths matching `[path]/**/*.{vim,lua}`
---@type fun(path: string): string[]
local find_scripts do
  local function find_scripts_inner(path, files, depth)
    local dir = uv.fs_opendir(path, nil, 64)
    if not dir then return end
    while true do
      local ents = dir:readdir()
      if not ents then
        dir:closedir()
        break
      end

      for _, ent in ipairs(ents) do
        if ent.type == 'file' then
          local ext = ent.name:sub(-4)
          if ext == '.vim' or ext == '.lua' then
            tinsert(files, path..'/'..ent.name)
          end
        elseif ent.type == 'directory' then
          if depth < 3 then
            find_scripts_inner(path..'/'..ent.name, files, depth + 1)
          end
        end
      end
    end
  end

  function find_scripts(path)
    local files = {}
    find_scripts_inner(path, files, 0)
    tsort(files)
    return files
  end
end


--- Lazy load plugins for filetype
---@param ft string
function Neopm._load_ft(ft)
  -- get lazy plugins for this filetype
  local plugs = lazy_fts[ft]
  if not plugs then return end
  lazy_fts[ft] = nil

  -- remove plugins that were already loaded
  for i = #plugs, 1, -1 do
    if plugs[i].loaded then
      tremove(plugs, i)
    else
      plugs[i].lazy = nil
    end
  end

  local setup_plugs = update_rtp()

  local function filereadable(path)
    local stat = uv.fs_stat(path)
    if not stat or stat.type == 'directory' or not uv.fs_access(path, 'R') then
      return false
    end
    return true
  end

  for _, plug in ipairs(plugs) do
    for _, name in ipairs(find_scripts(plug.path..'/plugin')) do
      vcmd('source '..name:gsub(' ', '\\ '))
    end
  end
  for _, plug in ipairs(plugs) do
    for _, name in ipairs(find_scripts(plug.path..'/after/plugin')) do
      vcmd('source '..name:gsub(' ', '\\ '))
    end
  end

  for _, plug in ipairs(plugs) do
    local fvim = plug.path..'/syntax/'..ft..'.vim'
    if filereadable(fvim) then
      vcmd('source '..fvim:gsub(' ', '\\ '))
    end
    local flua = plug.path..'/syntax/'..ft..'.lua'
    if filereadable(flua) then
      vcmd('source '..flua:gsub(' ', '\\ '))
    end
  end

  local after = {}
  for _, plug in ipairs(plugs) do
    local fvim = plug.path..'/after/syntax/'..ft..'.vim'
    if filereadable(fvim) then
      tinsert(after, fvim)
    end
    local flua = plug.path..'/after/syntax/'..ft..'.lua'
    if filereadable(flua) then
      tinsert(after, flua)
    end
  end
  if #after > 0 then
    vcmd('runtime after/syntax/'..ft..'.{vim,lua}')
    for _, file in ipairs(after) do
      -- TODO: I think these will be sourced twice with the :runtime command above.
      -- maybe just get rid of it and just do :runtime if there are any after/syntax files
      vcmd('source '..file:gsub(' ', '\\ '))
    end
  end

  vcmd(fmt([[
    doautocmd <nomodeline> filetypeplugin FileType %s
    doautocmd <nomodeline> filetypeindent FileType %s
    doautocmd <nomodeline> syntaxset      FileType %s
  ]], ft, ft, ft))

  -- run plug.setup
  for _, plug in ipairs(setup_plugs) do
    local setup = plug.setup
    if type(setup) == 'string' then
      vim.cmd(setup)
    elseif type(setup) == 'function' then
      setup()
    end
  end
end

--- Lazy load plugins for command
---@param cmd string
---@param bang string
---@param range number
---@param line1 number
---@param line2 number
---@param args string
function Neopm._load_cmd(cmd, bang, range, line1, line2, args)
  -- get lazy plugins for this command
  local plugs = lazy_cmds[cmd]
  if not plugs then return end
  lazy_cmds[cmd] = nil

  -- remove plugins that were already loaded
  for i = #plugs, 1, -1 do
    if plugs[i].loaded then
      tremove(plugs, i)
    else
      plugs[i].lazy = nil
    end
  end

  local setup_plugs = update_rtp()

  local bufread = false

  for _, plug in ipairs(plugs) do
    for _, name in ipairs(find_scripts(plug.path..'/ftdetect')) do
      bufread = true
      vcmd('source '..name:gsub(' ', '\\ '))
    end
  end
  for _, plug in ipairs(plugs) do
    for _, name in ipairs(find_scripts(plug.path..'/after/ftdetect')) do
      bufread = true
      vcmd('source '..name:gsub(' ', '\\ '))
    end
  end

  for _, plug in ipairs(plugs) do
    for _, name in ipairs(find_scripts(plug.path..'/plugin')) do
      bufread = true
      vcmd('source '..name:gsub(' ', '\\ '))
    end
  end
  for _, plug in ipairs(plugs) do
    for _, name in ipairs(find_scripts(plug.path..'/after/plugin')) do
      bufread = true
      vcmd('source '..name:gsub(' ', '\\ '))
    end
  end

  if bufread then
    vcmd('doautocmd BufRead')
  end

  -- run plug.setup
  for _, plug in ipairs(setup_plugs) do
    local setup = plug.setup
    if type(setup) == 'string' then
      vim.cmd(setup)
    elseif type(setup) == 'function' then
      setup()
    end
  end

  -- rerun command that triggered this
  local r = ''
  if range == 1 then
    r = tostring(line1)
  elseif range == 2 then
    r = tostring(line1)..','..tostring(line2)
  end
  vcmd(fmt('%s%s%s %s', r, cmd, bang, args))
end


--- Load plugins
function Neopm.load()
  prepare()

  vcmd([[
    augroup plug_lazy
      autocmd!
    augroup end
    silent! augroup! plug_lazy
  ]])

  local fts = {}
  local cmds = {}
  -- local maps = {}

  -- set up lazy loading
  for _, plug in ipairs(state.by_order) do
    if plug.ft then
      plug.lazy = true
      vcmd('augroup filetypedetect')
      for _, name in ipairs(find_scripts(plug.path..'/ftdetect')) do
        vcmd('source '..name:gsub(' ', '\\ '))
      end
      for _, name in ipairs(find_scripts(plug.path..'/after/ftdetect')) do
        vcmd('source '..name:gsub(' ', '\\ '))
      end
      vcmd('augroup end')

      for _, ft in ipairs(plug.ft) do
        tinsert(fts, ft)
        local lazy = lazy_fts[ft]
        if lazy then
          tinsert(lazy, plug)
        else
          lazy = { plug }
          lazy_fts[ft] = lazy
        end
      end
    end

    if plug.on then
      plug.lazy = true
      for _, on in ipairs(plug.on) do
        local cmd = on:match('^([A-Z].*)!*$')
        if cmd then
          tinsert(cmds, cmd)
          local lazy = lazy_cmds[cmd]
          if lazy then
            tinsert(lazy, plug)
          else
            lazy = { plug }
            lazy_cmds[cmd] = lazy
          end
        else
          error('Invalid on option in '..plug.uri, 2)
        end
      end
    end
  end

  local setup_plugs = update_rtp()

  if #fts > 0 then
    vcmd(fmt([[
      augroup plug_lazy
        autocmd FileType %s ++once
          \ lua require('neopm')._load_ft(vim.fn.expand('<amatch>'))
      augroup end
    ]], tconcat(fts, ',')))
  end

  for _, cmd in ipairs(cmds) do
    vcmd(fmt([[
      command! -nargs=* -range -bang -complete=file %s
        \ lua require('neopm')._load_cmd('%s', "<bang>", <range>, <line1>, <line2>, <q-args>)
    ]], cmd, cmd))
  end

  -- TODO: lazy key maps

  -- run plug.setup
  for _, plug in ipairs(setup_plugs) do
    local setup = plug.setup
    if type(setup) == 'string' then
      vim.cmd(setup)
    elseif type(setup) == 'function' then
      setup()
    end
  end
end


--- Install plugins
function Neopm.install()
  prepare()
  package.loaded['neopm.state'] = state
  return require('neopm.impl').install()
end

--- Update plugins
function Neopm.update()
  prepare()
  package.loaded['neopm.state'] = state
  return require('neopm.impl').update()
end


--- Get plugin statistics
---@return NeopmStats
function Neopm.stats()
  prepare()
  local total     = 0
  local managed   = 0
  local external  = 0
  local installed = 0

  for _, plug in ipairs(state.by_order) do
    total = total + 1
    if plug.ext then
      external = external + 1
    else
      managed = managed + 1
    end
  end

  local dir = uv.fs_opendir(state.install_dir, nil, 64)
  if dir then
    while true do
      local ents = dir:readdir()
      if not ents then
        dir:closedir()
        break
      end

      for _, ent in ipairs(ents) do
        if ent.type == 'directory' and state.by_dir[ent.name] then
          installed = installed + 1
        end
      end
    end
  end

  return {
    total       = total,
    external    = external,
    installed   = installed,
    uninstalled = managed - installed,
  }
end

--- Check and install missing plugins
---@param prompt? boolean   Ask for permission, off by default
function Neopm.autoinstall(prompt)
  local missing = Neopm.stats().uninstalled
  if missing <= 0 then return end

  if prompt then
    local msg = fmt('Missing %d plugin%s. Install? [y/n]: ',
      missing, missing == 1 and '' or 's')
    local ok, answer = pcall(fn.input, msg)
    if not ok or fn.match(answer, [[\v\c^\s*y%[es]\s*$]]) < 0 then
      return
    end
  end

  Neopm.install()
end

--- Set configuration
---@param config NeopmConfig
function Neopm.config(config)
  if type(config) ~= 'table' then
    error('Expected table', 2)
  end

  -- make a shallow copy
  local c = {}
  for k, v in pairs(config) do
    c[k] = v
  end

  for k, default in pairs(DEFAULT_OPTIONS) do
    -- pop value
    local v = c[k]
    c[k] = nil

    if v == nil then
      state[k] = default -- reset option back to default if not in config
    elseif type(v) ~= 'string' then
      error('Expected string in option: '..k, 2)
    elseif v:sub(1,2) == '~/' or v == '~' then
      state[k] = assert(HOME)..v:sub(2) -- expand "~/" to $HOME
    else
      state[k] = v
    end
  end

  for k in pairs(c) do
    error('Invalid option: '..tostring(k), 2)
  end
end


setmetatable(Neopm, { __call = addplugin })
return Neopm
