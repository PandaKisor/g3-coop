-- Headless suite for g3_coop.  Run from an engine checkout so src.* resolves:
--   cd Gen3Mod/dev-engine && luajit ../coop/tests/run.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local coop = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
local here = coop .. "/g3_coop"
local function lib(name) return dofile(here .. "/lib/" .. name .. ".lua") end

local T = require("tests.modkit")
local Protocol = lib("protocol")
local Presence = lib("presence")
local Ghost = lib("ghost")
local Session = lib("session")

-- ------- protocol

local function posMsg(over)
  local m = { type = "coop_pos", s = 1, m = "MAP_ROUTE101", x = 5, y = 6, d = "up",
              mv = false, g = 0, e = 3 }
  for k, v in pairs(over or {}) do m[k] = v end
  return m
end

T.check(Protocol.validate(posMsg()) ~= nil, "a resting pos validates")
T.check(Protocol.validate(posMsg({ mv = true, tx = 5, ty = 5, f = 16 })) ~= nil,
  "a one-cell step validates")
T.check(Protocol.validate(posMsg({ mv = true, tx = 5, ty = 4, f = 32 })) ~= nil,
  "a two-cell ledge jump validates")
T.eq(Protocol.validate(posMsg({ mv = true, tx = 9, ty = 6, f = 16 })), nil,
  "a four-cell 'step' is refused")
T.eq(Protocol.validate(posMsg({ mv = true, tx = 5, ty = 5 })), nil, "a step needs frames")
T.eq(Protocol.validate(posMsg({ x = 5.5 })), nil, "fractional coordinates are refused")
T.eq(Protocol.validate(posMsg({ x = 99999 })), nil, "out-of-range coordinates are refused")
T.eq(Protocol.validate(posMsg({ m = "../../etc" })), nil, "map ids are identifiers only")
T.eq(Protocol.validate(posMsg({ m = string.rep("A", 65) })), nil, "map ids are length-capped")
T.eq(Protocol.validate(posMsg({ d = "north" })), nil, "unknown directions are refused")
T.eq(Protocol.validate(posMsg({ g = "0" })), nil, "string numbers are refused")
T.eq(Protocol.validate({ type = "coop_eval", code = "os.exit()" }), nil, "unknown types drop")
T.eq(Protocol.validate("coop_pos"), nil, "non-tables drop")
local extra = Protocol.validate(posMsg({ evil = function() end }))
T.eq(extra.evil, nil, "validated messages are copies without unknown fields")
local hello = Protocol.validate({ type = "coop_hello", v = Protocol.VERSION, name = "MAY\0<x>",
                                  game = "emerald", link = {} })
T.eq(hello.name, "MAY??x?", "names are filtered to printable characters")
T.check(Protocol.validate({ type = "coop_emote", e = "wave" }) ~= nil, "a wave validates")
T.eq(Protocol.validate({ type = "coop_emote", e = "dance" }), nil, "unknown emotes are refused")
local _, why = Protocol.validate({ type = "coop_hello", v = Protocol.VERSION + 1, name = "A", game = "emerald", link = {} })
T.eq(why, "protocol_version", "a newer protocol is named as such")
T.eq(Protocol.validate(posMsg({ sf = true })).sf, true, "a surfing partner says so")
T.eq(Protocol.validate(posMsg({ sf = "yes" })).sf, false, "anything but true is not surfing")

-- team battle setups: plain data through JSON and back, intact
do
  local Json = require("src.link.Json")
  local mon = { species = 559, level = 6, moves = { 336, 33 }, pp = { [1] = 20, [3] = 5 },
                ivs = { hp = 31, atk = 0 }, nickname = "", isEgg = false, personality = 4294967295,
                fn = function() end }
  local wire = Json.decode(Json.encode(Protocol.team(3, Protocol.packTree({ name = "MAY", party = { mon } }))))
  local msg = Protocol.validate(wire)
  T.check(msg ~= nil, "a team setup survives JSON and validates")
  local back = msg and msg.d.party[1]
  T.eq(back and back.species, 559, "an expanded species survives")
  T.eq(back and back.moves[1], 336, "moves survive")
  T.eq(back and back.pp[3], 5, "a sparse number-keyed table keeps its keys")
  T.eq(back and back.pp[2], nil, "and its holes")
  T.eq(back and back.isEgg, false, "false survives")
  T.eq(back and back.fn, nil, "functions are dropped")
  T.eq(back and back.personality, 4294967295, "32-bit values survive")
  T.eq(Protocol.validate({ type = "coop_team", c = 3, d = { party = {} } }), nil, "raw tables are refused")
  local deep = {}
  local cur = deep
  for _ = 1, 20 do cur.x = {}; cur = cur.x end
  local packed = Protocol.packTree(deep)
  local _, whyDeep = Protocol.unpackTree({ ["~"] = { { "x", { ["~"] = { { "x", packed } } } } } })
  T.check(whyDeep ~= nil, "too-deep trees are refused")
  T.eq(Protocol.validate({ type = "coop_team", c = 3,
    d = { ["~"] = { { "name", string.rep("A", 300) } } } }), nil, "long strings are refused")
  T.eq(Protocol.validate({ type = "coop_ask", id = 5, act = "team" }).act, "team", "a team request validates")
end

-- ------- CO-OP > ADDRESS
do
  local ConnEdit = lib("connedit")
  local ed = ConnEdit.new({ address = "192.168.4.32:7791", onload = "JOIN" })
  T.eq(ed:address(), "192.168.4.32", "an address with a port splits")
  T.eq(ed.port, 7791, "and keeps its port")
  T.eq(ed.onload, "JOIN", "on-load choice is read back")
  local fresh = ConnEdit.new({ address = "not an ip", port = 7777 })
  T.eq(fresh:address(), "127.0.0.1", "a bad address falls back to this PC")
  ed:press("down")
  T.eq(ed.ip[1], 191, "DOWN lowers the selected number")
  ed:press("1"); ed:press("0")
  T.eq(ed.ip[1], 10, "typing replaces the number")
  ed:press("9"); ed:press("9")
  T.eq(ed.ip[1], 9, "typing past 255 starts over")
  ed:press("left")
  T.eq(ed.cursor, 6, "LEFT from the first field wraps to on-load")
  ed:press("up")
  T.eq(ed.onload, "OFF", "UP cycles on-load")
  ed:press("right"); ed:press("down")
  T.eq(ed.ip[1], 8, "fields wrap the other way too")
  ed.cursor = 4
  ed:press("up10"); ed:press("up10"); ed:press("up10")
  T.eq(ed.ip[4], 62, "L/R move by ten")
  ed.ip[4] = 0
  ed:press("down")
  T.eq(ed.ip[4], 255, "numbers wrap")
  ed.cursor = 5
  ed:press("back"); ed:press("back"); ed:press("back")
  T.eq(ed.port, 7, "backspace drops digits")
  T.eq(ed:result().port, 1024, "a short port is pulled up to the minimum")
  T.eq(ed:press("confirm"), "save", "A saves")
  T.eq(ed:press("cancel"), "cancel", "B cancels")
end

