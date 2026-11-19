local M = {}

local SEP = string.char(31)

-- 操作後に呼ばれるフック(init側で表示更新を登録する)
M.after = nil

local function run(script, cb)
  vim.system({ "osascript", "-e", script }, { text = true }, function(res)
    if cb then
      vim.schedule(function() cb(vim.trim(res.stdout or ""), res) end)
    end
  end)
end
M.run = run

local function after()
  if M.after then vim.defer_fn(M.after, 300) end
end

-- Spotify未起動時に勝手に起動しないよう、running を確認してから実行する
local function act(cmd)
  return function()
    run('if application "Spotify" is running then tell application "Spotify" to ' .. cmd, after)
  end
end

M.playpause = act("playpause")
M.next = act("next track")
M.prev = act("previous track")
M.toggle_shuffle = act("set shuffling to not shuffling")
M.toggle_repeat = act("set repeating to not repeating")

function M.seek(delta)
  act(("set player position to ((player position) + (%d))"):format(math.floor(delta)))()
end

function M.volume_delta(delta)
  act(("set sound volume to ((sound volume) + (%d))"):format(math.floor(delta)))()
end

function M.volume_set(n)
  act(("set sound volume to %d"):format(math.max(0, math.min(100, math.floor(n)))))()
end

-- ───────── 再生(未起動ならバックグラウンドで起動) ─────────
local function is_running(cb)
  run('application "Spotify" is running', function(out) cb(out == "true") end)
end

-- 未起動なら `open -g`(バックグラウンド起動)で起動し、AppleScriptが通るまで待つ
local function ensure_running(cb)
  is_running(function(running)
    if running then return cb(true) end
    vim.system({ "open", "-g", "-a", "Spotify" })
    local tries = 0
    local function poll()
      tries = tries + 1
      is_running(function(ok)
        if ok then
          -- 起動直後はAppleScriptが通らないことがあるので少し待つ
          vim.defer_fn(function() cb(true) end, 1500)
        elseif tries < 20 then
          vim.defer_fn(poll, 500)
        else
          cb(false)
        end
      end)
    end
    poll()
  end)
end

-- track / album / playlist のURIを再生。context を渡すとその中の1曲を再生する
function M.play_uri(uri, context)
  if not uri or not uri:match("^spotify:[%w:]+$") then return end
  local cmd = 'play track "' .. uri .. '"'
  if context and context:match("^spotify:[%w:]+$") then
    cmd = cmd .. ' in context "' .. context .. '"'
  end
  ensure_running(function(ok)
    if not ok then
      return vim.notify("Spotifyを起動できませんでした", vim.log.levels.WARN, { title = "Spotify" })
    end
    run('tell application "Spotify" to ' .. cmd, function()
      if M.after then vim.defer_fn(M.after, 600) end
    end)
  end)
end

-- ───────── 状態の取得 ─────────
local STATE_SCRIPT = [[
if application "Spotify" is not running then return ""
tell application "Spotify"
  set s to player state as string
  if s is "stopped" then return "stopped"
  set sep to (ASCII character 31)
  set t to current track
  set art to ""
  try
    set art to artwork url of t
  end try
  set u to ""
  try
    set u to spotify url of t
  end try
  return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (duration of t) & sep & (player position) & sep & (shuffling as string) & sep & (repeating as string) & sep & (sound volume) & sep & art & sep & u
end tell
]]

-- cb(state|nil)
function M.state(cb)
  run(STATE_SCRIPT, function(out)
    if out == "" or out == "stopped" then return cb(nil) end
    local f = vim.split(out, SEP, { plain = true })
    if #f < 11 then return cb(nil) end
    local duration = tonumber(f[5]) or 0
    if duration > 10000 then duration = duration / 1000 end -- ミリ秒なら秒へ
    cb({
      state = f[1],
      name = f[2],
      artist = f[3],
      album = f[4],
      duration = duration,
      position = tonumber((f[6]:gsub(",", "."))) or 0,
      shuffle = f[7] == "true",
      repeating = f[8] == "true",
      volume = tonumber(f[9]) or 0,
      art = f[10],
      url = f[11],
    })
  end)
end

-- "spotify:track:ID" → "https://open.spotify.com/track/ID"
function M.web_url(uri)
  local kind, id = (uri or ""):match("^spotify:(%w+):(%w+)$")
  if kind then return ("https://open.spotify.com/%s/%s"):format(kind, id) end
  return uri or ""
end

function M.track_id(uri)
  return (uri or ""):match("^spotify:track:(%w+)$")
end

return M
