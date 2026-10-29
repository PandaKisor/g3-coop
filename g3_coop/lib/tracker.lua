-- The Soul Link run on this machine: turns what happens in the game into
-- run events (lib/soullink.lua), keeps the run in mod.storage, and swaps
-- logs with the partner.  The run lives in per-playthrough storage, which
-- reloading a save does not rewind: a reset can't undo an encounter.
--
-- Where events come from:
--   encounters  battle.started (wild); main.lua tells static from wild
--   catches     pokemon.caught
--   misses      battle.ended without a catch
--   faints      battle.fainted as it happens, and a run POKeMON at 0 HP in
--               the party, checked when a battle ends and twice a second
--               in the overworld (poison)
--   gifts/eggs  a POKeMON with our trainer ID that appears in the party or
--               a box without being caught
--   nicknames   party scan
--
-- deps: { SL, now, toast(text), session() -> game3 session, read(key),
--         write(key, value), areaOf() -> area, areaName(area), baseOf(sp),
--         speciesName(sp), isShiny(mon), isEgg(mon), options() -> { on,
--         dupes, shiny, gift, static, enforce, hard }, newId(), send(fields)
--         or nil when not connected, storage = { openSlot(s) -> box, slot;
--         move(s, partyIndex, box, slot) -> ok (swaps with a box mon) } }
--
-- Hard rules: a dead or not-allowed run POKeMON can't be revived, and is
-- sent to the PC as soon as the field is free (swapped for a living one
-- from the boxes when it is the last that could battle).

local Tracker = {}
Tracker.__index = Tracker

Tracker.KEY = "soullink/run"
Tracker.SCAN_SECONDS = 0.5
Tracker.BOX_SCAN_SECONDS = 2

function Tracker.new(deps)
  return setmetatable({ d = deps, SL = deps.SL, run = nil, tid = nil, viewCache = nil,
                        battle = nil, scanAt = -1, boxAt = -1, peer = nil, dirty = false,
                        connected = false, greeted = false },
                      Tracker)
end

-- A save's trainer, as a run key: ID and name, so two saves with the same
-- ID can't be confused
function Tracker.tidOf(s)
  local id = tonumber(s and (s.trainerId or s.id or s.playerId))
  if not id then return nil end
  local name = tostring(s.name or s.playerName or ""):gsub("[^%w]", ""):sub(1, 12)
  return ("%.0f-%s"):format(id % 4294967296, name)
end

local function eachMon(s, withBoxes, fn)
  for _, mon in ipairs(s.party or {}) do
    if type(mon) == "table" then fn(mon, "party") end
  end
  if not withBoxes then return end
  local st = s.storage
  for _, box in ipairs(st and st.boxes or {}) do
    for _, mon in pairs(box.mons or {}) do
      if type(mon) == "table" then fn(mon, "box") end
    end
  end
end

function Tracker:_save()
  self.dirty = false
  local ok, code = self.d.write(Tracker.KEY, self.run)
  if not ok and not self.warnedSave then
    self.warnedSave = true
    self.d.toast("Soul Link: couldn't save the run (" .. tostring(code) .. ")")
  end
end

-- The run for the loaded save, creating it the first time Soul Link is on.
function Tracker:ensure()
  local d, SL = self.d, self.SL
  if not d.options().on then return nil end
  local s = d.session()
  local tid = Tracker.tidOf(s)
  if not tid then return nil end
  if self.run and self.tid == tid then return self.run end
  self.run, self.tid, self.viewCache, self.peer, self.battle = nil, tid, nil, nil, nil
  self.greeted = false
  local stored, code = d.read(Tracker.KEY)
  if type(stored) == "table" and stored.format == SL.FORMAT and stored.me and stored.me.tid == tid then
    self.run = stored
    self.run.known = self.run.known or {}
    self:_closePending()
    return self.run
  end
  if stored == nil and code ~= "not_found" then return nil end   -- storage trouble: don't clobber
  local name = tostring(s.name or s.playerName or "PLAYER"):sub(1, 12)
  local run = SL.newRun({ tid = tid, nm = name }, d.options(), d.newId())
  local n = 0
  eachMon(s, true, function(mon)
    local u = SL.uid(mon)
    if u then run.known[u], n = true, n + 1 end
  end)
  self.run = run
  self:_save()
  d.toast(n > 0 and ("Soul Link run started. The %d POKeMON you already have don't count."):format(n)
    or "Soul Link run started.", 6)
  return run
