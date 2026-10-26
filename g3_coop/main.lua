-- Gen 3 co-op: two players, each on their own save, see each other in the
-- same overworld.  One hosts, the other joins by address, over the engine's
-- own link transport (src/link/Net.lua, ENet on UDP).  START > CO-OP hosts,
-- joins or leaves, and ADDRESS sets the host's address and what to do on
-- load (kept in this player's save; the launcher's settings are the
-- fallback); F8 connects or disconnects in one key.  F7 (or START > CO-OP > SOUL LINK)
-- shows the Soul Link run.
--
-- The partner is drawn on your screen (on your map or a connected one).
-- Pressing A while facing them opens WAVE / BATTLE / TRADE; a battle or a
-- trade asks the partner first, then runs the engine's own link battle or
-- trade screen over the co-op connection.  Not yet: shared progression.
-- See ../DESIGN.md.

return function(mod)
  local function import(rel)
    return assert(load(assert(mod:read(rel)), "@g3_coop/" .. rel))()
  end

  local Protocol = import("lib/protocol.lua")
  local Presence = import("lib/presence.lua")
  local Ghost = import("lib/ghost.lua")
  local Session = import("lib/session.lua")
  local Channel = import("lib/channel.lua")
  local Activity = import("lib/activity.lua")
  local Requests = import("lib/requests.lua")
  local Npcs = import("lib/npcs.lua")
  local SoulLink = import("lib/soullink.lua")
  local Tracker = import("lib/tracker.lua")
  local Hud = import("lib/hud.lua")
  local LevelCap = import("lib/levelcap.lua")
  local TeamBattle = import("lib/teambattle.lua")
  local ConnEdit = import("lib/connedit.lua")
  local TradeFull = import("lib/tradefull.lua")
  local Credit = import("lib/credit.lua")
  local Progress = import("lib/progress.lua")

  mod.options:define(import("options.lua"))

  -- Connection settings: this player's own choices (CO-OP > ADDRESS and
  -- HOST/JOIN, kept in their save) over the launcher's.  A sealed cart
  -- hands its mods only the cart's options, the same for both players, so
  -- on a cart the launcher can't say who hosts or where the host is.
  local game
  local function connStored()
    if not game then return nil end
    local ok, v = pcall(mod.storage.read, mod.storage, game, "conn")
    return ok and type(v) == "table" and v or nil
  end
  local function connWrite(v)
    if game then pcall(mod.storage.write, mod.storage, game, "conn", v) end
  end
  local function setting(key)
    local c = connStored()
    if c then
      if key == "address" and type(c.address) == "string" then return c.address end
      if key == "port" and tonumber(c.port) then return tonumber(c.port) end
      if key == "autoconnect" and c.onload then return c.onload ~= "OFF" end
      if key == "role" then
        if c.onload == "HOST" or c.onload == "JOIN" then return c.onload:lower() end
        if c.role == "host" or c.role == "join" then return c.role end
      end
    end
    return mod.options:get(key)
  end

  local Net = require("src.link.Net")
  local Handshake = require("src.link.Handshake")
  local GameVersion = require("src.core.GameVersion")
  local GfxIds = require("src.core.game3.scripting.gfx_ids")

  local session, status, requests, activity
  -- when to try connecting again after a dropped link (see RETRY_REASONS)
  local retryAt
  local newRequests
  local toasts, seenEmotes, lastWaveAt = {}, 0, -1

  local function clock()
    if love and love.timer and love.timer.getTime then return love.timer.getTime() end
    return os.clock()
  end

  -- Soul Link's toasts get its label and colour (red for a death)
  local BAD_WORDS = { "gone", "fainted", "over", "broken", "can't battle", "against the rules" }
  local function toast(text, seconds)
    text = tostring(text)
    local t = { text = text, born = clock(), untilT = clock() + (seconds or 3), kind = "coop" }
    local rest = text:match("^Soul Link: (.*)$")
    if rest then
      t.label, t.text, t.kind = "SOUL LINK", rest, "sl"
      for _, w in ipairs(BAD_WORDS) do
        if rest:find(w, 1, true) then t.kind = "bad" break end
      end
    end
    toasts[#toasts + 1] = t
    while #toasts > 3 do table.remove(toasts, 1) end
  end

  -- Engine modules through require: inside the mod sandbox `package` is a
  -- stub whose `loaded` table is always empty, so looking modules up there
  -- finds nothing (that silently disabled every position update in 0.1.x).
  -- require hands back the live, already-loaded instance.
  local engineModules = {}
  local function engine(name)
    local m = engineModules[name]
    if m == nil then
      local ok, loaded = pcall(require, "src.core.game3." .. name)
      m = ok and type(loaded) == "table" and loaded or false
      engineModules[name] = m
    end
    return m or nil
  end

  local function uiModule(name)
    local ok, m = pcall(require, "src.ui.game3." .. name)
    return ok and type(m) == "table" and m or nil
  end

  -- everything an activity drives (lib/activity.lua)
  local function activityEngine()
    return {
      Link = engine("link"), LB = engine("link.battle"), LT = engine("link.trade"),
      Game3Link = require("src.link.Game3Link"),
      Message = uiModule("message"), Field = engine("field"),
      TradeMenu = uiModule("link_trade_menu"),
    }
  end

  -- Where a map sits on the local screen, in cells relative to the active
  -- map: (0, 0) for the active map, the connection offset for a neighbour
  -- the field is drawing alongside it, nil for anything off screen.
  local function offsetOf(mapId)
    local Map = engine("map")
    if not (Map and mapId) then return nil end
    if mapId == Map.current then return 0, 0 end
    for _, e in ipairs(Map.world or {}) do
      if e.id == mapId then return e.ox, e.oy end
    end
    return nil
  end

  -- every loaded mod and its version: map identity depends on content mods
  -- (the Inclement port re-indexes and adds maps), not only on what the link
  -- fingerprint covers
  local function modsKey(g)
    local parts = {}
    for _, m in ipairs(Handshake.mods(g)) do
      parts[#parts + 1] = tostring(m.id) .. "@" .. tostring(m.version)
    end
    return table.concat(parts, ",")
  end

  local function compat(localHello, remote)
    if remote.game ~= localHello.game then return false, "different_game" end
    if remote.mods ~= localHello.mods then return false, "different_mods" end
    local verdict, why = Handshake.checkCompat(localHello.link, remote.link)
    -- the ruleset is a battle setting; it does not change the world
    if verdict == "full" or verdict == "ruleset_skew" then return true end
    -- link battles need the identical release because they lockstep a
    -- simulation; walking around only needs the same maps, which the data
    -- fingerprint and the mod list already pin
    if verdict == "engine_skew" and localHello.link.fingerprint ~= nil
        and localHello.link.fingerprint == remote.link.fingerprint then
      return true, "engine_skew"
    end
    return false, why or verdict
  end

  local REASONS = {
    different_game = "different game",
    different_mods = "different mods",
    engine_mismatch = "different engine",
    engine_release_mismatch = "different engine release",
    fingerprint_mismatch = "different game data",
    generation_mismatch = "different generation",
    protocol_version = "different co-op version",
    partner_left = "partner left",
    timeout = "connection lost",
    no_hello = "partner didn't answer",
    network_error = "couldn't connect",
    left = "disconnected",
    stopped = "partner disconnected",
  }

  -- A link that worked and then dropped (the partner restarted, Wi-Fi
  -- blinked) is retried until it comes back or F8 stops it; so is a first
  -- attempt when CONNECT ON LOAD is on.  A refusal (different versions or
  -- mods) is not: retrying can't fix it.
  local RETRY_SECONDS = 5
  local RETRY_REASONS = { partner_left = true, timeout = true, no_hello = true, network_error = true }

  -- the host's wandering NPCs, mirrored on the joiner (lib/npcs.lua)
  local npcs = Npcs.new(clock)

  -- ------------------------------------------------------------ Soul Link

  local function gameSession()
    local Runtime = engine("runtime")
    return Runtime and Runtime.getSession and Runtime.getSession()
  end

  -- an area's name as the game's map popup shows it: Ruby/Sapphire/
  -- Emerald keep MAPSEC names in their own table, FireRed/LeafGreen in
  -- map_sections_extract
  local areaNames = {}
  local function areaName(sec)
    local n = areaNames[sec]
    if n then return n end
    local okR, Mapsec = pcall(require, "src.ui.game3.rse.mapsec")
    local okN, name = false, nil
    if okR and Mapsec and Mapsec.name then okN, name = pcall(Mapsec.name, sec) end
    if not (okN and type(name) == "string" and name ~= "") then
      local okS, Sections = pcall(require, "src.import.gba.map_sections_extract")
      local okI, info = false, nil
      if okS and Sections and Sections.getInfo then okI, info = pcall(Sections.getInfo, sec, nil, 0) end
      name = okI and type(info) == "table" and info.resolved and (info.rawName or info.name) or nil
    end
    if type(name) == "string" then name = name:gsub("[%c]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") end
    n = (type(name) == "string" and name ~= "" and name ~= "???") and name or ("AREA " .. tostring(sec))
    areaNames[sec] = n
    return n
  end

  -- the first species of an evolution line, for the dupes clause
  local parentOf
  local function baseOf(sp)
    sp = tonumber(sp)
    if not sp then return sp end
    if not parentOf then
      parentOf = {}
      local Pokemon = engine("pokemon")
      if Pokemon and Pokemon.evolutions then
        Pokemon.evolutions(1)
        for from, rows in pairs(Pokemon._evolutions or {}) do
          for _, evo in ipairs(rows) do
            local to = tonumber(evo.target or evo[3])
            if to and to ~= from and not parentOf[to] then parentOf[to] = tonumber(from) end
          end
        end
      end
    end
    local seen = 0
    while parentOf[sp] and seen < 4 do sp, seen = parentOf[sp], seen + 1 end
    return sp
  end

  local SL_OPTIONS = { dupes = "sl_dupes", shiny = "sl_shiny", gift = "sl_gift",
                       static = "sl_static", enforce = "sl_enforce", hard = "sl_hard",
                       caps = "sl_caps" }
  -- Soul Link settings picked in game (the panel's RULES tab), kept in this
  -- player's storage: they beat the launcher's, which a sealed cart never
  -- passes on (it hands its mods only the cart's own options).
  local slStored = nil
  local function slSettings()
    if slStored == nil and game then
      local ok, v = pcall(mod.storage.read, mod.storage, game, "sl_settings")
      slStored = ok and type(v) == "table" and v or {}
    end
    return slStored or {}
  end
  local function slOpt(key)
    local v = slSettings()[key]
    if v ~= nil then return v == true end
    return mod.options:get(key) == true
  end
  local function setSlOpt(key, on)
    local t = slSettings()
    t[key] = on == true
    slStored = t
    if game then pcall(mod.storage.write, mod.storage, game, "sl_settings", t) end
  end
  local tracker = Tracker.new({
    SL = SoulLink, now = clock, toast = toast, session = gameSession,
    read = function(key) return mod.storage:read(game, key) end,
    write = function(key, value) return mod.storage:write(game, key, value) end,
    areaOf = function()
      local Pokemon = engine("pokemon")
      return Pokemon and Pokemon.currentMapSec and Pokemon.currentMapSec(gameSession())
    end,
    giftArea = function(species, area, mon)
      -- The party scan can see the starter after Birch has moved us back
      -- to town. Use its met location for this one gift; other gifts keep
      -- their usual area. Log normalization also handles old starter pairs.
      if mon and tonumber(mon.metLevel) == 5 and tonumber(mon.metLocation) == 16 then
        local town = SoulLink.hoennStarterArea(GameVersion.get(), baseOf(species), 16)
        if town == 0 then return town end
      end
      return SoulLink.hoennStarterArea(GameVersion.get(), species, area)
    end,
    areaName = areaName, baseOf = baseOf,
    speciesName = function(sp)
      local Pokemon = engine("pokemon")
      local ok, n = pcall(Pokemon.name, tonumber(sp))
      return ok and n or ("#" .. tostring(sp))
    end,
    isShiny = function(mon) local P = engine("pokemon") return P and P.isShiny(mon) or false end,
    isEgg = function(mon) local P = engine("pokemon") return P and P.isEgg(mon) or false end,
    -- what a battle's foe is, for the FALLEN list: "YOUNGSTER JOEY",
    -- "wild ZUBAT"
    faintCause = function(st)
      if type(st) ~= "table" then return nil end
      if st.wild then
        local foe = st.enemy and st.enemy.mon
        local P = engine("pokemon")
        local ok, n = pcall(function() return P.name(tonumber(foe.species)) end)
        return ok and n and ("wild " .. n) or "a wild POKeMON"
      end
      local id = tonumber(st.trainerId)
      if not id then return st.link and "a link battle" or nil end
      local ok, info = pcall(function() return require("src.core.game3.scripting.trainers").info(id) end)
      if ok and info then
        local cls = info.className and info.className ~= "" and (info.className .. " ") or ""
        return (cls .. tostring(info.name or "")):gsub("%s+$", "")
      end
      return st.trainerName
    end,
    options = function()
      local o = { on = slOpt("soullink") }
      for k, key in pairs(SL_OPTIONS) do o[k] = slOpt(key) end
      return o
    end,
    newId = function()
      local r = love and love.math and love.math.random or math.random
      return ("%x%06x"):format(os.time(), r(0, 0xffffff))
    end,
    send = function(fields)
      if session and session.state == "connected" then session:sendSoulLink(fields) end
    end,
    -- hard rules: banned POKeMON go from the party to the PC
    storage = {
      openSlot = function(s)
        local Storage = engine("storage")
        return Storage.findOpenSlot(Storage.ensure(s))
      end,
      move = function(s, partyIndex, box, slot)
        local Storage = engine("storage")
        return Storage.moveMon(s, "party", partyIndex, "box", slot, nil, box) == true
      end,
    },
  })
  local slPanel = false
  -- the overlay (lib/hud.lua), made on the first frame; panelMax: how far
  -- the Soul Link panel can scroll
  local hud, panelMax = nil, 0
  -- START > CO-OP: picked from the start menu, opened once the field is
  -- free (coopMenu is defined with the menu, below)
  local menuPending, coopMenu, openEditor = false, nil, nil
  local slConnected = nil
  -- ROM texts swapped for a refused ball's message (see the bag wrap
  -- below), put back on the next tick
  local overridden = nil
  local function restoreText()
    if not overridden then return end
    local RomText = engine("rom_text")
    for k, v in pairs(overridden) do
      if v == false then RomText.overrides[k] = nil else RomText.overrides[k] = v end
    end
    overridden = nil
  end

  -- ----------------------------------------------------------- level caps

  -- the cap now (lib/levelcap.lua compute), worked out every 2 seconds
  local capState, capAt, capToldFor = nil, -1, false
  local CAP_SECONDS = 2
  local aceOf = {}

  local function capsOn()
    return tracker.run ~= nil and slOpt("soullink") and tracker:rules().caps == true
  end

  -- On a cart the built-in story lists don't apply: a cart renumbers its
  -- trainers (the Inclement port's are 60000+) and sets its own story, so
  -- the vanilla rival's flag would never be set and the cap would stay at
  -- the first fight forever.  A cart's mod may supply the cap instead:
  --   mod.exports.coopLevelCap(session) -> { cap = level, label = text }
  -- (cap = nil once there are no more caps).  Without one, caps are off.
  -- A cart that keeps the vanilla story and trainers says so instead
  -- (mod.exports.coopVanillaStory = true), and the built-in list applies.
  local function cartCap()
    local okS, SaveData = pcall(require, "src.core.SaveData")
    local cart = okS and SaveData.getCart and SaveData.getCart() or nil
    if not cart then return false end
    for id, ex in pairs(game and game.mods and game.mods.exports or {}) do
      if id ~= "g3_coop" and type(ex) == "table" and ex.coopVanillaStory == true then return false end
    end
    for id, ex in pairs(game and game.mods and game.mods.exports or {}) do
      if id ~= "g3_coop" and type(ex) == "table" and type(ex.coopLevelCap) == "function" then
        local ok, r = pcall(ex.coopLevelCap, gameSession())
        if ok and type(r) == "table" then
          return true, { cap = tonumber(r.cap), label = tostring(r.label or "next big fight") }
        end
        return true, nil
      end
    end
    return true, "no_list"
  end

  local function computeCap()
    local onCart, fromCart = cartCap()
    if onCart then return fromCart end
    local s = gameSession()
    local Space = engine("scripting.space")
    if not (s and Space and Space.store) then return nil end
    local Constants = require("src.core.game3.constants")
    local Flags = require("src.core.game3.scripting.flags")
    local Trainers = require("src.core.game3.scripting.trainers")
    local version = Constants.versionOf(s)
    local C = Constants.of(version)
    local ctx = Space.vm and Space.vm.ctx
    local function named(r)
      if type(r) == "table" and version == "emerald" then r.label = LevelCap.named(r.label, s.gender) end
      return r
    end
    return named(LevelCap.compute(LevelCap.listFor(version),
      function(name)
        local ok, id = pcall(C.id, C, "trainers", name)
        return ok and tonumber(id) or nil
      end,
      function(id)
        local ok, v = pcall(Flags.getFlag, Space.store, ctx, Flags.trainerFlagId(id))
        return ok and v == true
      end,
      function(id)
        if aceOf[id] == nil then
          local ok, t = pcall(Trainers.get, id)
          local top = false
          for _, m in ipairs(ok and t and t.party or {}) do
            local lv = tonumber(m.level or m.lvl)
            if lv and (not top or lv > top) then top = lv end
          end
          aceOf[id] = top
        end
        return aceOf[id] or nil
      end))
  end

  -- the next big fight, worked out whether or not caps are on (the status
  -- card and the Soul Link panel show it); nextToldFor: the last one toasted
  local storyState, nextToldFor = nil, nil
  local function stepCaps()
    local now = clock()
    if now < capAt then return end
    capAt = now + CAP_SECONDS
    local ok, st = pcall(computeCap)
    if not ok then
      mod.log:warn("level caps: %s", tostring(st))
      return
    end
    storyState = type(st) == "table" and st or nil
    if not capsOn() then
      capState, capToldFor = nil, false
      local label = storyState and storyState.label
      if label and nextToldFor and label ~= nextToldFor then
        toast(("Next big fight: %s."):format(label), 6)
      end
      if label then nextToldFor = label end
      return
    end
    nextToldFor = storyState and storyState.label or nextToldFor
    if st == "no_list" then
      capState = nil
      if capToldFor ~= "no_list" then
        capToldFor = "no_list"
        toast("Soul Link: this cart has no level-cap list yet, so level caps are off.", 6)
      end
      return
    end
    capState = st
    local key = st and (st.cap and (st.cap .. " " .. tostring(st.label)) or "none")
    if key and key ~= capToldFor then
      if capToldFor and st.cap and capToldFor:match("^(%d+) ") == tostring(st.cap) then
        toast(("Soul Link: next big fight is %s. The level cap stays %d."):format(st.label, st.cap), 6)
      elseif capToldFor and st.cap then
        toast(("Soul Link: level cap is now %d (%s)."):format(st.cap, st.label), 6)
      elseif capToldFor then
        toast("Soul Link: no more level caps. The League is beaten!", 6)
      elseif st.cap then
        toast(("Soul Link: level cap %d (%s)."):format(st.cap, st.label), 5)
      end
      capToldFor = key
    end
  end

  local function capNow()
    return capsOn() and capState and capState.cap or nil
  end

  local function dropSession()
    tracker:onDisconnected()
    slConnected = nil
    npcs:release()
    npcs:forget()
    if requests then requests:reset() end
    requests = nil
    -- a battle or trade in progress sees its channel fail and winds down
    -- through the engine (draw / aborted trade); it keeps being stepped
    if activity then activity:abort("partner_left") end
    -- a team battle in progress pauses at once (the link's own timeout
    -- would get there in about nine seconds)
    if activity and activity.kind == "team" then
      local Battle, LB = engine("battle"), engine("link.battle")
      if Battle and Battle.coopPause and LB and LB.state == "battle" then pcall(Battle.coopPause, "partner_left") end
    end
    session = nil
  end

  local function disconnect(reason)
    if session then session:close(reason or "left") end
    dropSession()
  end

  local function partyCount()
    local Runtime = engine("runtime")
    local s = Runtime and Runtime.getSession and Runtime.getSession()
    local n = 0
    for _, mon in ipairs(s and s.party or {}) do
      if (tonumber(mon.species) or 0) ~= 0 then n = n + 1 end
    end
    return n
  end

  -- whether this game can take part in act right now: the same checks the
  -- Union Room makes before it offers a battle, and the Trade Center's
  -- two-POKeMON rule
  -- the host's pick for the next team battle: { a = trainer id, b = trainer id }
  local pendingTeam = nil
  -- the team battle in progress: { slots, foes, written }
  local teamState = nil

  local function teamEngine()
    return {
      LB = engine("link.battle"), TowerLink = engine("link.tower_link"),
      Trainers = engine("scripting.trainers"), TextIR = engine("scripting.text_ir"),
      Party = engine("party"), Space = engine("scripting.space"), Flags = engine("scripting.flags"),
      Rng = engine("rng"), Pokemon = engine("pokemon"), Damage = engine("battle.damage"),
      Encounters = engine("encounters"), Map = engine("map"), Prize = engine("battle.prize"),
    }
  end

  local function hasLivingMon()
    local LB = engine("link.battle")
    local Runtime = engine("runtime")
    local s = Runtime and Runtime.getSession and Runtime.getSession()
    for _, mon in ipairs(s and s.party or {}) do
      if LB and LB.eligible(mon) and (tonumber(mon.hp) or 0) > 0 then return true end
    end
    return false
  end

  local function eligible(act)
    if act == "team" or act == "wild" or act == "trainer" or act == "joint" then
      if not hasLivingMon() then return false, "no_mons" end
      return true
    end
    if act == "battle" then
      local LB, Link = engine("link.battle"), engine("link")
      if not (LB and Link) then return false, "error" end
      return LB.validateParty(nil, Link.USING.SINGLE_BATTLE, { unionRoom = true })
    end
    if partyCount() < 2 then return false, "no_mons" end
    return true
  end

  local function fieldFree()
    if not (game and game.phase == "field") or activity then return false end
    local Hud, Player, Field = uiModule("hud"), engine("player"), engine("field")
    if Hud and Hud.busy and Hud.busy() then return false end
    if Player and Player.moving then return false end
    if Field and Field.isLocked and Field.isLocked() then return false end
    return true
  end

  local RESULT_TEXT = { win = "You won the battle!", lose = "You lost the battle.", run = "You got away safely.",
                        draw = "The battle ended in a draw." }
  local WHY_TEXT = {
    peer_left = "partner left", partner_left = "partner left", link_timeout = "no reply",
    setup_timeout = "no reply", engine_release_mismatch = "different engine release",
    engine_mismatch = "different engine", fingerprint_mismatch = "different game data",
    rules_mismatch = "different battle rules", cache_version_mismatch = "different game data",
    native_version_mismatch = "different engine",
  }

  -- what lib/activity.lua needs for a team battle on channel id
  local function teamDeps(s, id, pickOverride)
    local E = teamEngine()
    local seat = s.role == "host" and 0 or 1
    local pick = pickOverride or pendingTeam
    pendingTeam = nil
    teamState = { slots = nil, foes = nil, written = nil, faints = {}, wild = pick and pick.wild,
                  peerName = s.peer and s.peer.name }
    return {
      mine = function()
        local gs = gameSession()
        if not gs then return nil, "error" end
        local setup, why
        if seat == 0 then
          if not pick then return nil, "error" end
          local seed = math.floor((os.time() * 7919 + clock() * 1000003)) % 4294967296
          if pick.wild then
            setup, why = TeamBattle.hostWildSetup(E, gs, pick.map or gs.map or (E.Map and E.Map.current), seed)
          else
            setup, why = TeamBattle.hostSetup(E, gs, pick.a, pick.b, seed)
          end
        else
          setup = TeamBattle.mySide(E, gs)
        end
        if setup then teamState.slots = setup.slots end
        return setup, why
      end,
      send = function(setup) s:sendTeam(id, setup) end,
      take = function() return s:takeTeam(id) end,
      begin = function(mine, peer, onDone)
        teamState.foes = (seat == 0 and mine or peer).foes
        teamState.wild = (seat == 0 and mine or peer).wild and true or nil
        return TeamBattle.begin(E, mine, peer, seat, onDone)
      end,
    }
  end

  -- the field held still while a found wild POKeMON waits for the partner
  local WILD_LOCK = "g3coop_wild"

  -- a trade in progress (lib/tradefull.lua): { id, mine, uninstall }
  local tradeFull = nil
  local function endTradeFull()
    if tradeFull and tradeFull.uninstall then pcall(tradeFull.uninstall) end
    tradeFull = nil
  end

  -- A trainer fight this game's script is holding for a team battle:
  -- { done = the script's battle callback, noWhiteout }.  The script resumes
  -- only after the team battle's result (COOP.md "Campaign exports and
  -- event gate").
  local heldTrainer = nil

  -- Shared story progression (lib/progress.lua): the port's receipts for
  -- a rival, gym or story fight, so the partner's game plays the same
  -- post-battle script (badge, TM, story) as the initiator's.
  local function progressApi()
    if not gameSession() then return nil end
    for mid, ex in pairs(game and game.mods and game.mods.exports or {}) do
      if mid ~= "g3_coop" and type(ex) == "table" and type(ex.coopProgress) == "table"
          and ex.coopProgress.API == 1 then
        return ex.coopProgress
      end
    end
    return nil
  end
  local releaseHeld
  -- how long a follower's script waits at a scene's next fight
  local FOLLOW_SECONDS = 120
  local progress = Progress.new({
    api = progressApi,
    send = function(fields) if session then session:sendProg(fields) end end,
    connected = function() return session ~= nil and session.state == "connected" end,
    now = clock, toast = function(text, secs) toast(text, secs) end,
    -- saved at once (mod.storage), with the time in case an older save
    -- comes back: never the same id for two events
    newId = function()
      -- (storage keeps data tables only)
      local okR, v = pcall(mod.storage.read, mod.storage, game, "event_seq")
      local n = (okR and type(v) == "table" and tonumber(v.n) or 0) + 1
      local okW, wrote, why = pcall(mod.storage.write, mod.storage, game, "event_seq", { n = n })
      if not (okW and wrote) then mod.log:warn("event counter not saved: %s", tostring(why or wrote)) end
      local gs = gameSession() or {}
      return ("g3c:%d.%d:%d:%d"):format(tonumber(gs.trainerId) or 0, tonumber(gs.secretId) or 0,
        n, os.time())
    end,
    canJoin = function()
      return game ~= nil and game.phase == "field" and not activity and not heldTrainer
        and not (requests and (requests.outgoing or requests.busy))
    end,
    idle = function()
      if not fieldFree() then return false end
      local Space = engine("scripting.space")
      return not (Space and Space.vm and Space.vm.isRunning and Space.vm:isRunning())
    end,
    held = function() return heldTrainer and heldTrainer.event end,
    ownPrefix = function()
      local gs = gameSession()
      return gs and ("g3c:%d.%d:"):format(tonumber(gs.trainerId) or 0, tonumber(gs.secretId) or 0) or nil
    end,
    -- the leader fought a scene's later fight alone: our waiting script
    -- takes that result (a joint battle releases it itself)
    onResult = function(id, r)
      local h = heldTrainer
      if h and h.follow and h.event == id and not activity then releaseHeld(r) end
    end,
    map = function()
      local Space = engine("scripting.space")
      return Space and Space.mapId
    end,
    mapName = function(map)
      local words = tostring(map or ""):gsub("^EM_", ""):gsub("_", " ")
      return words ~= "" and words or nil
    end,
    log = function(fmt, ...) mod.log:warn(fmt, ...) end,
  })

  -- the trainer script's result: a win, a loss, or (a fight that never
  -- finished) "cancel", which halts the script without its post-battle
  -- part; an engine without "cancel" gets "lose" (a "draw" would count as
  -- beaten).  A shared story event takes the same result first.  Once.
  releaseHeld = function(word)
    local h = heldTrainer
    heldTrainer = nil
    if not (h and h.done) then return end
    local Field = engine("field")
    if Field and Field.unlock then Field.unlock(WILD_LOCK) end
    local r = word == "win" and "win" or (word == "lose" or word == "whiteout") and "lose"
      or (h.cancel and "cancel" or "lose")
    if h.event then
      -- the partner dropped out and this game didn't win: the fight stays
      -- open for their fallback win, and the script stops here
      local okL, left = false, false
      if h.dropped and r ~= "win" then okL, left = pcall(progress.leave, progress, h.event, true) end
      if okL and left then
        r = "cancel"
      else
        pcall(progress.finish, progress, h.event, r)
        if r == "win" then progress:started(h.event) end
      end
    end
    pcall(h.done, r)
  end

  local function startActivity(act, id, t)
    local s = session
    local ch = s:openChannel(id)
    if act == "trade" or act == "battle" then
      -- whole parties first, ahead of the engine's own link messages
      endTradeFull()
      local mine = TradeFull.side(gameSession())
      tradeFull = { id = id, mine = mine, act = act }
      s:sendTeam(id, mine)
    end
    -- a wild POKeMON one of us found: a team battle against two wild foes
    -- the host rolls on the shared map
    local wildPick = nil
    local jointFight = act == "joint"
    if act == "wild" then
      wildPick = { wild = true }
      act = "team"
      local Field = engine("field")
      if Field and Field.unlock then Field.unlock(WILD_LOCK) end
    elseif (act == "trainer" or act == "joint") and type(t) == "table" and t[1] then
      -- a trainer fight together: one trainer commanding both positions, or
      -- the event's pair; the host builds it whoever found it
      wildPick = { a = t[1], b = t[2] }
      act = "team"
      local Field = engine("field")
      if Field and Field.unlock then Field.unlock(WILD_LOCK) end
    end
    if act == "team" then ch.peerSeat = s.role == "host" and 1 or 0 end
    s:setBusy(act == "team" and "battle" or act)
    local mine
    mine = Activity.new({
      kind = act, seat = s.role == "host" and 0 or 1, channel = ch, game = game,
      now = clock, E = activityEngine(), team = act == "team" and teamDeps(s, id, wildPick) or nil,
      onEnd = function(result, why)
        if activity == mine then activity = nil end
        if session == s then
          s:closeChannel(id)
          s:setBusy("none")
        end
        if requests then requests:finished() end
        if act == "team" then teamState, pausePanel = nil, nil end
        -- the trainer's script carries on now: after the battle's own
        -- teardown, with its result (a fight that never started is lost)
        if heldTrainer then releaseHeld(result) end
        if act == "trade" or act == "battle" then endTradeFull() end
        if result == nil then
          toast("Couldn't " .. (act == "team" and "team up" or act) .. ": " .. tostring(WHY_TEXT[why] or why))
        elseif act == "battle" or act == "team" then
          toast(RESULT_TEXT[result] or ("Battle over (" .. tostring(result) .. ")."))
        elseif result == 1 then
          toast("Traded 1 POKeMON.")
        elseif result > 1 then
          toast(("Traded %d POKeMON."):format(result))
        else
          toast("Left the trade.")
        end
      end,
    })
    activity = mine
    -- a story fight's shared event: ours if we started it, else the one
    -- the partner just had us prepare
    if teamState and jointFight then
      teamState.event = heldTrainer and heldTrainer.event or progress:expected()
    end
    mine:start()
  end

  local function wave()
    if not session then return end
    session:emote("wave")
    toast("You waved at " .. tostring(session.peer and session.peer.name or "your partner"))
  end

  -- the game's own message box and choice menu, which the HUD drives in
  -- the field (src/ui/game3/hud.lua)
  local ui = {}
  local waitCancel
  function ui.close()
    local Message, Choice = uiModule("message"), uiModule("choice")
    waitCancel = nil
    if Choice and Choice.active then Choice.reset() end
    if Message and Message.isOpen() then Message.close() end
  end
  function ui.menu(text, labels, cb)
    local Message, Choice = uiModule("message"), uiModule("choice")
    Message.show(text, { stay = true })
    Choice.multi(labels, 0, function(index)
      if Message.isOpen() then Message.close() end
      -- B comes back as 127
      cb(index ~= 127 and index or nil)
    end)
  end
  function ui.ask(text, cb)
    uiModule("message").show(text, { stay = true })
    uiModule("choice").yesNo(cb)
  end
  -- only B cancels: A is the habit for "next" on a message box, and
  -- would call off a request the partner is about to accept
  function ui.wait(text, onCancel)
    uiModule("message").show(text, { stay = true })
    waitCancel = onCancel
  end
  ui.toast = function(text) toast(text) end

  newRequests = function(role)
    return Requests.new({
      session = function() return session end, now = clock,
      firstId = role == "host" and 1 or 2, ui = ui,
      -- a follower's script waits at a scene's next fight for the leader's
      canPrompt = function()
        if fieldFree() then return true end
        local h = heldTrainer
        return h ~= nil and h.follow == true and h.event ~= nil and not activity
          and game ~= nil and game.phase == "field"
      end,
      eligible = eligible, wave = wave, start = startActivity,
    })
  end

  -- role: "host"/"join" from the CO-OP menu, else the launcher setting
  local function connect(g, role)
    disconnect()
    if not Net.available() then
      status = "CO-OP: needs LOVE's ENet (not available here)"
      return
    end
    local net = Net.new()
    role = role or setting("role")
    local port = math.floor(tonumber(setting("port")) or Net.defaultPort())
    local address = tostring(setting("address") or ""):match("^%s*(.-)%s*$")
    local ok, sameMachine
    local loopback = address:match("^localhost") ~= nil or address:match("^127%.") ~= nil
    local localPort = tonumber(address:match(":(%d+)$")) or port
    if role == "join" and loopback and net:host(localPort) then
      -- joining this same computer, and the port was free: nobody here is
      -- hosting yet (both copies read one settings file, so both say JOIN).
      -- Be the host; the other copy's join then finds us.
      ok, role, sameMachine = true, "host", "hosting"
    elseif role == "join" then
      if loopback then net = Net.new() end
      -- the host's status line shows "ip:port"; accept it pasted whole
      -- rather than appending a second port
      ok = net:join(address:match("^.-:%d+$") and address or ("%s:%d"):format(address, port))
    else
      ok = net:host(port)
      -- two copies on one computer share the launcher's settings, so both
      -- start as HOST and the second finds the port taken.  The copy
      -- already holding it is the host it wants; join that instead.
      if not ok and tostring(net.error):find("can't open UDP port", 1, true) then
        local hostError = net.error
        net = Net.new()
        ok = net:join(("127.0.0.1:%d"):format(port))
        if ok then
          role, sameMachine = "join", true
        else
          net.error = hostError
        end
      end
    end
    if not ok then
      status = "CO-OP: " .. tostring(net.error):gsub("%s+", " ")
      return
    end
    local link = Handshake.hello(g)
    local hello = Protocol.hello(link.name, GameVersion.get(), link, modsKey(g))
    session = Session.new(net, role, hello,
      { Protocol = Protocol, Presence = Presence, Ghost = Ghost, Channel = Channel,
        compat = compat, offsetOf = offsetOf })
    session.sameMachine = sameMachine
    requests = newRequests(role)
    status = nil
  end

  local function snapshot(g)
    if g.phase ~= "field" then return nil end
    local Player = engine("player")
    local Map = engine("map")
    if not (Player and Map and Map.current) then return nil end
    local OwSprites = engine("ow_sprites")
    local gfx = OwSprites and OwSprites.playerGraphicsId and OwSprites.playerGraphicsId(g) or 0
    return Presence.sample(Player, Map.current, gfx, Player.isVisible and Player.isVisible())
  end

  local STEP = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

  -- A while standing still and facing the partner opens the talk menu.  The
  -- field sees the same press first; if it opened anything (a sign, a menu),
  -- Hud.busy() is true by now and the menu stands down.
  local function tryTalk(g)
    local input = g.input
    if not (input and input.wasPressed and input:wasPressed("a")) then return end
    local Player = engine("player")
    if not Player or Player.moving then return end
    local Hud = uiModule("hud")
    if Hud and Hud.busy and Hud.busy() then return end
    local d = STEP[Player.facing]
    local gx, gy = session.ghost:screenCell(offsetOf)
    if not (d and gx) then return end
    if Player.cellX + d[1] ~= gx or Player.cellY + d[2] ~= gy then return end
    if activity or not requests then return end
    local now = clock()
    if now - lastWaveAt < 0.5 then return end
    lastWaveAt = now
    requests:talk()
  end

  local function npcsCanMove()
    if progress:busy() then return false end
    local Space, Field, Hud = engine("scripting.space"), engine("field"), uiModule("hud")
    if Space and Space.vm and Space.vm.isRunning and Space.vm:isRunning() then return false end
    if Field and Field.isLocked and Field.isLocked() then return false end
    if Hud and Hud.busy and Hud.busy() then return false end
    return true
  end

  local function localPlayerAt(x, y)
    local P = engine("player")
    if not P then return false end
    if P.cellX == x and P.cellY == y then return true end
    return P.moving == true and P.targetX == x and P.targetY == y
  end

  -- While both players are on the same map the host's wandering NPCs lead
  -- and the joiner's follow; anywhere else each game moves its own.
  local function syncNpcs()
    local O, Map = engine("objects"), engine("map")
    if not (O and O._byId and Map and Map.current) then return end
    local ghost = session.ghost
    local together = ghost.known and ghost.map == Map.current and not activity
    if session.role == "host" then
      if together then
        local list = npcs:collect(O, Map.current)
        if #list > 0 then session:sendNpcs(Map.current, list) end
      else
        npcs:forget()
      end
    else
      for _, msg in ipairs(session:takeNpcs()) do
        if together and msg.m == Map.current then npcs:receive(O, msg) end
      end
      npcs:update(O, Map.current, npcsCanMove, localPlayerAt)
    end
  end

  local function stepActivity()
    if tradeFull and not tradeFull.uninstall and session then
      local peer = session:takeTeam(tradeFull.id)
      if peer then
        local byKey = TradeFull.lookup(tradeFull.mine, peer)
        if tradeFull.act == "battle" then
          local LB = engine("link.battle")
          local okS, SummaryData = pcall(require, "src.core.game3.summary_data")
          if LB then
            tradeFull.uninstall = TradeFull.installBattle(LB, byKey,
              { Pokemon = engine("pokemon"), SummaryData = okS and SummaryData or nil })
          end
        else
          local LT = engine("link.trade")
          if LT then tradeFull.uninstall = TradeFull.install(LT, byKey) end
        end
      end
    end
    if not activity then return end
    local current = activity
    local ok, err = pcall(current.step, current)
    if not ok then
      mod.log:warn("activity failed: %s", tostring(err))
      pcall(current._end, current, nil, "error")
      if activity == current then activity = nil end
    end
  end

  -- AUTOCONNECT waits for the overworld: at the title screen no save is
  -- loaded yet, so the hello would carry no trainer name ("PLAYER")
  local autoPending = false
  -- shared trainer credit and team prizes, defined with the battle events below
  local applyCredits, settlePrize
  -- mirrored story scenes, defined with the shared wild encounters below
  local applyScenes

  local hinted = false
  local progConnected, sceneBusy = nil, false
  local function tick(g)
    -- decided on reaching the field: this player's choice lives in the save
    if autoPending and g.phase == "field" then
      autoPending = false
      if setting("autoconnect") and not session and not retryAt then
        connect(g)
      elseif not session and not hinted then
        hinted = true
        toast("Co-op: START > CO-OP to host or join.", 6)
      end
    end
    stepActivity()
    pcall(tracker.tick, tracker, g.phase == "field", activity ~= nil,
      g.phase == "field" and not activity and npcsCanMove())
    stepCaps()
    restoreText()
    if g.phase == "field" then
      local okP, errP = pcall(progress.tick, progress)
      if not okP then mod.log:warn("story events: %s", tostring(errP)) end
      -- a follower waiting at a scene's next fight whose leader is gone (or
      -- never comes): stop the scene here, leaving its event open; the
      -- leader's result plays the rest when you meet again
      local h = heldTrainer
      if h and h.follow and not activity then
        h.since = h.since or clock()
        local linked = session and session.state == "connected"
        if not linked or clock() - h.since > FOLLOW_SECONDS then
          heldTrainer = nil
          progress:unfollow()
          local Field = engine("field")
          if Field and Field.unlock then Field.unlock(WILD_LOCK) end
          if h.event then pcall(progress.leave, progress, h.event, true) end
          pcall(h.done, "cancel")
          toast("The scene stops here for now: you get the rest of it when you meet your partner again.", 7)
        end
      end
    end
    if menuPending and fieldFree() then
      menuPending = false
      coopMenu(g)
    end
    if not session and retryAt and clock() >= retryAt then
      retryAt = nil
      local keep = status
      connect(g)
      -- a joiner whose host isn't back yet fails at once; keep saying so
      if not session then
        status, retryAt = keep, clock() + RETRY_SECONDS
      end
    end
    if not session then return end
    session:tick(snapshot(g))
    if session.state == "refused" or session.state == "closed" then
      local why = session.reason
      if session.sameMachine == true and why == "network_error" then
        -- the port was taken but nothing answered on it: a dead socket,
        -- usually an older game process still holding it
        status = ("CO-OP: port %s is held by an old game process - quit the game fully, or change PORT")
          :format(tostring(session.net.target):match(":(%d+)$") or "?")
      elseif RETRY_REASONS[why] and (session.peer or setting("autoconnect")) then
        status = "CO-OP: " .. (REASONS[why] or tostring(why)) .. " - reconnecting (F8 stops)"
        retryAt = clock() + RETRY_SECONDS
      else
        status = "CO-OP: " .. (REASONS[why] or tostring(why))
          .. (session.netError and (" (" .. tostring(session.netError):gsub("%s+", " ") .. ")") or "")
          .. " - F8 to retry"
      end
      dropSession()
      return
    end
    if session.state ~= "connected" then return end
    if slConnected ~= session then
      slConnected = session
      tracker:onConnected()
    end
    for _, msg in ipairs(session:takeSoulLink()) do
      tracker:onMessage(msg, session.role == "host")
    end
    local okC, errC = pcall(applyCredits)
    if not okC then mod.log:warn("trainer credit: %s", tostring(errC)) end
    local okS, errS = pcall(applyScenes, g)
    if not okS then mod.log:warn("story scene: %s", tostring(errS)) end
    if progConnected ~= session then
      progConnected = session
      local okP, errP = pcall(progress.connected, progress)
      if not okP then mod.log:warn("story events: %s", tostring(errP)) end
    end
    for _, msg in ipairs(session:takeProgs()) do
      local okP, errP = pcall(progress.onMessage, progress, msg)
      if not okP then mod.log:warn("story event: %s", tostring(errP)) end
    end
    -- the partner sees us busy while a story scene plays here
    local scene = progress:busy()
    if not activity and scene ~= sceneBusy then session:setBusy(scene and "script" or "none") end
    sceneBusy = scene
    if waitCancel and g.input and g.input.wasPressed and g.input:wasPressed("b") then
      local cancel = waitCancel
      waitCancel = nil
      cancel()
    end
    requests:tick()
    if session.emotes ~= seenEmotes then
      seenEmotes = session.emotes
      if session.lastEmote == "wave" then
        toast(tostring(session.peer and session.peer.name or "Partner") .. " waved at you!")
      end
    end
    if g.phase == "field" then
      syncNpcs()
      tryTalk(g)
    end
  end

  -- Close the socket before the game goes away.  On Linux, returning to
  -- the launcher execv()s the process in place, and an open UDP socket
  -- survives that: the new launcher (and every game it starts) silently
  -- inherits port 7777 and never answers on it.  Every exit route
  -- (window close, quit to launcher, relaunch) runs SessionLifecycle's
  -- game:reset(), so close there; core.quit_to_launcher covers window close
  -- even if reset is skipped.  The reset wrap is installed once per process
  -- and calls whichever load of this mod is current, so reloads don't stack.
  local Game3 = require("src.core.Game3")
  if not Game3._g3coopReset then
    Game3._g3coopReset = Game3.reset
    Game3.reset = function(self, ...)
      local teardown = Game3._g3coopTeardown
      if teardown then pcall(teardown) end
      return Game3._g3coopReset(self, ...)
    end
  end
  Game3._g3coopTeardown = function()
    retryAt = nil
    npcs:release()
    disconnect("left")
    -- the engine resets its link modules along with the game
    if activity then pcall(activity._end, activity, nil, "reset") end
    activity = nil
  end

  -- The partner is appended to the list Objects.forDraw hands the field
  -- renderer.  The virtual-object layer the Union Room uses would cull a
  -- partner standing on a connected map (it only draws inside the active
  -- map), so the entry is added here instead, in the same shape.  Installed
  -- once per process, calling whichever load of this mod is current.
  local drawRec = {}
  local function partnerDrawEntry()
    if not (session and session.state == "connected" and game and game.phase == "field") then
      return nil
    end
    return session.ghost:drawInto(drawRec, offsetOf, GfxIds.spriteFor)
  end
  local Objects = require("src.core.game3.objects")
  if not Objects._g3coopForDraw then
    Objects._g3coopForDraw = Objects.forDraw
    Objects.forDraw = function(...)
      local list = Objects._g3coopForDraw(...)
      local extra = Objects._g3coopExtra
      if extra and type(list) == "table" then
        local ok, rec = pcall(extra)
        if ok and rec then list[#list + 1] = rec end
      end
      return list
    end
  end
  Objects._g3coopExtra = partnerDrawEntry

  -- NPCs walk around the partner as they walk around the player, so the
  -- host's NPCs never step onto the joiner (whose copies follow them).
  -- Objects.playerBlocks is the check the engine's idle mover makes.
  local function partnerAt(tx, ty)
    if not (session and session.state == "connected" and game and game.phase == "field") then return false end
    local ghost = session.ghost
    local ox, oy = offsetOf(ghost.map)
    if not (ghost.known and ghost.visible and ox) then return false end
    if ghost.cellX + ox == tx and ghost.cellY + oy == ty then return true end
    return ghost.moving and ghost.targetX + ox == tx and ghost.targetY + oy == ty
  end
  if not Objects._g3coopPlayerBlocks then
    Objects._g3coopPlayerBlocks = Objects.playerBlocks
    Objects.playerBlocks = function(tx, ty, ...)
      local extra = Objects._g3coopBlocks
      if extra then
        local ok, hit = pcall(extra, tx, ty)
        if ok and hit then return true end
      end
      return Objects._g3coopPlayerBlocks(tx, ty, ...)
    end
  end
  Objects._g3coopBlocks = partnerAt

  -- The surf blob under a surfing partner.  FieldEffects.drawBehind draws
  -- it for the local player only (the layer under the actors), so the
  -- partner's is drawn right after it with the same sheet and frames
  -- (pokeemerald field_effect_objects.h:203).  Installed once per process.
  local BLOB_ANIM = { down = 1, up = 2, left = 3, right = 4 }
  local BLOB_STEP = { down = 0, up = 2, left = 4, right = 4 }
  local function drawPartnerBlob(camX, camY)
    if not (session and session.state == "connected" and game and game.phase == "field") then return end
    local px, py, facing = session.ghost:surfBlob(offsetOf)
    if not px then return end
    local FieldEffects = engine("field_effects")
    local sheet = FieldEffects and FieldEffects.loadSheet and FieldEffects.loadSheet("surf_blob", 32, 32, 6)
    if not sheet then return end
    local frameIdx, flip = BLOB_STEP[facing] or 0, facing == "right"
    local blob = sheet.frames < 6 and FieldEffects.manifestObject and FieldEffects.manifestObject("surf_blob")
    if blob and blob.anims then
      local seq = blob.anims[BLOB_ANIM[facing] or 1]
      local cmd = seq and seq[1]
      frameIdx, flip = cmd and cmd[2] or 0, cmd and cmd[4] == true or false
    end
    local q = sheet.quads[frameIdx]
    if not q then return end
    local sx, sy = px - (camX or 0) - 8, py - (camY or 0) - 8
    love.graphics.setColor(1, 1, 1, 1)
    if flip then
      love.graphics.draw(sheet.image, q, sx + 32, sy, 0, -1, 1)
    else
      love.graphics.draw(sheet.image, q, sx, sy)
    end
  end
  local FieldEffects = engine("field_effects")
  if FieldEffects and FieldEffects.drawBehind and not FieldEffects._g3coopDrawBehind then
    FieldEffects._g3coopDrawBehind = FieldEffects.drawBehind
    FieldEffects.drawBehind = function(camX, camY, ...)
      local r = FieldEffects._g3coopDrawBehind(camX, camY, ...)
      local extra = FieldEffects._g3coopExtra
      if extra then pcall(extra, camX, camY) end
      return r
    end
  end
  if FieldEffects then FieldEffects._g3coopExtra = drawPartnerBlob end

  mod.hooks:wrap("core.quit_to_launcher", function(next)
    disconnect("left")
    return next()
  end)

  mod.events:on("game.ready", function(ev)
    game = ev and ev.game
    if game and not session then autoPending = true end
  end)

  mod.hooks:wrap("input.step", function(next, g, dt)
    next(g, dt)
    game = g
    local ok, err = pcall(tick, g)
    if not ok then
      mod.log:warn("tick failed: %s", tostring(err))
      disconnect("error")
      status = "CO-OP: error, see log - F8 to retry"
    end
  end)

  -- While the Soul Link panel is open it takes the keys and buttons: up
  -- and down scroll, F7 / B / Esc close.  Releases still reach the game,
  -- so a direction held when it opened doesn't stick.
  local PANEL_CLOSE = { escape = true, x = true, z = true, backspace = true, ["return"] = true }
  local PANEL_SCROLL = { up = -1, down = 1, pageup = -5, pagedown = 5 }
  local PAD_SCROLL = { dpup = -1, dpdown = 1, leftshoulder = -5, rightshoulder = 5 }
  local PAD_CLOSE = { a = true, b = true, start = true, back = true }
  local function scrollPanel(by)
    if hud then hud.scroll = math.max(0, math.min((hud.scroll or 0) + by, panelMax or 0)) end
  end
  local function openPanel(open)
    slPanel = open
    if hud then hud.scroll = 0 end
  end

  -- The panel's tabs (Hud.TABS) and its RULES tab: this player's Soul Link
  -- settings, saved at once (slSettings).  Once linked, the host's rules
  -- apply to both, so a guest's rule rows are shown but locked.
  local slui = { tab = 1, sel = 1 }
  slui.RULE_ROWS = {
    { "soullink", "SOUL LINK", nil, "track this save's run" },
    { "sl_dupes", "DUPES CLAUSE", "dupes" }, { "sl_shiny", "SHINY CLAUSE", "shiny" },
    { "sl_gift", "GIFTS COUNT", "gift" }, { "sl_static", "STATICS COUNT", "static" },
    { "sl_enforce", "ENFORCE CATCH LIMITS", "enforce", "balls refused" },
    { "sl_hard", "HARD RULES", "hard", "the dead stay dead" },
    { "sl_caps", "LEVEL CAPS", "caps", "next big fight's ace" },
    { "show_next", "SHOW NEXT FIGHT", nil, "on the field" },
  }
  function slui.showNext()
    local v = slSettings().show_next
    if v == nil then return true end
    return v == true
  end
  function slui.rulesLocked()
    local run = tracker.run
    return slOpt("soullink") and run and run.partner and run.ruler and run.ruler ~= tracker.tid or false
  end
  function slui.rulesRows()
    local locked = slui.rulesLocked()
    local inForce = locked and tracker:rules() or {}
    local out = {}
    for _, r in ipairs(slui.RULE_ROWS) do
      local lock = locked and r[3] ~= nil
      local on
      if r[1] == "show_next" then on = slui.showNext()
      elseif lock then on = inForce[r[3]] == true
      else on = slOpt(r[1]) end
      out[#out + 1] = { key = r[1], label = r[2], on = on, locked = lock, note = r[4] }
    end
    return out
  end
  function slui.panelData()
    if not (slOpt("soullink") and tracker.run) then return nil end
    local ok, data = pcall(tracker.panel, tracker)
    return ok and data or nil
  end
  function slui.panelTabName()
    if not slui.panelData() then return "RULES" end
    return Hud.TABS[slui.tab]
  end
  slui.PANEL_TAB = { left = -1, right = 1, dpleft = -1, dpright = 1 }
  slui.PANEL_PICK = { z = true, ["return"] = true, kpenter = true, a = true }
  -- key: a key or button name; scroll: its scroll step; close: closes
  function slui.panelInput(key, scroll, close)
    if slui.PANEL_TAB[key] then
      slui.tab = (slui.tab - 1 + slui.PANEL_TAB[key]) % #Hud.TABS + 1
      if hud then hud.scroll = 0 end
      return
    end
    if slui.panelTabName() == "RULES" then
      local rows = slui.rulesRows()
      if scroll then
        slui.sel = math.max(1, math.min(#rows, slui.sel + (scroll > 0 and 1 or -1)))
        return
      end
      if slui.PANEL_PICK[key] then
        local row = rows[slui.sel]
        if not row then return end
        if row.locked then
          toast("Linked: the host's rules apply to both of you.", 4)
        else
          setSlOpt(row.key, not row.on)
          capAt = -1
        end
        return
      end
    end
    if scroll then scrollPanel(scroll) elseif close then openPanel(false) end
  end

  -- A team battle paused because the partner dropped (dev.21 engine): the
  -- battle stands still under this choice until one is picked.  Nothing can
  -- bring the partner back into this battle (COOP.md), so there is no
  -- "keep waiting": continue alone, or end it as a draw.
  local pausePanel = nil
  local PAUSE_OPTIONS = { "CONTINUE ALONE", "END THE BATTLE" }
  local PAUSE_MOVE = { up = -1, down = 1, left = -1, right = 1, dpup = -1, dpdown = 1, dpleft = -1, dpright = 1 }
  local PAUSE_PICK = { ["return"] = true, kpenter = true, z = true, a = true }
  local function pausePick()
    local p = pausePanel
    pausePanel = nil
    local Battle = engine("battle")
    if not (p and Battle) then return end
    if p.sel == 1 then
      local ok, accepted, why = pcall(Battle.coopContinueSolo)
      if ok and accepted then
        toast("Continuing alone: your team takes both places.", 5)
      else
        mod.log:warn("continue alone refused: %s", tostring(why or accepted))
        pcall(Battle.abort, "draw")
      end
    else
      pcall(Battle.abort, "draw")
    end
  end
  local function pauseInput(key)
    if not pausePanel then return false end
    if PAUSE_MOVE[key] then
      pausePanel.sel = ((pausePanel.sel - 1 + PAUSE_MOVE[key]) % #PAUSE_OPTIONS) + 1
    elseif PAUSE_PICK[key] then
      pausePick()
    end
    return true
  end
  mod.events:on("battle.coop_paused", function(ev)
    if not (activity and activity.kind == "team") then return end
    if teamState then teamState.dropped = true end
    if heldTrainer then heldTrainer.dropped = true end
    pausePanel = { sel = 1, name = (session and session.peer and session.peer.name)
      or (teamState and teamState.peerName) or "Your partner" }
  end)
  mod.events:on("battle.coop_solo", function()
    if teamState then teamState.solo = true end
  end)

  -- CO-OP > ADDRESS (lib/connedit.lua): while it's open it takes every key
  -- and button, and the field is held still
  local editor = nil
  local EDIT_LOCK = "g3coop_edit"
  local EDIT_KEYS = {
    left = "left", right = "right", up = "up", down = "down",
    pageup = "up10", pagedown = "down10", backspace = "back",
    ["return"] = "confirm", kpenter = "confirm", z = "confirm",
    escape = "cancel", x = "cancel",
  }
  local EDIT_PAD = {
    dpleft = "left", dpright = "right", dpup = "up", dpdown = "down",
    rightshoulder = "up10", leftshoulder = "down10", a = "confirm", b = "cancel", back = "cancel",
  }
  openEditor = function()
    local c = connStored() or {}
    local onload = c.onload
    if not onload then
      onload = setting("autoconnect") and (setting("role") == "join" and "JOIN" or "HOST") or "OFF"
    end
    editor = ConnEdit.new({ address = setting("address"), port = setting("port"), onload = onload })
    local Field = engine("field")
    if Field and Field.lock then Field.lock(EDIT_LOCK) end
  end
  local function closeEditor(save)
    local ed = editor
    editor = nil
    local Field = engine("field")
    if Field and Field.unlock then Field.unlock(EDIT_LOCK) end
    if not (save and ed) then return end
    local r = ed:result()
    local c = connStored() or {}
    c.address, c.port, c.onload = r.address, r.port, r.onload
    if r.onload ~= "OFF" then c.role = r.onload:lower() end
    connWrite(c)
    toast(("Co-op: saved %s:%d%s."):format(r.address, r.port,
      r.onload == "OFF" and "" or (", " .. r.onload:lower() .. " on load")), 5)
  end
  local function editorKey(key)
    if not (editor and key) then return end
    local what = editor:press(key)
    if what == "save" then closeEditor(true) elseif what == "cancel" then closeEditor(false) end
  end

  mod.hooks:wrap("input.key", function(next, g, ev)
    if pausePanel and ev then
      if ev.phase == "pressed" then pauseInput(ev.key) end
      return true
    end
    if editor and ev then
      if ev.phase == "pressed" then
        local k = ev.key
        local digit = type(k) == "string" and (k:match("^(%d)$") or k:match("^kp(%d)$"))
        editorKey(digit or EDIT_KEYS[k])
      end
      return true
    end
    if ev and ev.phase == "pressed" and ev.key == "f7" then
      openPanel(not slPanel)
      return true
    end
    if slPanel and ev and ev.phase == "pressed" and ev.key ~= "f8" then
      slui.panelInput(ev.key, PANEL_SCROLL[ev.key], PANEL_CLOSE[ev.key])
      return true
    end
    if ev and ev.phase == "pressed" and ev.key == "f8" then
      if retryAt and not session then
        retryAt = nil
        status = "CO-OP: stopped reconnecting - F8 to connect"
        return true
      end
      retryAt = nil
      if session then
        -- "stopped", not "left": the partner shouldn't keep redialing
        disconnect("stopped")
        status = "CO-OP: disconnected - F8 to connect"
      else
        connect(g or game)
      end
      return true
    end
    return next(g, ev)
  end)

  mod.hooks:wrap("input.gamepad", function(next, g, ev)
    if pausePanel and ev then
      if ev.phase == "pressed" then pauseInput(ev.button) end
      return true
    end
    if editor and ev then
      if ev.phase == "pressed" then editorKey(EDIT_PAD[ev.button]) end
      return true
    end
    if slPanel and ev and ev.phase == "pressed" then
      slui.panelInput(ev.button, PAD_SCROLL[ev.button], PAD_CLOSE[ev.button])
      return true
    end
    return next(g, ev)
  end)

  mod.hooks:wrap("input.wheel", function(next, g, dy)
    if slPanel then
      scrollPanel((tonumber(dy) or 0) > 0 and -1 or 1)
      return true
    end
    return next(g, dy)
  end)

  -- ------------------------------------------------------- START > CO-OP

  coopMenu = function(g)
    local addr = tostring(setting("address") or ""):match("^%s*(.-)%s*$")
    local port = math.floor(tonumber(setting("port")) or Net.defaultPort())
    if not addr:match(":%d+$") then addr = addr .. ":" .. port end
    local s = session
    if s and s.state == "connected" then
      local name = tostring(s.peer and s.peer.name or "your partner")
      ui.menu("Playing with " .. name .. ".", { "LEAVE", "SOUL LINK", "CANCEL" }, function(i)
        if i == 0 then
          ui.ask("Stop playing with " .. name .. "?", function(yes)
            if yes then
              retryAt = nil
              disconnect("stopped")
              status = "CO-OP: disconnected"
            end
          end)
        elseif i == 1 then
          openPanel(true)
        end
      end)
    elseif s or retryAt then
      local what = (s and s.role == "host" and s.state == "waiting") and "Waiting for your partner."
        or "Connecting..."
      ui.menu(what, { "STOP", "SOUL LINK", "CANCEL" }, function(i)
        if i == 0 then
          retryAt = nil
          disconnect("left")
          status = nil
        elseif i == 1 then
          openPanel(true)
        end
      end)
    else
      ui.menu("HOST a game here, or JOIN\n" .. addr .. "?", { "HOST", "JOIN", "ADDRESS", "SOUL LINK", "CANCEL" },
        function(i)
          if i == 0 or i == 1 then
            retryAt = nil
            local role = i == 0 and "host" or "join"
            -- remembered, so CONNECT ON LOAD and reconnects know which
            local c = connStored() or {}
            c.role = role
            connWrite(c)
            connect(g or game, role)
          elseif i == 2 then
            openEditor()
          elseif i == 3 then
            openPanel(true)
          end
        end)
    end
  end

  mod.hooks:wrap("ui.start_menu.items", function(next, g, items)
    local out = next(g, items)
    if type(out) ~= "table" then return out end
    local copy, at = {}, nil
    for i, e in ipairs(out) do
      copy[i] = e
      if type(e) == "table" and e.id == "save" and not at then at = i end
    end
    table.insert(copy, at or math.max(1, #copy), {
      id = "g3_coop", label = "CO-OP",
      onSelect = function()
        local StartMenu = uiModule("start_menu")
        if StartMenu and StartMenu.close then StartMenu.close(true) end
        -- opened from the field on the next free tick, once the start
        -- menu's window is gone
        menuPending = true
      end,
    })
    return copy
  end)

  -- Scripted wild battles (legendaries, Kecleon, Voltorb...) come in
  -- through the script adapter's startWildBattle, which always passes a
  -- done callback; grass, water, fishing and rock smash call startWild
  -- without one.  That is how Soul Link tells a static from a wild.
  local Bridge = engine("battle_bridge")
  if Bridge and Bridge.startWild and not Bridge._g3coopStartWild then
    Bridge._g3coopStartWild = Bridge.startWild
    Bridge.startWild = function(m, g, enc, opts)
      -- an ordinary step in the grass may become a shared wild double
      -- (_g3coopShare, below, decides and takes it over)
      local stepped = Bridge._g3coopStep
      Bridge._g3coopStep = nil
      if stepped and Bridge._g3coopShare then
        local ok, took = pcall(Bridge._g3coopShare, m, g, enc, opts)
        if ok and took then return true end
      end
      Bridge._g3coopHow = (type(opts) == "table" and opts.done) and "static" or "wild"
      return Bridge._g3coopStartWild(m, g, enc, opts)
    end
  end
  -- trainer battles a script starts (_g3coopTrainer, with the joint-fight
  -- gate, decides); co-op's own link battles and wild battles pass through
  if Bridge and Bridge.start and not Bridge._g3coopStart then
    Bridge._g3coopStart = Bridge.start
    Bridge.start = function(m, g, foe, opts)
      -- the campaign cart may add a tag partner (second trainer) first, so
      -- the joint fight is planned with both trainers
      if type(opts) == "table" and not opts.link and not opts.wild and opts.trainerId
          and type(Bridge.campaignTrainerOpts) == "function" then
        pcall(Bridge.campaignTrainerOpts, opts)
      end
      if type(opts) == "table" and not opts.link and not opts.wild and opts.trainerId
          and Bridge._g3coopTrainer then
        local ok, took = pcall(Bridge._g3coopTrainer, m, g, foe, opts)
        if ok and took then return true end
      end
      return Bridge._g3coopStart(m, g, foe, opts)
    end
  end
  -- which encounters came from a step: Sweet Scent, Rock Smash, fishing and
  -- scripted battles call startWild too, and stay solo
  local Encounters = engine("encounters")
  if Encounters and Encounters.onStep and not Encounters._g3coopOnStep then
    Encounters._g3coopOnStep = Encounters.onStep
    Encounters.onStep = function(...)
      local enc = Encounters._g3coopOnStep(...)
      if enc and Bridge then Bridge._g3coopStep = true end
      return enc
    end
  end

  -- The addendum's shared wild encounters: a step encounter with the partner
  -- on the same map, free, asks them to join.  Yes: both games enter a wild
  -- double the host rolls on that map.  No, no answer in time, B, or a
  -- dropped connection: the encounter that was found plays out alone.
  -- Surfing stays solo (the shared double rolls the land table).
  local function partnerHere()
    local s, gs = session, gameSession()
    if not (s and s.state == "connected" and not s:stale() and gs) then return false end
    if s.peerBusy ~= "none" then return false end
    local ghost = s.ghost
    return ghost and ghost.known and ghost.visible and ghost.map == gs.map
  end

  -- Story scenes both players watch together (the 2026-10-22 request: the
  -- Wally catching tutorial). When one player starts a listed scene with the
  -- partner on the same map and free, the partner's game runs the same
  -- script from the starter's spot, so neither has to start it again. Each
  -- game plays it against its own story; a game that has already seen it, is
  -- elsewhere, or is busy simply doesn't join. Emerald only.
  local SCENES = {
    -- Norman before the first badge: Wally arrives and the tutorial follows
    PetalburgCity_Gym_EventScript_Norman = { map = "EM_PETALBURG_CITY_GYM",
      wants = function(var) return var("VAR_PETALBURG_GYM_STATE") < 2 end },
  }
  local DIRS = { down = 1, up = 2, left = 3, right = 4 }
  local DIR_NAMES = { "down", "up", "left", "right" }
  local mirroring = false
  local function sceneVar(name)
    local C = require("src.core.game3.constants").of("emerald")
    local id = C.vars and C.vars.byName and C.vars.byName[name]
    local Space, Flags = engine("scripting.space"), engine("scripting.flags")
    if not (id and Space and Space.store and Flags) then return math.huge end
    return tonumber(Flags.getVar(Space.store, nil, id)) or 0
  end
  -- script keys are ROM addresses ("g3:082049f1"); the bundle's labels
  -- table names them
  local scenesByKey
  local function sceneFor(key)
    if not scenesByKey then
      local Space = engine("scripting.space")
      local bundle = Space and Space.ensureBundle and Space.ensureBundle()
      local labels = bundle and bundle.labels
      if not labels then return nil end
      scenesByKey = {}
      for label, scene in pairs(SCENES) do
        if labels[label] then scenesByKey[labels[label]] = scene end
      end
    end
    return scenesByKey[key] or SCENES[key]
  end
  local function sceneWanted(key, map)
    local scene = sceneFor(key)
    if not scene or GameVersion.get() ~= "emerald" then return false end
    if map and scene.map ~= map then return false end
    local ok, yes = pcall(scene.wants, sceneVar)
    return ok and yes == true
  end
  local Vm = engine("scripting.vm")
  if Vm and Vm.startTalk and not Vm._g3coopStartTalk then
    Vm._g3coopStartTalk = Vm.startTalk
    Vm.startTalk = function(vm, key, localId, facing, ...)
      local wanted = not mirroring and sceneWanted(key)
      local started = Vm._g3coopStartTalk(vm, key, localId, facing, ...)
      if wanted and started and partnerHere() then
        local gs, Player = gameSession(), engine("player")
        local f = tonumber(facing) or DIRS[Player and Player.facing] or 1
        session:sendScene(key, gs.map, Player and Player.cellX or gs.x, Player and Player.cellY or gs.y, f, localId)
      end
      return started
    end
  end
  applyScenes = function(g)
    if not (session and session.state == "connected") then return end
    local scenes = session:takeScenes()
    if #scenes == 0 then return end
    local gs = gameSession()
    local Space, Battle, Player = engine("scripting.space"), engine("battle"), engine("player")
    for _, msg in ipairs(scenes) do
      local free = gs and g and g.phase == "field" and not activity and Space and Space.vm
        and not Space.vm:isRunning() and not (Battle and Battle.isActive and Battle.isActive())
      if free and gs.map == msg.map and sceneWanted(msg.key, msg.map) then
        toast(("Joining %s for this scene..."):format(tostring(session.peer and session.peer.name or "your partner")), 4)
        if Player and Player.reset then Player.reset(msg.x, msg.y, DIR_NAMES[msg.facing]) end
        mirroring = true
        local ok, err = pcall(Space.startScript, msg.key, msg.localId ~= 0 and msg.localId or nil, msg.facing)
        mirroring = false
        if not ok then mod.log:warn("story scene: %s", tostring(err)) end
        return
      end
    end
  end
  if Bridge then
    Bridge._g3coopShare = function(m, g, enc, opts)
      local gs = gameSession()
      if activity or not requests or requests.outgoing or requests.busy then return false end
      if type(opts) == "table" and (opts.done or opts.wildScripted or opts.legendary) then return false end
      if not (game and game.phase == "field") or (gs and gs.surfing) or not partnerHere() then return false end
      local Field = engine("field")
      if Field and Field.lock then Field.lock(WILD_LOCK) end
      local alone = function()
        if Field and Field.unlock then Field.unlock(WILD_LOCK) end
        Bridge.startWild(m, g, enc, opts)
      end
      if not requests:request("wild", alone) then
        if Field and Field.unlock then Field.unlock(WILD_LOCK) end
        return false
      end
      toast("Wild POKeMON! Asking " .. tostring(session.peer and session.peer.name or "your partner") .. " to join...", 4)
      return true
    end
  end

  mod.events:on("battle.started", function(ev)
    if session then session:setBusy("battle") end
    local how = Bridge and Bridge._g3coopHow or "wild"
    if Bridge then Bridge._g3coopHow = nil end
    -- a co-op link battle is never an encounter; a team battle's faints
    -- are real, and a shared wild double is each player's own encounter
    -- a link battle without a team activity is a versus battle, even when
    -- this game didn't open the activity: never encounters or faints
    local st = ev and ev.battle
    if Bridge and Bridge._campaignPractice then
      -- the campaign's MOVE ANIMS practice battle: no encounter, no faints
      ev = { kind = "link" }
    elseif activity and activity.kind == "team" then
      ev = { kind = (teamState and teamState.wild) and "coopwild" or "coopteam", battle = ev and ev.battle }
    elseif activity or (type(st) == "table" and st.link and not st.coopTeam) then
      ev = { kind = "link" }
    end
    local ok, err = pcall(tracker.onBattleStarted, tracker, ev, how)
    if not ok then mod.log:warn("soul link: %s", tostring(err)) end
  end)
  mod.events:on("pokemon.caught", function(ev)
    local ok, err = pcall(tracker.onCaught, tracker, ev)
    if not ok then mod.log:warn("soul link: %s", tostring(err)) end
  end)
  mod.events:on("battle.fainted", function(ev)
    -- the three-faint limit in a team battle; both games see the same
    -- faints in the same order, so both mark the same owner out
    if teamState and activity and activity.kind == "team" then
      local okF, out = pcall(TeamBattle.onFainted, teamState.faints, ev)
      if okF and out then
        local s = session
        local mine = s and ((s.role == "host") == (tonumber(ev.battlerId) == 0))
        toast(mine and "That's three faints: you're out of this battle."
          or ((s and s.peer and s.peer.name or "Your partner") .. " is out of this battle (three faints)."), 5)
      end
    end
    local ok, err = pcall(tracker.onFainted, tracker, ev)
    if not ok then mod.log:warn("soul link: %s", tostring(err)) end
  end)
  -- ---------------------------------------------- shared trainer credit

  local credit = Credit.new({
    read = function()
      if not game then return nil end
      local ok, v = pcall(mod.storage.read, mod.storage, game, "credits")
      return ok and type(v) == "table" and v or nil
    end,
    write = function(v) if game then pcall(mod.storage.write, mod.storage, game, "credits", v) end end,
  })
  -- joint fights this game won with or for the partner (team battles, and
  -- story fights finished alone after a drop): these count for both even
  -- though they're story trainers
  local joint = Credit.new({
    read = function()
      if not game then return nil end
      local ok, v = pcall(mod.storage.read, mod.storage, game, "joint_wins")
      return ok and type(v) == "table" and v or nil
    end,
    write = function(v) if game then pcall(mod.storage.write, mod.storage, game, "joint_wins", v) end end,
  })
  local creditSentTo = nil

  -- Team-battle prizes, paid once per trainer: the receipts live in the save
  -- itself (session.modData), so money and receipts are saved -- or lost to a
  -- reload -- together.  A fight the partner finished after we dropped
  -- (joint credit) is paid here when it arrives.
  settlePrize = function(ids, multiplier)
    local gs = gameSession()
    if not gs then return 0 end
    gs.modData = type(gs.modData) == "table" and gs.modData or {}
    local mine = type(gs.modData.g3_coop) == "table" and gs.modData.g3_coop or {}
    gs.modData.g3_coop = mine
    mine.prizes = type(mine.prizes) == "table" and mine.prizes or {}
    local got = TeamBattle.settlePrize(teamEngine(), gs, ids, mine.prizes, multiplier)
    return got
  end

  local function trainerInfo(id)
    local Trainers = engine("scripting.trainers")
    local ok, info = pcall(Trainers.info, id)
    return ok and type(info) == "table" and info or {}
  end

  -- a joint fight (rival, gym, story) is never credited; a cart's mod may
  -- say which trainers those are (mod.exports.coopStoryTrainer(id) -> bool)
  local function storyTrainer(id)
    -- the port's list, as its engine holds it (also before a game exists)
    local P = engine("coop_progress")
    if P and type(P.story) == "function" then
      local ok, r = pcall(P.story, id)
      if ok and type(r) == "boolean" then return r end
    end
    for mid, ex in pairs(game and game.mods and game.mods.exports or {}) do
      if mid ~= "g3_coop" and type(ex) == "table" and type(ex.coopStoryTrainer) == "function" then
        local ok, r = pcall(ex.coopStoryTrainer, id)
        if ok and type(r) == "boolean" then return r end
      end
    end
    return Credit.isStoryClass(trainerInfo(id).className)
  end

  local function trainerBeaten(id, set)
    local Space, Flags = engine("scripting.space"), engine("scripting.flags")
    if not (Space and Space.store and Flags) then return nil end
    local ctx = Space.vm and Space.vm.ctx
    if set then pcall(Flags.setFlag, Space.store, ctx, Flags.trainerFlagId(id), true) end
    local ok, v = pcall(Flags.getFlag, Space.store, ctx, Flags.trainerFlagId(id))
    return ok and v == true
  end

  -- a solo win against an ordinary trainer: ours, and the partner's
  local function creditWin(st)
    if type(st) ~= "table" or st.wild or st.link then return end
    local fresh = {}
    for _, id in ipairs({ tonumber(st.trainerId), tonumber(st.trainerIdB) }) do
      if id and not storyTrainer(id) and credit:add(id) then fresh[#fresh + 1] = id end
    end
    if #fresh > 0 and session then session:sendCredit(fresh, true) end
  end

  -- the partner's credits: set the flags this game is missing
  applyCredits = function()
    if not (session and gameSession()) then return end
    for _, msg in ipairs(session:takeCredits()) do
      for _, id in ipairs(msg.ids) do
        if msg.joint or not storyTrainer(id) then
          local had = trainerBeaten(id)
          -- a story fight's win arrives as its shared event (lib/progress.lua),
          -- which sets the flag along with the badge and the rest
          local viaEvent = msg.joint and progress:api() ~= nil and storyTrainer(id)
          if had == false and not viaEvent then
            trainerBeaten(id, true)
            if msg.joint then
              local info = trainerInfo(id)
              toast(("%s finished the fight with %s %s: it counts for you too."):format(
                tostring(session.peer and session.peer.name or "Your partner"),
                tostring(info.className or "TRAINER"), tostring(info.name or "")), 6)
            elseif msg.fresh then
              local info = trainerInfo(id)
              toast(("%s beat %s %s: it counts for you too."):format(
                tostring(session.peer and session.peer.name or "Your partner"),
                tostring(info.className or "TRAINER"), tostring(info.name or "")), 5)
            end
          end
          if had ~= nil then (msg.joint and joint or credit):add(id) end
          -- still in our own team battle against them: battle.ended pays
          local fighting = false
          if activity and activity.kind == "team" and teamState then
            for _, f in ipairs(teamState.foes or {}) do
              if tonumber(f.trainerId) == id then fighting = true end
            end
          end
          if msg.joint and had ~= nil and not fighting then
            local okP, got = pcall(settlePrize, { id })
            if okP and (tonumber(got) or 0) > 0 then
              toast(("You got $%d for the fight %s finished."):format(got,
                tostring(session.peer and session.peer.name or "your partner")), 5)
            end
          end
        end
      end
    end
    -- on each new connection the whole list goes across once
    if creditSentTo ~= session and session.state == "connected" then
      creditSentTo = session
      for _, ids in ipairs(credit:chunks(Protocol.MAX_CREDIT_IDS)) do session:sendCredit(ids, false) end
      for _, ids in ipairs(joint:chunks(Protocol.MAX_CREDIT_IDS)) do session:sendCredit(ids, false, true) end
    end
  end

  -- ------------------------------------------- trainer fights together

  -- The port's plan for a trainer fight (COOP.md "Campaign exports"): one
  -- trainer commanding both positions, or an event's explicit pair.
  local function trainerPlan(id, second)
    for mid, ex in pairs(game and game.mods and game.mods.exports or {}) do
      if mid ~= "g3_coop" and type(ex) == "table" and type(ex.coopTrainerPlan) == "function" then
        local ok, plan = pcall(ex.coopTrainerPlan, id, second)
        if ok and type(plan) == "table" and type(plan.trainerIds) == "table" then return plan end
      end
    end
    return { trainerIds = second and { id, second } or { id },
             story = storyTrainer(id) or (second ~= nil and storyTrainer(second)) }
  end

  local function partnerCanJoin()
    return partnerHere() and not activity and not heldTrainer and not progress:busy()
      and not (requests and (requests.outgoing or requests.busy))
  end
  -- co-op is on: connected, hosting or joining, or reconnecting after a
  -- drop.  Story fights only wait for the partner then; with co-op off the
  -- game plays solo (user, 2026-10-25), Soul Link run or not.
  local function coopActive()
    if retryAt then return true end
    return session ~= nil and session.state ~= "refused" and session.state ~= "closed"
  end

  -- The joint-fight gate (user, 2026-10-21): a rival, gym or story fight
  -- doesn't start unless the partner can be in it, offline included.  The
  -- engine asks before any approach or cutscene and shows our text in a box
  -- the player can dismiss and walk away from.
  mod.hooks:wrap("trainer.joint_gate", function(next, trainerId, kind, context)
    local base = next(trainerId, kind, context)
    if type(base) == "table" and base.action == "wait" then return base end
    local story = false
    local ids = { trainerId }
    for _, id in ipairs(type(context) == "table" and type(context.trainers) == "table" and context.trainers or {}) do
      ids[#ids + 1] = id
    end
    for _, id in ipairs(ids) do
      if tonumber(id) and storyTrainer(tonumber(id)) then story = true end
    end
    if not story or not coopActive() or partnerCanJoin() then return base or { action = "allow" } end
    local name = session and session.peer and session.peer.name
    return { action = "wait", text = (name
      and ("This fight is for both of you.\nWait for " .. tostring(name) .. " to be here.")
      or "This fight is for both of you.\nPlease wait for your partner.")
      .. "\nTo fight alone, stop co-op in\nSTART > CO-OP." }
  end)

  -- A trainer battle the script is about to start becomes a team battle
  -- when the partner is here: a story fight pulls them in (they were
  -- checked at the gate), an ordinary one asks them first and runs solo on
  -- a no.  The script waits (heldTrainer) and gets the team battle's result.
  -- A story fight first has both games prepare its shared event (the
  -- port's continuation), so the partner's game plays the same post-battle
  -- script; one the port can't share yet is fought alone.
  local CALLED_OFF_WORD
  -- A later fight of a scene with several (the Museum, the Space Center):
  -- lib/progress.lua "chain".  The player who started the scene leads; the
  -- other's replay waits here for them.  Returns what the bridge hook does.
  local function chainedFight(m, g, foe, opts, tid, plan)
    local Field = engine("field")
    local name = tostring(session and session.peer and session.peer.name or "your partner")
    local function solo(why)
      -- the scene began together: this fight's win counts for both
      heldTrainer = nil
      if Field and Field.unlock then Field.unlock(WILD_LOCK) end
      toast(("%s isn't here for this fight (%s): you fight it, and %s gets the result."):format(name, tostring(why), name), 6)
      return false
    end
    if not progress:own(opts.coopChain) then
      -- follower: hold the script until the leader's fight (or its result)
      if Field and Field.lock then Field.lock(WILD_LOCK) end
      heldTrainer = { done = opts.done, noWhiteout = opts.noWhiteout, cancel = true, follow = true,
                      event = opts.coopBound }
      progress:follow(opts.coopChain, tid, opts.coopBound, function(id)
        if heldTrainer and heldTrainer.follow then heldTrainer.event = id end
      end)
      toast("Waiting for " .. name .. " to start the next fight...", 5)
      return true
    end
    local connected = session and session.state == "connected" and not session:stale()
    if not connected then
      local id, why = progress:solo(opts.coopContinuation)
      if not id then mod.log:warn("chained event: %s", tostring(why)) end
      if not coopActive() then
        heldTrainer = nil
        return false
      end
      return solo("not connected")
    end
    if Field and Field.lock then Field.lock(WILD_LOCK) end
    heldTrainer = { done = opts.done, noWhiteout = opts.noWhiteout, cancel = true }
    local function fightAlone(why)
      if not heldTrainer then return end
      heldTrainer = nil
      if Field and Field.unlock then Field.unlock(WILD_LOCK) end
      toast(("%s isn't here for this fight (%s): you fight it, and %s gets the result."):format(name, tostring(why), name), 6)
      Bridge._g3coopStart(m, g, foe, opts)
    end
    local id, why = progress:begin(opts.coopContinuation, function()
      if not heldTrainer then return end
      if not requests:request("joint", function() fightAlone("no answer") end, plan.trainerIds) then
        fightAlone("busy")
      end
    end, function(w) fightAlone(CALLED_OFF_WORD(w)) end)
    if not id then
      mod.log:warn("chained event for trainer %d: %s", tid, tostring(why))
      progress:solo(opts.coopContinuation)
      return solo(tostring(why))
    end
    heldTrainer.event = id
    toast("Waiting for " .. name .. " for the next fight...", 5)
    return true
  end

  local CALLED_OFF = {
    no_reply = "no answer", busy = "partner busy", no_api = "partner's game can't share it",
  }
  CALLED_OFF_WORD = function(why) return CALLED_OFF[why] or tostring(why) end
  if Bridge then
    Bridge._g3coopTrainer = function(m, g, foe, opts)
      local tid = tonumber(opts.trainerId)
      if not tid or opts.firstBattle or opts.trainerTower or opts.eReader or opts.secretBase then return false end
      if not (game and game.phase == "field") then return false end
      local plan = trainerPlan(tid, tonumber(opts.trainerIdB))
      local story = plan.story == true
      local shared = story and progress:api() ~= nil
      local cancel = progress:api() and "cancel" or "lose"
      if shared and opts.coopChain and type(opts.coopContinuation) == "table" then
        return chainedFight(m, g, foe, opts, tid, plan)
      end
      if not partnerCanJoin() then
        if not story or not coopActive() then return false end
        -- the gate let it through, but the partner is gone since
        toast("Your partner isn't here any more: this fight waits for both of you.", 6)
        pcall(opts.done, cancel)
        return true
      end
      if shared and type(opts.coopContinuation) ~= "table" then
        -- story fights are never fought alone (porting/DESIGN.md): one
        -- whose scene the port can't share yet waits for a later port
        local info = trainerInfo(tid)
        toast(("%s %s's scene can't be shared yet (%s). Story fights need both of you, so this one waits for an update."):format(
          tostring(info.className or "TRAINER"), tostring(info.name or ""),
          tostring(opts.coopContinuationError or "not supported")), 8)
        mod.log:warn("story trainer %d not shared: %s", tid, tostring(opts.coopContinuationError or "no continuation"))
        pcall(opts.done, cancel)
        return true
      end
      local Field = engine("field")
      if Field and Field.lock then Field.lock(WILD_LOCK) end
      heldTrainer = { done = opts.done, noWhiteout = opts.noWhiteout, cancel = cancel == "cancel" }
      local alone = function()
        if story then
          toast("The fight is called off: it needs both of you.", 6)
          releaseHeld("cancel")
        else
          heldTrainer = nil
          if Field and Field.unlock then Field.unlock(WILD_LOCK) end
          Bridge._g3coopStart(m, g, foe, opts)
        end
      end
      local name = tostring(session.peer and session.peer.name or "your partner")
      local function ask()
        if requests:request(story and "joint" or "trainer", alone, plan.trainerIds) then return true end
        if story then releaseHeld("cancel") return true end
        heldTrainer = nil
        if Field and Field.unlock then Field.unlock(WILD_LOCK) end
        return false
      end
      if shared then
        local id, why = progress:begin(opts.coopContinuation, function()
          if heldTrainer and heldTrainer.event then ask() end
        end, function(why)
          toast("The fight is called off (" .. tostring(CALLED_OFF[why] or why) .. ").", 6)
          releaseHeld("cancel")
        end)
        if not id then
          mod.log:warn("story event for trainer %d: %s", tid, tostring(why))
          toast("The fight can't be shared (" .. tostring(CALLED_OFF[why] or why) .. ").", 6)
          releaseHeld("cancel")
          return true
        end
        heldTrainer.event = id
        toast("Starting the fight with " .. name .. "...", 4)
        return true
      end
      if not ask() then return false end
      toast(story and ("Starting the fight with " .. name .. "...") or ("Asking " .. name .. " to join the fight..."), 4)
      return true
    end
  end

  mod.events:on("coop.progress", function(ev)
    local ok, err = pcall(progress.onStatus, progress, ev)
    if not ok then mod.log:warn("story event: %s", tostring(err)) end
  end)

  mod.events:on("battle.ended", function(ev)
    if not activity and ev and ev.result == "win" then
      local ok, err = pcall(creditWin, ev.battle)
      if not ok then mod.log:warn("trainer credit: %s", tostring(err)) end
    end
    -- a team battle writes the battle's result back to this player's own
    -- mons (a cable battle never does) and counts both trainers as beaten
    if teamState and activity and activity.kind == "team" and not teamState.written then
      local E, gs = teamEngine(), gameSession()
      local ok, n = pcall(TeamBattle.writeback, E, gs, ev and ev.battle, teamState.slots)
      teamState.written = ok and n or 0
      if not ok then mod.log:warn("team battle writeback: %s", tostring(n)) end
      -- the story event takes the shared result before any script carries
      -- on or a whiteout moves anyone (a fight ended without one, after a
      -- dropped partner, is called off in this game)
      if teamState.event then
        local r = ev and ev.result
        r = r == "win" and "win" or (r == "lose" or r == "whiteout") and "lose" or "cancel"
        local okF, errF
        if teamState.dropped and r ~= "win" then
          -- the partner left mid-battle: their fallback win may still
          -- count, so this game leaves it open (the initiator's held
          -- script detaches when it is released)
          if not (heldTrainer and heldTrainer.event == teamState.event) then
            okF, errF = pcall(progress.leave, progress, teamState.event, false)
          else
            okF = true
          end
        else
          okF, errF = pcall(progress.finish, progress, teamState.event, r)
        end
        if not okF then mod.log:warn("story event: %s", tostring(errF)) end
      end
      if ev and ev.result == "win" and not teamState.wild then
        pcall(TeamBattle.markBeaten, E, teamState.foes)
        local fresh = {}
        for _, f in ipairs(teamState.foes or {}) do
          if tonumber(f.trainerId) and joint:add(tonumber(f.trainerId)) then fresh[#fresh + 1] = tonumber(f.trainerId) end
        end
        if #fresh > 0 and session then session:sendCredit(fresh, false, true) end
        local ids = {}
        for _, f in ipairs(teamState.foes or {}) do ids[#ids + 1] = tonumber(f.trainerId) end
        local okP, got = pcall(settlePrize, ids, ev.battle and ev.battle.moneyMultiplier)
        if okP and (tonumber(got) or 0) > 0 then toast(("You got $%d for winning!"):format(got), 5) end
      end
      -- a lost team battle whites out both players, each in their own game
      -- (battle_bridge.lua does this for a normal battle; it never does for
      -- a link battle)
      if ev and (ev.result == "lose" or ev.result == "whiteout") then
        local B, Field, Party = engine("battle_bridge"), engine("field"), engine("party")
        if heldTrainer and heldTrainer.noWhiteout then
          -- the early rival: heal and carry on (battle_bridge.lua writeback)
          if Party and Party.healAll and gs then pcall(Party.healAll, gs.party) end
        else
          if B and B.applyWhiteoutMoneyLoss then pcall(B.applyWhiteoutMoneyLoss, gs, game and game.save) end
          if Field and Field.respawnAtHeal then pcall(Field.respawnAtHeal) end
        end
      end
    end
    if session then session:setBusy("none") end
    local ok, err = pcall(tracker.onBattleEnded, tracker, ev)
    if not ok then mod.log:warn("soul link: %s", tostring(err)) end
  end)

  -- Enforced catch limits.  The bag already refuses a ball when the party
  -- and the boxes are full ("The BOX is full!"), before the ball is used
  -- up; a ball Soul Link refuses goes down that same path with its own
  -- words.  Safari Zone's BALL command checks the same function.  The
  -- catch.rate hook is the backstop for any other way to throw one.
  local BagMenu = uiModule("bag_menu")
  local RomText = engine("rom_text")
  local TextIR = engine("scripting.text_ir")
  local BOX_FULL_KEYS = { "gOtherText_BoxIsFull", "gText_BoxFull" }
  if BagMenu and BagMenu.partyAndStorageFull and not BagMenu._g3coopFull then
    BagMenu._g3coopFull = BagMenu.partyAndStorageFull
    BagMenu.partyAndStorageFull = function(...)
      local extra = BagMenu._g3coopBlock
      if extra then
        local ok, text = pcall(extra)
        if ok and text then return true end
      end
      return BagMenu._g3coopFull(...)
    end
  end
  if BagMenu then
    BagMenu._g3coopBlock = function()
      local text = tracker:blockText()
      if not text then return nil end
      -- the message that follows reads one of these keys this frame
      if RomText and TextIR and TextIR.fromAscii and not overridden then
        overridden = {}
        local ir = TextIR.fromAscii(text)
        for _, k in ipairs(BOX_FULL_KEYS) do
          local cur = RomText.overrides[k]
          overridden[k] = cur == nil and false or cur
          RomText.overrides[k] = ir
        end
      end
      return text
    end
  end
  local BattleText = engine("battle.battle_text")
  if BattleText and BattleText.get and not BattleText._g3coopGet then
    BattleText._g3coopGet = BattleText.get
    BattleText.get = function(id, ...)
      local extra = BattleText._g3coopText
      if id == "STRINGID_BOXISFULL" and extra then
        local ok, text = pcall(extra)
        if ok and text then return text end
      end
      return BattleText._g3coopGet(id, ...)
    end
  end
  if BattleText then BattleText._g3coopText = function() return tracker:blockText() end end
  mod.hooks:wrap("catch.rate", function(next, ...)
    -- A shared battle resolves every throw on both games, and the two
    -- players' Soul Link eligibility may differ: a local veto here would
    -- catch on one game and miss on the other.  There the rule is applied
    -- only by the thrower's own bag (above), before any ball action exists.
    local Battle = engine("battle")
    local st = Battle and Battle.getState and Battle.getState()
    if st and (st.coopTeam or st.link) then return next(...) end
    if tracker:blockText() then return false, 0 end
    return next(...)
  end)

  -- Hard rules: the dead stay dead.  Every revive (REVIVE, MAX REVIVE,
  -- REVIVAL HERB, SACRED ASH; in battle and out) goes through
  -- ItemUse.revive, and a refusal reads "It won't have any effect."
  local ItemUse = engine("item_use")
  if ItemUse and ItemUse.revive and not ItemUse._g3coopRevive then
    ItemUse._g3coopRevive = ItemUse.revive
    ItemUse.revive = function(mon, ...)
      local extra = ItemUse._g3coopBanned
      if extra then
        local ok, banned = pcall(extra, mon)
        if ok and banned then return false, 0 end
      end
      return ItemUse._g3coopRevive(mon, ...)
    end
  end
  if ItemUse then ItemUse._g3coopBanned = function(mon) return tracker:isBanned(mon) end end

  -- Level caps: battle EXP stops at the cap (a POKeMON below it may still
  -- reach it), and a RARE CANDY won't take it past.
  mod.hooks:wrap("exp.gain", function(next, info)
    local amount = next(info)
    local cap = capNow()
    local mon = type(info) == "table" and info.mon
    if not (cap and mon) then return amount end
    local Exp = engine("battle.experience")
    if not (Exp and Exp.expForLevel) then return amount end
    return LevelCap.clampExp(mon.level, mon.exp, tonumber(amount) or 0, cap,
      function(level) return Exp.expForLevel(mon, level) end)
  end)
  if ItemUse and ItemUse.useRareCandy and not ItemUse._g3coopRareCandy then
    ItemUse._g3coopRareCandy = ItemUse.useRareCandy
    ItemUse.useRareCandy = function(session_, mon, ...)
      local extra = ItemUse._g3coopCandyText
      if extra then
        local ok, text = pcall(extra, mon)
        if ok and text then return false, "no_effect", text end
      end
      return ItemUse._g3coopRareCandy(session_, mon, ...)
    end
  end
  if ItemUse then
    ItemUse._g3coopCandyText = function(mon)
      local cap = capNow()
      if not (cap and type(mon) == "table" and (tonumber(mon.level) or 1) >= cap) then return nil end
      toast(("Soul Link: level cap %d (%s)."):format(cap, tostring(capState.label)), 4)
      return RomText and RomText.box and (RomText.box("gText_WontHaveEffect")) or nil
    end
  end

  local function statusLine()
    if not session then return status end
    local s = session
    if s.state == "waiting" then
      if s.sameMachine == "hosting" then
        return "CO-OP: hosting on this PC (" .. tostring(s.net.address) .. ") - waiting"
      elseif s.sameMachine then
        return "CO-OP: port in use, joining this PC's host " .. tostring(s.net.target) .. "..."
      end
      if s.role == "join" then return "CO-OP: joining " .. tostring(s.net.target) .. "..." end
      return "CO-OP: hosting on " .. tostring(s.net.address) .. " - waiting"
    elseif s.state == "handshake" then
      return "CO-OP: checking versions..."
    end
    local line = "CO-OP: " .. tostring(s.peer and s.peer.name or "partner")
    local Map = engine("map")
    local ghost = s.ghost
    if ghost.known and Map and ghost.map ~= Map.current and not offsetOf(ghost.map) then
      line = line .. " @ " .. tostring(ghost.map)
    end
    if activity then
      line = line .. (activity.kind == "battle" and " - battle" or " - trade")
    elseif s.peerBusy == "battle" then
      line = line .. " (battling)"
    elseif s.peerBusy == "trade" then
      line = line .. " (trading)"
    end
    if s:stale() then line = line .. " (no signal)" end
    return line
  end

  -- the area a map belongs to, by name (the partner card)
  local function mapArea(mapId)
    local maps = game and game.data and game.data.maps
    local def = maps and mapId and maps[mapId]
    local sec = type(def) == "table" and tonumber(def.regionMapSectionId)
    return sec and areaName(sec) or nil
  end

  local function pingMs(s)
    local peer = s.net and s.net.peer
    if not (peer and peer.round_trip_time) then return nil end
    local ok, rtt = pcall(peer.round_trip_time, peer)
    return ok and tonumber(rtt) or nil
  end

  -- Soul Link's tally for the card, worked out twice a second
  local slTally, slTallyAt = nil, -1
  local function soulLinkLine()
    local now = clock()
    if now >= slTallyAt then
      slTallyAt = now + 0.5
      local ok, data = pcall(tracker.panel, tracker)
      slTally = ok and data or nil
    end
    local d = slTally
    if not d then return nil end
    if d.over then return { "SOUL LINK: none left to battle", Hud.COLORS.bad } end
    return { ("SOUL LINK: %d alive, %d gone  (F7)"):format(d.alive, d.gone), Hud.COLORS.sl }
  end

  local STATUS_SECONDS = 15
  local cardStatus, cardStatusAt = nil, 0

  -- What the partner card says (lib/hud.lua drawCard), or nil for none.
  local function cardInfo()
    local C = Hud.COLORS
    local s = session
    if not s then
      if retryAt then
        return { dot = "wait", title = "RECONNECTING", lines = { (tostring(status or ""):gsub("^CO%-OP: ", "")) } }
      end
      -- a status with nothing behind it (an error, "disconnected") stays
      -- up for a while, then the card goes away
      if status ~= cardStatus then cardStatus, cardStatusAt = status, clock() end
      if status and clock() - cardStatusAt < STATUS_SECONDS then
        return { dot = "off", title = "CO-OP", lines = { (tostring(status):gsub("^CO%-OP: ", "")) } }
      end
      return nil
    end
    if s.state == "waiting" then
      if s.role == "join" then
        local note = s.sameMachine and "This PC's host" or "Joining"
        return { dot = "wait", title = "JOINING", lines = { note, { tostring(s.net.target), C.text } } }
      end
      return { dot = "wait", title = "HOSTING", lines = {
        s.sameMachine and "On this PC. Your partner joins:" or "Your partner joins:",
        { tostring(s.net.address), C.text }, "START > CO-OP to stop" } }
    elseif s.state == "handshake" then
      return { dot = "wait", title = "CONNECTING", lines = { "Checking versions..." } }
    end
    local card = { dot = s:stale() and "bad" or "ok",
                   title = tostring(s.peer and s.peer.name or "PARTNER"), lines = {} }
    local ms = pingMs(s)
    if s:stale() then card.right = "no signal"
    elseif ms then card.right = ("%d ms"):format(ms) end
    local Map = engine("map")
    local ghost = s.ghost
    local where
    if not ghost.known then where = "..."
    elseif Map and ghost.map == Map.current then where = "Here with you"
    elseif offsetOf(ghost.map) then where = "Just nearby"
    else where = mapArea(ghost.map) or "Somewhere else" end
    if activity then where = activity.kind == "battle" and "Battling you" or "Trading with you"
    elseif s.peerBusy == "battle" then where = where .. ", in a battle"
    elseif s.peerBusy == "trade" then where = where .. ", trading" end
    card.lines[1] = where
    card.lines[2] = soulLinkLine()
    local cap = capNow()
    if cap then card.lines[#card.lines + 1] = { ("LEVEL CAP %d: %s"):format(cap, capState.label), C.warn } end
    if not cap and slui.showNext() and storyState and storyState.cap then
      card.lines[#card.lines + 1] = { ("NEXT: %s (Lv%d)"):format(storyState.label, storyState.cap), C.warn }
    end
    return card
  end

  -- Playing alone: the next big fight in a small card on the field
  -- (RULES > SHOW NEXT FIGHT turns it off).
  function slui.nextCard()
    if not (slui.showNext() and storyState and storyState.cap) then return nil end
    if not (game and game.phase == "field") then return nil end
    local cap = capNow()
    return { dot = cap and "wait" or "off", title = "NEXT BIG FIGHT", lines = {
      { tostring(storyState.label), Hud.COLORS.text },
      { cap and ("Level cap %d"):format(cap) or ("Ace Lv%d"):format(storyState.cap), Hud.COLORS.warn } } }
  end

  mod.hooks:wrap("render.hud", function(next, g, viewport)
    next(g, viewport)
    if not (love and love.graphics) then return end
    hud = hud or Hud.new(love.graphics)
    local now = clock()
    for i = #toasts, 1, -1 do
      if toasts[i].untilT < now then table.remove(toasts, i) end
    end
    if pausePanel then
      local ok, err = pcall(hud.drawChoice, hud, viewport, tostring(pausePanel.name) .. " disconnected",
        { "The battle is paused. They can't come back into this battle.",
          "Continue alone: your team takes both places, with no three-faint limit. A win still counts for both of you.",
          "End the battle: it counts as a draw." },
        PAUSE_OPTIONS, pausePanel.sel)
      if not ok then mod.log:warn("co-op pause panel: %s", tostring(err)) end
      return
    end
    if editor then
      local ok, err = pcall(hud.drawEditor, hud, viewport, editor, #ConnEdit.FIELDS)
      if not ok then mod.log:warn("co-op address screen: %s", tostring(err)) end
      return
    end
    if slPanel then
      local data = slui.panelData()
      local locked = slui.rulesLocked()
      local view = { tab = slui.panelTabName(), rules = slui.rulesRows(), sel = slui.sel,
        locked = locked and (tostring(tracker.run.partner.nm or "Your partner")
          .. " hosts: their rules apply while you're linked.") or nil,
        nextFight = storyState and storyState.cap and { label = storyState.label, ace = storyState.cap, cap = capNow() } or nil }
      local ok, max = pcall(hud.drawPanel, hud, viewport, data,
        function(sp)
          local P = engine("pokemon")
          local okI, icon = pcall(P.icon, sp)
          return okI and icon or nil
        end, view)
      if ok then panelMax = max or 0 else mod.log:warn("soul link panel: %s", tostring(max)) end
      return
    end
    local y
    -- the battle and trade screens use the whole screen; keep the toasts
    if mod.options:get("hud") and not (activity and activity.stage ~= "link") then
      local okC, card = pcall(cardInfo)
      if okC and not card then okC, card = pcall(slui.nextCard) end
      if okC and card then
        local okD, below = pcall(hud.drawCard, hud, viewport, card)
        if okD then y = below else mod.log:warn("co-op card: %s", tostring(below)) end
      end
    end
    if #toasts > 0 then
      local ok, err = pcall(hud.drawToasts, hud, viewport, toasts, y, now)
      if not ok then mod.log:warn("co-op toasts: %s", tostring(err)) end
    end
  end)

  mod.exports.status = statusLine
  mod.exports.session = function() return session end
  mod.exports.compat = compat
  mod.exports.toasts = function() return toasts end
  mod.exports.drawEntry = partnerDrawEntry
  mod.exports.requests = function() return requests end
  mod.exports.activity = function() return activity end
  mod.exports.npcs = function() return npcs end
  mod.exports.tracker = function() return tracker end
  mod.exports.card = cardInfo
  -- prototype entry for team battles until there is a menu for it: the
  -- host picks two trainers by id and asks the partner
  mod.exports.teamBattle = function(trainerA, trainerB)
    if not (session and session.role == "host" and requests) then return false, "not_host" end
    pendingTeam = { a = tonumber(trainerA), b = tonumber(trainerB) }
    local ok = requests:request("team")
    if not ok then pendingTeam = nil end
    return ok
  end
  mod.exports.teamState = function() return teamState end
  mod.exports.progress = function() return progress end
  -- prototype entry for a wild double on the host's map (mapId: another
  -- map's table, for testing)
  mod.exports.teamWild = function(mapId)
    if not (session and session.role == "host" and requests) then return false, "not_host" end
    pendingTeam = { wild = true, map = mapId }
    local ok = requests:request("team")
    if not ok then pendingTeam = nil end
    return ok
  end
  mod.exports.editor = function() return editor end
  mod.exports.creditList = function() return credit:list() end
  mod.exports.openEditor = function() openEditor() end
  mod.exports.setting = setting
  mod.exports.levelCap = function() stepCaps() return capNow(), capState end
  mod.exports.menu = function(g) coopMenu(g) end
end
