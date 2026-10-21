-- Headless suite for lib/progress.lua (shared story progression) against a
-- model of the port's coopProgress API 1 (COOP-PROGRESSION.md), over the
-- real protocol validator and a JSON round trip.
--   cd Gen3Mod/inclement-engine && luajit ../coop/tests/run_progress.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local coop = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
local here = coop .. "/g3_coop"
local function lib(name) return dofile(here .. "/lib/" .. name .. ".lua") end

local T = require("tests.modkit")
local Json = require("src.link.Json")
local Protocol = lib("protocol")
local Progress = lib("progress")

-- ------------------------------------------------ a model of the port API

local function copy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = copy(x) end
  return o
end

local function newApi(game)
  local L = {}
  local api = { API = 1 }
  function api.prepare(id, d, origin)
    if type(d) ~= "table" or d.schema ~= 1 then return false, "build_mismatch" end
    local hash = Json.encode(d)
    local r = L[id]
    if r then return r.hash == hash, r.hash == hash and r.status or "id_conflict" end
    L[id] = { id = id, hash = hash, descriptor = copy(d), status = "battle", origin = origin == true }
    return true, "battle"
  end
  function api.resolve(id, result)
    local r = L[id]
    if not r then return false, "unknown_event" end
    if r.result then return r.result == result, r.result == result and r.status or "result_conflict" end
    r.result = result
    r.status = (result == "win") and "queued" or "cancelled"
    return true, r.status
  end
  function api.replay(id)
    local r = L[id]
    if not r then return false, "unknown_event" end
    if r.status == "done" or r.status == "cancelled" then return true, r.status end
    if r.status ~= "queued" then return false, r.status end
    if game.map ~= r.descriptor.map then return false, "return_to_map" end
    if game.busy then return false, "script_busy" end
    r.status = "running"
    game.scenes = game.scenes + 1
    game.rewards[id] = (game.rewards[id] or 0) + 1
    game.emit({ id = id, status = "running", replay = true })
    game.finishing = id
    return true, "running"
  end
  -- the native continuation (origin: done("win")) ends on a later tick
  function api._ended(id)
    local r = L[id]
    r.status = "done"
    game.emit({ id = id, status = "done", result = r.result })
  end
  function api.status(id)
    local r = L[id]
    return r and r.status or "unknown", r and r.peerAck == true
  end
  function api.get(id) return copy(L[id]) end
  function api.history()
    local out = {}
    for id in pairs(L) do out[#out + 1] = id end
    table.sort(out)
    return out
  end
  function api.pending()
    local out = {}
    for id, r in pairs(L) do if r.status ~= "cancelled" and not r.peerAck then out[#out + 1] = id end end
    table.sort(out)
    return out
  end
  function api.ack(id)
    local r = L[id]
    if not r or r.status ~= "done" then return false, "not_complete" end
    r.peerAck = true
    return true
  end
  api._L = L
  return api
end

-- ------------------------------------------------------- two games, a wire

local clockNow = 0
local function now() return clockNow end
local link = { up = true }

local function newGame(name)
  local g = { name = name, map = "EM_RUSTBORO_CITY_GYM", busy = false, scenes = 0, rewards = {},
              toasts = {}, inbox = {}, seq = 0, free = true }
  g.api = newApi(g)
  g.emit = function(ev) g.events = g.events or {}; g.events[#g.events + 1] = ev end
  g.p = Progress.new({
    api = function() return g.api end,
    send = function(fields)
      -- the real wire: Protocol builds it, JSON carries it, validate reads it
      local raw = Json.decode(Json.encode(Protocol.prog(fields)))
      local msg, why = Protocol.validate(raw)
      assert(msg, "message refused: " .. tostring(why))
      g.peer.inbox[#g.peer.inbox + 1] = msg
    end,
    connected = function() return link.up end,
    now = now,
    toast = function(text) g.toasts[#g.toasts + 1] = text end,
    newId = function() g.seq = g.seq + 1; return ("g3c:%s:%d:1"):format(g.name, g.seq) end,
    canJoin = function() return g.free end,
    idle = function() return not g.busy end,
    held = function() return g.held end,
    mapName = function(m) return m end,
    log = function() end,
  })
  return g
end

local A, B = newGame("A"), newGame("B")
A.peer, B.peer = B, A

local function pump(n)
  for _ = 1, n or 10 do
    for _, g in ipairs({ A, B }) do
      local box = g.inbox
      g.inbox = {}
      for _, m in ipairs(box) do g.p:onMessage(m) end
      for _, ev in ipairs(g.events or {}) do g.p:onStatus(ev) end
      g.events = {}
      if g.finishing then
        local id = g.finishing
        g.finishing = nil
        g.api._ended(id)
      end
      clockNow = clockNow + 0.6
      g.p:tick()
    end
  end
end

local function descriptor(trainer)
  return { schema = 1, build = "0.6.0-dev.23/progress-1", map = "EM_RUSTBORO_CITY_GYM",
           root = "RustboroCity_Gym_EventScript_Roxanne", trainerId = trainer or 265,
           strings = { string.rep("x", 600) }, stack = {}, flags = { { id = 2151, before = false, after = true } },
           vars = {}, temps = { ["16384"] = 0 }, scene = {}, objects = {} }
end

-- the initiator's script finishing natively after done("win")
local function originWins(g, id)
  g.held = nil
  g.p:finish(id, "win")
  g.p:started(id)
  g.rewards[id] = (g.rewards[id] or 0) + 1
  g.api._L[id].status = "running"
  g.finishing = id
end

-- --------------------------------------------------------- normal win

local readyId, failWhy
local id = A.p:begin(descriptor(), function(i) readyId = i end, function(w) failWhy = w end)
T.check(id ~= nil, "initiator prepares the held fight's event")
A.held = id
T.eq(A.api.status(id), "battle", "initiator receipt waits for the battle")
T.check(A.p:busy(), "initiator is busy while the partner prepares")
pump(1)
T.eq(B.api.status(id), "battle", "partner prepared the same event")
T.eq(B.api.get(id).descriptor.strings[1], string.rep("x", 600), "descriptor travels unshortened")
pump(1)
T.eq(readyId, id, "initiator hears the partner is ready")
T.eq(failWhy, nil, "no failure")
T.eq(B.p:expected(), id, "the partner's next joint battle is this event")
-- the battle: both games see the win
B.p:finish(id, "win")
T.eq(B.api.status(id), "queued", "partner queued its replay")
originWins(A, id)
pump(6)
T.eq(A.rewards[id], 1, "initiator ran its continuation once")
T.eq(B.rewards[id], 1, "partner replayed the continuation once")
T.eq(A.api.status(id), "done", "initiator done")
T.eq(B.api.status(id), "done", "partner done")
T.eq(select(2, A.api.status(id)), true, "initiator acknowledged the partner")
T.eq(select(2, B.api.status(id)), true, "partner acknowledged the initiator")
T.eq(#A.api.pending() + #B.api.pending(), 0, "nothing pending on either side")
T.eq(A.p:busy() or B.p:busy(), false, "no scene running")

-- duplicates: a resent event changes nothing
A.p:_send(A.p:_event(id))
pump(3)
T.eq(B.rewards[id], 1, "duplicate event does not replay twice")

-- --------------------------------------------------------- a loss

local id2 = A.p:begin(descriptor(), function() end, function() end)
A.held = id2
pump(2)
B.p:expected()
B.p:finish(id2, "lose")
A.p:finish(id2, "lose")
A.held = nil
pump(4)
T.eq(A.api.status(id2), "cancelled", "a loss stops the initiator's script")
T.eq(B.api.status(id2), "cancelled", "a loss gives the partner nothing")
T.eq(B.rewards[id2], nil, "no replay after a loss")

-- --------------------------------------------------------- partner busy

B.free = false
local failed2
local id3 = A.p:begin(descriptor(), function() error("must not start") end, function(w) failed2 = w end)
pump(3)
T.eq(failed2, "busy", "a busy partner calls the fight off")
T.eq(A.api.status(id3), "cancelled", "called-off event cancelled here")
T.eq(B.api.status(id3), "unknown", "the busy partner never prepared it")
B.free = true

-- --------------------------------------------------------- no reply

link.up = false
local failed3
local id4 = A.p:begin(descriptor(), function() error("must not start") end, function(w) failed3 = w end)
for _ = 1, 20 do clockNow = clockNow + 1; A.p:tick() end
T.eq(failed3, "no_reply", "no answer calls the fight off")
T.eq(A.api.status(id4), "cancelled", "timed-out event cancelled")
link.up = true
A.inbox, B.inbox = {}, {}

-- ------------------------------ partner dropped; initiator won alone

local id5 = A.p:begin(descriptor(), function() end, function() end)
A.held = id5
pump(2)
B.p:expected()
link.up = false
-- the partner's game closed mid-battle: its receipt stays unresolved
originWins(A, id5)
for _ = 1, 4 do
  clockNow = clockNow + 1
  A.p:tick()
  for _, ev in ipairs(A.events or {}) do A.p:onStatus(ev) end
  A.events = {}
  if A.finishing then local i = A.finishing; A.finishing = nil; A.api._ended(i) end
end
T.eq(A.api.status(id5), "done", "initiator finished alone")
T.eq(B.api.status(id5), "battle", "dropped partner left unresolved")
B.p.live = {}
link.up = true
A.p:connected(); B.p:connected()
pump(8)
T.eq(B.api.status(id5), "done", "reconnect replays the win for the partner")
T.eq(B.rewards[id5], 1, "partner got its rewards once")
T.eq(select(2, A.api.status(id5)), true, "initiator acknowledged after reconnect")

-- ---------------------------------- partner loaded an older save

B.api._L[id5] = nil
B.rewards[id5] = nil
A.p:connected(); B.p:connected()
pump(8)
T.eq(B.api.status(id5), "done", "older save gets the event again")
T.eq(B.rewards[id5], 1, "and plays it once")

-- --------------------- nobody finished: both dropped, both ended it

local id6 = A.p:begin(descriptor(), function() end, function() end)
A.held = id6
pump(2)
B.p:expected()
link.up = false
A.held = nil
A.p:finish(id6, "cancel")           -- the initiator ended the battle
B.p.live = {}                       -- the partner's game was closed
link.up = true
A.p:connected(); B.p:connected()
pump(6)
T.eq(B.api.status(id6), "cancelled", "a fight nobody finished is called off on reconnect")
T.eq(#B.api.pending(), 0, "no stale receipt blocks story fights")

-- ------------------- both carried on alone and ended it differently

local id7 = A.p:begin(descriptor(), function() end, function() end)
A.held = id7
pump(2)
B.p:expected()
link.up = false
B.p:finish(id7, "lose")
originWins(A, id7)
for _ = 1, 4 do
  clockNow = clockNow + 1
  for _, ev in ipairs(A.events or {}) do A.p:onStatus(ev) end
  A.events = {}
  if A.finishing then local i = A.finishing; A.finishing = nil; A.api._ended(i) end
end
link.up = true
A.p:connected(); B.p:connected()
pump(6)
T.eq(A.api.status(id7), "done", "the winner keeps its win")
T.eq(B.api.status(id7), "cancelled", "the loser keeps its loss")
T.eq(#A.api.pending(), 0, "the winner doesn't wait forever on the loser")
T.check(#B.toasts > 0, "the conflict is explained")

-- --------------------------------------------------- partner elsewhere

local id8 = A.p:begin(descriptor(), function() end, function() end)
A.held = id8
pump(2)
B.p:expected()
B.p:finish(id8, "win")
B.map = "EM_ROUTE_104"
originWins(A, id8)
pump(4)
T.eq(B.api.status(id8), "queued", "replay waits off the event's map")
local said = false
for _, t in ipairs(B.toasts) do if t:find("EM_RUSTBORO_CITY_GYM", 1, true) then said = true end end
T.check(said, "the partner is told where to go")
B.map = "EM_RUSTBORO_CITY_GYM"
B.busy = true
pump(2)
T.eq(B.api.status(id8), "queued", "replay waits for a busy field")
B.busy = false
pump(4)
T.eq(B.api.status(id8), "done", "replay runs back on the map")
T.eq(select(2, A.api.status(id8)), true, "and both finish")

-- ------------------------------------------------------ the validator

local bad = { type = "coop_prog", op = "prep", id = "x y" , d = {} }
T.eq(Protocol.validate(bad), nil, "ids with spaces refused")
T.eq(Protocol.validate({ type = "coop_prog", op = "prep", id = "a" }), nil, "prep without descriptor refused")
T.eq(Protocol.validate({ type = "coop_prog", op = "event", id = "a", d = {}, r = "draw" }), nil, "unknown result refused")
T.eq(Protocol.validate({ type = "coop_prog", op = "boom", id = "a" }), nil, "unknown op refused")
T.eq(Protocol.validate({ type = "coop_prog", op = "event", id = "a", d = { s = string.rep("y", 9000) } }), nil,
  "oversized string refused, not shortened")
local deep = {}
local cur = deep
for _ = 1, 20 do cur.x = {}; cur = cur.x end
T.eq(Protocol.validate({ type = "coop_prog", op = "event", id = "a", d = deep }), nil, "over-deep data refused")
local okm = Protocol.validate({ type = "coop_prog", op = "have", list = { { id = "a", s = "done", live = true } } })
T.eq(okm and okm.list[1].s, "done", "have list read")

T.finish("g3_coop progression")
