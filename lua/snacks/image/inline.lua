---@class snacks.image.inline
---@field buf number
---@field imgs table<number, snacks.image.Placement>
---@field matches table<string|number, snacks.image.Placement>
---@field idx table<number, snacks.image.Placement>
local M = {}
M.__index = M

function M.new(buf)
  local self = setmetatable({}, M)
  self.buf = buf
  self.imgs = {}
  self.matches = {}
  self.idx = {}
  local group = vim.api.nvim_create_augroup("snacks.image.inline." .. buf, { clear = true })

  local update = Snacks.util.debounce(function()
    self:update()
  end, { ms = 100 })

  vim.api.nvim_create_autocmd({ "BufWritePost", "WinScrolled", "BufWinEnter" }, {
    group = group,
    buffer = buf,
    callback = vim.schedule_wrap(update),
  })
  vim.api.nvim_create_autocmd({ "ModeChanged", "CursorMoved" }, {
    group = group,
    buffer = buf,
    callback = function(ev)
      if ev.buf == self.buf and ev.buf == vim.api.nvim_get_current_buf() then
        self:conceal()
      end
    end,
  })
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = update,
  })
  vim.schedule(update)
  return self
end

function M:conceal()
  local mode = vim.fn.mode():sub(1, 1):lower() ---@type string
  for _, img in pairs(self.imgs) do
    img:show()
  end
  if vim.wo.concealcursor:find(mode) then
    return
  end
  local from, to = vim.fn.line("v"), vim.fn.line(".")
  from, to = math.min(from, to), math.max(from, to)
  local hide = self:get(from, to)
  for _, img in pairs(hide) do
    if img.opts.conceal then
      img:hide()
    end
  end
end

function M:visible()
  local ret = {} ---@type table<number, snacks.image.Placement>
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    local info = vim.fn.getwininfo(win)[1]
    local top = math.max(info.topline - 1, 1)
    for _, img in pairs(self.imgs) do
      if self:is_visible(img, top, info.botline) then
        ret[img.id] = img
      end
    end
  end
  return ret
end

---@param from number 1-indexed inclusive
---@param to number 1-indexed inclusive
function M:get(from, to)
  local ret = {} ---@type table<number, snacks.image.Placement>
  local marks = vim.api.nvim_buf_get_extmarks(self.buf, Snacks.image.placement.ns, { from - 1, 0 }, { to, -1 }, {
    overlap = true,
    hl_name = false,
  })
  for _, m in ipairs(marks) do
    local p = self.idx[m[1]] ---@type snacks.image.Placement?
    if p and not self.imgs[p.id] then
      self.idx[m[1]] = nil
      p = nil
    end
    if p then
      ret[p.id] = p
    end
  end
  return ret
end

---@param img snacks.image.Placement
---@param top number
---@param bottom number
---@return boolean
function M:is_visible(img, top, bottom)
  for _, eid in ipairs(img.eids) do
    local ok, extmark = pcall(vim.api.nvim_buf_get_extmark_by_id, self.buf, Snacks.image.placement.ns, eid, {
      details = true,
    })
    if ok and extmark and #extmark > 0 then
      local row = extmark[1] + 1
      local details = extmark[3] or {}
      if row >= top and row <= bottom then
        return true
      end
      local virt_lines = details.virt_lines and #details.virt_lines or 0
      -- Virtual lines render below the anchor row and can still occupy the window
      -- after the source line itself has scrolled above the viewport.
      if virt_lines > 0 and row < top and row + virt_lines >= top then
        return true
      end
    end
  end
  return false
end

---@param match snacks.image.match
---@return snacks.image.Placement?
function M:find(match)
  local placement = self.matches[match.id]
  if placement and self.imgs[placement.id] then
    return placement
  end
  for _, img in pairs(self.imgs) do
    if img.img.src == match.src and vim.deep_equal(img.opts.range, match.range) then
      return img
    end
  end
end

---@param placement snacks.image.Placement
---@param match_id string|number
function M:track(placement, match_id)
  if placement._match_id and placement._match_id ~= match_id then
    self.matches[placement._match_id] = nil
  end
  placement._match_id = match_id
  self.matches[match_id] = placement
end

---@param placement snacks.image.Placement
function M:forget(placement)
  if placement._match_id then
    self.matches[placement._match_id] = nil
    placement._match_id = nil
  end
end

function M:update()
  local conceal = Snacks.image.config.doc.conceal
  conceal = type(conceal) ~= "function" and function()
    return conceal
  end or conceal
  local render_mode = Snacks.image.config.doc.render_mode
  render_mode = type(render_mode) ~= "function" and function()
    return render_mode or "inline"
  end or render_mode
  Snacks.image.doc.find_visible(self.buf, function(imgs)
    if not vim.api.nvim_buf_is_valid(self.buf) then
      return
    end
    local visible = self:visible()
    local stale = vim.deepcopy(self.imgs)
    local stats = { new = 0, del = 0, update = 0 }
    for _, i in ipairs(imgs) do
      local img = self:find(i)
      if not img then
        stats.new = stats.new + 1
        img = Snacks.image.placement.new(
          self.buf,
          i.src,
          Snacks.config.merge({}, Snacks.image.config.doc, {
            pos = i.pos,
            range = i.range,
            inline = true,
            conceal = vim.b[self.buf].snacks_image_conceal or conceal(i.lang, i.type, i.src),
            render_mode = render_mode(i.lang, i.type, i.src),
            type = i.type,
            ---@param p snacks.image.Placement
            on_update = function(p)
              for _, eid in ipairs(p.eids) do
                self.idx[eid] = p
              end
            end,
          })
        )
        self:track(img, i.id)
        for _, eid in ipairs(img.eids) do
          self.idx[eid] = img
        end
        self.imgs[img.id] = img
      else
        stats.update = stats.update + 1
        self:track(img, i.id)
        img.opts.pos = i.pos
        img.opts.range = i.range
        img:update()
      end
      stale[img.id] = nil
    end
    for _, img in pairs(stale) do
      -- Keep placements alive while their rendered extmarks are still on-screen.
      if not visible[img.id] then
        stats.del = stats.del + 1
        self:forget(img)
        img:close()
        self.imgs[img.id] = nil
      end
    end
    for k, v in pairs(stats) do
      stats[k] = v > 0 and v or nil
    end
    -- Snacks.notify(
    --   vim.inspect({ all = vim.tbl_count(self.imgs), stats = stats }),
    --   { ft = "lua", id = "snacks.image.inline" }
    -- )
  end)
end

return M