-- ------- whole-mon trades
do
  local TradeFull = lib("tradefull")
  local full = { species = 559, personality = 2280996672, otId = 37734, otSecretId = 54514,
                 moves = { 574, 43 }, nature = 3, abilityNum = 2 }
  local packed = { species = 559, personality = 2280996672, otId = 37734, otSecretId = 54514, moves = { { id = 574 } } }
  T.eq(TradeFull.key(full), TradeFull.key(packed), "a mon and its Gen 3 packet share a key")
  T.eq(TradeFull.key({ personality = 5, otId = 54514 * 65536 + 37734 }), TradeFull.key({ personality = 5, otId = 37734, otSecretId = 54514 }),
    "a 32-bit trainer id keys like the split one")
  local LT = { unpackMon = function() return "vanilla" end }
  local undo = TradeFull.install(LT, TradeFull.lookup({ tradeParty = {} }, { tradeParty = { full } }))
  local got = LT.unpackMon(packed)
  T.eq(got and got.moves[1], 574, "a known mon comes back whole")
  T.eq(got and got.abilityNum, 2, "with the fields Gen 3 can't carry")
  T.check(got ~= full, "as a copy")
  T.eq(LT.unpackMon({ personality = 1, otId = 2 }), "vanilla", "an unknown mon goes to the engine")
  undo()
  T.eq(LT.unpackMon(packed), "vanilla", "uninstall puts the engine's unpack back")
end
do
  local TradeFull = lib("tradefull")
  local full = { species = 559, personality = 7, otId = 1, otSecretId = 2, level = 8, hp = 3, maxHp = 24,
                 moves = { 574, 43 }, pp = { 1, 1 }, status = "psn" }
  local packet = { species = 559, personality = 7, otId = 1, otSecretId = 2, hp = 24, status = "",
                   moves = { { id = 574, pp = 10 }, { id = 43, pp = 30 } } }
  local LB = { unpackParty = function() return "vanilla" end, unpackOpts = function() return {} end }
  local E = { Pokemon = { applyStats = function(m) m.maxHp = 100 end, growthRate = function() return 0 end },
              SummaryData = { expForLevel = function(_, l) return l * 1000 end } }
  local undo = TradeFull.installBattle(LB, TradeFull.lookup({ tradeParty = { full } }, nil), E)
  local got = LB.unpackParty({ packet })
  T.eq(got and got[1].moves[1], 574, "battle parties come back whole")
  T.eq(got and got[1].hp, 24, "with the packet's (healed) HP")
  T.eq(got and got[1].status, nil, "and status")
  T.eq(got and got[1].pp[2], 30, "and PP")
  got = LB.unpackParty({ packet }, { forceLevel = 50 })
  T.eq(got and got[1].level, 50, "a forced level applies")
  T.eq(got and got[1].exp, 50000, "with its EXP")
  T.eq(got and got[1].hp, 100, "and stats worked out again")
  T.eq(LB.unpackParty({ packet, { personality = 99 } }), "vanilla", "one unknown mon sends the party to the engine")
  undo()
  T.eq(LB.unpackParty({ packet }), "vanilla", "uninstall restores the engine's")
end

-- ------- three-faint limit
do
  local Team = lib("teambattle")
  local st = { coopTeam = true, eliminated = {} }
  local counts = {}
  local function faint(id) return Team.onFainted(counts, { battle = st, battlerId = id }) end
  T.eq(faint(0), false, "a first faint doesn't eliminate")
  faint(2); faint(0)
  T.eq(st.eliminated[0], nil, "two faints don't either")
  T.eq(faint(1), false, "foe faints don't count")
  T.eq(faint(0), true, "the third faint of an owner eliminates them")
  T.eq(st.eliminated[0], true, "and marks the battle")
  T.eq(st.eliminated[2], nil, "the partner is still in")
  T.eq(faint(0), false, "an owner is only eliminated once")
  T.eq(Team.onFainted({}, { battle = { eliminated = {} }, battlerId = 0 }), false, "only in a co-op team battle")
end

