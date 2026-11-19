local osa = require("spotify.osa")
local actions = require("spotify.actions")
local util = require("spotify.util")
local uv = vim.uv or vim.loop

local M = { image = true }

local W, IMG_ROWS = 46, 12
local win, buf, timer, shown_art

-- snacks.image が使える端末か
local function want_image()
  if not M.image then return false end
  local ok, res = pcall(function() return Snacks.image.supports_terminal() end)
  return ok and res and true or false
end

local function bar(pos, dur, width)
  local frac = dur > 0 and math.min(pos / dur, 1) or 0
  local n = math.floor(frac * width + 0.5)
  return string.rep("━", n) .. "●" .. string.rep("─", math.max(width - n, 0))
end

local function onoff(b) return b and "on" or "off" end

local function render(st)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

  local img = st ~= nil and st.art ~= "" and want_image()
  local L = {}
  if not st then
    L = { "", "  Spotify は停止中、または未起動です" }
  else
    -- アートは snacks.image が markdown の ![](url) を描画する仕組みを利用
    if img then L[#L + 1] = "![](" .. st.art .. ")" end
    L[#L + 1] = ""
    L[#L + 1] = " " .. (st.state == "playing" and "▶ " or "⏸ ") .. st.name
    L[#L + 1] = "   " .. st.artist .. "  ·  " .. st.album
    L[#L + 1] = ""
    L[#L + 1] = " " .. bar(st.position, st.duration, W - 4)
    L[#L + 1] = (" %s / %s"):format(util.fmt_time(st.position), util.fmt_time(st.duration))
    L[#L + 1] = ""
    L[#L + 1] = (" shuffle:%s  repeat:%s  vol:%d"):format(onoff(st.shuffle), onoff(st.repeating), st.volume)
    L[#L + 1] = ""
    L[#L + 1] = " <Space>再生 n/p h/l:±10s s r y f +/- q"
  end

  vim.bo[buf].modifiable = true
  if img and shown_art == st.art then
    -- アートが同じなら画像行は触らず、テキスト部分だけ更新(ちらつき防止)
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, vim.list_slice(L, 2))
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, L)
    shown_art = img and st.art or nil
    if img and vim.bo[buf].filetype ~= "markdown" then
      vim.bo[buf].filetype = "markdown"
      pcall(function() Snacks.image.doc.attach(buf) end)
    end
  end
  vim.bo[buf].modifiable = false

  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_height, win, #L + (img and IMG_ROWS or 0))
  end
end

local function tick()
  osa.state(render)
end

local function stop_timer()
  if timer then
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end
end

function M.close()
  stop_timer()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win, buf, shown_art = nil, nil, nil
end

function M.toggle()
  if win and vim.api.nvim_win_is_valid(win) then return M.close() end

  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  shown_art = nil

  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = W,
    height = 10,
    row = 1,
    col = math.max(vim.o.columns - W - 2, 0),
    style = "minimal",
    border = "rounded",
    title = " Spotify ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", M.close)
  map("<Esc>", M.close)
  map("<Space>", osa.playpause)
  map("n", osa.next)
  map("p", osa.prev)
  map("h", function() osa.seek(-10) end)
  map("l", function() osa.seek(10) end)
  map("s", osa.toggle_shuffle)
  map("r", osa.toggle_repeat)
  map("+", function() osa.volume_delta(10) end)
  map("-", function() osa.volume_delta(-10) end)
  map("y", function() actions.copy_url(false) end)
  map("f", actions.save_current)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      stop_timer()
      win, buf, shown_art = nil, nil, nil
    end,
  })

  timer = uv.new_timer()
  timer:start(0, 1000, vim.schedule_wrap(tick))
end

return M
