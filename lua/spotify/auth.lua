local util = require("spotify.util")
local uv = vim.uv or vim.loop

local M = {}

M.config = {
  client_id = nil,     -- 未指定なら $SPOTIFY_CLIENT_ID
  client_secret = nil, -- 任意。未ログイン時の検索フォールバック用($SPOTIFY_CLIENT_SECRET)
  port = 8888,         -- Dashboardに http://127.0.0.1:<port>/callback を登録すること
  scopes = {
    "user-modify-playback-state",
    "user-read-playback-state",
    "playlist-read-private",
    "playlist-read-collaborative",
    "user-library-read",
    "user-library-modify",
  },
}

local TOKEN_URL = "https://accounts.spotify.com/api/token"
local AUTH_URL = "https://accounts.spotify.com/authorize"
local store = vim.fn.stdpath("data") .. "/spotify_token.json"

local function cid() return M.config.client_id or vim.env.SPOTIFY_CLIENT_ID end
local function secret() return M.config.client_secret or vim.env.SPOTIFY_CLIENT_SECRET end
local function redirect() return ("http://127.0.0.1:%d/callback"):format(M.config.port) end

-- ───────── トークンの保存 ─────────
local user -- { access_token, refresh_token, expires_at }

local function load()
  if user then return user end
  local f = io.open(store, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  local ok, d = pcall(vim.json.decode, s)
  if ok and type(d) == "table" and d.refresh_token then user = d end
  return user
end

local function save(d)
  user = d
  local f = io.open(store, "w")
  if not f then return end
  f:write(vim.json.encode(d))
  f:close()
  uv.fs_chmod(store, 384) -- 0600
end

function M.is_logged_in() return load() ~= nil end

function M.logout()
  user = nil
  os.remove(store)
  util.notify("ログアウトしました")
end

-- ───────── /api/token へのPOST ─────────
local function post(fields, cb, basic)
  local cmd = { "curl", "-s", "--max-time", "15", "-X", "POST", TOKEN_URL }
  if basic then vim.list_extend(cmd, { "-u", basic }) end
  for _, kv in ipairs(fields) do
    vim.list_extend(cmd, { "--data-urlencode", kv })
  end
  vim.system(cmd, { text = true }, function(res)
    local ok, d = pcall(vim.json.decode, res.stdout or "")
    cb(ok and type(d) == "table" and d or nil)
  end)
end

-- ───────── ユーザートークン(自動リフレッシュ) ─────────
local function user_token(cb)
  local u = load()
  if not u then return cb(nil) end
  if os.time() < (u.expires_at or 0) - 30 then return cb(u.access_token) end
  local id = cid()
  if not id then return cb(nil) end
  post({
    "grant_type=refresh_token",
    "refresh_token=" .. u.refresh_token,
    "client_id=" .. id,
  }, function(d)
    if d and d.access_token then
      save({
        access_token = d.access_token,
        refresh_token = d.refresh_token or u.refresh_token,
        expires_at = os.time() + (d.expires_in or 3600),
      })
      cb(d.access_token)
    else
      cb(nil)
    end
  end)
end

-- ───────── アプリトークン(Client Credentials) ─────────
local app = { token = nil, exp = 0 }

local function app_token(cb)
  if app.token and os.time() < app.exp - 30 then return cb(app.token) end
  local id, sec = cid(), secret()
  if not (id and sec) then return cb(nil) end
  post({ "grant_type=client_credentials" }, function(d)
    if d and d.access_token then
      app.token, app.exp = d.access_token, os.time() + (d.expires_in or 3600)
      cb(app.token)
    else
      cb(nil)
    end
  end, id .. ":" .. sec)
end

-- opts.user = true ならユーザートークン必須
function M.get(opts, cb)
  user_token(function(t)
    if t then return cb(t) end
    if opts and opts.user then
      return cb(nil, "ログインが必要です(:Spotify login)")
    end
    app_token(function(a)
      if a then
        cb(a)
      else
        cb(nil, "認証できません。:Spotify login するか SPOTIFY_CLIENT_ID/SECRET を設定してください")
      end
    end)
  end)
end

-- ───────── PKCEログイン ─────────
local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

local function rand(n)
  local ok, bytes = pcall(uv.random, n)
  local t = {}
  for i = 1, n do
    local b = (ok and bytes) and bytes:byte(i) or math.random(0, 255)
    local idx = b % #CHARS + 1
    t[i] = CHARS:sub(idx, idx)
  end
  return table.concat(t)
end

function M.login()
  local id = cid()
  if not id then
    return util.notify("SPOTIFY_CLIENT_ID が未設定です", vim.log.levels.ERROR)
  end

  local verifier, state = rand(64), rand(16)
  local hex = vim.fn.sha256(verifier)
  local raw = hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
  local challenge = vim.base64.encode(raw):gsub("%+", "-"):gsub("/", "_"):gsub("=", "")

  local function exchange(code)
    post({
      "client_id=" .. id,
      "grant_type=authorization_code",
      "code=" .. code,
      "redirect_uri=" .. redirect(),
      "code_verifier=" .. verifier,
    }, function(d)
      if d and d.access_token then
        save({
          access_token = d.access_token,
          refresh_token = d.refresh_token,
          expires_at = os.time() + (d.expires_in or 3600),
        })
        util.notify("ログインしました")
      else
        util.notify("トークン交換に失敗しました", vim.log.levels.ERROR)
      end
    end)
  end

  local server = uv.new_tcp()
  local ok, err = server:bind("127.0.0.1", M.config.port)
  if not ok then
    server:close()
    return util.notify(("ポート %d を開けません: %s"):format(M.config.port, tostring(err)), vim.log.levels.ERROR)
  end

  local closed = false
  local function shutdown()
    if closed then return end
    closed = true
    if not server:is_closing() then server:close() end
  end

  server:listen(1, function(lerr)
    if lerr then return end
    local client = uv.new_tcp()
    server:accept(client)
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then return end
      client:read_stop()
      local path = chunk:match("^GET (%S+)") or ""
      local code = path:match("[?&]code=([^&]+)")
      local st = path:match("[?&]state=([^&]+)")
      local msg = (code and st == state) and "認証が完了しました。このタブは閉じて構いません。" or "認証に失敗しました。"
      local html = "<html><head><meta charset='utf-8'></head><body>" .. msg .. "</body></html>"
      client:write(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: "
          .. #html .. "\r\n\r\n" .. html,
        function() client:close() end
      )
      shutdown()
      if code and st == state then
        exchange(code)
      else
        util.notify("認証に失敗しました", vim.log.levels.ERROR)
      end
    end)
  end)

  local url = AUTH_URL
    .. "?client_id=" .. util.enc(id)
    .. "&response_type=code"
    .. "&redirect_uri=" .. util.enc(redirect())
    .. "&code_challenge_method=S256"
    .. "&code_challenge=" .. challenge
    .. "&state=" .. state
    .. "&scope=" .. util.enc(table.concat(M.config.scopes, " "))

  local opened = pcall(vim.ui.open, url)
  if not opened then vim.system({ "open", url }) end
  util.notify("ブラウザで認証してください(2分でタイムアウト)")
  vim.defer_fn(shutdown, 120000)
end

return M
