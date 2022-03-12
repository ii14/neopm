local uv = vim.loop
local api = vim.api
local tinsert = table.insert

local UPDATE_INTERVAL = 50 -- minimum time in ms to flush changes
local COLUMN_WIDTH    = 50 -- plugin uri column width

---@type NeopmState
local state = require('neopm.state')

---@class NeopmUpdateView
---@field bufnr number
---@field lines string[]
---@field last_update number
---@field pending_redraw boolean
local UpdateView = {}
UpdateView.__index = UpdateView

--- Create a new update view
---@return NeopmUpdateView
function UpdateView.new()
  vim.cmd([[
    enew
    setl buftype=nofile
    setl nowrap
  ]])
  local bufnr = api.nvim_get_current_buf()
  api.nvim_buf_set_option(bufnr, 'modifiable', false)

  -- TODO: reuse previous buffer
  local ok, err = pcall(api.nvim_buf_set_name, bufnr, '[neopm]')
  if not ok then
    if err:match('^Vim:E95:') then
      local created = false
      for i = 2, 99 do -- to not go forever if something goes wrong I guess
        ok, err = pcall(api.nvim_buf_set_name, bufnr, '[neopm('..i..')]')
        if ok then
          created = true
          break
        elseif not err:match('^Vim:E95:') then
          error(err)
        end
      end
      if not created then
        error('failed to create a new buffer')
      end
    else
      error(err)
    end
  end

  local lines = {}
  -- populate buffer with plugin uris
  for i, plug in ipairs(state.by_order) do
    lines[i] = plug.uri
  end
  -- add line for global status
  tinsert(lines, '')

  local this = setmetatable({
    bufnr = bufnr,
    lines = lines,
    last_update = uv.now(),
    pending_redraw = false,
  }, UpdateView)

  return this
end

--- Set plugin status string
---@param plug NeopmPlug
---@param status string
function UpdateView:set(plug, status)
  self.lines[plug.order] = plug.uri..string.rep(' ', COLUMN_WIDTH - #plug.uri)..status
  self.pending_redraw = true
end

--- Set global status string
---@param status string
function UpdateView:global(status)
  self.lines[#self.lines] = status
  self.pending_redraw = true
  self:flush(true)
end

--- Flush changes to the buffer
---@param force? boolean  Update the buffer immediately
function UpdateView:flush(force)
  if not self.pending_redraw then
    return
  end

  local now = uv.now()
  if not force and now - self.last_update < UPDATE_INTERVAL then
    return
  end

  self.last_update = now
  self.pending_redraw = false
  api.nvim_buf_set_option(self.bufnr, 'modifiable', true)
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, self.lines)
  api.nvim_buf_set_option(self.bufnr, 'modifiable', false)
  vim.cmd('redraw')
end

return UpdateView
