local osa = require("spotify.osa")
local auth = require("spotify.auth")
local util = require("spotify.util")
local actions = require("spotify.actions")
local uv = vim.uv or vim.loop

local M = {}

M.opts = {
  interval = 3000, -- lualine用の更新間隔(ms)
  max_len = 40,    -- lualineに出す最大文字数
  image = true,    -- Now Playingにアルバムアートを出す(snacks.image対応端末のみ)
  keymaps = true,  -- <leader>s 系のキーマップを登録する
  client_id = nil, -- 未指定なら $SPOTIFY_CLIENT_ID
  client_secret = nil,
  port = 8888,
}

-- ───────── lualine用の表示 ─────────
function M.refresh()
  osa.state(function(st)
    local s = ""
    if st then
      s = (st.state == "playing" and "▶ " or "⏸ ") .. st.name .. " - " .. st.artist
      local max = M.opts.max_len
      if vim.fn.strchars(s) > max then
        s = vim.fn.strcharpart(s, 0, max - 1) .. "…"
      end
      if st.shuffle then s = s .. " ⇄" end
      if st.repeating then s = s .. " ↻" end
    end
    if s ~= vim.g.spotify_now then
      vim.g.spotify_now = s
      pcall(function() require("lualine").refresh() end)
    end
  end)
end

local timer
function M.start_timer()
  if timer then return end
  timer = uv.new_timer()
  timer:start(0, M.opts.interval, vim.schedule_wrap(M.refresh))
end

function M.stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

-- ───────── 連打モード ─────────
function M.hydra()
  local keys = {
    [" "] = osa.playpause,
    n = osa.next,
    p = osa.prev,
    h = function() osa.seek(-10) end,
    l = function() osa.seek(10) end,
    ["+"] = function() osa.volume_delta(10) end,
    ["-"] = function() osa.volume_delta(-10) end,
    s = osa.toggle_shuffle,
    r = osa.toggle_repeat,
    y = function() actions.copy_url(false) end,
    f = actions.save_current,
  }
  local help = "Spotify  Space:再生 n/p:次/前 h/l:±10s +/-:音量 s:shuffle r:repeat y:URL f:保存  q/Esc:終了"
  while true do
    vim.api.nvim_echo({ { help .. "  " .. (vim.g.spotify_now or ""), "Question" } }, false, {})
    vim.cmd.redraw()
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == "\27" or ch == "q" then break end
    local fn = keys[ch]
    if fn then fn() end
  end
  vim.api.nvim_echo({ { "" } }, false, {})
end

-- ───────── :Spotify コマンド ─────────
local function picker() return require("spotify.picker") end

local C = {
  search = function() picker().search() end,
  library = function(a)
    if a[1] then picker().library(a[1]) else picker().library_menu() end
  end,
  now = function() require("spotify.ui").toggle() end,
  play = function() osa.playpause() end,
  next = function() osa.next() end,
  prev = function() osa.prev() end,
  seek = function(a) osa.seek(tonumber(a[1]) or 10) end,
  volume = function(a)
    local v = a[1]
    if not (v and tonumber(v)) then
      return util.notify("使い方: :Spotify volume 50 / +10 / -10", vim.log.levels.WARN)
    end
    if v:match("^[+-]") then osa.volume_delta(tonumber(v)) else osa.volume_set(tonumber(v)) end
  end,
  shuffle = function() osa.toggle_shuffle() end,
  ["repeat"] = function() osa.toggle_repeat() end,
  url = function() actions.copy_url(false) end,
  save = function() actions.save_current() end,
  hydra = function() M.hydra() end,
  login = function() auth.login() end,
  logout = function() auth.logout() end,
}

local names = vim.tbl_keys(C)
table.sort(names)

local function create_command()
  vim.api.nvim_create_user_command("Spotify", function(o)
    local args = vim.split(o.args, "%s+", { trimempty = true })
    local sub = table.remove(args, 1) or "now"
    local fn = C[sub]
    if not fn then
      return util.notify("不明なサブコマンド: " .. sub, vim.log.levels.WARN)
    end
    fn(args)
  end, {
    nargs = "*",
    desc = "Spotify control",
    complete = function(lead, line)
      local parts = vim.split(line, "%s+")
      if #parts <= 2 then
        return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, names)
      elseif parts[2] == "library" then
        return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, { "playlist", "track", "album" })
      end
      return {}
    end,
  })
end

-- ───────── setup ─────────
function M.setup(opts)
  M.opts = vim.tbl_extend("force", M.opts, opts or {})
  auth.config.client_id = M.opts.client_id
  auth.config.client_secret = M.opts.client_secret
  auth.config.port = M.opts.port
  require("spotify.ui").image = M.opts.image
  osa.after = M.refresh
  vim.g.spotify_now = vim.g.spotify_now or ""

  create_command()

  if M.opts.keymaps then
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { desc = "Spotify: " .. desc })
    end
    map("<leader>ss", C.search, "検索(曲/アルバム/プレイリスト/アーティスト)")
    map("<leader>sL", function() C.library({}) end, "ライブラリ")
    map("<leader>si", C.now, "Now Playing")
    map("<leader>sp", osa.playpause, "play/pause")
    map("<leader>sn", osa.next, "next")
    map("<leader>sb", osa.prev, "prev")
    map("<leader>sh", function() osa.seek(-10) end, "-10秒")
    map("<leader>sl", function() osa.seek(10) end, "+10秒")
    map("<leader>sz", osa.toggle_shuffle, "shuffle")
    map("<leader>sr", osa.toggle_repeat, "repeat")
    map("<leader>s+", function() osa.volume_delta(10) end, "volume up")
    map("<leader>s-", function() osa.volume_delta(-10) end, "volume down")
    map("<leader>sy", function() actions.copy_url(false) end, "URLをコピー")
    map("<leader>sY", function() actions.copy_url(true) end, "URLをカーソル位置に挿入")
    map("<leader>sf", actions.save_current, "現在の曲をライブラリに保存")
    map("<leader>s.", M.hydra, "連打モード")
  end

  M.start_timer()
end

return M
