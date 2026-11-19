local M = {}

function M.enc(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

-- luvのコールバック内からでも安全に通知できる
function M.notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO, { title = "Spotify" })
  end)
end

function M.fmt_time(sec)
  sec = math.max(0, math.floor(sec or 0))
  return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

return M
