---@class snacks.image.buf
local M = {}

---@param buf number
---@param opts? snacks.image.Opts|{src?: string}
function M._attach(buf, opts)
  Snacks.image.placement.clean(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  opts = opts or {}
  local file = opts.src or vim.api.nvim_buf_get_name(buf)
  if Snacks.image.config.ignore and Snacks.image.config.ignore(file) then
    return
  end
  if not Snacks.image.supports(file) then
    local lines = {} ---@type string[]
    lines[#lines + 1] = "# Image viewer"
    lines[#lines + 1] = "- **file**: `" .. file .. "`"
    if not Snacks.image.supports_file(file) then
      lines[#lines + 1] = "- unsupported image format"
    end
    if not Snacks.image.supports_terminal() then
      lines[#lines + 1] = "- terminal does not support the kitty graphics protocol."
      lines[#lines + 1] = "  See `:checkhealth snacks` for more info."
    end
    vim.bo[buf].modifiable = true
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(table.concat(lines, "\n"), "\n"))
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  else
    -- Evaluate render_mode for this file
    local render_mode = Snacks.image.config.doc.render_mode
    if type(render_mode) == "function" then
      render_mode = render_mode(nil, "image", file)
    end

    if render_mode == "virt_lines" then
      -- Keep source text visible, render image as virtual lines below
      local lines = vim.fn.readfile(file)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local ext = vim.fn.fnamemodify(file, ":e"):lower()
      local ft_map = { svg = "xml" }
      Snacks.util.bo(buf, {
        filetype = ft_map[ext] or ext,
        modified = false,
        swapfile = false,
      })
      local line_count = vim.api.nvim_buf_line_count(buf)
      local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
      opts.render_mode = "virt_lines"
      opts.inline = true
      opts.auto_resize = true
      opts.pos = { line_count, 0 }
      opts.range = { line_count, 0, line_count, #last_line }
      return Snacks.image.placement.new(buf, file, opts)
    else
      Snacks.util.bo(buf, {
        filetype = "image",
        modifiable = false,
        modified = false,
        swapfile = false,
      })
      opts.conceal = true
      opts.auto_resize = true
      return Snacks.image.placement.new(buf, file, opts)
    end
  end
end

---@param buf number
---@param opts? snacks.image.Opts|{src?: string}
function M.attach(buf, opts)
  if Snacks.image.config.enabled == false then
    return
  end
  local Terminal = require("snacks.image.terminal")
  Terminal.detect(function()
    M._attach(buf, opts)
  end)
end

return M
