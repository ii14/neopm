local eq, same, truthy, falsy, has_error =
  assert.equals, assert.same, assert.truthy, assert.falsy, assert.has_error
local api = vim.api

local Plug = require('neopm')
local state = require('neopm.state')

local RUNTIMEPATH = api.nvim_get_option('runtimepath')
local INSTALL_DIR = '/tmp/neopm-test/plugins'
local PATCH_DIR   = '/tmp/neopm-test/patches'

Plug.config {
  install_dir = INSTALL_DIR,
  patch_dir   = PATCH_DIR,
}


local function get_rtp()
  local res = {}
  local rtp = api.nvim_get_option('runtimepath')
  for _, path in ipairs(vim.split(rtp, ',', { plain = true })) do
    res[path] = true
  end
  return res
end

local function get_autocmds()
  local autocmds = api.nvim_exec('autocmd neopm_lazy', true)
  autocmds = vim.split(autocmds, '\n', { plain = true, trimempty = true })
  -- skip "--- Autocommands ---"
  table.remove(autocmds, 1)

  local res = {}
  local event
  for _, line in ipairs(autocmds) do
    local pattern, command = line:match('^    (%S+)%s+(.+)$')
    if pattern then
      assert(event, 'no event')
      if not res[event] then
        res[event] = {}
      end
      res[event][pattern] = command
    else
      event = line:match('^neopm_lazy%s+(%S+)$')
      if not event then
        error('could not parse line: '..line)
      end
    end
  end

  return res
end


