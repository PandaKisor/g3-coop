-- Headless suite for g3_coop's Soul Link (lib/soullink.lua, lib/tracker.lua).
--   cd Gen3Mod/gen1recomp-0.3.73 && luajit ../coop/tests/run_soullink.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local coop = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
local here = coop .. "/g3_coop"
local function lib(name) return dofile(here .. "/lib/" .. name .. ".lua") end

local T = require("tests.modkit")
local Protocol = lib("protocol")
local SL = lib("soullink")
local Tracker = lib("tracker")

-- species: 1 -> 2 -> 3 is one line; 10, 20, 30, 40 stand alone
local PARENT = { [2] = 1, [3] = 2 }
local function baseOf(s) while PARENT[s] do s = PARENT[s] end return s end
local RULES = SL.copyRules({ dupes = true, shiny = true, gift = true, static = true })

-- ------- rules

local run = SL.newRun({ tid = "1-A", nm = "A" }, RULES, "runA")
local function add(tid, ev) local l = SL.log(run, tid) l[#l + 1] = ev end
T.eq(SL.uid({ personality = 4294967295, otId = 12345 }), "4294967295:12345", "uids are personality:OT id")

local v = SL.derive(run, baseOf)
T.eq(SL.judge(run, RULES, v, { a = 16, s = 10, h = "wild" }), "counts", "a fresh area's first encounter counts")
add("1-A", { k = "enc", a = 16, s = 10, h = "wild" })
v = SL.derive(run, baseOf)
T.eq(select(2, SL.judge(run, RULES, v, { a = 16, s = 20, h = "wild" })), "used", "the second one in that area is blocked")
T.eq(SL.judge(run, RULES, v, { a = 16, s = 20, h = "wild", sh = true }), "free", "a shiny is always free")
T.eq(SL.judge(run, SL.copyRules({ shiny = false }), v, { a = 16, s = 20, h = "wild", sh = true }), "blocked",
  "unless the shiny clause is off")
T.eq(select(2, SL.judge(run, SL.copyRules({ static = false }), v, { a = 16, s = 20, h = "static" })), "static",
  "with statics not counting, a static is a free catch")
T.eq(select(2, SL.judge(run, SL.copyRules({ gift = false }), v, { a = 16, s = 20, h = "gift" })), "gift",
  "with gifts not counting, a gift is a free catch")

-- pairing
local function hello(r) return { run = r.id, tid = r.me.tid, nm = r.me.nm, pt = r.partner and r.partner.tid } end
local runB = SL.newRun({ tid = "2-B", nm = "B" }, RULES, "runB")
T.eq(SL.pair(run, hello(runB), true), "paired", "two fresh runs pair up")
T.eq(SL.pair(runB, hello(run), false), "paired", "on both sides")
T.eq(runB.id, "runA", "the joiner takes the host's run id")
T.eq(SL.pair(run, hello(runB), true), "same", "meeting again is the same run")
local runC = SL.newRun({ tid = "3-C", nm = "C" }, RULES, "runC")
T.eq(SL.pair(run, hello(runC), true), "mismatch", "a run linked with B won't take C")
T.eq(SL.pair(runC, hello(run), false), "mismatch", "and C won't join a run that's linked with someone else")

-- links, deaths, broken links
add("1-A", { k = "catch", a = 16, s = 10, u = "1:1" })
add("2-B", { k = "enc", a = 16, s = 40, h = "wild" })
v = SL.derive(run, baseOf)
T.eq(v.pairs[1].status, "waiting", "a pair waits for both catches")
add("2-B", { k = "catch", a = 16, s = 40, u = "2:2" })
v = SL.derive(run, baseOf)
T.eq(v.pairs[1].status, "alive", "two catches in one area are linked")
add("1-A", { k = "enc", a = 17, s = 2, h = "wild" })
add("1-A", { k = "catch", a = 17, s = 2, u = "1:3" })
v = SL.derive(run, baseOf)
T.eq(select(2, SL.judge(run, RULES, v, { a = 18, s = 3, h = "wild" })), "dupe", "the dupes clause covers the whole line")
T.eq(select(2, SL.judge(run, RULES, v, { a = 18, s = 40, h = "wild" })), "dupe", "and the partner's catches too")
T.eq(SL.judge(run, RULES, v, { a = 18, s = 40, h = "gift" }), "counts", "a gift can't be skipped as a dupe")
T.eq(SL.judge(run, SL.copyRules({ dupes = false }), v, { a = 18, s = 40, h = "wild" }), "counts",
  "with the dupes clause off, dupes count")
add("2-B", { k = "enc", a = 17, s = 30, h = "wild" })
add("2-B", { k = "miss", a = 17 })
v = SL.derive(run, baseOf)
T.eq(v.pairs[2].status, "broken", "a missed encounter breaks its link")
T.check(v.dead["1:3"], "and the other side's catch is gone")
add("2-B", { k = "faint", u = "2:2" })
v = SL.derive(run, baseOf)
T.check(v.pairs[1].status == "dead" and v.dead["1:1"] and v.dead["2:2"], "one faint takes both of a pair")
add("1-A", { k = "nick", u = "1:1", nm = "SPARKY" })
T.eq(SL.derive(run, baseOf).names["1:1"], "SPARKY", "nicknames are kept")

-- merging logs
local r2 = SL.newRun({ tid = "1-A", nm = "A" }, RULES, "x")
T.eq(SL.mergeLog(r2, "2-B", 1, { { k = "miss", a = 1 }, { k = "miss", a = 2 } }), 3, "a log slice appends")
T.eq(SL.mergeLog(r2, "2-B", 5, { { k = "miss", a = 5 } }), 3, "a gap is refused and asks again")
T.eq(SL.mergeLog(r2, "2-B", 2, { { k = "miss", a = 2 }, { k = "miss", a = 3 } }), 4, "an overlap is harmless")

-- ------- the wire

local good = Protocol.sl({ hi = true, run = "runA", tid = "1-A", nm = "MAY", rules = RULES, from = 1, want = 1,
  ev = { { k = "enc", a = 16, s = 10, h = "wild" }, { k = "catch", a = 16, s = 10, u = "1:1", nm = "ZIG" } } })
local ok = Protocol.validate(good)
T.check(ok and ok.hi and #ok.ev == 2 and ok.ev[2].nm == "ZIG", "a Soul Link message validates")
local function bad(over)
  local m = {}
  for k, val in pairs(good) do m[k] = val end
  for k, val in pairs(over) do m[k] = val end
  return Protocol.validate(m)
end
T.eq(bad({ ev = { { k = "enc", a = 16, s = 10, h = "teleport" } } }), nil, "unknown encounter kinds are refused")
T.eq(bad({ ev = { { k = "catch", a = 16, s = 10, u = "os.exit()" } } }), nil, "uids are digits only")
T.eq(bad({ ev = { { k = "eval", a = 1 } } }), nil, "unknown events are refused")
T.eq(bad({ run = "../x" }), nil, "run ids are identifiers")
local long = {}
for i = 1, Protocol.MAX_SL_EVENTS + 1 do long[i] = { k = "miss", a = 1 } end
T.eq(bad({ ev = long }), nil, "slices are capped")
T.eq(bad({ nm = "<script>" }).nm, "?script?", "names are filtered")

-- ------- the tracker, with a fake game

local clockT = 0
local function newGame(tid, name)
  return { trainerId = tid, name = name, party = {}, storage = { boxes = { { mons = {} } } }, map = "M", sec = 16 }
end
local function newTracker(g, opts)
  local store, toasts, sent = {}, {}, {}
  local o = { on = true, dupes = true, shiny = true, gift = true, static = true, enforce = false }
  for k, val in pairs(opts or {}) do o[k] = val end
  local tr = Tracker.new({
    SL = SL, now = function() return clockT end,
    toast = function(text) toasts[#toasts + 1] = text end,
    session = function() return g end,
    read = function(k) if store[k] then return store[k] end return nil, "not_found" end,
    write = function(k, val) store[k] = val return true end,
    areaOf = function() return g.sec end,
    areaName = function(a) return "AREA" .. a end,
    baseOf = baseOf,
    speciesName = function(s) return "SP" .. tostring(s) end,
    isShiny = function(mon) return mon.isShiny == true end,
    isEgg = function() return false end,
    options = function() return o end,
    newId = function() return "id" .. tostring(tid) end,
    send = function(f) sent[#sent + 1] = f end,
  })
  return tr, { store = store, toasts = toasts, sent = sent, opts = o }
end
local function lastToast(io) return io.toasts[#io.toasts] or "" end
local function mon(p, ot, sp, extra)
  local m = { personality = p, otId = ot, species = sp, hp = 20 }
  for k, val in pairs(extra or {}) do m[k] = val end
  return m
end
local function wild(tr, sp, how, shiny)
  tr:onBattleStarted({ kind = "wild", speciesId = sp, battle = { enemy = { mon = { isShiny = shiny } } } }, how or "wild")
end

local gA = newGame(100, "MAY")
gA.party[1] = mon(9, 100, 1)             -- had before the run
local A, ioA = newTracker(gA)
T.check(A:ensure() ~= nil, "turning Soul Link on starts a run")
T.check(lastToast(ioA):find("1 POKeMON you already have", 1, true), "and says the POKeMON so far don't count")
A:tick(true, false)
T.eq(#SL.log(A.run, A.tid), 0, "an old POKeMON is not mistaken for a gift")

-- the starter: a gift with our trainer ID
gA.party[2] = mon(11, 100, 20)
clockT = clockT + 1
A:tick(true, false)
local l = SL.log(A.run, A.tid)
T.check(#l == 2 and l[1].k == "enc" and l[1].h == "gift" and l[2].k == "catch", "a gift counts as its area's encounter")
-- a traded-in POKeMON (someone else's ID) is not a gift
gA.party[3] = mon(12, 555, 30)
clockT = clockT + 1
A:tick(true, false)
T.eq(#SL.log(A.run, A.tid), 2, "a POKeMON with another trainer's ID is not a gift")

-- a wild encounter in a new area that gets away
gA.sec = 17
wild(A, 10)
T.check(lastToast(ioA):find("SP10 is your AREA17 encounter", 1, true), "the area's encounter is announced")
A:onBattleEnded({})
T.eq(SL.derive(A.run, baseOf).mine.areas[17].state, "failed", "one that gets away is a missed encounter")
wild(A, 30)
T.check(A.battle.verdict == "blocked" and A:blockText() == nil, "the area is used; without enforcing, balls still work")
ioA.opts.enforce = true
T.check(A:blockText():find("already had", 1, true), "enforced, the bag refuses the ball")
A:onCaught({ mon = mon(13, 100, 30) })
A:onBattleEnded({})
local ex = SL.derive(A.run, baseOf).mine.extras
T.check(#ex == 1 and ex[1].why == "over", "a catch against the rules (some other way) is marked not allowed")
wild(A, 30, "wild", true)
T.eq(A:blockText(), nil, "a shiny is never refused")
A:onBattleEnded({})

-- a static in a new area, caught
gA.sec = 18
wild(A, 40, "static")
A:onCaught({ mon = mon(14, 100, 40, { nickname = "BOLT" }) })
A:onBattleEnded({})
local areas = SL.derive(A.run, baseOf).mine.areas
T.check(areas[18].state == "caught" and areas[18].h == "static", "a static counts as its area's encounter")
gA.party[4] = mon(14, 100, 40, { nickname = "BOLT" })

-- dupes: line 1 isn't caught in a link (the pre-run one doesn't count) but 20 is
gA.sec = 19
wild(A, 20)
T.eq(A.battle.why, "dupe", "a dupe of a caught line is refused")
A:onBattleEnded({})
T.eq(SL.derive(A.run, baseOf).mine.areas[19], nil, "and doesn't use up the area")

-- a reset in mid-encounter: the pending encounter is lost
gA.sec = 20
wild(A, 2)
local A2, ioA2 = newTracker(gA)
for k, val in pairs(ioA.store) do ioA2.store[k] = val end
A2:ensure()
T.eq(SL.derive(A2.run, baseOf).mine.areas[20].state, "failed", "reloading mid-encounter counts as missing it")

-- ------- two trackers sharing a run

local gB = newGame(200, "BRENDAN")
local B, ioB = newTracker(gB)
B:ensure()
local function deliver(from, to, isHost)
  local out = {}
  for i, f in ipairs(from.sent) do out[i] = f end
  for i = #from.sent, 1, -1 do from.sent[i] = nil end
  for _, f in ipairs(out) do
    local m = Protocol.validate(Protocol.sl(f))
    T.check(m ~= nil, nil)
    if m then to:onMessage(m, isHost) end
  end
end
-- the run on A is the host's; settle both sides' outboxes a few times
for i = #ioA2.sent, 1, -1 do ioA2.sent[i] = nil end
ioA2.opts.enforce = true
A2:onConnected()
B:onConnected()
for _ = 1, 3 do
  deliver(ioA2, B, false)
  deliver(ioB, A2, true)
end
T.eq(B.run.id, A2.run.id, "the joiner's run takes the host's id")
T.eq(#SL.log(B.run, A2.tid), #SL.log(A2.run, A2.tid), "the host's whole log reached the joiner")
T.check(B.run.rules.enforce == true, "and the joiner plays by the host's rules")

-- B catches in area 18 (A's static) -> linked
gB.sec = 18
wild(B, 10)
B:onCaught({ mon = mon(21, 200, 10) })
B:onBattleEnded({})
deliver(ioB, A2, true)
local pr
for _, row in ipairs(A2:view().pairs) do if row.a == 18 then pr = row end end
T.eq(pr and pr.status, "alive", "the two area-18 catches are linked on the host")
gB.party[1] = mon(21, 200, 10)

-- A's BOLT faints -> B's partner is gone, B is told
gA.party[4].hp = 0
clockT = clockT + 1
A2:tick(true, false)
deliver(ioA2, B, false)
T.check(B:view().dead["21:200"], "a faint in one game kills its link in the other")
T.check(lastToast(ioB):find("are gone", 1, true), "and the partner hears about it")

-- B's area 11 encounter while offline, synced later
B:onDisconnected()
for i = #ioB.sent, 1, -1 do ioB.sent[i] = nil end
gB.sec = 21
wild(B, 30)
B:onBattleEnded({})
T.eq(#ioB.sent, 0, "offline, nothing is sent")
B:onConnected()
deliver(ioB, A2, true)
T.eq(A2:view().theirs.areas[21].state, "failed", "the offline events reach the partner on reconnect")

-- autoconnect connects at the title screen, before the save (and run) loads
local gJ = { party = {}, storage = { boxes = { { mons = {} } } }, map = "M", sec = 16 }
local J, ioJ = newTracker(gJ)
local H, ioH = newTracker(newGame(300, "MAY"))
H:ensure()
H:onConnected()
J:onConnected()
T.eq(#ioJ.sent, 0, "at the title there is no run to share yet")
deliver(ioH, J, false)
T.eq(#ioJ.toasts, 0, "the host's early hello brings no 'turn SOUL LINK on' nag")
gJ.trainerId, gJ.name = 301, "BRENDAN"
clockT = clockT + 1
J:tick(false, false)
T.check(ioJ.sent[1] and ioJ.sent[1].hi, "once the save loads, the hello goes out")
for _ = 1, 3 do
  deliver(ioJ, H, true)
  deliver(ioH, J, false)
end
T.eq(H.run.partner and H.run.partner.tid, J.tid, "and the host links with the late joiner")
T.eq(J.run.partner and J.run.partner.tid, H.tid, "and the joiner with the host")

local pan = A2:panel()
T.eq(type(pan), "table", "the panel lists the run")
local found
for _, r in ipairs(pan.rows) do
  if r.area == "AREA18" then found = r end
end
T.check(found and found.mine.name == "BOLT" and found.mine.dead and found.status == "dead",
  "with nicknames and who is dead")
T.check(found and found.mine.s == 40 and found.theirs.s == 10, "and each side's species, for the icons")
T.eq(pan.partner, "BRENDAN", "the panel names the partner")

-- ------- hard rules

-- a fresh pair of games: C (host, hard rules) and D
local function storageFor(g)
  return {
    openSlot = function(s)
      for b, bx in ipairs(s.storage.boxes) do
        for sl = 1, (bx.size or 30) do if not bx.mons[sl] then return b, sl end end
      end
    end,
    move = function(s, i, b, sl)
      local m = s.party[i]
      local other = s.storage.boxes[b].mons[sl]
      s.storage.boxes[b].mons[sl] = m
      if other then s.party[i] = other else table.remove(s.party, i) end
      return true
    end,
  }
end
local gC = newGame(300, "RED")
local C, ioC = newTracker(gC, { hard = true })
C.d.storage = storageFor(gC)
C:ensure()
T.check(C:enforcing(), "hard rules enforce the catch limits too")
gC.sec = 30
wild(C, 10)
C:onCaught({ mon = mon(31, 300, 10) })
C:onBattleEnded({})
gC.party[1] = mon(31, 300, 10)
gC.sec = 31
wild(C, 20)
C:onCaught({ mon = mon(32, 300, 20) })
C:onBattleEnded({})
gC.party[2] = mon(32, 300, 20)
T.eq(C:isBanned(gC.party[1]), false, "a living catch may battle")

-- a faint in the middle of a battle is recorded at once
C:onBattleStarted({ kind = "trainer" })
C:onFainted({ sideName = "enemy", battler = { side = "enemy", mon = mon(31, 300, 10) } })
T.eq(C:view().dead["31:300"], nil, "the other side's faints are not ours")
C:onFainted({ sideName = "player", battler = { side = "player", mon = gC.party[1] } })
T.check(C:view().dead["31:300"], "our POKeMON fainting in a trainer battle is recorded as it happens")
T.check(C:isBanned(gC.party[1]), "and under hard rules it can't battle any more")
gC.party[1].hp = 0
C:onBattleEnded({})
local faints = 0
for _, ev in ipairs(SL.log(C.run, C.tid)) do if ev.k == "faint" then faints = faints + 1 end end
T.eq(faints, 1, "and only once")

-- a co-op link battle is played with copies
C:onBattleStarted({ kind = "link" })
C:onFainted({ sideName = "player", battler = { side = "player", mon = gC.party[2] } })
gC.party[2].hp = 0
C:onBattleEnded({})
T.eq(C:view().dead["32:300"], nil, "faints in a co-op link battle don't count")
gC.party[2].hp = 20

-- the field is free: the dead one goes to the PC
gC.party[1].hp = 30   -- healed at a POKeMON CENTER
clockT = clockT + 1
C:tick(true, false, true)
T.eq(#gC.party, 1, "the dead POKeMON left the party")
T.eq(gC.storage.boxes[1].mons[1].personality, 31, "and is in the PC")
T.check(lastToast(ioC):find("Sent to the PC", 1, true), "the player is told")
-- withdrawn again: back it goes
gC.party[2] = gC.storage.boxes[1].mons[1]
gC.storage.boxes[1].mons[1] = nil
clockT = clockT + 1
C:tick(true, false, false)
T.eq(#gC.party, 2, "nothing moves while a menu has the field")
clockT = clockT + 1
C:tick(true, false, true)
T.eq(#gC.party, 1, "a dead POKeMON taken out of the PC goes straight back")

-- the last one standing dies: a living box mon takes its place
gC.storage.boxes[1].mons[2] = mon(33, 999, 40)   -- traded in: not a run catch
C:onBattleStarted({ kind = "trainer" })
C:onFainted({ sideName = "player", battler = { side = "player", mon = gC.party[1] } })
C:onBattleEnded({})
clockT = clockT + 1
C:tick(true, false, true)
T.eq(gC.party[1] and gC.party[1].personality, 33, "the last fighter is swapped for a living one from the PC")
T.check(lastToast(ioC):find("came out of the PC", 1, true), "and the player is told which")
T.eq(C.over, false, "the run goes on")
-- and when nothing living is left, the run is over
gC.storage.boxes[1].mons[2] = mon(32, 300, 20)
gC.party[1] = mon(34, 300, 30)
C:_append({ k = "catch", a = 40, s = 30, u = "34:300", x = "over" })
clockT = clockT + 1
C:tick(true, false, true)
T.eq(#gC.party, 1, "the party is never left empty")
T.eq(C.over, true, "with nothing that may battle, the run is over")
T.check(lastToast(ioC):find("no POKeMON left that can battle", 1, true), "and says so")
T.check(C:panel().over, "the panel shows it")
T.check(C:isBanned(gC.party[1]), "a catch against the rules can't battle under hard rules")

-- without hard rules nothing is moved and revives work
local gE = newGame(400, "LEAF")
local E = newTracker(gE)
E.d.storage = storageFor(gE)
E:ensure()
gE.sec = 50
wild(E, 10)
E:onCaught({ mon = mon(41, 400, 10) })
E:onBattleEnded({})
gE.party[1] = mon(41, 400, 10)
gE.party[2] = mon(42, 400, 20)
E:_append({ k = "faint", u = "41:400" })
clockT = clockT + 1
E:tick(true, false, true)
T.eq(#gE.party, 2, "without hard rules the dead stay where they are")
T.eq(E:isBanned(gE.party[1]), false, "and may be revived")

-- the hard rule travels with the host's rules
local hardMsg = Protocol.validate(Protocol.sl({ run = "r", tid = "1-A", nm = "A", from = 1, want = 1,
  rules = SL.copyRules({ hard = true }), ev = {} }))
T.check(hardMsg and hardMsg.rules.hard == true, "the hard rule crosses the wire")

-- ------- level caps

local LevelCap = lib("levelcap")
local LIST = {
  { label = "RIVAL", names = { "R_A", "R_B" } },
  { label = "GYM1", names = { "G1" } },
  { label = "OPTIONAL", names = { "OPT" } },
  { label = "GYM2", names = { "G2" } },
  { label = "WEAK", names = { "W" } },
  { label = "MISSING", names = { "NOPE" } },
  { label = "CHAMP", names = { "C" } },
}
local IDS = { R_A = 1, R_B = 2, G1 = 3, OPT = 4, G2 = 5, W = 6, C = 7 }
local ACE = { [1] = 5, [2] = 6, [3] = 15, [4] = 20, [5] = 25, [6] = 18, [7] = 50 }
local won = {}
local function capNow()
  return LevelCap.compute(LIST, function(n) return IDS[n] end, function(id) return won[id] == true end,
    function(id) return ACE[id] end)
end
local c = capNow()
T.check(c.cap == 6 and c.label == "RIVAL", "the first cap is the rival's ace (the higher of the variants)")
won[2] = true
T.check(capNow().cap == 15 and capNow().label == "GYM1", "beating the rival moves the cap to the first gym's ace")
won[3] = true
T.eq(capNow().label, "OPTIONAL", "then the next fight in story order")
won[5] = true
T.eq(capNow().label, "WEAK", "a skipped fight stops counting once a later boss falls")
T.eq(capNow().cap, 25, "and the cap never goes down below an ace already beaten")
won[6] = true
T.eq(capNow().label, "CHAMP", "fights this game doesn't have are skipped")
won[7] = true
T.eq(capNow().cap, nil, "after the last fight there is no cap")
local function expAt(l) return l * l * l end
T.eq(LevelCap.clampExp(14, expAt(14) + 10, 5000, 15, expAt), expAt(15) - expAt(14) - 10,
  "EXP below the cap only reaches the cap's level")
T.eq(LevelCap.clampExp(15, expAt(15), 5000, 15, expAt), 0, "at the cap a POKeMON gains nothing")
T.eq(LevelCap.clampExp(15, expAt(15), 5000, nil, expAt), 5000, "without a cap, everything")

local Constants = require("src.core.game3.constants")
for _, g in ipairs({ { "emerald", LevelCap.EMERALD }, { "ruby", LevelCap.RUBY }, { "firered", LevelCap.FIRERED } }) do
  local C = Constants.of(g[1])
  local missing = {}
  for _, m in ipairs(g[2]) do
    for _, n in ipairs(m.names) do
      if not C:id("trainers", n) then missing[#missing + 1] = n end
    end
  end
  T.eq(table.concat(missing, ","), "", "every " .. g[1] .. " big fight is a real trainer")
end
T.eq(LevelCap.listFor("leafgreen"), LevelCap.FIRERED, "LeafGreen uses the Kanto list")
T.eq(LevelCap.listFor("sapphire"), LevelCap.RUBY, "Sapphire the Ruby one")
local capsMsg = Protocol.validate(Protocol.sl({ run = "r", tid = "1-A", nm = "A", from = 1, want = 1,
  rules = SL.copyRules({ caps = true }), ev = {} }))
T.check(capsMsg and capsMsg.rules.caps == true, "level caps travel with the host's rules")

-- ------- shared wild doubles and team battles (co-op 0.8)
do
  local gW = newGame(500, "MAY")
  gW.sec = 40
  local W, ioW = newTracker(gW)
  W:ensure()
  local function coopWild(a, b)
    W:onBattleStarted({ kind = "coopwild", battle = { foeParty = { { species = a }, { species = b } } } })
  end
  local function events(kind)
    local n = 0
    for _, e in ipairs(SL.log(W.run, W.tid)) do if e.k == kind then n = n + 1 end end
    return n
  end
  coopWild(60, 61)
  T.eq(events("enc"), 1, "a shared wild double is this player's encounter")
  T.check(lastToast(ioW):find("Catch either one", 1, true), "and says either foe will do")
  gW.party[1] = mon(501, 500, 61)
  W:onCaught({ mon = gW.party[1] })
  local log = SL.log(W.run, W.tid)
  T.eq(log[#log].k, "catch", "catching the second foe is the encounter's catch")
  T.eq(log[#log].s, 61, "recorded as the species actually caught")
  T.eq(log[#log].x, nil, "and allowed")
  gW.party[2] = mon(502, 500, 60)
  W:onCaught({ mon = gW.party[2] })
  log = SL.log(W.run, W.tid)
  T.eq(log[#log].x, "over", "catching both foes: the second is not allowed")
  W:onBattleEnded({})
  T.eq(events("miss"), 0, "a caught encounter is no miss")

  coopWild(70, 71)
  T.check(lastToast(ioW):find("already had", 1, true), "a used area stays used in a shared battle")
  W:onBattleEnded({})

  gW.sec = 41
  coopWild(61, 72)          -- 61's line is caught: 72 is the only one that counts
  T.eq(events("enc"), 2, "one foe a dupe, the other still counts")
  gW.party[3] = mon(503, 500, 61)
  W:onCaught({ mon = gW.party[3] })
  log = SL.log(W.run, W.tid)
  T.eq(log[#log].x, "over", "catching the dupe of the two is against the rules")
  W:onBattleEnded({})

  gW.sec = 42
  coopWild(80, 81)
  W:onBattleEnded({})
  T.eq(events("miss"), 1, "an eligible shared encounter that escapes is a miss")

  W:onBattleStarted({ kind = "coopteam" })
  local before = #SL.log(W.run, W.tid)
  W:onFainted({ sideName = "player", battlerId = 2, battle = { linkOwn = 0 },
                battler = { side = "player", mon = gW.party[1] } })
  T.eq(#SL.log(W.run, W.tid), before, "a team battle's partner-side faint is the partner's to record")
  W:onFainted({ sideName = "player", battlerId = 0, battle = { linkOwn = 0 },
                battler = { side = "player", mon = gW.party[1] } })
  log = SL.log(W.run, W.tid)
  T.eq(log[#log].k, "faint", "our own faint in a team battle is real")
  W:onBattleEnded({})
end

T.finish("g3_coop soul link")
