-- Soul Link rules, as pure data.  A run is one shared record for the two
-- partners' saves: each player appends events about their own game to their
-- own log, the logs are swapped over the co-op connection, and everything
-- else (which encounters pair up, who is dead, which lines are taken) is
-- derived from the two logs.  Nothing is ever edited in place, so merging
-- is just "take the longer copy of each log".
--
-- An area is a region-map section (MAPSEC): every route and every town is
-- one area, and the maps inside it (a cave's floors, a town's houses) share
-- it.  Each player gets one encounter per area; the two players' encounters
-- in the same area are linked.  Rules (host's, once paired):
--   dupes:   a wild/static encounter whose evolution line either player has
--            already caught doesn't count; the next one does
--   shiny:   a shiny can always be caught, outside the area limit, unlinked
--   gift:    gifts (and eggs) count as their area's encounter
--   static:  scripted wild battles count as their area's encounter
--   enforce: balls are refused when a catch would break the rules
--   caps:    no POKeMON grows past the next big fight's ace (lib/levelcap.lua)
--   hard:    enforce, and the dead stay dead: revives don't work on them and
--            they (and catches marked not allowed) can't stay in the party
--
-- Events (each player's log, in order):
--   { k = "enc",   a = area, s = species, h = "wild"|"static"|"gift", sh }
--   { k = "catch", a = area, s = species, u = uid, nm = nickname, x = why }
--       x nil: the area's encounter; x = "shiny"|"static"|"gift": a free
--       catch the rules allow; x = "over": caught against the rules
--   { k = "miss",  a = area }        the area's encounter got away / was KO'd
--   { k = "faint", u = uid }         any run POKeMON fainted in this game
--   { k = "nick",  u = uid, nm = nickname }

local SL = {}

SL.FORMAT = 1
SL.RULES = { "dupes", "shiny", "gift", "static", "enforce", "hard", "caps" }
SL.DEFAULT_RULES = { dupes = true, shiny = true, gift = true, static = true, enforce = false, hard = false, caps = false }
SL.HOW = { wild = true, static = true, gift = true }
SL.WHY = { shiny = true, static = true, gift = true, over = true }
SL.KINDS = { enc = true, catch = true, miss = true, faint = true, nick = true }

function SL.uid(mon)
  if type(mon) ~= "table" then return nil end
  local p, o = tonumber(mon.personality), tonumber(mon.otId or mon.trainerId)
  if not (p and o) then return nil end
  return ("%.0f:%.0f"):format(p % 4294967296, o % 4294967296)
end

function SL.copyRules(src)
  local out = {}
  for _, k in ipairs(SL.RULES) do
    local v = src and src[k]
    if v == nil then v = SL.DEFAULT_RULES[k] end
    out[k] = v == true
  end
  return out
end

-- me: { tid, nm }; id: a fresh run id
function SL.newRun(me, rules, id)
  return { format = SL.FORMAT, id = id, me = me, partner = nil,
           rules = SL.copyRules(rules), logs = { [me.tid] = {} }, known = {} }
end

function SL.log(run, tid)
  local l = run.logs[tid]
  if not l then
    l = {}
    run.logs[tid] = l
  end
  return l
end

-- The partner's log as received: events from index `from` on.  Returns
-- the index we now want next (a gap leaves the log alone and asks again).
function SL.mergeLog(run, tid, from, events)
  local l = SL.log(run, tid)
  if from > #l + 1 then return #l + 1 end
  for i, ev in ipairs(events) do l[from + i - 1] = ev end
  return #l + 1
end

-- One player's areas and catches.
local function playerView(events)
  local v = { areas = {}, extras = {}, names = {}, faints = {} }
  for _, ev in ipairs(events or {}) do
    if ev.k == "enc" then
      if not v.areas[ev.a] then
        v.areas[ev.a] = { state = "pending", s = ev.s, h = ev.h, sh = ev.sh }
      end
    elseif ev.k == "catch" then
      if ev.x then
        v.extras[#v.extras + 1] = { a = ev.a, s = ev.s, u = ev.u, why = ev.x }
      else
        local ar = v.areas[ev.a] or {}
        v.areas[ev.a] = ar
        ar.state, ar.s, ar.u = "caught", ev.s, ev.u
      end
      if ev.nm and ev.nm ~= "" then v.names[ev.u] = ev.nm end
    elseif ev.k == "miss" then
      local ar = v.areas[ev.a]
      if ar and ar.state == "pending" then ar.state = "failed" end
    elseif ev.k == "faint" then
      v.faints[ev.u] = true
    elseif ev.k == "nick" then
      v.names[ev.u] = ev.nm
    end
  end
  return v
end

-- Everything the run implies.  baseOf(species) -> the first species of its
-- evolution line (for the dupes clause).
--   pairs: one row per area either player has used, sorted by area:
--     { a, mine, theirs, status = "alive"|"dead"|"broken"|"waiting" }
--   dead[uid]: fainted, linked to a fainted one, or left without a partner
--     by a failed encounter
--   lines[base]: evolution lines caught by either player
--   banned[uid]: may not battle under the hard rules: dead, or caught
--     against the rules
function SL.derive(run, baseOf)
  local me = run.me.tid
  local them = run.partner and run.partner.tid
  local mine = playerView(run.logs[me])
  local theirs = playerView(them and run.logs[them] or nil)
  local fainted = {}
  for u in pairs(mine.faints) do fainted[u] = true end
  for u in pairs(theirs.faints) do fainted[u] = true end
  local dead = {}
  for u in pairs(fainted) do dead[u] = true end
  local names = {}
  for u, n in pairs(theirs.names) do names[u] = n end
  for u, n in pairs(mine.names) do names[u] = n end

  local seen, order = {}, {}
  for a in pairs(mine.areas) do if not seen[a] then seen[a] = true order[#order + 1] = a end end
  for a in pairs(theirs.areas) do if not seen[a] then seen[a] = true order[#order + 1] = a end end
  table.sort(order)
  local rows = {}
  for _, a in ipairs(order) do
    local m, t = mine.areas[a], theirs.areas[a]
    local row = { a = a, mine = m, theirs = t }
    local mf = m and m.state == "failed"
    local tf = t and t.state == "failed"
    local mc = m and m.state == "caught"
    local tc = t and t.state == "caught"
    if mf or tf then
      -- a missed encounter breaks the link: the other side's catch is gone too
      row.status = "broken"
      if mc then dead[m.u] = true end
      if tc then dead[t.u] = true end
    elseif mc and tc then
      if fainted[m.u] or fainted[t.u] then
        row.status = "dead"
        dead[m.u], dead[t.u] = true, true
      else
        row.status = "alive"
      end
    else
      row.status = "waiting"
    end
    rows[#rows + 1] = row
  end

  local lines = {}
  local function addLine(s)
    if s then lines[baseOf and baseOf(s) or s] = true end
  end
  for _, ar in pairs(mine.areas) do if ar.state == "caught" then addLine(ar.s) end end
  for _, ar in pairs(theirs.areas) do if ar.state == "caught" then addLine(ar.s) end end

  local banned = {}
  for u in pairs(dead) do banned[u] = true end
  for _, e in ipairs(mine.extras) do if e.why == "over" then banned[e.u] = true end end
  for _, e in ipairs(theirs.extras) do if e.why == "over" then banned[e.u] = true end end

  return { pairs = rows, dead = dead, banned = banned, lines = lines, names = names,
           mine = mine, theirs = theirs, baseOf = baseOf }
end

-- May this player count / catch an encounter?  enc = { a, s, h, sh }.
-- Returns verdict, why:
--   "counts"            it is the area's encounter
--   "free", why         catchable outside the limit (shiny/static/gift rule)
--   "blocked", why      catching it breaks the rules ("used" / "dupe")
function SL.judge(run, rules, view, enc)
  if enc.sh and rules.shiny then return "free", "shiny" end
  if enc.h == "static" and not rules.static then return "free", "static" end
  if enc.h == "gift" and not rules.gift then return "free", "gift" end
  if view.mine.areas[enc.a] then return "blocked", "used" end
  if rules.dupes and enc.h ~= "gift" and view.lines[view.baseOf and view.baseOf(enc.s) or enc.s] then
    return "blocked", "dupe"
  end
  return "counts"
end

-- Pairing on first contact.  info: the partner's { run, tid, nm, pt }
-- (pt: who their run is linked with, if anyone).  Returns "paired" (run
-- now shared; the guest takes the host's id), "same" (already linked to
-- this partner), or "mismatch", nil.
function SL.pair(run, info, isHost)
  local p = run.partner
  if p then
    if p.tid == info.tid and run.id == info.run then return "same" end
    return "mismatch"
  end
  if info.pt ~= nil and info.pt ~= run.me.tid then return "mismatch" end
  run.partner = { tid = info.tid, nm = info.nm }
  if not isHost then run.id = info.run end
  SL.log(run, info.tid)
  return "paired"
end

return SL
