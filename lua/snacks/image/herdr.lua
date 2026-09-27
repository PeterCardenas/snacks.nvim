---@class snacks.image.herdr
local M = {}

local checked = false
local available = false
local info ---@type table?
local request_id = 0
local layers = {} ---@type table<string, true>
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

---@param placement snacks.image.Placement
---@param state snacks.image.State
function M.render(placement, state)
  if not placement.img._herdr or not check() then
    return false
  end
  local data = file_data(placement.img.file)
  local image = placement.img.info and placement.img.info.size
  if not data or not image then
    return false
  end
  for _, win in ipairs(state.wins) do
    local cursor = placement:_fallback_cursor(win)
    if cursor then
      local payload = M.payload(placement, state, win, cursor, image.width, image.height, data)
      local layer = payload.params.layer_id
      layers[layer] = true
      request(payload, function(ok)
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
      layers[layer] = nil
      request({
        method = "pane.graphics.clear",
        params = { pane_id = vim.env.HERDR_PANE_ID, layer_id = layer },
      })
    end
  end
end

function M.reset()
  checked = false
  available = false
  info = nil
  request_id = 0
  layers = {}
  encoded = {}
end

return M