end

-- An encounter still pending when the run loads was cut short by a reset
-- or a crash: it counts as missed.
function Tracker:_closePending()
  local view = self:view()
  local closed = false
  for a, ar in pairs(view.mine.areas) do
    if ar.state == "pending" then
      local l = self.SL.log(self.run, self.tid)
      l[#l + 1] = { k = "miss", a = a }
      closed = true
    end
  end
  if closed then
    self.viewCache = nil
    self:_save()
  end
end

function Tracker:view()
  if not self.viewCache then
    self.viewCache = self.SL.derive(self.run, self.d.baseOf, self.d.giftArea, self.d.ignoreEncounter)
    local tracked = {}
    for _, v in ipairs({self.viewCache.mine, self.viewCache.theirs}) do
      for u in pairs(v.species) do tracked[u] = true end
    end
    self.viewCache.tracked = tracked
  end
  return self.viewCache
end

-- The rules in force: the host's once paired (kept while offline), our
-- own settings otherwise.
function Tracker:rules()
  local run = self.run
  if run.partner and run.ruler and run.ruler ~= self.tid then return run.rules end
  run.rules = self.SL.copyRules(self.d.options())
  return run.rules
end

function Tracker:hard()
  return self.run ~= nil and self.d.options().on and self:rules().hard == true
end

-- balls are refused when they would break the rules
function Tracker:enforcing()
  local r = self:rules()
  return r.enforce == true or r.hard == true
end

function Tracker:_append(ev)
  -- New observations have passed the live scene exclusions; legacy cleanup
  -- must not mistake a genuine gift from another compatible mod for a loan.
  if ev.k == "enc" or ev.k == "catch" then ev.sc = true end
  local l = self.SL.log(self.run, self.tid)
  l[#l + 1] = ev
  local before = self.viewCache
  self.viewCache = nil
  self:_save()
  self:_sendFrom(#l)
  self:_announceDeaths(before)
end

-- Tell the player about run POKeMON that just died.
function Tracker:_announceDeaths(before)
  if not before then return end
  local after = self:view()
  local d = self.d
  local partner = self.run.partner and self.run.partner.nm or "your partner"
  for _, row in ipairs(after.pairs) do
    local m, t = row.mine, row.theirs
    local mu, tu = m and m.u, t and t.u
    local newly = (mu and after.dead[mu] and not before.dead[mu])
      or (tu and after.dead[tu] and not before.dead[tu])
    if newly then
      local mine = mu and self:_monName(mu, m.s)
      local theirs = tu and self:_monName(tu, t.s)
      if row.status == "broken" then
        d.toast(("Soul Link: the %s link is broken, so %s is gone."):format(
          d.areaName(row.a), mine or (partner .. "'s " .. tostring(theirs))), 6)
      else
        d.toast(("Soul Link: %s and %s's %s are gone."):format(
          tostring(mine), partner, tostring(theirs)), 6)
      end
    end
  end
end

function Tracker:_monName(u, s)
  local v = self:view()
  return (u and v.names[u]) or self.d.speciesName(s)
end

-- ------------------------------------------------------------------ battle

-- First encounters without duplicates (user, 2026-10-28): while a player's
-- encounter on this area is still open, a wild double's Pokémon are of
-- different evolution lines, and (dupes clause on) of none either player
-- already has.  encs: rolled encounters ({ species = id, ... }); roll()
-- rolls another (nil when it can't); fixed[i]: encs[i] stays (a fishing
-- or scripted lead); both: the area counts as open while either player
-- still has it (the shared co-op double).  Rerolls a few times and keeps
-- the original roll when the table has nothing better.
Tracker.PICK_TRIES = 24
function Tracker:pickFirstEncounters(encs, roll, fixed, both)
  if not self:ensure() or type(encs) ~= "table" or #encs < 2 then return encs end
  local v, a = self:view(), self.d.areaOf()
  if not a then return encs end
  local open = not v.mine.areas[a] or (both and self.run.partner ~= nil and not v.theirs.areas[a])
  if not open then return encs end
  local dupes = self:rules().dupes
  local base = function(s) return v.baseOf and v.baseOf(s) or s end
  local taken = {}
  local function ok(enc)
    local s = type(enc) == "table" and tonumber(enc.species)
    if not s then return false end
    local b = base(s)
    return not taken[b] and not (dupes and v.lines[b])
  end
  local out = {}
  for i, enc in ipairs(encs) do
    local pick = enc
    if not (fixed and fixed[i]) and not ok(enc) then
      for _ = 1, self.PICK_TRIES do
        local r = roll()
        if r and ok(r) then pick = r break end
      end
    end
    out[i] = pick
    local s = type(pick) == "table" and tonumber(pick.species)
    if s then taken[base(s)] = true end
  end
  return out
end

-- how: "wild" or "static" (main.lua knows which)
function Tracker:onBattleStarted(ev, how)
  if not self:ensure() then return end
  local kinds = ev and ev.battle and ev.battle.kinds or {}
  if kinds.firstBattle == "birch" or kinds.tutorial == "wally" then
    -- Birch's rescue uses our real starter; Wally's demonstration uses a
    -- borrowed party. Neither spends an encounter or restricts tutorial balls.
    self.battle = { other = true, tutorial = kinds.tutorial == "wally" }
    return
  end
  if ev and ev.kind == "coopwild" then return self:_coopWildStarted(ev) end
  if ev and ev.kind == "coopteam" then
    -- a team battle against trainers: real faints, our own mons only
    self.battle = { other = true, team = true }
    return
  end
  if not ev or ev.kind ~= "wild" then
    -- a co-op link battle is played with copies: its faints aren't real
    self.battle = { other = true, link = ev and ev.kind == "link" }
    return
  end
  local d = self.d
  local st = ev.battle
  local mon = st and st.enemy and st.enemy.mon
  local enc = { a = d.areaOf(), s = tonumber(ev.speciesId), h = how or "wild",
                sh = mon and d.isShiny(mon) or nil }
  if not (enc.a and enc.s) then
    self.battle = { other = true }
    return
  end
  local verdict, why = self.SL.judge(self.run, self:rules(), self:view(), enc)
  self.battle = { enc = enc, verdict = verdict, why = why, caught = false }
  local area, name = d.areaName(enc.a), d.speciesName(enc.s)
  if verdict == "counts" then
    self:_append({ k = "enc", a = enc.a, s = enc.s, h = enc.h, sh = enc.sh })
    d.toast(("Soul Link: %s is your %s encounter."):format(name, area), 5)
  elseif verdict == "free" and why == "shiny" then
    d.toast(("Soul Link: a shiny %s! Free to catch."):format(name), 5)
  elseif verdict == "blocked" then
    local enforced = self:enforcing() and " Balls won't work." or ""
    if why == "dupe" then
      d.toast(("Soul Link: dupes clause, %s's line is caught.%s"):format(name, enforced), 5)
    else
      d.toast(("Soul Link: you already had your %s encounter.%s"):format(area, enforced), 5)
    end
  end
end

-- A wild double shared with the partner (lib/teambattle.lua).  Each player
-- has their own first encounter per area (the addendum): this game judges
-- only its own.  Either foe may be the one this player catches, so the
-- encounter counts if either foe would; the catch itself is judged again by
-- the species actually caught (onCaught).
function Tracker:_coopWildStarted(ev)
  local d = self.d
  local st = ev.battle
  local a = d.areaOf()
  local best, foes = nil, {}
  for _, mon in ipairs(st and st.foeParty or {}) do
    local enc = { a = a, s = tonumber(mon.species or mon.speciesId), h = "wild",
                  sh = d.isShiny(mon) or nil }
    if enc.a and enc.s then
      local verdict, why = self.SL.judge(self.run, self:rules(), self:view(), enc)
      foes[#foes + 1] = { enc = enc, verdict = verdict, why = why }
      local rank = verdict == "counts" and 3 or verdict == "free" and 2 or 1
      if not best or rank > best.rank then best = { enc = enc, verdict = verdict, why = why, rank = rank } end
    end
  end
  if not best then
    self.battle = { other = true, team = true }
    return
  end
  self.battle = { enc = best.enc, verdict = best.verdict, why = best.why, caught = false,
                  team = true, coopWild = true, foes = foes }
  local area = d.areaName(a)
  if best.verdict == "counts" then
    self:_append({ k = "enc", a = a, s = best.enc.s, h = "wild", sh = best.enc.sh })
    d.toast(("Soul Link: this is your %s encounter. Catch either one."):format(area), 5)
  elseif best.verdict == "free" then
    d.toast("Soul Link: a shiny! Free to catch.", 5)
  elseif best.why == "dupe" then
    d.toast("Soul Link: dupes clause, both lines are caught.", 5)
  else
    d.toast(("Soul Link: you already had your %s encounter."):format(area), 5)
  end
end

function Tracker:onCaught(ev)
  if not self:ensure() then return end
  local b = self.battle
  local mon = ev and ev.mon
  local u = self.SL.uid(mon)
  if not (b and b.enc and u) then return end
  if b.coopWild then
    -- judged by what was caught: the other foe may have been the dupe
    local s = tonumber(mon.species or mon.speciesId)
    for _, f in ipairs(b.foes or {}) do
      if f.enc.s == s then
        if b.verdict == "counts" and f.verdict ~= "counts" then
          b.verdict, b.why = f.verdict, f.why
          if f.verdict == "blocked" then b.verdict = "late" end
        end
        b.enc = { a = b.enc.a, s = s, h = "wild", sh = f.enc.sh }
        break
      end
    end
  end
  local second = b.caught
  b.caught = true
  self.run.known[u] = true
  local x = nil
  if b.verdict == "free" then x = b.why elseif b.verdict ~= "counts" then x = "over" end
  -- both foes of a wild double caught: only the first is the encounter
  if second and x == nil then x = "over" end
  local nick = mon.nickname
  self:_append({ k = "catch", a = b.enc.a, s = b.enc.s, u = u, x = x,
                 nm = type(nick) == "string" and nick ~= "" and nick:sub(1, 12) or nil })
  if x == "over" then
    self.d.toast("Soul Link: caught against the rules. It's marked as not allowed.", 6)
  elseif not x then
    self:_announceLink(b.enc.a)
  end
end

function Tracker:_announceLink(a)
  local v = self:view()
  for _, row in ipairs(v.pairs) do
    if row.a == a and row.status == "alive" then
      self.d.toast(("Soul Link: %s is linked with %s's %s."):format(
        self:_monName(row.mine.u, row.mine.s), self.run.partner.nm,
        self:_monName(row.theirs.u, row.theirs.s)), 6)
    end
  end
end

function Tracker:onBattleEnded(_)
  local b = self.battle
  self.battle = nil
  if not self:ensure() then return end
  if b and (b.link or b.tutorial) then return end
  if b and b.verdict == "counts" and not b.caught then
    self:_append({ k = "miss", a = b.enc.a })
    self.d.toast(("Soul Link: your %s encounter got away."):format(self.d.areaName(b.enc.a)), 5)
  end
  self:_scanFaints(self.d.session())
end

-- The bag's message when a ball would break the rules, or nil.
function Tracker:blockText()
  local b = self.battle
  if not (b and b.verdict == "blocked" and self.run and self.d.options().on and self:enforcing()) then
    return nil
  end
  if b.why == "dupe" then return "SOUL LINK: dupes clause.\nThat line is already caught." end
  return "SOUL LINK: you already had\nyour encounter here."
end

-- One of our POKeMON fainted in battle (battle.fainted).  Recorded at
-- once, so a revive can't reach it before the battle ends.
function Tracker:onFainted(ev)
  if not self:ensure() then return end
  local b = self.battle
  if b and (b.link or b.tutorial) then return end
  -- versus battles are played with copies (and restored after)
  local live = ev and ev.battle
  if type(live) == "table" and live.link and not live.coopTeam and not (b and b.team) then return end
  local battler = ev and ev.battler
  if not (battler and (ev.sideName or battler.side) == "player") then return end
  -- a team battle's player side holds the partner's mons too; their
  -- faints are the partner's to record
  -- whose mon it is goes by its party slot's owner, not the position: after
  -- continuing alone both positions hold this player's mons
  local st = ev and ev.battle
  if b and b.team and st and st.linkOwn ~= nil then
    local owners = st.partyOwner and st.partyOwner.player
    local owner = owners and battler.partyIndex and owners[battler.partyIndex]
    if owner == nil then owner = tonumber(ev.battlerId) end
    if owner ~= st.linkOwn then return end
  end
  local mon = battler.mon
  local u = self.SL.uid(mon)
  local v = self:view()
  if not (u and v.tracked[u]) or v.dead[u] or self.d.isEgg(mon) then return end
  self.d.toast(("Soul Link: %s fainted."):format(tostring(self:_monName(u, mon.species))), 5)
  -- where, and to what (the FALLEN list)
  local by = self.d.faintCause and self.d.faintCause(st)
  self:_append({ k = "faint", u = u, a = self.d.areaOf(), by = by and tostring(by):sub(1, 24) or nil,
                 lv = tonumber(mon.level) })
end

-- May not battle (hard rules on): dead, or caught against the rules.
function Tracker:isBanned(mon)
  if mon and mon._g3coopBorrowed then return false end
  if not self:hard() then return false end
  local u = self.SL.uid(mon)
  return u ~= nil and self:view().banned[u] == true
end

-- ------------------------------------------------------------------- scans

function Tracker:_scanFaints(s)
  if not s then return end
  local v = self:view()
  local SL, d = self.SL, self.d
  local hits = {}
  eachMon(s, false, function(mon)
    if mon._g3coopBorrowed then return end
    local u = SL.uid(mon)
    if u and v.tracked[u] and not v.dead[u] and not d.isEgg(mon) and (tonumber(mon.hp) or 1) <= 0 then
      hits[#hits + 1] = { u = u, mon = mon }
    end
  end)
  for _, h in ipairs(hits) do
    d.toast(("Soul Link: %s fainted."):format(tostring(self:_monName(h.u, h.mon.species))), 5)
    self:_append({ k = "faint", u = h.u })
  end
end

function Tracker:_scanParty(s, withBoxes)
  local SL, d = self.SL, self.d
  local v = self:view()
  local myId = tonumber(s.trainerId or s.id or s.playerId)
  local gifts = {}
  eachMon(s, withBoxes, function(mon, where)
    if mon._g3coopBorrowed then return end
    local u = SL.uid(mon)
    if not u then return end
    if not self.run.known[u] and not v.tracked[u] then
      self.run.known[u] = true
      self.dirty = true
      local ot = tonumber(mon.otId or mon.trainerId)
      if ot and myId and ot % 4294967296 == myId % 4294967296 then
        gifts[#gifts + 1] = mon
      end
    elseif where == "party" and v.tracked[u] then
      local nick = mon.nickname
      if type(nick) == "string" and nick ~= "" and nick:sub(1, 12) ~= v.names[u] then
        self:_append({ k = "nick", u = u, nm = nick:sub(1, 12) })
        v = self:view()
      end
    end
  end)
  for _, mon in ipairs(gifts) do self:_gift(mon) end
end

function Tracker:_gift(mon)
  if mon._g3coopBorrowed then return end
  local SL, d = self.SL, self.d
  local enc = { a = d.areaOf(), s = tonumber(mon.species or mon.speciesId), h = "gift",
                sh = d.isShiny(mon) or nil }
  if d.giftArea then enc.a = d.giftArea(enc.s, enc.a, mon) end
  if not (enc.a and enc.s) then return end
  local u = SL.uid(mon)
  local verdict, why = SL.judge(self.run, self:rules(), self:view(), enc)
  local name = d.speciesName(enc.s)
  if verdict == "counts" then
    self:_append({ k = "enc", a = enc.a, s = enc.s, h = "gift", sh = enc.sh })
    self:_append({ k = "catch", a = enc.a, s = enc.s, u = u })
    d.toast(("Soul Link: %s (a gift) is your %s encounter."):format(name, d.areaName(enc.a)), 6)
    self:_announceLink(enc.a)
  elseif verdict == "free" then
    self:_append({ k = "catch", a = enc.a, s = enc.s, u = u, x = why })
  else
    self:_append({ k = "catch", a = enc.a, s = enc.s, u = u, x = "over" })
    d.toast(("Soul Link: you already had your %s encounter, so %s doesn't count."):format(
      d.areaName(enc.a), name), 6)
  end
end

-- One overworld tick.  busy: a co-op battle/trade is running (its party
-- changes aren't the player's).  free: nothing (menu, script) has the
-- field, so the party may be rearranged.
function Tracker:tick(inField, busy, free)
  local d = self.d
  local t = d.now()
  if t < self.scanAt then return end
  self.scanAt = t + Tracker.SCAN_SECONDS
  if not self:ensure() then return end
  self:_greet()
  if not inField or busy or self.battle then return end
  local s = d.session()
  if not s then return end
  local boxes = t >= self.boxAt
  if boxes then self.boxAt = t + Tracker.BOX_SCAN_SECONDS end
  self:_scanFaints(s)
  self:_scanParty(s, boxes)
  if self.dirty then self:_save() end
  if free then self:enforceParty(s) end
end

local function realMon(mon)
  return type(mon) == "table" and (tonumber(mon.species or mon.speciesId) or 0) ~= 0
end

-- Hard rules: send banned POKeMON from the party to the PC.  Only while
-- the field is free (no menu, script or battle has the party).  Returns
-- how many moved.
function Tracker:enforceParty(s)
  if not (s and self:hard() and self.d.storage) then return 0 end
  local d, st = self.d, self.d.storage
  local v = self:view()
  local function banned(mon) local u = self.SL.uid(mon) return u and v.banned[u] end
  local function canBattle(mon) return realMon(mon) and not banned(mon) and not d.isEgg(mon) end
  local moved = 0
  for _ = 1, 6 do
    local party = s.party or {}
    local idx
    for i, mon in ipairs(party) do
      if realMon(mon) and banned(mon) then idx = i break end
    end
    if not idx then break end
    local mon = party[idx]
    local name = self:_monName(self.SL.uid(mon), mon.species)
    local others = 0
    for i, m in ipairs(party) do
      if i ~= idx and canBattle(m) then others = others + 1 end
    end
    local done = false
    if others > 0 then
      local box, slot = st.openSlot(s)
      if box and st.move(s, idx, box, slot) then
        d.toast(("Soul Link: %s can't battle any more. Sent to the PC."):format(name), 5)
        done = true
      end
    end
    if not done then
      -- the last one standing (or the boxes are full): trade places with a
      -- living one from the boxes
      local box, slot, sub
      for b, bx in ipairs(s.storage and s.storage.boxes or {}) do
        for sl = 1, 30 do
          local m = bx.mons and bx.mons[sl]
          if canBattle(m) then box, slot, sub = b, sl, m break end
        end
        if box then break end
      end
      if box and st.move(s, idx, box, slot) then
        d.toast(("Soul Link: %s can't battle any more. %s came out of the PC instead."):format(
          name, self:_monName(self.SL.uid(sub), sub.species)), 6)
        done = true
      end
    end
    if not done then break end
    moved = moved + 1
  end
  self:_checkOver(s, canBattle)
  return moved
end

-- No POKeMON left anywhere that may battle: the run is over.
function Tracker:_checkOver(s, canBattle)
  -- (before the starter there is nothing to lose yet)
  local any, some = false, false
  eachMon(s, true, function(mon)
    if realMon(mon) and not self.d.isEgg(mon) then some = true end
    if canBattle(mon) then any = true end
  end)
  local over = some and not any
  if over and not self.over then
    self.d.toast("Soul Link: no POKeMON left that can battle. Decide together whether the run goes on.", 10)
  end
  self.over = over
end

-- -------------------------------------------------------------------- sync

function Tracker:_fields(from)
  local run = self.run
  local mine = self.SL.log(run, self.tid)
  local theirs = run.partner and run.logs[run.partner.tid] or {}
  local ev = {}
  for i = from, math.min(#mine, from + 63) do ev[#ev + 1] = mine[i] end
  return { run = run.id, tid = self.tid, nm = run.me.nm, pt = run.partner and run.partner.tid,
           rules = self:rules(), from = from, want = #theirs + 1, ev = ev }
end

function Tracker:_sendAll(hi)
  local send = self.d.send
  if not send then return end
  local n = #self.SL.log(self.run, self.tid)
  local from = 1
  repeat
    local f = self:_fields(from)
    f.hi = hi
    send(f)
    hi = nil
    from = from + 64
  until from > n
end

function Tracker:_sendFrom(i)
  if not (self.peer and self.peer.ok and self.d.send) then return end
  self.d.send(self:_fields(i))
end

-- the co-op connection is up
-- Autoconnect connects at the title screen, before a save is loaded and
-- there is a run to share: keep trying (from tick) until there is.  Our
-- hello makes the partner pair and send its own log back.
function Tracker:onConnected()
  self.connected, self.greeted = true, false
  self.peer = { ok = false }
  self:_greet()
end

function Tracker:_greet()
  if not self.connected or self.greeted or not self:ensure() then return end
  self.greeted = true
  self:_sendAll(true)
end

function Tracker:onDisconnected()
  self.connected, self.greeted = false, false
  self.peer = nil
end

function Tracker:onMessage(msg, isHost)
  local d, SL = self.d, self.SL
  local run = self:ensure()
  if not run then
    -- with Soul Link on, the run is just not loaded yet: _greet catches up
    if msg.hi and not self.toldOff and not d.options().on then
      self.toldOff = true
      d.toast(msg.nm .. " is playing Soul Link. Turn SOUL LINK on in Settings to join in.", 6)
    end
    return
  end
  self.peer = self.peer or { ok = false }
  if not self.peer.ok then
    if self.peer.bad then return end
    local r = SL.pair(run, { run = msg.run, tid = msg.tid, nm = msg.nm, pt = msg.pt }, isHost)
    if r == "mismatch" then
      self.peer.bad = true
      local with = run.partner and run.partner.nm or "someone else"
      d.toast(("Soul Link: this save's run is with %s, not %s. Not sharing."):format(with, msg.nm), 8)
      return
    end
    if r == "paired" then
      run.ruler = isHost and self.tid or msg.tid
      d.toast(("Soul Link: runs linked with %s."):format(msg.nm), 6)
    end
    self.peer.ok = true
    -- our own log, in case they connected before turning Soul Link on
    self:_sendAll(false)
  end
  if run.ruler == msg.tid then run.rules = SL.copyRules(msg.rules) end
  local before = self.viewCache or self:view()
  local want = SL.mergeLog(run, msg.tid, msg.from, msg.ev)
  self.viewCache = nil
  self:_save()
  self:_announceDeaths(before)
  if #msg.ev > 0 and want ~= msg.from + #msg.ev then
    -- a gap: ask for the rest
    if d.send then d.send(self:_fields(#SL.log(run, self.tid) + 1)) end
  elseif #msg.ev == 0 and msg.want <= #SL.log(run, self.tid) then
    -- an explicit request for our log from msg.want on
    local n = #SL.log(run, self.tid)
    for from = msg.want, n, 64 do self:_sendFrom(from) end
  end
end

-- --------------------------------------------------------------------- HUD

-- What the F7 panel shows, or nil with Soul Link off:
--   { partner, rules = { "DUPES", ... }, rows = { { area, status, mine,
--     theirs } }, extras = { { name, s, why } }, alive, gone, over }
-- where mine/theirs are nil or { name, s, state = "caught"|"missed"|
-- "battle", dead }.
function Tracker:panel()
  local run = self.run
  if not run then return nil end
  local d = self.d
  local v = self:view()
  local r = self:rules()
  local out = { partner = run.partner and run.partner.nm, rules = {}, rows = {}, extras = {},
                alive = 0, gone = 0, over = self.over == true and r.hard == true }
  for _, k in ipairs({ "dupes", "shiny", "gift", "static" }) do
    if r[k] then out.rules[#out.rules + 1] = k == "gift" and "GIFTS" or k == "static" and "STATICS" or k:upper() end
  end
  if r.hard then out.rules[#out.rules + 1] = "HARD"
  elseif r.enforce then out.rules[#out.rules + 1] = "ENFORCED" end
  local function cell(ar)
    if not ar then return nil end
    if ar.state == "failed" then return { name = "missed", s = ar.s, state = "missed" } end
    if ar.state == "pending" then return { name = "in battle", s = ar.s, state = "battle" } end
    return { name = self:_monName(ar.u, ar.s), s = ar.s, state = "caught", dead = v.dead[ar.u] == true }
  end
  for _, row in ipairs(v.pairs) do
    if row.status == "alive" then out.alive = out.alive + 1
    elseif row.status ~= "waiting" then out.gone = out.gone + 1 end
    out.rows[#out.rows + 1] = { area = d.areaName(row.a), status = row.status,
                                mine = cell(row.mine), theirs = cell(row.theirs) }
  end
  for _, e in ipairs(v.mine.extras) do
    out.extras[#out.extras + 1] = { name = self:_monName(e.u, e.s), s = e.s, why = e.why,
                                    dead = v.dead[e.u] == true }
  end
  out.fallen = self:_fallen(v)
  out.stats = self:_stats(v)
  return out
end

-- Why a run POKeMON is gone, for the FALLEN list.
local function faintCause(self, ev)
  local where = ev.a and self.d.areaName(ev.a) or nil
  local parts = {}
  if where then parts[#parts + 1] = where end
  if ev.by then parts[#parts + 1] = "vs " .. ev.by end
  if ev.lv then parts[#parts + 1] = "Lv" .. ev.lv end
  if #parts == 0 then return "fainted" end
  return table.concat(parts, ", ")
end

-- One row per lost link (dead or broken), in area order, plus run
-- POKeMON outside the links that fell: { area, status, mine, theirs },
-- each side { name, s, why } (why: where it fell / "linked" / "missed").
function Tracker:_fallen(v)
  local byUid = {}
  for _, ev in ipairs(v.mine.faintList) do byUid[ev.u] = ev end
  for _, ev in ipairs(v.theirs.faintList) do byUid[ev.u] = ev end
  local function side(ar, other)
    if not ar then return nil end
    if ar.state == "failed" then return { name = "missed", s = ar.s, why = "got away / KO'd", missed = true } end
    if ar.state ~= "caught" then return nil end
    local ev = byUid[ar.u]
    local why
    if ev then why = faintCause(self, ev)
    elseif other and other.state == "failed" then why = "link broken"
    else why = "linked: partner fell" end
    return { name = self:_monName(ar.u, ar.s), s = ar.s, why = why, fell = ev ~= nil }
  end
  local out = {}
  for _, row in ipairs(v.pairs) do
    -- (a catch can fall while its link still waits for the partner's)
    local fell = (row.mine and row.mine.u and byUid[row.mine.u]) or (row.theirs and row.theirs.u and byUid[row.theirs.u])
    if row.status == "dead" or row.status == "broken" or fell then
      out[#out + 1] = { area = self.d.areaName(row.a), status = row.status == "broken" and "broken" or "dead",
                        mine = side(row.mine, row.theirs), theirs = side(row.theirs, row.mine) }
    end
  end
  -- free catches (shiny, gifts...) that fell
  for _, who in ipairs({ "mine", "theirs" }) do
    for _, e in ipairs(v[who].extras) do
      local ev = byUid[e.u]
      if ev then
        local cell = { name = self:_monName(e.u, e.s), s = e.s, why = faintCause(self, ev), fell = true }
        out[#out + 1] = { area = self.d.areaName(e.a), status = "extra",
                          mine = who == "mine" and cell or nil, theirs = who == "theirs" and cell or nil }
      end
    end
  end
  return out
end

-- The run in numbers, for the RUN tab.
function Tracker:_stats(v)
  local st = { alive = 0, dead = 0, broken = 0, waiting = 0,
               caught = { 0, 0 }, extra = { #v.mine.extras, #v.theirs.extras },
               fainted = { #v.mine.faintList, #v.theirs.faintList },
               missed = { v.mine.misses, v.theirs.misses }, areas = #v.pairs }
  for _, row in ipairs(v.pairs) do
    st[row.status] = (st[row.status] or 0) + 1
    if row.mine and row.mine.state == "caught" then st.caught[1] = st.caught[1] + 1 end
    if row.theirs and row.theirs.state == "caught" then st.caught[2] = st.caught[2] + 1 end
  end
  -- the most recent of our own faints
  local last = v.mine.faintList[#v.mine.faintList]
  if last then
    st.lastFall = { name = self:_monName(last.u, v.mine.species[last.u]), why = faintCause(self, last) }
  end
  return st
end

return Tracker
