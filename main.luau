-- Shimlar loop for shimlar.org/modern.php, any browser window size.
--
-- It fights, picks a stat on level up, banks gold, buys and equips better
-- gear, moves on to stronger monsters and revives after a death. It finds the
-- bank, the shop and the infirmary by reading the zone map.
--
-- In the Shimlar tab:  Option+L  starts or stops it,  Option+P  pauses or
-- resumes it,  Escape  stops it. It also pauses by itself while the Shimlar
-- tab is not the front window, and carries on when you come back.
-- Settings are in Rebind's options for this script.
--
-- It works by reading the window: before every click it takes a picture of
-- the browser window and has ocr.swift (macOS text recognition) find the
-- words on it, so nothing depends on where things were last time. The helper
-- is compiled once into the script's data folder.

local looping = false
local paused = false -- by Option+P
local start_loop, stop_loop, hud_preview

local cfg = UI.Schema({
  loop = UI.Button("Start / stop the loop", {
    onPress = function()
      if looping then
        stop_loop("stopped from Rebind")
      else
        App.Activate("Brave Browser")
        Sleep(1200)
        start_loop()
      end
    end,
  }),
  preview = UI.Button("Show where the HUD sits (20 seconds)", {
    onPress = function()
      if not looping then
        App.Activate("Brave Browser")
        Sleep(1200)
        hud_preview()
      end
    end,
  }),
  stat = UI.Select("dex", { "ntl", "wis", "vit", "str", "dex" }, { label = "Stat to raise on level up" }),
  action = UI.Select("attack", { "attack", "cast" }, { label = "In a fight" }),

  auto_bank = UI.Toggle(true, { label = "Bank gold", group = "Banking" }),
  bank_pct = UI.Slider(20, {
    label = "Bank when gold on hand is this share of all your gold",
    min = 1, max = 100, step = 1, suffix = "%", group = "Banking",
  }),
  bank_min = UI.Slider(100, {
    label = "...and at least this much gold",
    min = 0, max = 100000, step = 50, group = "Banking",
  }),
  bank_square = UI.Text("auto", { label = "Bank square: auto (from the map) or x,y", group = "Banking" }),

  auto_gear = UI.Toggle(true, { label = "Buy and equip better gear", group = "Gear" }),
  gear_pct = UI.Slider(50, {
    label = "Spend up to this share of all your gold on a shopping trip",
    min = 5, max = 100, step = 5, suffix = "%", group = "Gear",
  }),
  shop_square = UI.Text("auto", { label = "Shop square: auto (from the map) or x,y", group = "Gear" }),

  auto_revive = UI.Toggle(true, { label = "Revive at the infirmary after a death", group = "Dying" }),
  infirmary_square = UI.Text("auto", { label = "Infirmary square: auto (from the map) or x,y", group = "Dying" }),

  auto_monster = UI.Toggle(true, { label = "Move on to stronger monsters", group = "Monsters" }),
  easy_streak = UI.Slider(15, {
    label = "Easy kills in a row before moving up",
    min = 3, max = 100, step = 1, group = "Monsters",
  }),
  easy_attacks = UI.Slider(2, {
    label = "A kill is easy when it takes at most this many attacks",
    min = 1, max = 10, step = 1, group = "Monsters",
  }),
  hard_attacks = UI.Slider(6, {
    label = "Move down when a kill takes more attacks than this",
    min = 2, max = 30, step = 1, group = "Monsters",
  }),
  low_health = UI.Slider(40, {
    label = "Move down when health after a kill is below",
    min = 5, max = 95, step = 5, suffix = "%", group = "Monsters",
  }),

  hud_position = UI.Select("bottom-right", {
    "bottom-right", "bottom-left", "top-right", "top-left", "in the game window",
  }, { label = "Where the HUD sits", group = "HUD" }),
  hud_capture = UI.Toggle(false, { label = "Show the HUD in screenshots and recordings", group = "HUD" }),

  pace = UI.Slider(250, {
    label = "Extra wait after each click",
    min = 0, max = 3000, step = 50, suffix = " ms", group = "Pace",
  }),
})

----------------------------------------------------------------------------
-- reading the window

local OCR = nil  -- path of the compiled helper
local SHOT = nil -- path of the picture it reads

local function sh(s)
  return '"' .. s .. '"'
end

-- coroutine-only. Compiles ocr.swift the first time.
local function ensure_ocr()
  if OCR then return true end
  local data = File.GetDataDir()
  local bin = data .. "/ocr"
  SHOT = data .. "/shot.png"
  if not File.Exists("@data/ocr") then
    UI.Notify("Shimlar: building the screen reader, one moment")
    local src = File.GetScriptDir() .. "/ocr.swift"
    local r = System.Exec("/usr/bin/swiftc -O " .. sh(src) .. " -o " .. sh(bin) .. " 2>&1", { timeout = 180000 })
    if r.exit ~= 0 then
      return false, "could not build ocr.swift (needs Xcode's command line tools): " .. r.stdout:sub(1, 200)
    end
  end
  OCR = bin
  return true
end

local function in_game()
  local w = System.Window()
  return w ~= nil and w.title:find("Shimlar", 1, true) ~= nil
end

local function is_alert()
  local w = System.Window()
  return w ~= nil and w.title:find("shimlar.org says", 1, true) ~= nil
end

local function num(t)
  local digits = t:gsub("[^%d]", "")
  return tonumber(digits)
end

local function norm(name)
  return (name:lower():gsub("[^%a%d]", ""))
end

local warmed = false
local function capture(region, flags)
  local cmd = string.format(
    "/usr/sbin/screencapture -x -t png -R%d,%d,%d,%d %s && %s %s%s",
    region.x, region.y, region.w, region.h, sh(SHOT), sh(OCR), flags or "", sh(SHOT)
  )
  -- the very first recognition after a restart can take most of a minute
  local r = System.Exec(cmd, { timeout = warmed and 20000 or 120000 })
  warmed = true
  if r.exit ~= 0 then
    return nil, "could not read the screen: " .. (r.stderr or ""):sub(1, 160)
  end
  return r.stdout
end

