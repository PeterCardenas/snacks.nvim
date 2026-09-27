---@module "luassert"

local Herdr = require("snacks.image.herdr")

describe("image.herdr", function()
  it("requires both a compatible version and the legacy graphics capability", function()
    assert.is_true(Herdr.compatible("herdr 0.9.1", {
      type = "pane_graphics_info",
      max_layers_per_pane = 16,
    }))
    assert.is_false(Herdr.compatible("herdr 0.9.1", { error = { code = "unknown_method" } }))
    assert.is_false(Herdr.compatible("herdr 0.9.2", { type = "pane_graphics_info" }))
    assert.is_false(Herdr.compatible("herdr dev", { type = "pane_graphics_info" }))
  end)

  it("places a fully visible image without changing its geometry", function()
    local old_screenpos = vim.fn.screenpos
    local old_getwininfo = vim.fn.getwininfo
    vim.fn.screenpos = function()
      return { row = 5, col = 8 }
    end
    vim.fn.getwininfo = function()
      return { { winrow = 3, wincol = 2, width = 100, height = 40, topline = 5, botline = 44 } }
    end
    local placement = Herdr.position({ opts = { inline = true, pos = { 10, 2 } } }, {
      loc = { width = 80, height = 20 },
    }, 11)
    vim.fn.screenpos = old_screenpos
    vim.fn.getwininfo = old_getwininfo
    assert.same({ viewport_col = 7, viewport_row = 4, grid_cols = 80, grid_rows = 20 }, placement)
  end)

  it("hides a placement rather than scaling it into a clipped window", function()
    local old_screenpos = vim.fn.screenpos
    local old_getwininfo = vim.fn.getwininfo
    vim.fn.screenpos = function()
      return { row = 12, col = 8 }
    end
    vim.fn.getwininfo = function()
      return { { winrow = 3, wincol = 2, width = 40, height = 10, topline = 5, botline = 14 } }
    end
    local placement = Herdr.position({ opts = { inline = true, pos = { 10, 2 } } }, {
      loc = { width = 80, height = 20 },
    }, 11)
    vim.fn.screenpos = old_screenpos
    vim.fn.getwininfo = old_getwininfo
    assert.is_nil(placement)
  end)

  it("does not pin an off-screen inline placement to the window origin", function()
    local old_screenpos = vim.fn.screenpos
    vim.fn.screenpos = function()
      return { row = 0, col = 0 }
    end
    local placement = Herdr.position({ opts = { inline = true, pos = { 100, 0 } } }, {
      loc = { width = 80, height = 20 },
    }, 11)
    vim.fn.screenpos = old_screenpos
    assert.is_nil(placement)
  end)

  it("detects overlapping floating windows", function()
    assert.is_true(
      Herdr.overlaps({ row = 4, col = 8, width = 80, height = 20 }, { row = 10, col = 20, width = 30, height = 5 })
    )
    assert.is_false(
      Herdr.overlaps({ row = 4, col = 8, width = 80, height = 20 }, { row = 30, col = 20, width = 30, height = 5 })
    )
  end)

  it("builds one PNG layer per placement and window", function()
    local payload = Herdr.payload({ img = { id = 42 }, id = 7 }, {
      loc = { width = 80, height = 20 },
    }, 11, { 3, 5 }, 1821, 1080, "aGVsbG8=")
    assert.same("pane.graphics.set", payload.method)
    assert.same("snacks-42-7-11", payload.params.layer_id)
    assert.same("png", payload.params.format)
    assert.same(1821, payload.params.image_width)
    assert.same(1080, payload.params.image_height)
    assert.same({ viewport_col = 5, viewport_row = 2, grid_cols = 80, grid_rows = 20 }, payload.params.placement)
    assert.same("aGVsbG8=", payload.params.data_base64)
  end)
end)