-- ------- a request's fallback (shared wild encounters)
do
  local Requests = lib("requests")
  local P = Protocol
  local t, sent, waitCancel = 0, {}, nil
  local sess = { state = "connected", P = P, peer = { name = "MAY" },
    ask = function(_, id, act) sent[#sent + 1] = { "ask", id, act } end,
    answer = function(_, id, ok) sent[#sent + 1] = { "answer", id, ok } end,
    cancelAsk = function(_, id) sent[#sent + 1] = { "cancel", id } end,
    takeRequests = function(self) local l = self.q or {}; self.q = {}; return l end }
  local ui = { menu = function() end, ask = function() end, close = function() end, toast = function() end,
               wait = function(_, cb) waitCancel = cb end }
  local started
  local R = Requests.new({ session = function() return sess end, now = function() return t end, firstId = 1, ui = ui,
    canPrompt = function() return true end, eligible = function() return true end,
    wave = function() end, start = function(act) started = act end })
  local alone = 0
  local function fallback() alone = alone + 1 end
  T.check(R:request("wild", fallback), "a wild request goes out")
  sess.q = { { type = P.ANSWER, id = 1, ok = false, why = "no" } }
  R:tick()
  T.eq(alone, 1, "a no plays the encounter alone")
  T.check(R:request("wild", fallback), "another")
  t = t + Requests.ANSWER_SECONDS_FOR.wild + 1
  R:tick()
  T.eq(alone, 2, "no answer within the wild timeout plays it alone")
  T.check(R:request("wild", fallback), "another")
  waitCancel()
  T.eq(alone, 3, "B to cancel plays it alone")
  T.check(R:request("wild", fallback), "another")
  R:reset()
  T.eq(alone, 4, "a dropped connection plays it alone")
  T.check(R:request("wild", fallback), "another")
  sess.q = { { type = P.ANSWER, id = 9, ok = true } }
  R:tick()
  T.eq(started, "wild", "a yes starts the shared battle")
  T.eq(alone, 4, "and nothing plays alone")
  -- trainer fights: the ask carries the trainer(s); a joint fight is joined
  -- without a prompt
  local ask = Protocol.validate(Protocol.ask(5, "trainer", { 60616 }))
  T.eq(ask and ask.t and ask.t[1], 60616, "a trainer fight's ask carries the trainer")
  T.eq(Protocol.validate(Protocol.ask(5, "trainer", { 1, 2, 3 })), nil, "at most a pair")
  T.eq(Protocol.validate(Protocol.ask(5, "trainer", { "x" })), nil, "trainer ids are numbers")
  local startedWith
  local R2 = Requests.new({ session = function() return sess end, now = function() return t end, firstId = 2, ui = ui,
    canPrompt = function() return true end, eligible = function() return true end,
    wave = function() end, start = function(act, _, tt) startedWith = { act, tt } end })
  sent = {}
  sess.q = { { type = P.ASK, id = 11, act = "joint", t = { 265 } } }
  R2:tick()
  T.eq(startedWith and startedWith[1], "joint", "a joint fight starts without asking")
  T.eq(startedWith and startedWith[2][1], 265, "against the trainer it named")
end

-- ------- shared trainer credit
do
  local Credit = lib("credit")
  T.check(Credit.isStoryClass("LEADER"), "gym leaders are joint fights")
  T.check(Credit.isStoryClass("Aqua Admin"), "admins too, any case")
  T.check(Credit.isStoryClass("PKMN TRAINER"), "and the rival's class")
  T.check(not Credit.isStoryClass("Youngster"), "route trainers are not")
  T.check(not Credit.isStoryClass(nil), "nor an unknown class")
  local store
  local c = Credit.new({ read = function() return store end, write = function(v) store = v end })
  T.eq(c:add(60319), true, "a new credit is recorded")
  T.eq(c:add(60319), false, "once")
  T.eq(c:add(0), false, "ids are positive")
  T.eq(c:add(1.5), false, "and whole")
  for i = 1, 600 do c:add(1000 + i) end
  local chunks = c:chunks(512)
  T.eq(#chunks, 2, "the list goes across in message-sized pieces")
  T.eq(#chunks[1] + #chunks[2], 601, "all of it")
  local msg = Protocol.validate(Protocol.credit(chunks[1], false))
  T.check(msg and #msg.ids == 512, "a full piece validates")
  T.eq(Protocol.validate({ type = "coop_credit", ids = { 1, "2" } }), nil, "string ids are refused")
  T.eq(Protocol.validate(Protocol.credit({ 60319 }, true)).fresh, true, "a fresh win says so")
  T.eq(Protocol.validate(Protocol.credit({ 60319 }, false, true)).joint, true, "a joint win says so")
  T.eq(Protocol.validate(Protocol.credit({ 60319 }, false)).joint, false, "an ordinary credit isn't joint")
  local Team = lib("teambattle")
  local paid
  local E = { Prize = { calcRse = function(id) return id == 1 and 100 or 250 end,
                        apply = function(_, amount) paid = amount; return amount end } }
  T.eq(Team.prize(E, {}, { { trainerId = 1 }, { trainerId = 2 } }), 350, "each player gets both trainers' prizes")
  T.eq(paid, 350, "paid in full")
  T.eq(Team.prize(E, {}, { { name = "" }, { name = "" } }), 0, "wild foes pay nothing")
  local receipts = {}
  T.eq(Team.settlePrize(E, {}, { 1, 2 }, receipts), 350, "a team win settles both prizes")
  T.eq(Team.settlePrize(E, {}, { 2 }, receipts), 0, "a later joint credit for the same win pays nothing")
  T.eq(#receipts, 2, "receipts for both")
  T.eq(Team.settlePrize(E, {}, { 1, 1 }, {}), 100, "an id twice in one call pays once")
  local st = { coopTeam = true, eliminated = {}, coopSolo = true }
  T.eq(Team.onFainted({}, { battle = st, battlerId = 0 }), false, "no faint limit once alone")
  -- Steven's multi lends his mons into the party; the partner replaces him
  local side = Team.mySide({ LB = { eligible = function() return true end } },
    { name = "MAY", trainerId = 1, party = { { species = 1 }, { species = 2 }, { species = 3, stevenPartner = true } } })
  T.eq(#side.party, 2, "a story partner's lent POKeMON stay out of the team")
  T.eq(side.slots[2], 2, "own POKeMON keep their party slots")
end

-- ------- presence

local player = { cellX = 3, cellY = 4, facing = "down", moving = false, elevation = 3, visible = true }
local pres = Presence.new()
local seq = pres:tick(Presence.sample(player, "MAP_A", 0))
T.eq(seq, 1, "the first sample is sent")
T.eq(pres:tick(Presence.sample(player, "MAP_A", 0)), nil, "an unchanged sample is not resent")
player.moving, player.targetX, player.targetY, player.stepFrames = true, 3, 5, 16
local _, snap = pres:tick(Presence.sample(player, "MAP_A", 0))
T.check(snap and snap.mv and snap.ty == 5 and snap.f == 16, "a step start is announced with its target")
for _ = 1, Presence.HEARTBEAT_TICKS - 1 do T.eq(pres:tick(Presence.sample(player, "MAP_A", 0)), nil, nil) end
T.check(pres:tick(Presence.sample(player, "MAP_A", 0)) ~= nil, "a heartbeat resends after a second")
T.eq(pres:tick(Presence.sample(player, nil, 0)), nil, "no map, no message")

-- ------- ghost

local function v(m) return assert(Protocol.validate(m)) end

local g = Ghost.new()
g:apply(v(posMsg({ x = 5, y = 6 })))
T.check(g.known and g.cellX == 5 and g.cellY == 6 and not g.moving, "first sight places the ghost")
g:apply(v(posMsg({ s = 2, mv = true, x = 5, y = 6, tx = 5, ty = 5, f = 16 })))
g:tick()
T.check(g.moving and g.py < 6 * 16 and g.py > 5 * 16, "the ghost walks the announced step")
g:apply(v(posMsg({ s = 3, mv = true, x = 5, y = 6, tx = 5, ty = 5, f = 16 })))
T.eq(#g.queue, 0, "a heartbeat repeating the current step is not queued again")
g:apply(v(posMsg({ s = 4, mv = true, x = 5, y = 5, tx = 5, ty = 4, f = 16 })))
for _ = 1, 15 do g:tick() end
T.check(g.cellX == 5 and g.cellY == 5 and g.moving and g.targetY == 4,
  "the next step starts on the tick the first one lands")
for _ = 1, 16 do g:tick() end
T.check(g.cellY == 4 and not g.moving, "both steps land")
g:apply(v(posMsg({ s = 5, x = 5, y = 4, d = "left" })))
g:tick()
T.eq(g.facing, "left", "a rest turns the ghost in place")
g:apply(v(posMsg({ s = 6, m = "MAP_HOUSE", x = 2, y = 9 })))
T.check(g.map == "MAP_HOUSE" and g.cellX == 2 and g.cellY == 9 and not g.moving,
  "a map change snaps instead of walking")
for i = 1, 6 do
  g:apply(v(posMsg({ s = 6 + i, m = "MAP_HOUSE", mv = true, x = 2, y = 9 - i + 1, tx = 2, ty = 9 - i, f = 16 })))
end
T.check(#g.queue <= Ghost.MAX_QUEUE and g.cellY == 6, "a long backlog snaps forward instead of replaying")

-- draw entries, in the local screen's cells
local offsets = { MAP_A = { 0, 0 }, MAP_NORTH = { 0, -20 } }
local function offsetOf(id) local o = offsets[id] if o then return o[1], o[2] end end
local function spriteFor(gid) return "SPRITE_" .. tostring(gid) end
local rg = Ghost.new()
rg:apply(v(posMsg({ m = "MAP_A", x = 4, y = 4, g = 7 })), offsetOf)
rg:apply(v(posMsg({ s = 2, m = "MAP_A", mv = true, x = 4, y = 4, tx = 5, ty = 4, f = 16, g = 7, d = "right" })), offsetOf)
rg:tick()
local rec = rg:drawInto({}, offsetOf, spriteFor)
T.check(rec and rec.virtualId == Ghost.VOBJ_ID and rec.graphicsId == 7 and rec.sprite == "SPRITE_7",
  "the partner becomes a draw entry with its sprite")
T.check(rec and rec.moving and rec.px > 64 and rec.facing == "right" and rec.cellX == 4,
  "with its in-flight pixel position and facing")
local x, y = rg:screenCell(offsetOf)
T.check(x == 5 and y == 4, "its screen cell is where it is stepping to")
T.eq(rg:drawInto({}, function() return nil end, spriteFor), nil, "nothing is drawn when its map is off screen")

-- a partner on a connected map north of ours is drawn shifted by the connection
local ng = Ghost.new()
ng:apply(v(posMsg({ m = "MAP_NORTH", x = 6, y = 18, g = 0 })), offsetOf)
local nrec = ng:drawInto({}, offsetOf, spriteFor)
T.check(nrec and nrec.cellX == 6 and nrec.cellY == -2, "a neighbour-map partner is placed by the connection offset")
-- ...and walking south across the seam carries on instead of snapping
ng:apply(v(posMsg({ s = 2, m = "MAP_NORTH", mv = true, x = 6, y = 19, tx = 6, ty = 20, f = 16, d = "down" })), offsetOf)
ng:tick()
local before = ng:drawInto({}, offsetOf, spriteFor).py
ng:apply(v(posMsg({ s = 3, m = "MAP_A", mv = true, x = 6, y = 0, tx = 6, ty = 1, f = 16, d = "down" })), offsetOf)
ng:tick()
local after = ng:drawInto({}, offsetOf, spriteFor)
T.eq(ng.map, "MAP_A", "the seam crossing moves the partner to our map")
T.check(after and after.py == before + 1, "without a jump: the step in flight keeps its pixel position")
for _ = 1, 40 do ng:tick() end
T.check(ng.cellX == 6 and ng.cellY == 1, "and both steps land on the far side")

-- surfing: the blob goes under the partner, on a neighbour map too
T.eq(ng:surfBlob(offsetOf), nil, "a walking partner gets no surf blob")
ng:apply(v(posMsg({ s = 4, m = "MAP_NORTH", x = 3, y = 18, sf = true, d = "left" })), offsetOf)
for _ = 1, 3 do ng:tick() end
local bx, by, bf = ng:surfBlob(offsetOf)
T.check(bx == 48 and by == -32 and bf == "left", "a surfing partner gets a blob at its pixel position")
ng:apply(v(posMsg({ s = 5, m = "MAP_NORTH", x = 3, y = 18, d = "left" })), offsetOf)
T.eq(ng:surfBlob(offsetOf), nil, "and loses it on landing")

-- the wave: two hops, then back on the ground
local hg = Ghost.new()
hg:apply(v(posMsg({ m = "MAP_A", x = 2, y = 2 })), offsetOf)
hg:wave()
local peak = 0
for _ = 1, Ghost.HOP_FRAMES * 2 do hg:tick() peak = math.min(peak, hg.raiseY) end
T.eq(peak, -Ghost.HOP_HEIGHT, "a wave hops the partner up")
hg:tick()
T.eq(hg.raiseY, 0, "and lands")
-- a two-cell step (ledge) arcs
hg:apply(v(posMsg({ s = 2, m = "MAP_A", mv = true, x = 2, y = 2, tx = 2, ty = 4, f = 32, d = "down" })), offsetOf)
local top = 0
for _ = 1, 32 do hg:tick() top = math.min(top, hg.raiseY) end
T.eq(top, -Ghost.JUMP_HEIGHT, "a ledge jump arcs over the ledge")

-- ------- NPCs: the host's wanderers lead, the joiner's follow

local Npcs = lib("npcs")
local function npcWorld()
  local O = { _order = {}, _byId = {}, _tracks = {} }
  local function add(lid, over)
    local eo = { localId = lid, cellX = 5, cellY = 5, facing = "down", movement = "WALK",
                 visible = true, moving = false }
    for k, val in pairs(over or {}) do eo[k] = val end
    O._order[#O._order + 1] = lid
    O._byId[lid] = eo
    return eo
  end
  -- the engine's pushStep: face and start a one-cell step
  O.pushStep = function(eo, dir, frames)
    local d = ({ up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } })[dir]
    if eo.moving or not d then return false end
    eo.facing, eo.moving = dir, true
    eo.targetX, eo.targetY, eo.stepFrames = eo.cellX + d[1], eo.cellY + d[2], frames
    return true
  end
  return O, add
end
local function land(eo) eo.cellX, eo.cellY, eo.moving = eo.targetX, eo.targetY, false end

local nt = 0
local HO, hadd = npcWorld()
local walker = hadd(1)
hadd(2, { sight = 3 })                         -- a trainer
hadd(3, { movement = "STAY" })                 -- stands still anyway
hadd(4, { movement = "LOOK_AROUND", hidden = true })
local leader = Npcs.new(function() return nt end)
local first = leader:collect(HO, "MAP_A")
T.eq(#first, 1, "the leader reports only plain wanderers (no trainers, no hidden or still NPCs)")
T.eq(first[1].id, 1, "the walker")
T.eq(#leader:collect(HO, "MAP_A"), 0, "and nothing while nothing changes")
walker.moving, walker.targetX, walker.targetY, walker.stepFrames, walker.facing = true, 6, 5, 16, "right"
local stepMsg = leader:collect(HO, "MAP_A")
T.check(#stepMsg == 1 and stepMsg[1].tx == 6 and stepMsg[1].f == 16, "a step start is reported with its target")
local wire = Protocol.validate(Protocol.npc("MAP_A", stepMsg))
T.check(wire and wire.n[1].tx == 6, "and passes the partner's validator")
T.eq(Protocol.validate(Protocol.npc("MAP_A", { { id = 1, x = 5, y = 5, d = "right", tx = 7, ty = 5, f = 16 } })), nil,
  "a two-cell NPC 'step' is refused")
T.eq(Protocol.validate(Protocol.npc("MAP_A", { { id = 300, x = 5, y = 5, d = "up" } })), nil,
  "NPC ids are capped")
local many = {}
for i = 1, Protocol.MAX_NPCS + 1 do many[i] = { id = 1, x = 1, y = 1, d = "up" } end
T.eq(Protocol.validate(Protocol.npc("MAP_A", many)), nil, "and so is the list")
walker.scriptBusy = true
land(walker)
T.eq(#leader:collect(HO, "MAP_A"), 0, "an NPC a script is moving is not reported")
walker.scriptBusy = nil
for _ = 1, Npcs.HEARTBEAT_TICKS do leader:collect(HO, "MAP_A") end
local beat
for _ = 1, Npcs.HEARTBEAT_TICKS do
  local l = leader:collect(HO, "MAP_A")
  if #l > 0 then beat = l end
end
T.check(beat and beat[1].x == 6, "a heartbeat repeats every wanderer")

local GO, gadd = npcWorld()
local copy = gadd(1)
local gtrainer = gadd(2, { sight = 3 })
local follower = Npcs.new(function() return nt end)
local mePlayerAt = { x = 9, y = 9 }
local function blockedAt(x, y) return x == mePlayerAt.x and y == mePlayerAt.y end
local function yes() return true end
follower:receive(GO, wire)
T.eq(copy.movement, "STAY", "the follower parks its copy so its own idle mover leaves it alone")
follower:update(GO, "MAP_A", yes, blockedAt)
T.check(copy.moving and copy.targetX == 6 and copy.facing == "right", "and walks the leader's step")
land(copy)
follower:receive(GO, Protocol.validate(Protocol.npc("MAP_A", { { id = 1, x = 3, y = 3, d = "up" }, { id = 2, x = 1, y = 1, d = "up" } })))
follower:update(GO, "MAP_A", yes, blockedAt)
T.check(copy.cellX == 3 and copy.cellY == 3 and copy.facing == "up", "a copy that drifted is put back where the leader has it")
T.check(gtrainer.cellX == 5 and gtrainer.movement == "WALK", "a local trainer is never touched")
follower:receive(GO, Protocol.validate(Protocol.npc("MAP_A", { { id = 1, x = 3, y = 3, d = "down" } })))
follower:update(GO, "MAP_A", function() return false end, blockedAt)
T.eq(copy.facing, "up", "nothing moves while a script or menu has our field (it keeps facing us)")
follower:update(GO, "MAP_A", yes, blockedAt)
T.eq(copy.facing, "down", "and catches up after")
mePlayerAt.x, mePlayerAt.y = 3, 4
follower:receive(GO, Protocol.validate(Protocol.npc("MAP_A", { { id = 1, x = 3, y = 3, d = "down", tx = 3, ty = 4, f = 16 } })))
follower:update(GO, "MAP_A", yes, blockedAt)
T.check(not copy.moving and copy.facing == "down", "a step onto our own player is not walked")
nt = nt + Npcs.RELEASE_SECONDS + 1
follower:update(GO, "MAP_A", yes, blockedAt)
T.eq(copy.movement, "WALK", "with no word from the leader for a while, the copy wanders on its own again")
follower:receive(GO, wire)
T.eq(copy.movement, "STAY", "parked again on the next report")
follower:update(GO, "MAP_B", yes, blockedAt)
T.eq(copy.movement, "WALK", "and given back when we change maps")
follower:receive(GO, wire)
copy.movement = "LOOK"                          -- a script set a new movement
follower:update(GO, "MAP_A", yes, blockedAt)
T.eq(copy.movement, "LOOK", "a script's own movement change wins over parking")
follower:receive(GO, wire)
follower:release()
T.eq(copy.movement, "LOOK", "released cleanly")

-- ------- session over the engine's loopback transport

local Net = require("src.link.Net")
local clock = 1000
local deps = { Protocol = Protocol, Presence = Presence, Ghost = Ghost,
               now = function() return clock end,
               compat = function(l, r)
                 if l.game ~= r.game then return false, "different_game" end
                 return true
               end }

local function pair(gameA, gameB)
  local a, b = Net.loopbackPair()
  local sa = Session.new(a, "host", Protocol.hello("BRENDAN", gameA, {}, ""), deps)
  local sb = Session.new(b, "join", Protocol.hello("MAY", gameB, {}, ""), deps)
  return sa, sb
end

local sa, sb = pair("emerald", "emerald")
local pa = { cellX = 10, cellY = 10, facing = "down", moving = false, elevation = 3 }
local pb = { cellX = 1, cellY = 1, facing = "up", moving = false, elevation = 3 }
for _ = 1, 3 do
  sa:tick(Presence.sample(pa, "MAP_ROUTE101", 0))
  sb:tick(Presence.sample(pb, "MAP_ROUTE101", 89))
end
T.eq(sa.state, "connected", "host connects")
T.eq(sb.state, "connected", "guest connects")
T.eq(sa.peer.name, "MAY", "host learns the guest's name")
T.check(sb.ghost.known and sb.ghost.cellX == 10, "the guest sees the host's position")
T.eq(sa.ghost.gfx, 89, "the host sees the guest's sprite")

pa.moving, pa.targetX, pa.targetY, pa.stepFrames = true, 11, 10, 8
sa:tick(Presence.sample(pa, "MAP_ROUTE101", 0))
sb:tick(Presence.sample(pb, "MAP_ROUTE101", 89))
T.check(sb.ghost.moving and sb.ghost.targetX == 11 and sb.ghost.frames == 8,
  "a running step crosses the wire with its speed")

sa:setBusy("battle")
sb:tick(Presence.sample(pb, "MAP_ROUTE101", 89))
T.eq(sb.peerBusy, "battle", "busy state reaches the partner")

sa:emote("wave")
sb:tick(Presence.sample(pb, "MAP_ROUTE101", 89))
T.check(sb.emotes == 1 and sb.lastEmote == "wave" and sb.ghost.hop > 0, "a wave reaches the partner and hops the ghost")

sb.net:send({ type = "coop_pos", s = 1, m = "X", x = 1e9, y = 0, d = "up", g = 0 })
sb.net:send({ type = "coop_pos", s = 1, m = "X", x = 1, y = 0, d = "up", g = 0, mv = true, tx = 50, ty = 0, f = 4 })
sa:tick(Presence.sample(pa, "MAP_ROUTE101", 0))
T.eq(sa.dropped, 2, "malformed partner messages are dropped and counted")
T.eq(sa.state, "connected", "without tearing down the session")

sb:close("left")
sa:tick(Presence.sample(pa, "MAP_ROUTE101", 0))
T.eq(sa.state, "closed", "the partner leaving closes the host's session")
T.eq(sa.reason, "partner_left", "with the reason")

local ra, rb = pair("emerald", "firered")
for _ = 1, 3 do ra:tick(nil); rb:tick(nil) end
T.eq(ra.state, "refused", "different games refuse")
T.check(ra.reason == "different_game" or rb.reason == "different_game", "and say why")

local sa2, sb2 = pair("emerald", "emerald")
sb2.net.send = function() end   -- a partner that pairs but never says hello
sa2:tick(nil)
clock = clock + Session.HANDSHAKE_SECONDS + 1
sa2:tick(nil)
T.eq(sa2.reason, "no_hello", "a silent partner times out of the handshake")
T.check(sa2.net.closed, "and the socket is closed, freeing the port")

-- the regression the real game showed: both players on the title screen
-- (no overworld, so no position updates) must stay connected
local sa3, sb3 = pair("emerald", "emerald")
for _ = 1, 3 do sa3:tick(nil); sb3:tick(nil) end
T.eq(sa3.state, "connected", "title-screen pair connects")
for _ = 1, 60 do
  clock = clock + 0.5
  sa3:tick(nil); sb3:tick(nil)
end
T.check(sa3.state == "connected" and sb3.state == "connected" and not sa3:stale() and not sb3:stale(),
  "30 seconds with no overworld on either side: keep-alives hold the connection")

-- timeouts are wall-clock: thousands of fast ticks in under a second are not 15 seconds
local sa4, sb4 = pair("emerald", "emerald")
for _ = 1, 3 do sa4:tick(nil); sb4:tick(nil) end
for _ = 1, 5000 do sa4:tick(nil) end   -- sb4 stops ticking (silent), but no time passes
T.eq(sa4.state, "connected", "a fast tick rate does not time a partner out")
clock = clock + Session.STALE_SECONDS + 0.5
sa4:tick(nil)
T.check(sa4:stale() and sa4.state == "connected", "real silence goes stale after 5 seconds")
clock = clock + Session.TIMEOUT_SECONDS
sa4:tick(nil)
T.eq(sa4.reason, "timeout", "and times out after 15")

-- ------- the mod itself, through the real loader on a Gen 3 boot

local Runtime = require("src.mods.Runtime")
local root = coop
-- the engine's story-trainer list (the port's coop_progress): Roxanne only
local realProgress = package.loaded["src.core.game3.coop_progress"]
package.loaded["src.core.game3.coop_progress"] = setmetatable({ story = function(id) return id == 265 end },
  { __index = realProgress })
local run = T.sdk.loadMod("g3_coop", { root = root, generation = 3, data = T.sdk.gen3Data() })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
T.check(Runtime.wantsHook("input.step"), "ticks on input.step")
T.check(Runtime.wantsHook("input.key"), "listens for F8")
T.check(Runtime.wantsHook("render.hud"), "draws a status line")

local exports = run.loader.exports.g3_coop
local consumed = Runtime.call("input.key", function() return "vanilla" end,
  { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(consumed, true, "F8 is consumed")
T.check(tostring(exports.status()):find("ENet", 1, true) ~= nil,
  "without ENet the status says so instead of crashing")
T.eq(Runtime.call("input.key", function() return "vanilla" end, {}, { phase = "pressed", key = "z" }),
  "vanilla", "other keys pass through")

-- two copies on one computer: the second HOST finds the port taken and
-- joins the first instead of failing
local Net = require("src.link.Net")
local realAvailable, realNew = Net.available, Net.new
local joined
Net.available = function() return true end
Net.new = function()
  return {
    paired = false, closed = false,
    host = function(self, port)
      self.error = ("can't open UDP port %d (Address already in use)"):format(port)
      return false
    end,
    join = function(self, addr) joined, self.target = addr, addr return true end,
    update = function() end, poll = function() return {} end,
    send = function() end, close = function(self) self.closed = true end,
  }
end
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(joined, "127.0.0.1:7777", "a taken host port falls back to joining this computer")
T.check(tostring(exports.status()):find("this PC", 1, true) ~= nil, "and the status line says so")
T.eq(exports.session() and exports.session().role, "join", "the session runs as the joiner")
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(exports.session(), nil, "F8 disconnects it again")
Net.new = function()
  return {
    host = function(self) self.error = "can't open UDP port 7777 (denied)" return false end,
    join = function(self) self.error = "no answer from\n127.0.0.1:7777" return false end,
  }
end
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(exports.status(), "CO-OP: can't open UDP port 7777 (denied)",
  "if the fallback also fails, the original hosting error is shown on one line")
-- both copies on one computer set to JOIN: the first finds the port free
-- and hosts; the second finds it taken and joins
local portTaken, hostedOn, joinedTo = false, nil, nil
Net.new = function()
  return {
    paired = false, closed = false, address = "192.168.4.32:7777",
    host = function(self, port)
      if portTaken then self.error = "can't open UDP port 7777 (taken)" return false end
      portTaken, hostedOn = true, port
      return true
    end,
    join = function(self, addr) joinedTo, self.target = addr, addr return true end,
    update = function() end, poll = function() return {} end,
    send = function() end, close = function(self) self.closed = true end,
  }
end
run.loader.modOptions.g3_coop = { role = "join", address = "127.0.0.1", port = 7777 }
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(hostedOn, 7777, "a JOIN to this PC with the port free hosts instead")
T.eq(exports.session().role, "host", "and runs as the host")
T.check(tostring(exports.status()):find("hosting on this PC", 1, true) ~= nil, "saying so on the status line")
-- the session's own disconnect frees nothing in this fake, so the port
-- stays taken, as it would be by the first window
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(joinedTo, "127.0.0.1:7777", "a JOIN to this PC with the port taken joins normally")
T.eq(exports.session().role, "join", "as the joiner")
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
run.loader.modOptions.g3_coop = { role = "join", address = "192.168.4.40", port = 7777 }
hostedOn, joinedTo, portTaken = nil, nil, false
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(hostedOn, nil, "a JOIN to another computer never hosts")
T.eq(joinedTo, "192.168.4.40:7777", "it just dials")
-- the joint-fight gate (user, 2026-10-25): a story fight waits for the
-- partner only while co-op is on; solo, it just starts
local function gate()
  local r = Runtime.call("trainer.joint_gate", function() return nil end, 265, "single", {})
  return type(r) == "table" and r.action or r
end
T.eq(gate(), "wait", "with co-op on and no partner here, Roxanne waits")
local box = Runtime.call("trainer.joint_gate", function() return nil end, 265, "single", {})
T.check(tostring(box and box.text):find("START > CO-OP", 1, true) ~= nil, "and the box says how to fight alone")
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(gate(), "allow", "with co-op off, Roxanne fights solo")
T.eq(Runtime.call("trainer.joint_gate", function() return nil end, 300, "single", {}).action, "allow",
  "an ordinary trainer is never gated")

-- leaving the game must close the socket, or the relaunched process
-- inherits a port nobody answers on
local Game3 = require("src.core.Game3")
local resetCalls, closedNets = 0, 0
local realReset = Game3._g3coopReset
Game3._g3coopReset = function() resetCalls = resetCalls + 1 end
local function liveNet()
  return {
    paired = false, closed = false, address = "x:7777",
    host = function() return true end,
    join = function(self, a) self.target = a return true end,
    update = function() end, poll = function() return {} end, send = function() end,
    close = function(self) self.closed = true closedNets = closedNets + 1 end,
  }
end
Net.new = liveNet
run.loader.modOptions.g3_coop = { role = "host", port = 7777 }
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.check(exports.session() ~= nil, "a session is open")
Game3.reset({})
T.eq(exports.session(), nil, "game:reset() (every exit route) closes the session")
T.eq(closedNets, 1, "and its socket")
T.eq(resetCalls, 1, "and still runs the engine's own reset")
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
local veto = Runtime.call("core.quit_to_launcher", function() return "vanilla answer" end)
T.eq(exports.session(), nil, "closing the window closes the session")
T.eq(veto, "vanilla answer", "without changing the engine's quit decision")
Game3._g3coopReset = realReset

-- a dead socket on the port: taken, but nothing answers
Net.new = function()
  return {
    paired = false, closed = false,
    host = function(self) self.error = "can't open UDP port 7777 (taken)" return false end,
    join = function(self, a) self.target = a return true end,
    update = function(self) self.closed, self.error = true, "no answer from\n" .. self.target end,
    poll = function() return {} end, send = function() end, close = function() end,
  }
end
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
Runtime.call("input.step", function() end, { phase = "boot" }, 1 / 60)
T.check(tostring(exports.status()):find("held by an old game process", 1, true) ~= nil,
  "a taken port that never answers is named as a stale process, not 'no answer'")
run.loader.modOptions.g3_coop = nil

-- the mod wraps Objects.forDraw once, so the stock renderer draws the partner
do
  local Objects = require("src.core.game3.objects")
  T.check(Objects._g3coopForDraw ~= nil, "the field draw list is wrapped")
  local saved = Objects._g3coopExtra
  local entry = { virtualId = Ghost.VOBJ_ID, cellX = -3, cellY = -3, visible = true }
  Objects._g3coopExtra = function() return entry end
  local found
  for _, a in ipairs(Objects.forDraw()) do if a == entry then found = true end end
  T.check(found, "the partner entry reaches the draw list even outside the active map")
  Objects._g3coopExtra = function() error("boom") end
  T.check(pcall(Objects.forDraw), "a failing partner entry never breaks the field draw")
  Objects._g3coopExtra = saved
end

-- the snapshot path through the real sandbox: engine modules must come from
-- require (the sandbox's package.loaded is an empty stub), and a connected
-- session in the overworld must actually send positions
do
  local Player = require("src.core.game3.player")
  local MapMod = require("src.core.game3.map")
  local savedCur = MapMod.current
  Player.cellX, Player.cellY, Player.facing, Player.moving = 7, 8, "left", false
  MapMod.current = "EM_LITTLEROOT_TOWN"
  local sent, inbox = {}, {}
  Net.new = function()
    return {
      paired = true, closed = false, address = "x:7777",
      host = function() return true end,
      update = function() end,
      poll = function() local out = inbox inbox = {} return out end,
      send = function(_, m) sent[#sent + 1] = m end,
      close = function(self) self.closed = true end,
    }
  end
  run.loader.modOptions.g3_coop = { role = "host", port = 7777 }
  Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
  local fieldGame = { phase = "field" }
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)   -- handshake: our hello goes out
  local hello
  for _, m in ipairs(sent) do if m.type == "coop_hello" then hello = m end end
  T.check(hello ~= nil, "the mod sends its hello through the real sandbox")
  if hello then
    local echo = {}
    for k, v in pairs(hello) do echo[k] = v end
    echo.name = "PARTNER"
    inbox[1] = echo
  end
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)   -- partner's hello arrives
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)   -- first position goes out
  local pos
  for _, m in ipairs(sent) do if m.type == "coop_pos" then pos = m end end
  T.eq(exports.session() and exports.session().state, "connected", "an identical install is accepted")
  T.check(pos ~= nil, "in the overworld, the sandboxed mod sends its position")
  T.check(pos and pos.m == "EM_LITTLEROOT_TOWN" and pos.x == 7 and pos.y == 8 and pos.d == "left",
    "read from the live player and map modules")
  T.check(pos and Protocol.validate(pos) ~= nil, "and the partner's validator accepts it")

  -- the partner stands one cell to our left; we face left and press A
  inbox[1] = { type = "coop_pos", s = 1, m = "EM_LITTLEROOT_TOWN", x = 6, y = 8, d = "right", g = 0, e = 3 }
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  local function waves()
    local n = 0
    for _, m in ipairs(sent) do if m.type == "coop_emote" then n = n + 1 end end
    return n
  end
  local pressA = { wasPressed = function(_, b) return b == "a" end }
  Player.facing = "right"
  fieldGame.input = pressA
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  T.eq(waves(), 0, "A while facing away from the partner does nothing")
  Player.facing = "left"
  local Choice = require("src.ui.game3.choice")
  local Message = require("src.ui.game3.message")
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  T.check(Choice.active and Choice.options and Choice.options[1] == "WAVE"
    and Choice.options[2] == "BATTLE" and Choice.options[3] == "TRADE",
    "A while facing the partner opens WAVE / BATTLE / TRADE")
  T.check(Message.isOpen(), "with the game's own message box")
  T.eq(waves(), 0, "nothing is sent until something is picked")
  Choice.autoPick(0)
  T.eq(waves(), 1, "WAVE sends a wave")
  T.check(not Message.isOpen() and not Choice.active, "and closes the menu")
  local last = exports.toasts()[#exports.toasts()]
  T.check(last and last.text:find("You waved at PARTNER", 1, true), "and says so on screen")
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  T.check(not Choice.active, "holding A does not reopen the menu at once")
  Choice.reset()
  if Message.isOpen() then Message.close() end
  inbox[1] = { type = "coop_emote", e = "wave" }
  fieldGame.input = nil
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  last = exports.toasts()[#exports.toasts()]
  T.check(last and last.text:find("PARTNER waved at you!", 1, true), "a wave from the partner shows a toast")
  local entry = exports.drawEntry()
  T.check(entry and entry.cellX == 6 and entry.cellY == 8 and (entry.raiseY or 0) < 0,
    "and the partner's character hops in the draw list")

  -- the partner's game goes away (quit, crash): we keep trying to get back
  local realLove = rawget(_G, "love")
  local fakeT = 1000
  _G.love = { timer = { getTime = function() return fakeT end } }
  local opened = 0
  local realNewNet = Net.new
  Net.new = function() opened = opened + 1 return realNewNet() end
  inbox[1] = { type = "coop_bye", reason = "left" }
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  T.eq(exports.session(), nil, "a partner who left ends the session")
  T.check(tostring(exports.status()):find("reconnecting", 1, true) ~= nil, "and the status says it will reconnect")
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  T.eq(opened, 0, "not straight away")
  fakeT = fakeT + 6
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  T.eq(opened, 1, "a few seconds later it hosts again")
  T.check(exports.session() ~= nil and exports.session().role == "host", "and waits for the partner")
  -- a partner who pressed F8 on purpose is not redialed
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  hello = nil
  for _, m in ipairs(sent) do if m.type == "coop_hello" then hello = m end end
  local echo = {}
  for k, val in pairs(hello) do echo[k] = val end
  echo.name = "PARTNER"
  inbox[1] = echo
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  T.eq(exports.session().state, "connected", "the partner is back")
  inbox[1] = { type = "coop_bye", reason = "stopped" }
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  fakeT = fakeT + 60
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  T.eq(opened, 1, "a partner who disconnected with F8 is not waited for")
  T.check(tostring(exports.status()):find("F8 to retry", 1, true) ~= nil, "the status offers F8 instead")
  -- F8 stops a pending reconnect
  inbox = {}
  Runtime.call("input.key", function() end, fieldGame, { phase = "pressed", key = "f8" })
  T.eq(opened, 2, "F8 connects again")
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  hello = nil
  for _, m in ipairs(sent) do if m.type == "coop_hello" then hello = m end end
  echo = {}
  for k, val in pairs(hello) do echo[k] = val end
  echo.name = "PARTNER"
  inbox[1] = echo
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  inbox[1] = { type = "coop_bye", reason = "left" }
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  Runtime.call("input.key", function() end, fieldGame, { phase = "pressed", key = "f8" })
  fakeT = fakeT + 60
  Runtime.call("input.step", function() end, fieldGame, 1 / 60)
  T.eq(opened, 2, "F8 while waiting to reconnect stops it")
  T.check(tostring(exports.status()):find("stopped reconnecting", 1, true) ~= nil, "and says so")
  Net.new = realNewNet
  _G.love = realLove
  T.eq(exports.session(), nil, "nothing left open")
  MapMod.current = savedCur
  run.loader.modOptions.g3_coop = nil
end

-- the joiner may paste the host's status-line address, port included
local dialed
Net.new = function()
  return {
    paired = false, closed = false,
    join = function(self, addr) dialed, self.target = addr, addr return true end,
    update = function() end, poll = function() return {} end,
    send = function() end, close = function(self) self.closed = true end,
  }
end
run.loader.modOptions.g3_coop = { role = "join", address = " 192.168.1.23:7777 ", port = 7777 }
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(dialed, "192.168.1.23:7777", "an address with a port is dialed as-is, trimmed")
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
run.loader.modOptions.g3_coop = { role = "join", address = "192.168.1.23", port = 7800 }
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
T.eq(dialed, "192.168.1.23:7800", "a bare address gets the PORT option")
Runtime.call("input.key", function() end, { phase = "field" }, { phase = "pressed", key = "f8" })
run.loader.modOptions.g3_coop = nil
Net.available, Net.new = realAvailable, realNew

-- ------- START > CO-OP, the card, hard-rule revives

local items = Runtime.call("ui.start_menu.items", function(_, list) return list end, { phase = "field" },
  { { id = "pokemon", label = "POKeMON" }, { id = "save", label = "SAVE" }, { id = "exit", label = "EXIT" } })
T.check(items[2] and items[2].label == "CO-OP" and items[3].id == "save", "START gets a CO-OP row, before SAVE")
local ChoiceUi = require("src.ui.game3.choice")
local MessageUi = require("src.ui.game3.message")
if ChoiceUi.active then ChoiceUi.reset() end
items[2].onSelect()
Runtime.call("input.step", function() end, { phase = "field" }, 1 / 60)
T.check(ChoiceUi.active and ChoiceUi.options[1] == "HOST" and ChoiceUi.options[2] == "JOIN"
  and ChoiceUi.options[3] == "ADDRESS" and ChoiceUi.options[4] == "SOUL LINK",
  "CO-OP offers HOST / JOIN / ADDRESS / SOUL LINK")
ChoiceUi.autoPick(4)
T.check(not ChoiceUi.active and not MessageUi.isOpen(), "CANCEL closes it")
T.check(exports.session() == nil, "and connects nothing")
items[2].onSelect()
Runtime.call("input.step", function() end, { phase = "field" }, 1 / 60)
ChoiceUi.autoPick(2)
T.check(exports.editor() ~= nil, "ADDRESS opens the address screen")
T.eq(Runtime.call("input.key", function() return "vanilla" end, {}, { phase = "pressed", key = "up" }), true,
  "which takes the keys")
T.eq(Runtime.call("input.gamepad", function() return "vanilla" end, {}, { phase = "pressed", button = "dpdown" }),
  true, "and the buttons")
Runtime.call("input.key", function() end, {}, { phase = "pressed", key = "escape" })
T.eq(exports.editor(), nil, "B / Esc closes it without saving")
local card = exports.card()
T.check(card == nil or card.dot == "off", "with nothing connected the card at most shows the last status")
T.check(require("src.core.game3.item_use")._g3coopRevive ~= nil, "revives pass through the hard-rules check")
T.check(require("src.core.game3.item_use")._g3coopRareCandy ~= nil, "RARE CANDY passes through the level cap")
T.check(Runtime.wantsHook("exp.gain"), "battle EXP passes through the level cap")
T.eq(Runtime.call("exp.gain", function() return 123 end, { mon = { level = 5, exp = 0 } }), 123,
  "with level caps off, EXP is untouched")
T.eq(Runtime.call("input.key", function() return "vanilla" end, {}, { phase = "pressed", key = "f7" }), true,
  "F7 opens the Soul Link panel")
T.eq(Runtime.call("input.key", function() return "vanilla" end, {}, { phase = "pressed", key = "left" }), true,
  "which takes the keys while it's open")
T.eq(Runtime.call("input.key", function() return "vanilla" end, {}, { phase = "released", key = "left" }), "vanilla",
  "but not releases")
Runtime.call("input.key", function() end, {}, { phase = "pressed", key = "escape" })
T.eq(Runtime.call("input.key", function() return "vanilla" end, {}, { phase = "pressed", key = "left" }), "vanilla",
  "Esc closes it")

local Hud = dofile(here .. "/lib/hud.lua")
local wrapped = Hud.wrap(function(t) return #t end, "Soul Link: the ROUTE 104 link is broken", 12)
T.check(#wrapped == 4 and wrapped[1] == "Soul Link:", "toasts wrap on spaces")
for _, l in ipairs(wrapped) do T.check(#l <= 12 or not l:find(" "), nil) end

local lh = { game = "emerald", mods = "a@1", link = { generation = 3, protocol = 2, engineVersion = "1.0.0", fingerprint = "f" } }
local function rh(over)
  local r = { game = "emerald", mods = "a@1", link = { generation = 3, protocol = 2, engineVersion = "1.0.0", fingerprint = "f" } }
  for k, val in pairs(over or {}) do r[k] = val end
  return r
end
T.eq(exports.compat(lh, rh()), true, "identical installs are compatible")
T.eq(select(2, exports.compat(lh, rh({ mods = "a@2" }))), "different_mods", "a different mod version is refused")
T.eq(select(2, exports.compat(lh, rh({ link = { generation = 3, protocol = 2, engineVersion = "1.0.0", fingerprint = "g" } }))),
  "fingerprint_mismatch", "different game data is refused by the engine's own link check")
local okSkew, note = exports.compat(lh, rh({ link = { generation = 3, protocol = 2, engineVersion = "1.0.1", fingerprint = "f" } }))
T.eq(okSkew, true, "a different engine release with the same game data may share a world")
T.eq(note, "engine_skew", "and is noted as such")
T.eq(exports.compat(lh, rh({ link = { generation = 3, protocol = 2, engineVersion = "1.0.1", fingerprint = "g" } })), false,
  "but not with different game data")
T.eq(exports.compat(lh, rh({ link = { generation = 3, protocol = 2, engineVersion = "2.0.0", fingerprint = "f" } })), false,
  "and never across engine majors")
run.release()

-- field guide snapshots travel as data only (0.8.6)
do
  local snap = { name = "MAY", party = { { 280, 33, 0, 66, 3, 31, 31, 20, 0, 0, 0, 252, 252, 4, 0, 0, 0, 52, 98, 0, 0 } }, box = {} }
  local msg = Protocol.validate(Protocol.guide(snap))
  T.check(msg ~= nil and msg.type == Protocol.GUIDE, "a guide snapshot validates")
  T.eq(msg and msg.d.party[1][1], 280, "the party survives the trip")
  T.eq(Protocol.validate({ type = Protocol.GUIDE, d = "x" }), nil, "a non-table guide is refused")
end
T.finish("g3_coop")
