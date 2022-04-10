local Command = {}

---@type NeopmState
local state
local function load_state()
  if state then
    return true
  end

  local ok, res = pcall(require, 'neopm.state')
  if not ok then
    return false
  end

  state = res
  return true
end

local function echo(msg, hl, history)
  vim.api.nvim_echo({{msg, hl}}, history or false, {})
end

local RE_CMD = vim.regex([=[\C\v^\s*N%[eopm]>%(\s+|$)\zs]=])

local RE_INSTALL = vim.regex([=[\c\v^%[install]$]=])
local RE_UPDATE  = vim.regex([=[\c\v^%[update]$]=])

function Command.complete(ArgLead, CmdLine, CursorPos)
  if not load_state() then return {} end

  -- trim out everything after cursor position
  CmdLine = CmdLine:sub(1, CursorPos)
  -- find :Neopm position
  local start = RE_CMD:match_str(CmdLine)
  if not start then return {} end
  -- trim :Neopm and split arguments
  local args = CmdLine:sub(start + 1)
  args = vim.split(args, '%s+', { trimempty = true })
  -- ignore if there are more arguments than 1 for now
  if #args > 1 then return {} end

  local res = {}

  if RE_INSTALL:match_str(ArgLead) then
    res[#res+1] = 'install'
  end
  if RE_UPDATE:match_str(ArgLead) then
    res[#res+1] = 'update'
  end

  return res
end

function Command.run(args)
  args = vim.split(args, '%s+', { trimempty = true })

  if #args == 0 then
    return echo('Neopm: command required', 'ErrorMsg')
  end
  if #args > 1 then
    return echo('Neopm: unexpected argument', 'ErrorMsg')
  end

  local arg = args[1]
  if RE_INSTALL:match_str(arg) then
    require('neopm').install()
  elseif RE_UPDATE:match_str(arg) then
    require('neopm').update()
  else
    echo('Neopm: invalid command', 'ErrorMsg')
  end
end

return Command
