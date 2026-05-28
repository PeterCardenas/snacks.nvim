---@module "luassert"

local inline = require("snacks.image.inline")

describe("image.inline scrolling", function()
  local old_find_visible = Snacks.image.doc.find_visible
  local old_new = Snacks.image.placement.new
  local old_win_findbuf = vim.fn.win_findbuf
  local old_getwininfo = vim.fn.getwininfo

  local function count(tbl)
    return vim.tbl_count(tbl)
  end

  after_each(function()
    Snacks.image.doc.find_visible = old_find_visible
    Snacks.image.placement.new = old_new
    vim.fn.win_findbuf = old_win_findbuf
    vim.fn.getwininfo = old_getwininfo
  end)

  local function fake_doc(state)
    local doc = setmetatable({
      buf = 1,
      imgs = {},
      matches = {},
      idx = {},
      _visible = state.visible,
    }, inline)

    function doc:visible()
      return self._visible
    end

    return doc
  end

  local function stub_placements()
    local created = 0
    local closed = {}

    Snacks.image.placement.new = function(_, src, opts)
      created = created + 1
      local placement = {
        id = created,
        img = { src = src },
        opts = opts,
        eids = { created },
        updates = 0,
        close = function(self)
          closed[self.id] = true
        end,
        update = function(self)
          self.updates = self.updates + 1
        end,
      }
      if opts.on_update then
        opts.on_update(placement)
      end
      return placement
    end

    return closed
  end

  it("reuses an off-screen placement when the source becomes visible again", function()
    local state = {
      matches = {
        {
          id = "image-1",
          src = "/tmp/image.png",
          pos = { 10, 0 },
          range = { 10, 0, 10, 12 },
          lang = "markdown",
          type = "image",
        },
      },
      visible = {},
    }

    Snacks.image.doc.find_visible = function(_, cb)
      cb(vim.deepcopy(state.matches))
    end
    stub_placements()

    local doc = fake_doc(state)
    doc:update()
    local first = vim.tbl_values(doc.imgs)[1]

    state.matches = {}
    state.visible = { [first.id] = first }
    doc._visible = state.visible
    doc:update()
    assert.are.equal(1, count(doc.imgs), "expected the off-screen placement to stay tracked")

    state.matches = {
      {
        id = "image-1",
        src = "/tmp/image.png",
        pos = { 10, 0 },
        range = { 10, 0, 10, 12 },
        lang = "markdown",
        type = "image",
      },
    }
    state.visible = {}
    doc._visible = state.visible
    doc:update()

    assert.are.equal(1, count(doc.imgs), "expected to reuse the existing placement")
    local second = vim.tbl_values(doc.imgs)[1]
    assert.are.equal(first.id, second.id, "expected the original placement id to be preserved")
  end)

  it("closes placements that are neither source-visible nor render-visible", function()
    local state = {
      matches = {
        {
          id = "image-1",
          src = "/tmp/image.png",
          pos = { 10, 0 },
          range = { 10, 0, 10, 12 },
          lang = "markdown",
          type = "image",
        },
      },
      visible = {},
    }

    Snacks.image.doc.find_visible = function(_, cb)
      cb(vim.deepcopy(state.matches))
    end
    local closed = stub_placements()

    local doc = fake_doc(state)
    doc:update()
    local first = vim.tbl_values(doc.imgs)[1]

    state.matches = {}
    doc:update()

    assert.are.equal(0, count(doc.imgs), "expected invisible placements to be cleaned up")
    assert.is_true(closed[first.id], "expected the stale placement to be closed")
  end)

  it("treats virt_lines spillover as visible after the anchor scrolls above the viewport", function()
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(function(i)
      return ("Line %02d"):format(i)
    end, vim.fn.range(1, 40)))

    local eid = vim.api.nvim_buf_set_extmark(buf, Snacks.image.placement.ns, 23, 0, {
      virt_lines = vim.tbl_map(function(i)
        return { { ("virt %02d"):format(i) } }
      end, vim.fn.range(1, 15)),
    })

    local placement = {
      id = 1,
      img = { src = "/tmp/image.png" },
      opts = { range = { 12, 0, 22, 0 } },
      eids = { eid },
    }
    local doc = setmetatable({
      buf = buf,
      imgs = { [placement.id] = placement },
      matches = {},
      idx = { [eid] = placement },
    }, inline)
    local win = vim.api.nvim_get_current_win()

    vim.fn.win_findbuf = function(query_buf)
      return query_buf == buf and { win } or {}
    end
    vim.fn.getwininfo = function(query_win)
      if query_win == win then
        return {
          {
            topline = 26,
            botline = 33,
          },
        }
      end
      return {}
    end

    assert.are.equal(
      1,
      count(doc:visible()),
      "expected the placement to stay visible while virt_lines still spill into the window"
    )
  end)
end)
