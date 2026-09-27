---@class snacks.image.herdr
local M = {}

local checked = false
local available = false
local info ---@type table?
local request_id = 0
local layers = {} ---@type table<string, string>
local pending = {} ---@type table<string, { next: { payload: table, callback: fun(ok: boolean)? }? }>
local encoded = {} ---@type table<string, string>

---@param version string
---@param result table
function M.compatible(version, result)
  local major, minor, patch = version:match("(%d+)%.(%d+)%.(%d+)")
  if not major then
    return false
  end
  local numeric = tonumber(major) * 1e6 + tonumber(minor) * 1e3 + tonumber(patch)
  return numeric >= 7004 and numeric <= 9001 and result.type == "pane_graphics_info"
end

---@param placement snacks.image.Placement
---@param state snacks.image.State
---@param win number
---@param cursor {[1]: number, [2]: number}
---@param width number
---@param height number
---@param data string
function M.payload(placement, state, win, cursor, width, height, data)
  return {
    id = "snacks-image",
    method = "pane.graphics.set",
    params = {
      pane_id = vim.env.HERDR_PANE_ID,
      layer_id = ("snacks-%d-%d-%d"):format(placement.img.id, placement.id, win),
      format = "png",
      image_width = width,
      image_height = height,
      data_base64 = data,
      placement = {
        viewport_col = cursor[2],
        viewport_row = cursor[1] - 1,
        grid_cols = state.loc.width,
        grid_rows = state.loc.height,
      },
    },
  }
end

---@param payload table
---@param callback? fun(ok: boolean)
---@param wait? boolean
---@return table?
local function request(payload, callback, wait)
  request_id = request_id + 1
  payload.id = "snacks-image-" .. request_id
  local command = { "nc", "-N", "-U", vim.env.HERDR_SOCKET_PATH }
  local options = { stdin = vim.json.encode(payload) .. "\n", text = true }
  if wait then
    local result = vim.system(command, options):wait(500)
    if result.code ~= 0 or result.stdout == "" then
      return nil
    end
    local ok, response = pcall(vim.json.decode, result.stdout)
    return ok and response or nil
  end
  vim.system(command, options, function(result)
    local ok = result.code == 0 and result.stdout ~= ""
    if ok then
      local decoded, response = pcall(vim.json.decode, result.stdout)
      ok = decoded and response.error == nil
    end
    if callback then
      vim.schedule(function()
        callback(ok)
      end)
    end
  end)
end

local function check()
  if checked then
    return available
  end
  checked = true
  if
    Snacks.image.config.herdr == false
    or vim.env.HERDR_ENV ~= "1"
    or not vim.env.HERDR_SOCKET_PATH
    or not vim.env.HERDR_PANE_ID
    or vim.fn.executable("nc") ~= 1
    or vim.fn.executable("herdr") ~= 1
  then
    return false
  end
  local version = vim.system({ "herdr", "--version" }, { text = true }):wait(500)
  if version.code ~= 0 then
    return false
  end
  local response = request({
    method = "pane.graphics.info",
    params = { pane_id = vim.env.HERDR_PANE_ID },
  }, nil, true)
  info = response and response.result or nil
  available = info ~= nil and M.compatible(version.stdout, info)
  return available
end

function M.enabled()
  return check()
end

local function file_data(path)
  if encoded[path] then
    return encoded[path]
  end
  local file = io.open(path, "rb")
  if not file then
    return
  end
  local data = file:read("*a")
  file:close()
  encoded[path] = vim.base64.encode(data)
  return encoded[path]
end

---@param a { row: number, col: number, width: number, height: number }
---@param b { row: number, col: number, width: number, height: number }
function M.overlaps(a, b)
  return a.col < b.col + b.width and a.col + a.width > b.col and a.row < b.row + b.height and a.row + a.height > b.row
end

---@param position table
---@param win number
local function occluded(position, win)
  local image = {
    row = position.viewport_row,
    col = position.viewport_col,
    width = position.grid_cols,
    height = position.grid_rows,
  }
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if other ~= win and vim.api.nvim_win_get_config(other).relative ~= "" then
      local info = vim.fn.getwininfo(other)[1]
      if
        info
        and M.overlaps(image, {
          row = info.winrow - 1,
          col = info.wincol - 1,
          width = info.width,
          height = info.height,
        })
      then
        return true
      end
    end
  end
  return false