describe('neopm', function()
  after_each(function()
    state.clear()
    api.nvim_set_option('runtimepath', RUNTIMEPATH)
  end)

  it('should add a basic plugin', function()
    Plug 'abc/def'
    Plug.load()

    eq(#state.by_order, 1)
    local p = truthy(state.by_uri['abc/def'])
    eq(p.uri, 'abc/def')
    eq(p.as, 'def')
    eq(p.path, INSTALL_DIR..'/def')
    eq(p.order, 1)
    eq(p, state.by_dir['def'])
    eq(p, state.by_order[1])
    truthy(get_rtp()[INSTALL_DIR..'/def'])
  end)

  it('should add multiple plugins', function()
    Plug 'abc/def'
    Plug 'ghi/jkl'
    Plug.load()

    eq(#state.by_order, 2)
    local rtp = get_rtp()

    do
      local p = truthy(state.by_uri['abc/def'])
      eq(p.uri, 'abc/def')
      eq(p.as, 'def')
      eq(p.path, INSTALL_DIR..'/def')
      eq(p.order, 1)
      eq(p, state.by_dir['def'])
      eq(p, state.by_order[1])
      truthy(rtp[INSTALL_DIR..'/def'])
    end

    do
      local p = truthy(state.by_uri['ghi/jkl'])
      eq(p.uri, 'ghi/jkl')
      eq(p.as, 'jkl')
      eq(p.path, INSTALL_DIR..'/jkl')
      eq(p.order, 2)
      eq(p, state.by_dir['jkl'])
      eq(p, state.by_order[2])
      truthy(rtp[INSTALL_DIR..'/jkl'])
    end
  end)

  it('should correctly process SSH URI', function()
    Plug 'git@github.com:ii14/neopm.git'
    Plug.load()

    eq(#state.by_order, 1)
    local p = truthy(state.by_uri['git@github.com:ii14/neopm.git'])
    eq(p.uri, 'git@github.com:ii14/neopm.git')
    eq(p.as, 'neopm.git')
    eq(p.path, INSTALL_DIR..'/neopm.git')
    eq(p.order, 1)
    eq(p, state.by_dir['neopm.git'])
    eq(p, state.by_order[1])
    truthy(get_rtp()[INSTALL_DIR..'/neopm.git'])
  end)

  it('should correctly process HTTPS URI', function()
    Plug 'https://github.com/ii14/neopm.git'
    Plug.load()

    eq(#state.by_order, 1)
    local p = truthy(state.by_uri['https://github.com/ii14/neopm.git'])
    eq(p.uri, 'https://github.com/ii14/neopm.git')
    eq(p.as, 'neopm.git')
    eq(p.path, INSTALL_DIR..'/neopm.git')
    eq(p.order, 1)
    eq(p, state.by_dir['neopm.git'])
    eq(p, state.by_order[1])
    truthy(get_rtp()[INSTALL_DIR..'/neopm.git'])
  end)

  it('should refer to the same plugin when the URI is the same', function()
    Plug 'abc/def'
    Plug 'abc/def'
    Plug 'abc/def'
    Plug.load()

    eq(#state.by_order, 1)
    local p = truthy(state.by_uri['abc/def'])
    eq(p.uri, 'abc/def')
    eq(p.as, 'def')
    eq(p.path, INSTALL_DIR..'/def')
    eq(p.order, 1)
    eq(p, state.by_dir['def'])
    eq(p, state.by_order[1])
    truthy(get_rtp()[INSTALL_DIR..'/def'])
  end)

  describe('URI', function()
    it('should error on conflicting names', function()
      has_error(function()
        Plug 'abc/def'
        Plug 'ghi/def'
        Plug.load()
      end, 'Conflicting plugin name: def')
    end)

    it('should error on invalid string', function()
      has_error(function() Plug('abc') end, 'Invalid plugin URI: abc')
    end)

    it('should error on invalid type', function()
      local errmsg = 'Invalid plugin URI, expected string'
      has_error(function() Plug(nil)  end, errmsg)
      has_error(function() Plug(true) end, errmsg)
      has_error(function() Plug(0)    end, errmsg)
      has_error(function() Plug({})   end, errmsg)
    end)
  end)

  it('should error on invalid options type', function()
    local errmsg = 'Invalid plugin options, expected table'
    has_error(function() Plug 'abc/def' (nil)   end, errmsg)
    has_error(function() Plug 'abc/def' (true)  end, errmsg)
    has_error(function() Plug 'abc/def' (0)     end, errmsg)
    has_error(function() Plug 'abc/def' ('abc') end, errmsg)
  end)

  it('should error on unknown option', function()
    has_error(function() Plug 'abc/def' { ghi = 'jkl' } end,
      'Invalid option for plugin abc/def: ghi')
  end)

  describe('"as" option', function()
    it('should overwrite directory', function()
      Plug 'abc/def' { as = 'ghi' }
      Plug.load()

      local p = truthy(state.by_uri['abc/def'])
      eq(p.uri, 'abc/def')
      eq(p.as, 'ghi')
      eq(p.path, INSTALL_DIR..'/ghi')
      eq(p.order, 1)
      truthy(get_rtp()[INSTALL_DIR..'/ghi'])
    end)

    it('should error on invalid type', function()
      has_error(function() Plug 'abc/def' { as = true } end,
        'Invalid value "as" for plugin abc/def: expected string')
    end)
  end)

  describe('"run" option', function()
    it('should accept string', function()
      local f = 'echo "run"'

      Plug 'abc/def' { run = f }
      Plug.load()

      eq(state.by_uri['abc/def'].run, f)
    end)

    it('should accept lua function', function()
      local f = function() print('run') end

      Plug 'abc/def' { run = f }
      Plug.load()

      eq(state.by_uri['abc/def'].run, f)
    end)

    -- TODO: implement "run"

    it('should error on invalid type', function()
      has_error(function() Plug 'abc/def' { run = true } end,
        'Invalid value "run" for plugin abc/def: expected string or function')
    end)
  end)

  describe('"setup" option', function()
    after_each(function()
      vim.g.neopm_test = nil
    end)

    it('should run vim script commands', function()
      local f = 'let g:neopm_test = 1'
      Plug 'abc/def' { setup = f }
      Plug.load()

      eq(state.by_uri['abc/def'].setup, f)
      eq(vim.g.neopm_test, 1)
    end)

    it('should run lua functions', function()
      local f = function() vim.g.neopm_test = 1 end
      Plug 'abc/def' { setup = f }
      Plug.load()

      eq(state.by_uri['abc/def'].setup, f)
      eq(vim.g.neopm_test, 1)
    end)

    it('should error on invalid type', function()
      has_error(function() Plug 'abc/def' { setup = true } end,
        'Invalid value "setup" for plugin abc/def: expected string or function')
    end)
  end)

  describe('"depends" option', function()
    it('should implicitly add plugin', function()
      Plug 'abc/def' { depends = 'some/dep' }
      Plug 'ghi/jkl' { depends = { 'some/dep' } }
      Plug.load()

      truthy(state.by_uri['some/dep'])
      same(truthy(state.by_uri['abc/def']).depends, { 'some/dep' })
      same(truthy(state.by_uri['ghi/jkl']).depends, { 'some/dep' })
    end)

    it('should error on invalid type', function()
      has_error(function() Plug 'abc/def' { depends = true } end,
        'Invalid value "depends" for plugin abc/def: expected string or array of strings')
    end)
  end)

  describe('"ft" option', function()
    after_each(function()
      vim.cmd([[
        augroup neopm_lazy | autocmd! | augroup end
      ]])
    end)

    it('should set up single filetype', function()
      Plug 'abc/def' { ft = 'fta' }
      Plug.load()

      local p = truthy(state.by_uri['abc/def'])
      same(p.ft, { 'fta' })
      local aus = get_autocmds()
      truthy(aus.FileType)
      truthy(aus.FileType['fta'])
      falsy(get_rtp()[INSTALL_DIR..'/def'])
    end)

    it('should set up multiple filetypes', function()
      Plug 'abc/def' { ft = { 'fta', 'ftb' } }
      Plug.load()

      local p = truthy(state.by_uri['abc/def'])
      same(p.ft, { 'fta', 'ftb' })
      local aus = get_autocmds()
      truthy(aus.FileType)
      truthy(aus.FileType['fta'])
      truthy(aus.FileType['ftb'])
      falsy(get_rtp()[INSTALL_DIR..'/def'])
    end)

    -- TODO: test loading

    it('should error on invalid type', function()
      has_error(function() Plug 'abc/def' { ft = true } end,
        'Invalid value "ft" for plugin abc/def: expected string or array of strings')
    end)
  end)

  describe('"on" option', function()
    after_each(function()
      vim.cmd([[
        silent! delcommand NeopmTestA
        silent! delcommand NeopmTestB
      ]])
    end)

    it('should set up single command', function()
      Plug 'abc/def' { on = 'NeopmTestA' }
      Plug.load()

      local p = truthy(state.by_uri['abc/def'])
      same(p.on, { 'NeopmTestA' })
      local cmds = api.nvim_get_commands({})
      truthy(cmds.NeopmTestA)
    end)

    it('should set up multiple commands', function()
      Plug 'abc/def' { on = { 'NeopmTestA', 'NeopmTestB' } }
      Plug.load()

      local p = truthy(state.by_uri['abc/def'])
      same(p.on, { 'NeopmTestA', 'NeopmTestB' })
      local cmds = api.nvim_get_commands({})
      truthy(cmds.NeopmTestA)
      truthy(cmds.NeopmTestB)
    end)

    -- TODO: test loading

    it('should error on invalid type', function()
      has_error(function() Plug 'abc/def' { on = true } end,
        'Invalid value "on" for plugin abc/def: expected string or array of strings')
    end)
  end)
end)