-- Words on screen inside `region` ({x, y, w, h} in screen coordinates), each
-- { t, x, y (centre), w, h, l, r (left and right edge) }.
local function read_words(region)
  local out, problem = capture(region)
  if not out then return nil, problem end
  local words = {}
  for line in out:gmatch("[^\n]+") do
    local x, y, w, h, t = line:match("^(%d+) (%d+) (%d+) (%d+) (.+)$")
    if t then
      local l = region.x + tonumber(x) / 10000 * region.w
      local ww = tonumber(w) / 10000 * region.w
      local hh = tonumber(h) / 10000 * region.h
      local cy = region.y + tonumber(y) / 10000 * region.h + hh / 2
      -- "VIT|STR" comes back as one word now and then: cut it at the bars
      local len, i = #t, 1
      while i <= len do
        local j = t:find("|", i, true) or (len + 1)
        if j > i then
          local pl = l + (i - 1) / len * ww
          local pw = (j - i) / len * ww
          words[#words + 1] = { t = t:sub(i, j - 1), x = pl + pw / 2, y = cy, w = pw, h = hh, l = pl, r = pl + pw }
        end
        i = j + 1
      end
    end
  end
  return words
end

local function window_region()
  local win = System.Window()
  return { x = win.x, y = win.y, w = win.width, h = win.height }, win
end

local function same_row(a, b)
  return math.abs(a.y - b.y) < math.max(a.h, b.h) * 0.6
end

local function find(words, text, ok)
  for _, w in ipairs(words) do
    if w.t == text and (not ok or ok(w)) then return w end
  end
  return nil
end

-- the words right of `key` on its row, left to right
local function right_of(words, key, ok)
  local out = {}
  for _, w in ipairs(words) do
    if w ~= key and w.x > key.x and same_row(w, key) and (not ok or ok(w)) then out[#out + 1] = w end
  end
  table.sort(out, function(a, b) return a.x < b.x end)
  return out
end

-- the number written after the leftmost word starting with `label`
-- ("1,802" is sometimes read as two words: glue the pieces back together)
local function value_of(words, label)
  local key = nil
  for _, w in ipairs(words) do
    if w.t:sub(1, #label) == label and (not key or w.x < key.x) then key = w end
  end
  if not key then return nil end
  if #key.t > #label and num(key.t) then return num(key.t) end
  local digits, last = "", key
  for _, w in ipairs(right_of(words, key)) do
    if not w.t:match("^[%d,%.]+$") or w.l - last.r > key.h * 1.2 then break end
    digits = digits .. w.t
    last = w
  end
  return num(digits)
end

local chat_top = nil -- screen y where the chat starts, once known

-- Everything the loop needs to know about the screen right now.
local function sense(whole)
  local region, win = window_region()
  local cropped = false
  if not whole and chat_top and chat_top > win.y + 100 and chat_top < win.y + win.height then
    region.h = math.floor(chat_top - win.y)
    cropped = true
  end
  local all, problem = read_words(region)
  if not all then return nil, problem end

  local s = { win = win, left_max = win.x + win.width * 0.35, centre_min = win.x + win.width * 0.42 }

  -- the chat is not part of the game state: cut everything from its Send row
  local send = find(all, "Send", function(w)
    return find(all, "Chat", function(c) return same_row(c, w) and c.x > w.x end) ~= nil
  end)
  if send then
    chat_top = send.y + send.h * 1.5
  elseif cropped then
    chat_top = nil -- the layout moved: look at the whole window next time
  end
  local words = {}
  for _, w in ipairs(all) do
    if not send or w.y < send.y - send.h then words[#words + 1] = w end
  end
  s.words = words

  local function on_left(w) return w.x < s.left_max end
  s.link_stats = find(words, "Stats", on_left)
  s.link_inventory = find(words, "Inventory", on_left)
  s.link_map = find(words, "Map", on_left)

  s.gold = value_of(words, "Gold:")
  s.bank = value_of(words, "Bank:")
  s.health = value_of(words, "Health:")
  local lvl = find(words, "Level")
  if lvl then
    local nxt = right_of(words, lvl)[1]
    s.level = nxt and num(nxt.t) or nil
  end

  -- "You are at 0, 4 in Silverdale"
  local at = find(words, "at", function(w)
    return find(words, "are", function(a) return same_row(a, w) and a.x < w.x end) ~= nil
  end)
  if at then
    local parts = {}
    for _, w in ipairs(right_of(words, at)) do parts[#parts + 1] = w.t end
    local x, y, zone = table.concat(parts, " "):match("^(%-?%d+)%s*[,%.]?%s*(%-?%d+)%s+in%s+(%a+)")
    if x then s.pos = { x = tonumber(x), y = tonumber(y), zone = zone } end
  end

  -- everything said in the middle of the page, lower case
  local said = {}
  for _, w in ipairs(words) do
    if w.x >= s.centre_min then said[#said + 1] = w.t:lower() end
  end
  s.said = table.concat(said, " ")

  -- fight panel
  local monsters_word = find(words, "Monsters")
  s.fight = find(words, "Fight", function(w) return monsters_word ~= nil and same_row(w, monsters_word) end)
    or find(words, "Fight", function(w) return w.x >= s.centre_min end)
  if s.fight then
    local name, right_edge = {}, s.fight.r + s.fight.w * 3
    for _, w in ipairs(right_of(words, s.fight)) do
      if w.t == "Monsters" then
        right_edge = w.l
        break
      end
      if #w.t > 1 then name[#name + 1] = w.t end
    end
    s.monster = table.concat(name, " ")
    s.select = { x = (s.fight.r + right_edge) / 2, y = s.fight.y, w = (right_edge - s.fight.r) * 0.5, h = s.fight.h }
    local below = function(w) return w.y > s.fight.y + s.fight.h * 0.8 end
    s.attack = find(words, "Attack", below)
    s.cast = find(words, "Cast", below)
    local stats, n = {}, 0
    for _, w in ipairs(words) do
      if below(w) and w.x < win.x + win.width * 0.8 and (w.t == "NTL" or w.t == "WIS" or w.t == "VIT" or w.t == "STR" or w.t == "DEX") then
        stats[w.t:lower()] = w
        n += 1
      end
    end
    if n >= 3 then s.stats = stats end
  end

  -- the direction buttons: a 3x3 grid. Its rows are where the "North ...",
  -- "West"/"East" and "South ..." labels are, its outer columns where the
  -- lone "West" and "East" are.
  local function starts(w, text)
    return w.t:sub(1, #text) == text
  end
  local north, south = nil, nil
  for _, w in ipairs(words) do
    if starts(w, "North") and (not north or w.y < north.y) then north = w end
  end
  if north then
    for _, w in ipairs(words) do
      if starts(w, "South") and w.y > north.y + north.h and w.y < north.y + north.h * 12
        and math.abs(w.x - north.x) < win.width * 0.25 and (not south or w.y < south.y) then
        south = w
      end
    end
  end
  if north and south then
    s.page_top = north.y - north.h * 1.5
    local west, east = nil, nil
    for _, w in ipairs(words) do
      if w.y > north.y + north.h * 0.7 and w.y < south.y - north.h * 0.7
        and math.abs(w.x - north.x) < win.width * 0.25 then
        if starts(w, "West") then west = w end
        if starts(w, "East") then east = w end
      end
    end
    if west and east and east.x > west.x then
      local mid = { x = (west.x + east.x) / 2, y = west.y }
      local function spot(col, row)
        return { x = col.x, y = row.y, w = west.w, h = west.h }
      end
      s.nav = {
        nw = spot(west, north), n = spot(mid, north), ne = spot(east, north),
        w = spot(west, mid), e = spot(east, mid),
        sw = spot(west, south), s = spot(mid, south), se = spot(east, south),
      }
    end
  end

  -- bank page: [ amount ] [ Deposit All v ] [ OK ]
  if find(words, "National") then
    local ok = find(words, "OK")
    if ok then
      local mode = right_of(words, { x = ok.x - win.width * 0.2, y = ok.y, h = ok.h }, function(w) return w.x < ok.x end)
      if #mode > 0 then
        local names = {}
        for _, w in ipairs(mode) do names[#names + 1] = w.t end
        s.bank_page = {
          ok = ok,
          mode = table.concat(names, " "),
          select = mode[1],
          input = { x = mode[1].l - (ok.x - mode[1].l) * 0.9, y = ok.y, w = ok.w, h = ok.h },
        }
      end
    end
  end

  -- shop page: [ Swords v ] [ Sword I (85) v ] [ Buy ] [ Examine ]
  local buy = nil
  for _, w in ipairs(words) do
    if w.t == "Buy" and w.x >= s.centre_min and (not buy or w.y < buy.y)
      and find(words, "Examine", function(e) return same_row(e, w) and e.x > w.x end) then
      buy = w
    end
  end
  if buy then
    local row = right_of(words, { x = buy.x - win.width * 0.22, y = buy.y, h = buy.h }, function(w) return w.x < buy.x end)
    local price = nil
    for _, w in ipairs(row) do
      if w.t:sub(1, 1) == "(" then price = w end
    end
    if #row > 0 then
      s.shop = {
        buy = buy,
        examine = find(words, "Examine", function(e) return same_row(e, buy) and e.x > buy.x end),
        category = row[1],
        item = price or row[#row],
      }
    end
  end

  -- inventory panel: [ Arrow I (LH) v ] [ Equip ] [ Examine ]
  local equip = find(words, "Equip", function(w)
    return w.x < s.centre_min and find(words, "Examine", function(e) return same_row(e, w) and e.x > w.x end) ~= nil
  end)
  if equip then
    local row = right_of(words, { x = win.x, y = equip.y, h = equip.h }, function(w) return w.x < equip.x end)
    if #row > 0 then s.pack = { equip = equip, select = row[1] } end
  end
  return s
end

----------------------------------------------------------------------------
-- the HUD: a small panel in the bottom-right corner of the screen

local HUD_W, HUD_H = 310, 132
local hud = {
  surface = nil, complained = false, waiting = false,
  placed = nil,   -- what the surface was last placed by
  game_xy = nil,  -- the free strip inside the game window, when there is one
  doing = "", kills = 0, deaths = 0, bought = 0, started = 0,
  monster = nil, level = nil, gold = nil, bank = nil, health = nil,
}

local function commas(n)
  if not n then return "?" end
  local text = tostring(math.floor(n))
  while true do
    local changed
    text, changed = text:gsub("^(%d+)(%d%d%d)", "%1,%2")
    if changed == 0 then break end
  end
  return text
end

local function hud_draw()
  local secs = hud.started > 0 and math.floor((System.Time() - hud.started) / 1000) or 0
  local clock = string.format("%d:%02d:%02d", secs // 3600, secs // 60 % 60, secs % 60)
  local per_hour = secs > 30 and string.format("  (%d/h)", hud.kills * 3600 // secs) or ""
  local doing = hud.doing
  if #doing > 44 then doing = doing:sub(1, 43) .. "…" end
  local ops = {
    { kind = "rect", x = 0, y = 0, w = HUD_W, h = HUD_H, fill = "#140a18e0", border = "#75fb6a80", border_width = 1, radius = 8 },
    { kind = "text", x = 12, y = 9, text = "Shimlar loop", color = hud.waiting and "#dddd48" or looping and "#75fb6a" or "#ea612f", bold = true, size = 13 },
    { kind = "text", x = HUD_W - 70, y = 10, text = clock, color = "#b0a8b4", size = 12 },
    { kind = "text", x = 12, y = 31, text = doing, color = "#ffffff", size = 12 },
    { kind = "text", x = 12, y = 51, text = "Kills " .. commas(hud.kills) .. per_hour, color = "#dddd48", bold = true, size = 12 },
    { kind = "text", x = 12, y = 69, text = string.format("Deaths %d    Gear bought %d", hud.deaths, hud.bought), color = "#b0a8b4", size = 12 },
    {
      kind = "text", x = 12, y = 87, size = 12, color = "#b0a8b4",
      text = string.format("Lvl %s   Gold %s   Bank %s   HP %s",
        tostring(hud.level or "?"), commas(hud.gold), commas(hud.bank), tostring(hud.health or "?")),
    },
    { kind = "text", x = 12, y = 108, text = "Opt+L start/stop   Opt+P pause   Esc stop", color = "#7d7482", size = 11 },
  }
  local where = cfg.hud_position
  local opts = { width = HUD_W, height = HUD_H, ops = ops, capturable = cfg.hud_capture }
  if where == "in the game window" and hud.game_xy then
    opts.x, opts.y = hud.game_xy.x, hud.game_xy.y
  else
    if where == "in the game window" then where = "bottom-right" end
    opts.anchor, opts.display = where, "primary"
    opts.offset_x, opts.offset_y = 16, where:sub(1, 6) == "bottom" and 100 or 50
  end
  local placed = string.format("%s %s %s %s", where, tostring(opts.x), tostring(opts.y), tostring(cfg.hud_capture))
  local fine, err = pcall(function()
    if hud.surface and hud.placed ~= placed then
      hud.surface:remove()
      hud.surface = nil
    end
    if hud.surface then
      hud.surface:draw(ops)
    else
      hud.surface = rb.overlay.surface(opts)
      hud.placed = placed
    end
  end)
  if not fine and not hud.complained then
    hud.complained = true
    Log.Warn("HUD: " .. tostring(err))
  end
end

local function hud_remove()
  if hud.surface then
    pcall(function() hud.surface:remove() end)
    hud.surface = nil
  end
end

-- "in the game window": the top of the empty strip between the left panel
-- and the middle column, level with the stats header, which no page of the
-- game writes in. A narrow window has no such strip, and the HUD stays in its
-- screen corner. `s` is a reading of the screen.
local function hud_place(s)
  hud.game_xy = nil
  if s.win.width >= 1300 then
    local top = s.page_top or (s.win.y + s.win.height * 0.14)
    hud.game_xy = {
      x = math.floor(s.win.x + s.win.width * 0.31),
      y = math.floor(top + 4),
    }
  end
end

-- say what the loop is doing (nil just redraws)
local show
show = function(text)
  if text then hud.doing = text end
  hud_draw()
end

----------------------------------------------------------------------------
-- mouse

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local REFOCUS = "refocus" -- raised after a pause: look at the screen again
local STOPPED = "stopped"

-- coroutine-only. Call before acting on what was read from the screen. While
-- the loop is paused, by Option+P or because the Shimlar tab is not the front
-- window, it waits here; afterwards it raises REFOCUS, because whatever was
-- read before the pause is stale. So a click never lands in another app.
local function guard()
  if not looping then error(STOPPED, 0) end
  if is_alert() then error(REFOCUS, 0) end
  if not paused and in_game() then return end
  Log.Info(paused and "paused by hotkey" or "paused: the Shimlar tab is not in front")
  hud.waiting = true
  while looping and (paused or not in_game()) and not is_alert() do
    show(paused and "paused (Option+P resumes)" or "paused: Shimlar tab is not in front")
    Sleep(300)
  end
  hud.waiting = false
  if not looping then error(STOPPED, 0) end
  Log.Info("resumed")
  show("resuming")
  Sleep(600)
  error(REFOCUS, 0)
end

-- coroutine-only. Glides to a point inside the target and clicks it.
local function click(target)
  guard()
  local x = target.x + clamp(Math.Gaussian(0, target.w * 0.15), -target.w * 0.35, target.w * 0.35)
  local y = target.y + clamp(Math.Gaussian(0, target.h * 0.15), -target.h * 0.3, target.h * 0.3)
  x, y = math.floor(x + 0.5), math.floor(y + 0.5)
  local mx, my = System.Mouse()
  local dist = math.sqrt((x - mx) ^ 2 + (y - my) ^ 2)
  if dist > 2 then
    HID.MoveTo(x, y, math.floor(clamp(160 + dist * 0.6 + math.random(0, 140), 160, 800)))
    local ax, ay = System.Mouse()
    if math.abs(ax - x) > 2 or math.abs(ay - y) > 2 then HID.MoveTo(x, y) end
  end
  Sleep(math.random(50, 130))
  guard()
  HID.Down("Mouse1")
  Sleep(math.random(45, 110))
  HID.Up("Mouse1")
end

local function settle()
  Sleep(350 + cfg.pace + math.random(0, 200))
end

----------------------------------------------------------------------------
-- drop-down lists

-- coroutine-only. Clicks a drop-down, reads the list that opens, and clicks
-- the row `choose(list)` returns the index of (nil closes the list again).
-- Each row is { name, x, y, w, h }. Returns the list, or nil when it could
-- not be read.
local function pick_from_list(target, choose)
  click(target)
  Sleep(450 + math.random(0, 150))
  local region, win = window_region()
  local words = read_words(region)
  -- the list is a light box over the dark page, its current row blue
  local function on_list(x, y)
    local c = Screen.GetPixelColor(math.floor(x), math.floor(y))
    local r, g, b = tonumber(c:sub(1, 2), 16) or 0, tonumber(c:sub(3, 4), 16) or 0, tonumber(c:sub(5, 6), 16) or 0
    return (r + g + b > 450 and math.max(r, g, b) - math.min(r, g, b) < 40) or (b > 200 and b > r + 80)
  end
  local rows, checked = {}, 0
  for _, w in ipairs(words or {}) do
    if math.abs(w.x - target.x) < win.width * 0.25 then
      -- pixel reads are slow: give the tick back every few words, and drop a
      -- word as soon as two of its six samples are off the list
      checked += 1
      if checked % 6 == 0 then Sleep(1) end
      local n, miss, dy = 0, 0, w.h * 0.8
      for _, p in ipairs({
        { w.x, w.y - dy }, { w.x, w.y + dy }, { w.l - 5, w.y }, { w.r + 5, w.y },
        { w.l - 5, w.y - dy }, { w.r + 5, w.y + dy },
      }) do
        if on_list(p[1], p[2]) then n += 1 else miss += 1 end
        if miss > 1 then break end
      end
      if n >= 5 then
        local row = nil
        for _, r in ipairs(rows) do
          if same_row(r[1], w) then
            row = r
            break
          end
        end
        if row then row[#row + 1] = w else rows[#rows + 1] = { w } end
      end
    end
  end
  table.sort(rows, function(a, b) return a[1].y < b[1].y end)
  -- The browser's own light toolbar passes that test too. The list is the run
  -- of evenly spaced rows nearest the drop-down: drop whatever is cut off
  -- from it by a gap.
  if #rows > 0 then
    local near = 1
    for i, row in ipairs(rows) do
      if math.abs(row[1].y - target.y) < math.abs(rows[near][1].y - target.y) then near = i end
    end
    local gap = rows[near][1].h * 3
    local first, last = near, near
    while first > 1 and rows[first][1].y - rows[first - 1][1].y < gap do first -= 1 end
    while last < #rows and rows[last + 1][1].y - rows[last][1].y < gap do last += 1 end
    local kept = {}
    for i = first, last do kept[#kept + 1] = rows[i] end
    rows = kept
  end
  local list, names = {}, {}
  for _, row in ipairs(rows) do
    table.sort(row, function(a, b) return a.x < b.x end)
    -- the tick in front of the current row reads as a stray character
    while #row > 1 and #row[1].t == 1 and not row[1].t:match("[%a%d]") do table.remove(row, 1) end
    if #row > 1 and (row[1].t == "v" or row[1].t == "V") then table.remove(row, 1) end
    local parts = {}
    for _, w in ipairs(row) do parts[#parts + 1] = w.t end
    local name = table.concat(parts, " ")
    if name:match("%a%a") then
      local first, last = row[1], row[#row]
      list[#list + 1] = { name = name, x = (first.l + last.r) / 2, y = first.y, w = last.r - first.l, h = first.h }
      names[#names + 1] = name
    end
  end
  Log.Info("list: " .. table.concat(names, ", "))
  if #list < 2 then
    HID.Press("Escape")
    Sleep(300)
    return nil
  end
  local want = choose(list)
  if want and list[want] then
    click(list[want])
  else
    HID.Press("Escape")
  end
  Sleep(400)
  return list
end

local function index_of(list, name)
  for i, row in ipairs(list) do
    if norm(row.name) == norm(name) then return i end
  end
  return nil
end

----------------------------------------------------------------------------
-- the zone map

local town = nil -- { zone, places = { B = { {x, y}, ... }, ... } }

local function square(text)
  local x, y = tostring(text):match("^%s*(%-?%d+)%s*[, ]%s*(%-?%d+)%s*$")
  if not x then return nil end
  return { x = tonumber(x), y = tonumber(y) }
end

-- where a place is: the setting when it holds x,y, else the nearest tile
-- with that letter on the map
local function place(setting, letter, from)
  local fixed = square(setting)
  if fixed then return fixed end
  local best = nil
  for _, p in ipairs(town and town.places[letter] or {}) do
    local d = from and math.max(math.abs(p.x - from.x), math.abs(p.y - from.y)) or 0
    if not best or d < best.d then best = { x = p.x, y = p.y, d = d } end
  end
  return best
end

-- the nearest tile with no letter on it: those are the ones with monsters
local function plain_tile(from)
  local best = nil
  for c = 0, town.cols - 1 do
    for r = 0, town.rows - 1 do
      local x, y = town.x0 + c, town.y_top - r
      local d = math.max(math.abs(x - from.x), math.abs(y - from.y))
      if d > 0 and not town.marked[x .. "," .. y] and (not best or d < best.d) then
        best = { x = x, y = y, d = d }
      end
    end
  end
  return best
end

-- coroutine-only. Opens the Map view, reads the tile grid, goes back to
-- Stats. `s` must know where you stand. Returns true, or false + why.
local function read_map(s)
  if not s.pos or not s.link_map then return false, "no Map link or position on screen" end
  show("reading the map")
  click(s.link_map)
  settle()
  Sleep(400)
  local top = s.page_top or (s.win.y + s.win.height * 0.14)
  local bottom = (s.link_stats and s.link_stats.y - s.link_stats.h) or (s.win.y + s.win.height * 0.6)
  local out = capture({
    x = s.win.x, y = math.floor(top), w = math.floor(s.win.width * 0.4), h = math.floor(bottom - top),
  }, "--grid ")
  local back = sense(true)
  if back and back.link_stats then
    click(back.link_stats)
    settle()
  end
  if not out then return false, "could not read the map" end
  local cols, rows = out:match("grid (%d+) (%d+)")
  local cells, here = {}, nil
  for c, r, mark in out:gmatch("cell (%d+) (%d+) (%S+)") do
    local cell = { c = tonumber(c), r = tonumber(r), mark = mark }
    if mark == "@" then here = cell else cells[#cells + 1] = cell end
  end
  if not cols or tonumber(cols) < 2 or not here then return false, "could not find the map grid" end
  local places, seen = {}, {}
  for _, cell in ipairs(cells) do
    -- rows count down the screen, y counts up
    local p = { x = s.pos.x + cell.c - here.c, y = s.pos.y - (cell.r - here.r) }
    places[cell.mark] = places[cell.mark] or {}
    table.insert(places[cell.mark], p)
    seen[#seen + 1] = string.format("%s %d,%d", cell.mark, p.x, p.y)
  end
  local marked = {}
  for _, list in pairs(places) do
    for _, p in ipairs(list) do marked[p.x .. "," .. p.y] = true end
  end
  town = {
    zone = s.pos.zone, places = places, marked = marked,
    cols = tonumber(cols), rows = tonumber(rows),
    x0 = s.pos.x - here.c, y_top = s.pos.y + here.r,
  }
  Log.Info(string.format("map of %s (%sx%s): %s", tostring(s.pos.zone), cols, rows, table.concat(seen, "  ")))
  return true
end

----------------------------------------------------------------------------
-- walking

-- coroutine-only. Walks to a square; returns the last reading, or nil + why.
local function walk_to(tx, ty)
  local stuck, last = 0, nil
  for _ = 1, 80 do
    guard()
    local s, problem = sense()
    if not s then return nil, problem end
    if s.pos and s.pos.x == tx and s.pos.y == ty then return s end
    if not s.pos or not s.nav then
      stuck += 1
      if stuck > 3 then return nil, "cannot read where you are" end
    else
      if last and last.x == s.pos.x and last.y == s.pos.y then
        stuck += 1
        if stuck > 3 then return nil, "cannot walk any closer to " .. tx .. "," .. ty end
      else
        stuck = 0
      end
      last = s.pos
      local dir = (ty > s.pos.y and "n" or ty < s.pos.y and "s" or "")
        .. (tx > s.pos.x and "e" or tx < s.pos.x and "w" or "")
      show("walking to " .. tx .. "," .. ty .. " (at " .. s.pos.x .. "," .. s.pos.y .. ")")
      click(s.nav[dir])
    end
    settle()
  end
  return nil, "the walk took too long"
end

----------------------------------------------------------------------------
-- the bank

-- coroutine-only. Makes the bank's drop-down say `want`.
local function bank_mode(s, want)
  if norm(s.bank_page.mode) == norm(want) then return true end
  local found = false
  pick_from_list(s.bank_page.select, function(list)
    local i = index_of(list, want)
    found = i ~= nil
    return i
  end)
  return found
end

-- coroutine-only, standing on the bank square
local function deposit_all(s)
  if not bank_mode(s, "Deposit All") then return false end
  click(s.bank_page.ok)
  settle()
  return true
end

-- coroutine-only, standing on the bank square
local function withdraw(s, amount)
  click(s.bank_page.input)
  Sleep(250)
  HID.Combo("LMeta+A")
  Sleep(120)
  HID.Type(tostring(amount))
  Sleep(300)
  if not bank_mode(s, "Withdraw") then return false end
  Sleep(300)
  click(s.bank_page.ok)
  settle()
  return true
end

----------------------------------------------------------------------------
-- gear

local ROMAN = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6, VII = 7, VIII = 8, IX = 9, X = 10 }

-- "Helmet II (1,207)" or "Arrow I (LH)" -> base "helmet", tier 2, price 1207
local function parse_item(name)
  local body, price = name:match("^(.-)%s*%(([%d,%.%s]+)%)%s*$")
  body = (body or name):gsub("%s*%(%a+%)%s*$", "")
  local words = {}
  for w in body:gmatch("%S+") do words[#words + 1] = w end
  local tier = 0
  if #words > 1 then
    -- I is often read as 1 or l
    local t = ROMAN[(words[#words]:gsub("[1l|]", "I")):upper()]
    if t then
      tier = t
      table.remove(words)
    end
  end
  return { base = norm(table.concat(words, " ")), tier = tier, price = price and num(price) or nil }
end

-- the shop list each slot is bought from, by what is worn there now
local WEAPON_LISTS = {
  bow = "Bows", sword = "Swords", axe = "Axes", staff = "Staves", mace = "Maces", claw = "Claws",
  scythe = "Scythes", arrow = "Arrow", shield = "Shields",
}
local SLOTS = {
  { label = "Right", list = function(base) return WEAPON_LISTS[base] end },
  { label = "Left", list = function(base) return WEAPON_LISTS[base] end },
  { label = "Armor:", list = function() return "Body Armor" end },
  { label = "Helmet:", list = function() return "Helmet" end },
  { label = "Leggings:", list = function() return "Leggings" end },
  { label = "Gauntlets:", list = function() return "Gauntlets" end },
  { label = "Boots:", list = function() return "Boots" end },
}

local gear = {
  worn = nil,       -- what each slot holds, once the Inventory panel was read
  surveyed = false, -- the shop was visited this run
  off = false,
  blocked = {},     -- items whose requirements are not met
}

-- What the script has learned and keeps between runs, in memory.json in its
-- data folder: for each zone, what every shop list sells and for how much.
local memory = nil

local function shop_prices(zone)
  if not memory then
    local fine, saved = pcall(File.ReadJSON, "@data/memory.json")
    memory = (fine and type(saved) == "table") and saved or {}
    memory.zones = memory.zones or {}
  end
  zone = zone or "?"
  memory.zones[zone] = memory.zones[zone] or { prices = {} }
  return memory.zones[zone].prices
end

local function save_memory()
  pcall(File.WriteJSON, "@data/memory.json", memory)
end

-- what is worn in each slot, from the Inventory panel
local function read_slots(s)
  local worn = {}
  for _, slot in ipairs(SLOTS) do
    local key = find(s.words, slot.label, function(w) return w.x < s.left_max end)
    if key and (slot.label == "Right" or slot.label == "Left") then
      key = find(s.words, "Hand:", function(w) return same_row(w, key) and w.x > key.x end)
    end
    if key then
      local parts = {}
      for _, w in ipairs(right_of(s.words, key, function(w) return w.x < s.centre_min end)) do
        if w.t ~= "(X)" then parts[#parts + 1] = w.t end
      end
      worn[slot.label] = parse_item(table.concat(parts, " "))
    end
  end
  return worn
end

-- what the Examine text says about wearing the item
local function can_wear(said, level)
  said = said:match("item class.*") or said
  if not said:find("no level requirements", 1, true) then
    local need = said:match("level%D-(%d+)")
    if not need or tonumber(need) > (level or 0) then return false end
  end
  local need, have = said:match("required:%s*(%d+)"), said:match("your %a+:%s*(%d+)")
  if need and have and tonumber(need) > tonumber(have) then return false end
  return true
end

-- the best item of a remembered list that is better than what is worn and
-- costs at most `budget`
local function best_known(known, list_name, have, budget)
  local best = nil
  for _, item in ipairs(known) do
    if item.tier > have.tier and item.price <= budget and not gear.blocked[list_name .. item.tier]
      and (not best or item.tier > best.tier) then
      best = item
    end
  end
  return best
end

-- coroutine-only, standing on the shop square with `budget` gold on hand.
-- Opens only the lists it has to: those not seen before, and those with
-- something affordable. Returns how many items were bought, or nil + why
-- gear buying should stop.
local function shop_visit(budget, level, zone)
  local s = sense(true)
  if not s or not s.shop then return nil, "no shop here" end
  if not s.link_inventory then return nil, "no Inventory link" end
  click(s.link_inventory)
  settle()
  s = sense(true)
  if not s or not find(s.words, "Helmet:") then return nil, "the Inventory panel did not open" end
  gear.worn = read_slots(s)
  local prices = shop_prices(zone)
  local bought = 0

  for _, slot in ipairs(SLOTS) do
    local have = gear.worn[slot.label]
    local list_name = have and slot.list(have.base)
    local known = list_name and prices[list_name]
    if list_name and looping and (not known or best_known(known, list_name, have, budget)) then
      show("shop: looking at " .. list_name)
      s = sense(true)
      if not s or not s.shop then return nil, "lost the shop page" end
      local in_list = false
      pick_from_list(s.shop.category, function(list)
        local i = index_of(list, list_name)
        in_list = i ~= nil
        return i
      end)
      if in_list then
        settle()
        s = sense(true)
        if not s or not s.shop then return nil, "lost the shop page" end
        local pick = nil
        pick_from_list(s.shop.item, function(list)
          local best, before, seen = nil, nil, {}
          for i, row in ipairs(list) do
            local item = parse_item(row.name)
            -- "Bow II" is sometimes read as "Bow": the list runs I, II, III...
            if item.tier == 0 and before and before.base == item.base then item.tier = before.tier + 1 end
            before = item
            if item.price and item.tier > 0 then
              seen[#seen + 1] = { tier = item.tier, price = item.price }
              if item.tier > have.tier and item.price <= budget and not gear.blocked[list_name .. item.tier]
                and (not best or item.tier > best.item.tier) then
                best = { i = i, item = item, name = row.name }
              end
            end
          end
          if #seen > 0 then prices[list_name] = seen end
          pick = best
          return best and best.i
        end)
        save_memory()
        if pick then
          settle()
          s = sense(true)
          if not s or not s.shop or not s.shop.examine then return nil, "lost the shop page" end
          click(s.shop.examine)
          settle()
          s = sense(true)
          if not s or not s.shop then return nil, "lost the shop page" end
          if not can_wear(s.said, level) then
            Log.Info("gear: cannot wear " .. pick.name .. " yet")
            gear.blocked[list_name .. pick.item.tier] = true
          else
            click(s.shop.buy)
            settle()
            s = sense(true)
            if not s or not s.said:find("you bought", 1, true) then
              return nil, "buying " .. pick.name .. " did not work"
            end
            budget -= pick.item.price
            bought += 1
            hud.bought += 1
            have.tier = pick.item.tier
            Log.Info(string.format("gear: bought %s for %d", pick.name, pick.item.price))
            -- put it on: it is in the pack list now
            if s.pack then
              local found = false
              pick_from_list(s.pack.select, function(list)
                -- worn items carry a tag such as "(RH)"; the new one has none
                local choice = nil
                for i, row in ipairs(list) do
                  local item = parse_item(row.name)
                  local tagged = row.name:match("%(%a+%)%s*$") ~= nil
                  if item.base == pick.item.base and not tagged
                    and (not choice or item.tier == pick.item.tier) then
                    choice = i
                  end
                end
                found = choice ~= nil
                return choice
              end)
              if found then
                settle()
                s = sense(true)
                if s and s.pack then
                  click(s.pack.equip)
                  settle()
                  Log.Info("gear: equipped " .. pick.name)
                end
              else
                Log.Warn("gear: " .. pick.name .. " is bought but was not found in the pack to equip")
              end
            end
          end
        end
      end
    end
  end
  gear.surveyed = true
  return bought
end

local function gear_budget(s)
  return math.floor(((s.gold or 0) + (s.bank or 0)) * cfg.gear_pct / 100)
end

-- Is a shop trip worth it now? "buy" when a remembered price fits the
-- budget, "look" once per run when this zone's shop has lists not seen yet
-- (a walk there with the gold on hand, no bank visit), else nil.
local function gear_plan(s)
  if gear.off or not gear.worn or not s.pos or not s.gold or not s.bank then return nil end
  local prices, budget, unseen = shop_prices(s.pos.zone), gear_budget(s), false
  for _, slot in ipairs(SLOTS) do
    local have = gear.worn[slot.label]
    local list_name = have and slot.list(have.base)
    if list_name then
      local known = prices[list_name]
      if not known then
        unseen = true
      elseif best_known(known, list_name, have, budget) then
        return "buy"
      end
    end
  end
  if unseen and not gear.surveyed then return "look" end
  return nil
end

----------------------------------------------------------------------------
-- trips from the fight square

-- coroutine-only. Each returns true, or false + why the loop should stop.

local function bank_trip(s, bank)
  local home = s.pos
  Log.Info(string.format("banking %d gold (bank %d) at %d,%d", s.gold or 0, s.bank or 0, bank.x, bank.y))
  local there, why = walk_to(bank.x, bank.y)
  if not there then return false, why end
  if not there.bank_page then return false, "there is no bank at " .. bank.x .. "," .. bank.y end
  deposit_all(there)
  local back
  back, why = walk_to(home.x, home.y)
  if not back then return false, why end
  return true
end

local function gear_trip(s, bank, shop, plan)
  local home = s.pos
  local budget = gear_budget(s)
  local there, why
  if plan == "buy" and bank then
    Log.Info(string.format("gear trip with up to %d gold", budget))
    there, why = walk_to(bank.x, bank.y)
    if not there then return false, why end
    if not there.bank_page then return false, "there is no bank at " .. bank.x .. "," .. bank.y end
    local need = budget - (there.gold or 0)
    if need > 0 then
      if not withdraw(there, need) then return false, "could not withdraw at the bank" end
    end
  else
    Log.Info("first look at this zone's shop")
    budget = math.min(budget, s.gold or 0)
  end
  there, why = walk_to(shop.x, shop.y)
  if not there then return false, why end
  local bought, trouble = shop_visit(budget, s.level, s.pos.zone)
  if not bought then
    gear.off = true
    UI.Notify("Shimlar: gear buying is off for this run (" .. tostring(trouble) .. ")")
  end
  -- back to the Stats panel, which the loop reads gold and health from
  local now = sense(true)
  if now and now.link_stats then
    click(now.link_stats)
    settle()
  end
  local back
  back, why = walk_to(home.x, home.y)
  if not back then return false, why end
  return true
end

local function revive(s, infirmary)
  local home = s.pos
  local there, why = walk_to(infirmary.x, infirmary.y)
  if not there then return false, "you died; " .. why end
  local rise = nil
  for _, w in ipairs(there.words) do
    if w.t:sub(1, 4) == "Rise" then rise = w end
  end
  if not rise then return false, "you died and there is no Rise! button at " .. infirmary.x .. "," .. infirmary.y end
  click(rise)
  settle()
  local back
  back, why = walk_to(home.x, home.y)
  if not back then return false, why end
  return true
end

----------------------------------------------------------------------------
-- the loop

local monsters = nil -- the fight square's list, weakest first

local function monster_index(name)
  return monsters and index_of(monsters, name)
end

-- coroutine-only. Draws the HUD where a run would put it, for 20 seconds.
hud_preview = function()
  if not in_game() or not ensure_ocr() then return end
  local s = sense(true)
  if not s then return end
  hud_place(s)
  show("preview: the HUD sits here")
  Timer.After(20000, function()
    if not looping then hud_remove() end
  end)
end

stop_loop = function(why)
  if not looping then return end
  looping = false
  hud.waiting = false
  show("stopped: " .. why)
  Timer.After(15000, function()
    if not looping then hud_remove() end
  end)
  Log.Info("loop stopped: " .. why)
  UI.Notify("Shimlar loop stopped: " .. why)
end

local function run()
  local ok, problem = ensure_ocr()
  if not ok then
    stop_loop(problem)
    return
  end
  show("reading the screen")

  local attacks = 0 -- attack clicks in the fight going on
  local stat_tries, blind, alerts, kills, deaths = 0, 0, 0, 0, 0
  local banking = cfg.auto_bank
  local climbing = cfg.auto_monster
  local best_health = 0
  local streak = 0          -- easy kills in a row on the current monster
  local no_up_before = 0    -- level needed before trying a stronger one again
  local pending = 0         -- monster change waiting: +1 stronger, -1 weaker
  local banked_for_step = false
  local map_tried = false
  local home = nil          -- the fight square, to walk back to after a pause
  local sought = false      -- a fight square has been looked for
  monsters, chat_top, town = nil, nil, nil
  gear = { worn = nil, surveyed = false, off = not cfg.auto_gear, blocked = {} }
  local worn_tried = false
  hud.kills, hud.deaths, hud.bought, hud.started = 0, 0, 0, System.Time()
  hud.waiting, paused = false, false

  local function body()
  while looping do
    if is_alert() then
      alerts += 1
      if alerts > 5 then
        stop_loop("the site keeps showing an alert")
        break
      end
      HID.Press("Enter")
      Sleep(600)
      continue
    end
    guard()
    local s, why = sense()
    if not s then
      stop_loop(why)
      break
    end
    if not looping then break end
    if s.health then best_health = math.max(best_health, s.health) end
    hud.monster, hud.level = s.monster or hud.monster, s.level or hud.level
    hud.gold, hud.bank, hud.health = s.gold or hud.gold, s.bank or hud.bank, s.health or hud.health
    hud_place(s)

    -- the left panel has to show Stats: gold and health are read from it
    if not s.gold and s.link_stats and blind < 2 then
      blind += 1
      click(s.link_stats)
      settle()
      continue
    end

    if s.fight and s.pos then home = s.pos end
    if not s.fight and home and s.pos and (s.pos.x ~= home.x or s.pos.y ~= home.y) then
      -- a pause cut a trip short: go back to the fight square
      local back, trouble = walk_to(home.x, home.y)
      if not back then
        stop_loop(trouble)
        break
      end
      continue
    end

    if not s.fight and not home and not sought and s.pos and s.gold then
      -- started somewhere with no monsters (a new character starts on the
      -- guide's square): read the map and step onto the nearest plain tile
      sought = true
      if not town then
        map_tried = true
        read_map(s)
      end
      local tile = town and plain_tile(s.pos)
      if tile then
        Log.Info(string.format("no monsters at %d,%d: walking to %d,%d", s.pos.x, s.pos.y, tile.x, tile.y))
        walk_to(tile.x, tile.y)
      end
      continue
    end

    if not s.fight then
      blind += 1
      if blind > 3 then
        stop_loop("no Fight button on this square")
        break
      end
      Sleep(700)
      continue
    end
    blind = 0

    -- 1. a level up waits for a stat
    local stat = s.stats and s.stats[cfg.stat]
    if stat then
      stat_tries += 1
      if stat_tries > 4 then
        stop_loop("the " .. cfg.stat .. " pick did not take")
        break
      end
      show("level up: raising " .. cfg.stat)
      click(stat)
      settle()
      continue
    end
    stat_tries = 0

    -- 2. a fight is open
    local hit = (cfg.action == "cast" and s.cast) or s.attack or s.cast
    if hit then
      attacks += 1
      alerts = 0
      click(hit)
      settle()
      continue
    end

    -- 3. between fights: first learn the zone
    if not town and not map_tried then
      map_tried = true
      local fine, trouble = read_map(s)
      if not fine then UI.Notify("Shimlar: " .. tostring(trouble) .. "; places come from the settings only") end
      continue
    end
    -- ...and what is worn, from the Inventory panel
    if not gear.off and not gear.worn and not worn_tried and s.link_inventory then
      worn_tried = true
      show("checking your gear")
      click(s.link_inventory)
      settle()
      local inv = sense(true)
      if inv and find(inv.words, "Helmet:") then
        gear.worn = read_slots(inv)
        local parts = {}
        for _, slot in ipairs(SLOTS) do
          local have = gear.worn[slot.label]
          if have then parts[#parts + 1] = string.format("%s %s %d", slot.label, have.base, have.tier) end
        end
        Log.Info("wearing: " .. table.concat(parts, ", "))
      end
      if inv and inv.link_stats then
        click(inv.link_stats)
        settle()
      end
      continue
    end
    local bank = place(cfg.bank_square, "B", s.pos)
    local shop = place(cfg.shop_square, "S", s.pos)
    local infirmary = place(cfg.infirmary_square, "R", s.pos)

    if s.health == 0 or s.said:find("you have been killed", 1, true) then
      deaths += 1
      hud.deaths = deaths
      Log.Info(string.format("killed by %s (death %d)", s.monster, deaths))
      if not cfg.auto_revive or not infirmary or not s.pos then
        stop_loop(s.monster .. " killed you")
        break
      end
      show("killed by " .. s.monster .. ": going to the infirmary")
      local fine, trouble = revive(s, infirmary)
      if not fine then
        stop_loop(trouble)
        break
      end
      if not climbing or deaths > 3 then
        stop_loop(s.monster .. " killed you; you are revived and back on your square")
        break
      end
      attacks, streak, pending = 0, 0, -1
      no_up_before = (s.level or 0) + 3
      continue
    end

    if attacks > 0 then
      kills += 1
      hud.kills = kills
      local health_pct = (s.health and best_health > 0) and (s.health / best_health * 100) or 100
      local step = 0
      if attacks > cfg.hard_attacks or health_pct < cfg.low_health then
        step = -1
        streak = 0
        no_up_before = (s.level or 0) + 2
      elseif attacks <= cfg.easy_attacks then
        streak += 1
        if streak >= cfg.easy_streak and (s.level or 0) >= no_up_before then step = 1 end
      else
        streak = 0
      end
      Log.Info(string.format(
        "kill %d: %s, %d attacks, health %d%%, streak %d, gold %s, bank %s",
        kills, s.monster, attacks, health_pct, streak, tostring(s.gold), tostring(s.bank)
      ))
      attacks = 0
      if climbing and step ~= 0 then pending = step end
    end

    -- gear before anything riskier: better gear, then stronger monsters
    local plan = shop and gear_plan(s)
    if plan and (plan == "look" or bank) then
      local fine, trouble = gear_trip(s, bank, shop, plan)
      if not fine then
        stop_loop(trouble)
        break
      end
      continue
    end

    -- a stronger monster may kill you, and gold on hand is lost then: bank it first
    if pending > 0 and banking and bank and not banked_for_step and (s.gold or 0) > 0 and s.pos then
      banked_for_step = true
      local fine, trouble = bank_trip(s, bank)
      if not fine then
        stop_loop(trouble)
        break
      end
      continue
    end

    if pending ~= 0 then
      local step = pending
      pending, banked_for_step, streak = 0, false, 0
      local found = false
      local list = pick_from_list(s.select, function(list)
        monsters = list
        local i = monster_index(s.monster)
        if i and list[i + step] then
          found = true
          show("switching to " .. list[i + step].name)
          Log.Info(string.format("monster: %s -> %s", s.monster, list[i + step].name))
          return i + step
        end
        return nil
      end)
      if not list then
        climbing = false
        UI.Notify("Shimlar: could not read the monster list, staying on " .. s.monster)
      end
      if step < 0 and not found then
        stop_loop(s.monster .. " is too strong and there is nothing weaker to pick")
        break
      end
      continue
    end

    if banking and bank and s.pos and s.gold and s.bank and s.gold > 0 and s.gold >= cfg.bank_min
      and s.gold >= (s.gold + s.bank) * cfg.bank_pct / 100 then
      local fine, trouble = bank_trip(s, bank)
      if not fine then
        stop_loop(trouble)
        break
      end
      continue
    end

    show("fighting " .. s.monster)
    click(s.fight)
    settle()
  end
  end

  -- a pause ends whatever was going on with REFOCUS: start over from a fresh
  -- look at the screen, with the counters kept
  while looping do
    local fine, err = pcall(body)
    if fine or not looping or err == STOPPED then break end
    if err ~= REFOCUS then
      stop_loop(tostring(err))
      break
    end
    attacks = 0
  end
end

start_loop = function()
  if looping then return end
  looping = true
  Log.Info("loop started")
  Run(function()
    local fine, err = pcall(run)
    if not fine and err ~= STOPPED then stop_loop(tostring(err)) end
    looping = false
  end)
end

Bind("LAlt+L", {
  when = function() return looping or in_game() end,
  action = function()
    if looping then stop_loop("you pressed Option+L") else start_loop() end
  end,
})

Bind("LAlt+P", {
  when = function() return looping end,
  action = function()
    paused = not paused
  end,
})

Bind("Escape", {
  when = function() return looping end,
  action = function() stop_loop("you pressed Escape") end,
})

-- keep the HUD's clock moving between clicks
Timer.Every(1000, function()
  if looping and hud.surface then hud_draw() end
end)

function OnStop()
  looping = false
  hud_remove()
end

Log.Info("shimlar-macro loaded: in the Shimlar tab press Option+L to start the loop")
