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
