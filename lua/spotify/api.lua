local auth = require("spotify.auth")
local util = require("spotify.util")

local M = {}

local BASE = "https://api.spotify.com/v1"

-- cb(data, err, http_code) は必ずメインループ側(vim.schedule済み)で呼ばれる
function M.request(method, path, opts, cb)
  opts = opts or {}
  auth.get({ user = opts.user }, function(token, aerr)
    if not token then
      return vim.schedule(function() cb(nil, aerr or "認証に失敗しました", 401) end)
    end

    local url = BASE .. path
    local qs = {}
    for k, v in pairs(opts.query or {}) do
      qs[#qs + 1] = k .. "=" .. util.enc(tostring(v))
    end
    table.sort(qs)
    if #qs > 0 then url = url .. "?" .. table.concat(qs, "&") end

    local cmd = {
      "curl", "-s", "--max-time", "15", "-X", method,
      "-w", "\n%{http_code}",
      "-H", "Authorization: Bearer " .. token,
    }
    if opts.body then
      vim.list_extend(cmd, { "-H", "Content-Type: application/json", "-d", vim.json.encode(opts.body) })
    end
    cmd[#cmd + 1] = url

    vim.system(cmd, { text = true }, function(res)
      local body, code = (res.stdout or ""):match("^(.*)\n(%d+)$")
      code = tonumber(code)
      vim.schedule(function()
        if not code then return cb(nil, "通信エラー", 0) end
        local ok, data = pcall(vim.json.decode, body ~= "" and body or "{}")
        if code >= 200 and code < 300 then
          return cb(ok and data or {}, nil, code)
        end
        local msg = "HTTP " .. code
        if ok and type(data) == "table" and data.error then
          msg = type(data.error) == "table" and (data.error.message or msg) or tostring(data.error)
        end
        cb(nil, msg, code)
      end)
    end)
  end)
end

function M.report(err, code)
  local msg = err or "エラー"
  if code == 401 then
    msg = msg .. "(:Spotify login が必要かもしれません)"
  elseif code == 403 then
    msg = msg .. "(Premiumが必要、または権限不足。:Spotify logout → login で再認証)"
  elseif code == 404 then
    msg = msg .. "(アクティブなデバイスがない可能性。Spotifyで一度再生してください)"
  end
  util.notify(msg, vim.log.levels.ERROR)
end

-- ───────── 正規化 ─────────
local function artist_name(r)
  return r.artists and r.artists[1] and r.artists[1].name or ""
end

local norm = {
  track = function(r)
    return { name = r.name, sub = artist_name(r), extra = r.album and r.album.name or "" }
  end,
  album = function(r)
    local year = (r.release_date or ""):sub(1, 4)
    return { name = r.name, sub = artist_name(r), extra = year .. " · " .. (r.total_tracks or "?") .. "曲" }
  end,
  playlist = function(r)
    local total = (r.tracks or r.items or {}).total
    return {
      name = r.name,
      sub = r.owner and r.owner.display_name or "",
      extra = total and (total .. "曲") or "",
    }
  end,
  artist = function(r)
    return { name = r.name, sub = (r.genres and r.genres[1]) or "", extra = "" }
  end,
}

function M.normalize(kind, r, context)
  if type(r) ~= "table" or not r.uri or not norm[kind] then return nil end
  local it = norm[kind](r)
  it.kind, it.id, it.uri, it.context = kind, r.id, r.uri, context
  it.text = table.concat({ it.name or "", it.sub, it.extra }, " ")
  return it
end

-- ───────── ページング ─────────
function M.paged(path, query, max, user, cb)
  local all, offset = {}, 0
  local function step()
    local q = vim.tbl_extend("force", { limit = 50, offset = offset }, query or {})
    M.request("GET", path, { query = q, user = user }, function(d, err, code)
      if not d then return cb(#all > 0 and all or nil, err, code) end
      vim.list_extend(all, d.items or {})
      offset = offset + #(d.items or {})
      if type(d.next) == "string" and #all < max then
        step()
      else
        cb(all)
      end
    end)
  end
  step()
end

-- ───────── 検索(曲・アルバム・プレイリスト・アーティスト混在) ─────────
-- 接頭辞: t: 曲 / al: アルバム / pl: プレイリスト / ar: アーティスト
local PREFIX = { t = "track", al = "album", pl = "playlist", ar = "artist" }
local ORDER = { "track", "album", "playlist", "artist" }

function M.mixed_search(query, cb)
  local pfx, rest = query:match("^%s*(%a%a?):%s*(.*)$")
  local types, limit = ORDER, 5
  if pfx and PREFIX[pfx:lower()] then
    types, limit, query = { PREFIX[pfx:lower()] }, 10, rest
  end
  if vim.trim(query) == "" then return cb({}) end

  M.request("GET", "/search", {
    query = { q = query, type = table.concat(types, ","), limit = limit },
  }, function(d, err, code)
    if not d then return cb(nil, err, code) end
    local items = {}
    for _, kind in ipairs(types) do
      local box = d[kind .. "s"]
      for _, raw in ipairs(box and box.items or {}) do
        local it = M.normalize(kind, raw)
        if it then items[#items + 1] = it end
      end
    end
    cb(items)
  end)
end

-- ───────── ドリルダウン ─────────
local function track_item(t, context, extra)
  local it = M.normalize("track", t, context)
  if it and extra then it.extra = extra end
  return it
end

function M.album_tracks(item, cb)
  M.paged("/albums/" .. item.id .. "/tracks", {}, 100, false, function(raws, err, code)
    if not raws then return cb(nil, err, code) end
    local items = {}
    for _, t in ipairs(raws) do
      local it = track_item(t, item.uri, util.fmt_time((t.duration_ms or 0) / 1000))
      if it then items[#items + 1] = it end
    end
    cb(items)
  end)
end

function M.play(uri, context)
  local function fallback(why)
    util.notify("AppleScript経由で再生(" .. why .. ")", vim.log.levels.WARN)
    osa.play_uri(uri, context)
  end
  if not auth.is_logged_in() then return fallback("未ログイン") end

  local function done(d, _, code)
    if d then
      util.notify("Web API経由で再生")
      if osa.after then vim.defer_fn(osa.after, 800) end
    else
      fallback("API失敗 HTTP " .. tostring(code))
    end
  end

  api.play(uri, context, nil, function(d, err, code)
    if d then return done(d) end
    if code == 404 then
      -- アクティブなデバイスがない場合、このMacのSpotifyを探して指定する
      api.devices(function(devs)
        local target
        for _, dev in ipairs(devs or {}) do
          if dev.type == "Computer" then target = dev; break end
        end
        if not (target and target.id) then return fallback("デバイスなし") end
        api.play(uri, context, target.id, done)
      end)
    else
      fallback("HTTP " .. tostring(code) .. " " .. tostring(err))
    end
  end)
end

function M.artist_albums(item, cb)
  M.paged("/artists/" .. item.id .. "/albums", { include_groups = "album,single" }, 100, false,
    function(raws, err, code)
      if not raws then return cb(nil, err, code) end
      local items = {}
      for _, r in ipairs(raws) do
        local it = M.normalize("album", r)
        if it then items[#items + 1] = it end
      end
      cb(items)
    end)
end

-- ───────── ユーザー操作(要ログイン) ─────────
function M.queue(uri, cb)
  M.request("POST", "/me/player/queue", { user = true, query = { uri = uri } }, cb)
end

function M.save(kind, id, cb)
  local path = kind == "album" and "/me/albums" or "/me/tracks"
  M.request("PUT", path, { user = true, body = { ids = { id } } }, cb)
end

return M
