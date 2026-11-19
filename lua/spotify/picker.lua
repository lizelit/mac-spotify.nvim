local api = require("spotify.api")
local osa = require("spotify.osa")
local auth = require("spotify.auth")
local util = require("spotify.util")

local M = {}

local TAG = { track = "♪", album = "◉", playlist = "☰", artist = "★" }
local cache = {} -- uri -> 子要素(アルバムの曲一覧など)

-- ───────── 表示 ─────────
local function format(item)
  return {
    { (TAG[item.kind] or "?") .. " ", "SnacksPickerSpecial" },
    { item.name, "SnacksPickerLabel" },
    { item.sub ~= "" and ("  " .. item.sub) or "", "SnacksPickerComment" },
    { item.extra ~= "" and ("  (" .. item.extra .. ")") or "", "SnacksPickerDir" },
  }
end

-- ───────── 子要素の取得(ドリルダウン / プレビュー共通) ─────────
local function children(item, cb)
  if cache[item.uri] then return cb(cache[item.uri]) end
  local function done(items, err, code)
    if items then cache[item.uri] = items end
    cb(items, err, code)
  end
  if item.kind == "album" then
    api.album_tracks(item, done)
  elseif item.kind == "playlist" then
    api.playlist_tracks(item, done)
  elseif item.kind == "artist" then
    api.artist_albums(item, done)
  else
    cb({})
  end
end

-- ───────── プレビュー ─────────
local function preview(ctx)
  local item = ctx.item
  if not item then return end
  ctx.preview:reset()
  ctx.preview:set_title(item.name)

  local function show(lines)
    if ctx.item ~= item then return end -- 選択が移動していたら破棄
    pcall(function() ctx.preview:set_lines(lines) end)
  end

  if item.kind == "track" then
    return show({ item.name, "", "Artist: " .. item.sub, "Album : " .. item.extra })
  end

  show({ "読み込み中…" })
  children(item, function(items, err)
    vim.schedule(function()
      if not items then return show({ "取得できませんでした: " .. tostring(err) }) end
      local lines = {}
      for i, it in ipairs(items) do
        local tail = it.kind == "track" and it.extra or it.sub
        lines[#lines + 1] = ("%2d  %s  %s"):format(i, it.name, tail)
      end
      show(#lines > 0 and lines or { "(空)" })
    end)
  end)
end

-- ───────── 共通オプション ─────────
function M.activate(item)
  if item.kind == "artist" then return M.open_children(item) end
  osa.play_uri(item.uri, item.context)
  util.notify("▶ " .. item.name .. (item.sub ~= "" and (" - " .. item.sub) or ""))
end

local function base(opts)
  return vim.tbl_deep_extend("force", {
    format = format,
    preview = preview,
    confirm = function(picker, item)
      picker:close()
      if item then M.activate(item) end
    end,
    actions = {
      -- 中身を開く(アルバム→曲、プレイリスト→曲、アーティスト→アルバム)
      spotify_children = function(picker, item)
        if item and item.kind ~= "track" then
          picker:close()
          M.open_children(item)
        end
      end,
      -- キューに追加(曲のみ)
      spotify_queue = function(_, item)
        if not item or item.kind ~= "track" then
          return util.notify("キューに追加できるのは曲だけです(<C-t> で曲一覧を開けます)", vim.log.levels.WARN)
        end
        api.queue(item.uri, function(d, err, code)
          if d then util.notify("キューに追加: " .. item.name) else api.report(err, code) end
        end)
      end,
      -- ライブラリに保存(曲・アルバム)
      spotify_save = function(_, item)
        if not item or (item.kind ~= "track" and item.kind ~= "album") then
          return util.notify("保存できるのは曲とアルバムです", vim.log.levels.WARN)
        end
        api.save(item.kind, item.id, function(d, err, code)
          if d then util.notify("ライブラリに保存: " .. item.name) else api.report(err, code) end
        end)
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-t>"] = { "spotify_children", mode = { "n", "i" }, desc = "中身を開く" },
          ["<C-a>"] = { "spotify_queue", mode = { "n", "i" }, desc = "キューに追加" },
          ["<C-s>"] = { "spotify_save", mode = { "n", "i" }, desc = "ライブラリに保存" },
        },
      },
    },
  }, opts)
end

-- 非同期にアイテムを取得する静的picker用finder。fetch(cb) の cb は (items, err, code)
local function async_finder(fetch)
  return function(_, ctx)
    return function(cb)
      local async = ctx.async
      fetch(function(items, err, code)
        vim.schedule(function()
          if not items and err then api.report(err, code) end
          for _, it in ipairs(items or {}) do cb(it) end
          async:resume()
        end)
      end)
      async:suspend()
    end
  end
end

-- ───────── ドリルダウン ─────────
function M.open_children(item)
  Snacks.picker(base({
    title = item.name,
    finder = async_finder(function(cb) children(item, cb) end),
  }))
end

-- ───────── 混在検索(ライブ) ─────────
local pending -- 入力デバウンス用タイマー

function M.search()
  Snacks.picker(base({
    title = "Spotify  (t: 曲 / al: アルバム / pl: プレイリスト / ar: アーティスト)",
    live = true,
    supports_live = true,
    finder = function(_, ctx)
      local q = ctx.filter.search
      if not q or vim.trim(q) == "" then return {} end
      return function(cb)
        local async = ctx.async
        if pending and not pending:is_closing() then
          pending:stop()
          pending:close()
        end
        pending = (vim.uv or vim.loop).new_timer()
        local timer = pending
        timer:start(250, 0, vim.schedule_wrap(function()
          if not timer:is_closing() then timer:close() end
          api.mixed_search(q, function(items, err, code)
            if not items then api.report(err, code) end
            for _, it in ipairs(items or {}) do cb(it) end
            async:resume()
          end)
        end))
        async:suspend()
      end
    end,
  }))
end

-- ───────── 自分のライブラリ(要ログイン) ─────────
local LIB = {
  playlist = { path = "/me/playlists", inner = nil, title = "プレイリスト" },
  track = { path = "/me/tracks", inner = "track", title = "保存した曲" },
  album = { path = "/me/albums", inner = "album", title = "保存したアルバム" },
}

function M.library(kind)
  if not auth.is_logged_in() then
    return util.notify(":Spotify login が必要です", vim.log.levels.WARN)
  end
  local def = LIB[kind or "playlist"]
  if not def then
    return util.notify("library: playlist / track / album から選んでください", vim.log.levels.WARN)
  end
  kind = kind or "playlist"
  Snacks.picker(base({
    title = "Library: " .. def.title,
    finder = async_finder(function(cb)
      api.paged(def.path, {}, 200, true, function(raws, err, code)
        if not raws then return cb(nil, err, code) end
        local items = {}
        for _, r in ipairs(raws) do
          local it = api.normalize(kind, def.inner and r[def.inner] or r)
          if it then items[#items + 1] = it end
        end
        cb(items)
      end)
    end),
  }))
end

function M.library_menu()
  local kinds = { "playlist", "track", "album" }
  vim.ui.select(kinds, {
    prompt = "Spotify ライブラリ",
    format_item = function(k) return LIB[k].title end,
  }, function(k)
    if k then M.library(k) end
  end)
end

return M
