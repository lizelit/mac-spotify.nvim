local osa = require("spotify.osa")
local api = require("spotify.api")
local util = require("spotify.util")

local M = {}

-- 現在の曲のURLをレジスタへ。insert=true ならカーソル位置にも挿入
function M.copy_url(insert)
  osa.state(function(st)
    if not st then
      return util.notify("再生中の曲がありません", vim.log.levels.WARN)
    end
    local url = osa.web_url(st.url)
    vim.fn.setreg("+", url)
    vim.fn.setreg('"', url)
    if insert then vim.api.nvim_put({ url }, "c", true, true) end
    util.notify("コピー: " .. url)
  end)
end

-- 現在の曲をライブラリに保存(要ログイン)
function M.save_current()
  osa.state(function(st)
    local id = st and osa.track_id(st.url)
    if not id then
      return util.notify("保存できる曲がありません", vim.log.levels.WARN)
    end
    api.save("track", id, function(d, err, code)
      if d then
        util.notify("ライブラリに保存: " .. st.name)
      else
        api.report(err, code)
      end
    end)
  end)
end

return M
