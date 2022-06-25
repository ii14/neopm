-- runtime path optimization

local uv = vim.loop
local fn = vim.fn

local UMASK = 511
local RUNTIME = fn.stdpath('cache')..'/neopm/runtime'

local state = require('neopm.state')

local t_plugs = 0
local c_plugs = 0
local c_dirs = 0
local c_links = 0

local plugs = {}
for dir, plug in pairs(state.by_dir) do
  t_plugs = t_plugs + 1
  if plug.lazy == nil then
    plugs[dir] = { path = plug.path }
  else
    print('lazy', plug.path)
  end
end


local function mk_glob(t)
  for i, pattern in ipairs(t) do
    t[i] = vim.regex(fn.glob2regpat(pattern))
  end

  return function(path)
    for _, re in ipairs(t) do
      if re:match_str(path) then
        return true
      end
    end
    return false
  end
end

local VIMDIRS = {
  'after',
  'autoload',
  'colors',
  'compiler',
  'ftdetect',
  'ftplugin',
  'health',
  'indent',
  'keymap',
  'lang',
  'lua',
  'plugin',
  'print',
  'spell',
  'syntax',
  'tutor',
}

local VIMFILES = {
  'delmenu',
  'filetype',
  'ftoff',
  'ftplugin',
  'ftplugof',
  'indent',
  'indoff',
  'macmap',
  'makemenu',
  'menu',
  'mswin',
  'optwin',
  'scripts',
  'synmenu',
}

local INCLUDE = mk_glob {
  '{'..table.concat(VIMDIRS, ',')..'}/*.{vim,lua}',
  '{'..table.concat(VIMFILES, ',')..'}.{vim,lua}',
  'doc/*.{txt,md}',
}

local EXCLUDE = mk_glob {
  '.git',
  '.github',
  'doc/tags',
  'test',
  'tests',
}

local DISABLE = mk_glob {
  'rplugin',
  'bin',
  'data',
  'pack',
}


-- scan files
do
  local function scan(res, root, path)
    local lead = path and path..'/' or ''
    local dir = assert(uv.fs_opendir(root..(path and '/'..path or ''), nil, 64))
    while true do
      local ents = dir:readdir()
      if ents == nil then break end
      for _, ent in ipairs(ents) do
        local name = lead..ent.name
        if DISABLE(name) then
          return false
        elseif ent.type == 'directory' then
          if not EXCLUDE(name) and not scan(res, root, name) then
            return false
          end
        elseif INCLUDE(name) and not EXCLUDE(name) then
          table.insert(res, name)
        end
      end
    end
    assert(dir:closedir())
    return true
  end

  for _, plug in pairs(plugs) do
    local files = {}
    if scan(files, plug.path) then
      plug.files = files
    else
      plug.files = false
      print('disabled', plug.path)
    end
  end
end


local files = {}

do
  local conflicts = {}

  -- initialize `files` set, find conflicts
  for _, plug in pairs(plugs) do
    if plug.files then
      c_plugs = c_plugs + 1
      for _, path in ipairs(plug.files) do
        local plug2 = files[path]
        if plug2 then
          conflicts[plug] = true
          conflicts[plug2] = true
        else
          files[path] = plug
        end
      end
    end
  end

  -- remove files from conflicting plugins
  for plug in pairs(conflicts) do
    c_plugs = c_plugs - 1
    print('conflict', plug.path)
    for _, path in ipairs(plug.files) do
      files[path] = nil
    end
  end

  -- resolve source path from plugins
  for path, plug in pairs(files) do
    files[path] = plug.path..'/'..path
  end
end


-- create symlinks
do
  local dirs = {}
  local function mkdir(path)
    local dir = ''
    for part in path:gmatch('/*[^/]+') do
      dir = dir..part
      if not dirs[dir] then
        local ok, err, errno = uv.fs_mkdir(dir, UMASK)
        if not ok and errno ~= 'EEXIST' then
          error(err)
        end
        dirs[dir] = true
        c_dirs = c_dirs + 1
      end
    end
  end

  for target, source in pairs(files) do
    target = RUNTIME..'/'..target
    mkdir(target:match('(.*)/'))
    -- TODO: check EEXIST, or wipe runtime directory before
    assert(uv.fs_symlink(source, target))
    c_links = c_links + 1
  end

  print(('optimized %d/%d plugins: created symlinks for %d files in %d directories'):format(
    c_plugs, t_plugs, c_links, c_dirs
  ))
end