end

---@param placement snacks.image.Placement
---@param state snacks.image.State
---@param win number
---@return table?
function M.position(placement, state, win)
  local cursor
  if placement.opts.inline then
    local pos = placement.opts.pos or { 1, 0 }
    local range = placement.opts.range
    local row = range and range[3] or pos[1]
    local col = range and range[2] or pos[2]
    if placement.opts.render_mode == "virt_lines" then
      row = row + 1
      col = 0
    end
    local ok, screen = pcall(vim.fn.screenpos, win, row, col + 1)
    if not ok or not screen or screen.row <= 0 or screen.col <= 0 then
      return
    end
    cursor = { screen.row, screen.col - 1 }
  else
    cursor = placement:_fallback_cursor(win)
  end
  if not cursor then
    return
  end
  local window = vim.fn.getwininfo(win)[1]
  if not window then
    return
  end
  local last_row = window.winrow + window.height - 1
  local last_col = window.wincol + window.width - 1
  if
    cursor[1] < window.winrow
    or cursor[2] + 1 < window.wincol
    or cursor[1] + state.loc.height - 1 > last_row
    or cursor[2] + state.loc.width > last_col
  then
    return
  end
  return {
    viewport_col = cursor[2],
    viewport_row = cursor[1] - 1,
    grid_cols = state.loc.width,
    grid_rows = state.loc.height,
  }
end

---@param layer string
---@param payload table
---@param callback? fun(ok: boolean)
local function layer_request(layer, payload, callback)
  if pending[layer] then
    pending[layer].next = { payload = payload, callback = callback }
    return
  end
  pending[layer] = {}
  request(payload, function(ok)
    local next = pending[layer] and pending[layer].next
    pending[layer] = nil
    if callback then
      callback(ok)
    end
    if ok and next then
      layer_request(layer, next.payload, next.callback)
    end
  end)
end

local function clear_layer(layer)
  layers[layer] = nil
  layer_request(layer, {
    method = "pane.graphics.clear",
    params = { pane_id = vim.env.HERDR_PANE_ID, layer_id = layer },
  })
end

---@param placement snacks.image.Placement
---@param state snacks.image.State
function M.render(placement, state)
  if not placement.img._herdr or not check() then
    return false
  end
  local prefix = ("snacks-%d-%d-"):format(placement.img.id, placement.id)
  local desired = {} ---@type table<string, true>
  local data = file_data(placement.img.file)
  local image = placement.img.info and placement.img.info.size
  if not state.hidden and data and image then
    for _, win in ipairs(state.wins) do
      local position = M.position(placement, state, win)
      if position and position.grid_cols > 0 and position.grid_rows > 0 and not occluded(position, win) then
        local visible = { loc = { width = position.grid_cols, height = position.grid_rows } }
        local cursor = { position.viewport_row + 1, position.viewport_col }
        local payload = M.payload(placement, visible, win, cursor, image.width, image.height, data)
        local layer = payload.params.layer_id
        local signature = vim.inspect(payload.params.placement)
        desired[layer] = true
        if layers[layer] ~= signature then
          layers[layer] = signature
          layer_request(layer, payload, function(ok)
            if ok then
              return
            end
            available = false
            placement.img._herdr = nil
            placement.img.sent = false
            placement._state = nil
            placement.img:send()
          end)
        end
      end
    end
  end
  for layer in pairs(layers) do
    if vim.startswith(layer, prefix) and not desired[layer] then
      clear_layer(layer)
    end
  end
  return true
end

---@param placement snacks.image.Placement
function M.clear(placement)
  if not placement.img._herdr then
    return
  end
  local prefix = ("snacks-%d-%d-"):format(placement.img.id, placement.id)
  for layer in pairs(layers) do
    if vim.startswith(layer, prefix) then
      clear_layer(layer)
    end
  end
end

function M.reset()
  checked = false
  available = false
  info = nil
  request_id = 0
  layers = {}
  pending = {}
  encoded = {}
end

return M
