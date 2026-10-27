-- Wire messages for the co-op session.  Everything a peer sends passes
-- through validate() before any other module sees it: this is the second
-- place in the game that reads bytes somebody else wrote, so the rules in
-- docs/link-security.md apply -- typed fields, clamped ranges, capped
-- strings, nothing executed.

local Protocol = {}

-- 2: battle/trade requests and the link channel (0.3.0)
-- 3: surfing flag on coop_pos, host-driven NPCs (coop_npc) (0.4.0)
-- 4: Soul Link run sync (coop_sl) (0.5.0)
-- 5: Soul Link hard rules travel with the host's rules (0.6.0)
-- 6: and level caps (0.7.0)
-- 7: team battles against the game's trainers (coop_team, act "team")
-- 8: shared wild encounters (act "wild"), shared trainer credit (coop_credit)
-- 9: trainer fights together (acts "trainer" and "joint", ask carries t)
-- 10: shared story progression (coop_prog, lib/progress.lua)
Protocol.VERSION = 10

Protocol.HELLO = "coop_hello"
Protocol.POS = "coop_pos"
Protocol.STATE = "coop_state"
Protocol.BYE = "coop_bye"
Protocol.EMOTE = "coop_emote"
Protocol.ASK = "coop_ask"
Protocol.ANSWER = "coop_answer"
Protocol.CANCEL = "coop_cancel"
Protocol.LINK = "coop_link"
Protocol.NPC = "coop_npc"
Protocol.SL = "coop_sl"
Protocol.TEAM = "coop_team"
Protocol.CREDIT = "coop_credit"
Protocol.MAX_CREDIT_IDS = 512
Protocol.PROG = "coop_prog"
-- story scenes both players watch: one starts it, the other's game joins
Protocol.SCENE = "coop_scene"

Protocol.MAX_NAME = 16
Protocol.MAX_MAP = 64
Protocol.MAX_COORD = 1024
Protocol.MIN_COORD = -16
Protocol.MAX_FRAMES = 64
Protocol.MAX_GFX = 1023
-- NPC entries per coop_npc message, and their local ids
Protocol.MAX_NPCS = 32
Protocol.MAX_NPC_ID = 255
-- Soul Link log events per coop_sl message, and the longest log
Protocol.MAX_SL_EVENTS = 64
Protocol.MAX_SL_LOG = 2 ^ 20

local DIRS = { up = true, down = true, left = true, right = true }
local BUSY = { none = true, battle = true, trade = true, menu = true, script = true }
local EMOTES = { wave = true }
local ACTS = { battle = true, trade = true, team = true, wild = true, trainer = true, joint = true }
-- why a request was turned down; the HUD words each one
local DECLINES = { no = true, busy = true, no_mons = true, bad_egg = true,
                   enigma_berry = true, timeout = true, error = true }
Protocol.MAX_REQUEST = 2 ^ 31

local function int(v, lo, hi)
  if type(v) ~= "number" or v ~= v or v ~= math.floor(v) then return nil end
  if v < lo or v > hi then return nil end
  return v
end

local function str(v, max, pattern)
  if type(v) ~= "string" or #v == 0 or #v > max then return nil end
  if pattern and not v:match(pattern) then return nil end
  return v
end

local function coord(v)
  return int(v, Protocol.MIN_COORD, Protocol.MAX_COORD)
end

-- hello carries the engine's own link hello (src/link/Handshake.lua) so
-- compatibility is judged by the same rules link play uses
function Protocol.hello(name, gameVersion, linkHello, modsKey)
  return {
    type = Protocol.HELLO, v = Protocol.VERSION,
    name = tostring(name or "PLAYER"):sub(1, Protocol.MAX_NAME),
    game = gameVersion, link = linkHello, mods = modsKey,
  }
end

-- snap: { m, x, y, d, mv, tx, ty, f, g, e, vis, sf }
function Protocol.pos(seq, snap)
  return {
    type = Protocol.POS, s = seq, m = snap.m, x = snap.x, y = snap.y,
    d = snap.d, mv = snap.mv, tx = snap.tx, ty = snap.ty, f = snap.f,
    g = snap.g, e = snap.e, vis = snap.vis, sf = snap.sf == true or nil,
  }
end

function Protocol.state(busy)
  return { type = Protocol.STATE, busy = busy }
end

function Protocol.emote(e)
  return { type = Protocol.EMOTE, e = e }
end

-- id: the requester's request number, also the link channel number
function Protocol.ask(id, act, t)
  return { type = Protocol.ASK, id = id, act = act, t = t }
end

function Protocol.answer(id, ok, why)
  return { type = Protocol.ANSWER, id = id, ok = ok == true, why = why }
end

function Protocol.cancel(id)
  return { type = Protocol.CANCEL, id = id }
end

-- one message of the engine's own link protocol (src/link/Game3Link.lua and
-- the battle/trade modules on top of it), carried on channel c
function Protocol.link(c, m)
  return { type = Protocol.LINK, c = c, m = m }
end

-- the host's wandering NPCs on map m: { {id, x, y, d [, tx, ty, f]}, ... },
-- a step in flight carrying its target and frame count like coop_pos
function Protocol.npc(m, list)
  return { type = Protocol.NPC, m = m, n = list }
end

-- Soul Link: who we are and which run we keep (run id, trainer key, name,
-- the partner our run is linked with, the rules), plus a slice of our own
-- log starting at index `from`, and the index of the partner's log we want
-- next.  hi = true on the first message of a connection.
function Protocol.sl(f)
  return { type = Protocol.SL, hi = f.hi == true or nil, run = f.run, tid = f.tid,
           nm = f.nm, pt = f.pt, rules = f.rules, from = f.from, want = f.want, ev = f.ev }
end

-- A team battle's setup for channel c (lib/teambattle.lua): plain data
-- (names, parties, the host's foes and seed) packed by Protocol.packTree.
function Protocol.team(c, d)
  return { type = Protocol.TEAM, c = c, d = d }
end

-- Plain Lua data <-> JSON-safe trees.  JSON loses the difference between
-- an array and a table with number keys (a party slot's moves, a sparse
-- table), so every table travels as a list of {key, value} pairs.  Only
-- numbers, strings, booleans and tables survive; functions, userdata and
-- anything deeper than MAX_TREE_DEPTH are dropped.
Protocol.MAX_TREE_DEPTH = 8
Protocol.MAX_TREE_NODES = 20000
Protocol.MAX_TREE_STRING = 200

function Protocol.packTree(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
  end
  if t == "string" then return v:sub(1, Protocol.MAX_TREE_STRING) end
  if t == "boolean" then return v end
  if t ~= "table" or depth >= Protocol.MAX_TREE_DEPTH then return nil end
  local out = {}
  for k, val in pairs(v) do
    local kt = type(k)
    if (kt == "string" and #k <= 64) or (kt == "number" and k == math.floor(k) and math.abs(k) <= 1e6) then
      local packed = Protocol.packTree(val, depth + 1)
      if packed ~= nil then out[#out + 1] = { k, packed } end
    end
  end
  return { ["~"] = out }
end

-- the reverse, validating as it goes: nil plus a reason on anything that
-- Protocol.packTree could not have produced
function Protocol.unpackTree(v)
  local nodes = 0
  local function walk(x, depth)
    nodes = nodes + 1
    if nodes > Protocol.MAX_TREE_NODES then return nil, "too_big" end
    local t = type(x)
    if t == "number" then
      if x ~= x or x == math.huge or x == -math.huge then return nil, "bad_number" end
      return x
    end
    if t == "string" then
      if #x > Protocol.MAX_TREE_STRING then return nil, "long_string" end
      return x
    end
    if t == "boolean" then return x end
    if t ~= "table" or depth >= Protocol.MAX_TREE_DEPTH then return nil, "bad_tree" end
    local pairsList = x["~"]
    if type(pairsList) ~= "table" then return nil, "bad_tree" end
    local out = {}
    for _, kv in ipairs(pairsList) do
      if type(kv) ~= "table" then return nil, "bad_tree" end
      local k = kv[1]
      local kt = type(k)
      if not ((kt == "string" and #k <= 64)
              or (kt == "number" and k == math.floor(k) and math.abs(k) <= 1e6)) then
        return nil, "bad_key"
      end
      local val, why = walk(kv[2], depth + 1)
      if val == nil then return nil, why end
      out[k] = val
    end
    return out
  end
  return walk(v, 0)
end

-- trainers beaten alone that count for both (lib/credit.lua); fresh = a win
-- just now (the partner hears about it), else the list sent on connect
-- joint: joint fights won (a story fight finished alone after the partner
-- dropped counts for both; never filtered as a story trainer)
function Protocol.credit(ids, fresh, joint)
  return { type = Protocol.CREDIT, ids = ids, fresh = fresh == true or nil, joint = joint == true or nil }
end

-- Shared story progression (lib/progress.lua).  The descriptor is the
-- port's own data (COOP-PROGRESSION.md): it travels exactly as given, never
-- through packTree (which shortens strings); the port validates it before
-- using it.  fields: { op, id, d, r, ok, why, list }
Protocol.MAX_PROG_DEPTH = 16
Protocol.MAX_PROG_NODES = 60000
Protocol.MAX_PROG_STRING = 8192
Protocol.MAX_PROG_LIST = 2048
local PROG_OPS = { prep = true, prepped = true, event = true, done = true, have = true }
local PROG_RESULTS = { win = true, lose = true, cancel = true }
local PROG_STATUS = { battle = true, queued = true, running = true, done = true, failed = true,
                      cancelled = true, unknown = true }
local PROG_ID = "^[%w%.:_%-]+$"

function Protocol.prog(f)
  return { type = Protocol.PROG, op = f.op, id = f.id, d = f.d, r = f.r, ok = f.ok, why = f.why,
           list = f.list }
end

-- a copy of plain JSON data, or nil plus why if it's too big or not data;
-- nothing is shortened or dropped
function Protocol.copyData(v)
  local nodes = 0
  local function walk(x, depth)
    nodes = nodes + 1
    if nodes > Protocol.MAX_PROG_NODES then return nil, "too_big" end
    local t = type(x)
    if t == "number" then
      if x ~= x or x == math.huge or x == -math.huge then return nil, "bad_number" end
      return x
    end
    if t == "string" then
      if #x > Protocol.MAX_PROG_STRING then return nil, "long_string" end
      return x
    end
    if t == "boolean" then return x end
    if t ~= "table" or depth >= Protocol.MAX_PROG_DEPTH then return nil, "bad_data" end
    local out = {}
    for k, val in pairs(x) do
      local kt = type(k)
      if not ((kt == "string" and #k <= 128) or (kt == "number" and k == math.floor(k) and math.abs(k) <= 1e6)) then
        return nil, "bad_key"
      end
      local c, why = walk(val, depth + 1)
      if c == nil then return nil, why end
      out[k] = c
    end
    return out
  end
  return walk(v, 0)
end

-- a mirrored story scene (main.lua SCENES): script key, the object talked
-- to, the starter's facing (1-4) and where they stand on map
function Protocol.scene(key, map, x, y, facing, localId)
  return { type = Protocol.SCENE, key = key, map = map, x = x, y = y, facing = facing, localId = localId }
end

function Protocol.bye(reason)
  return { type = Protocol.BYE, reason = reason }
end

local validators = {}

validators[Protocol.HELLO] = function(m)
  if m.v ~= Protocol.VERSION then return nil, "protocol_version" end
  local name = str(m.name, Protocol.MAX_NAME)
  local game = str(m.game, 32, "^[%w_]+$")
  if not (name and game) then return nil, "bad_hello" end
  if type(m.link) ~= "table" then return nil, "bad_hello" end
  if m.mods ~= nil and type(m.mods) ~= "string" then return nil, "bad_hello" end
  -- printable ASCII only; the HUD draws it verbatim
  name = name:gsub("[^%w %-%.!?']", "?")
  return { type = m.type, v = m.v, name = name, game = game, link = m.link,
           mods = m.mods }
end

validators[Protocol.POS] = function(m)
  local out = {
    type = m.type,
    s = int(m.s, 0, 2 ^ 31),
    m = str(m.m, Protocol.MAX_MAP, "^[%w_]+$"),
    x = coord(m.x), y = coord(m.y),
    d = DIRS[m.d] and m.d or nil,
    mv = m.mv == true,
    g = int(m.g, 0, Protocol.MAX_GFX),
    e = int(m.e, 0, 15) or 0,
    vis = m.vis ~= false,
    sf = m.sf == true,
  }
  if not (out.s and out.m and out.x and out.y and out.d and out.g) then
    return nil, "bad_pos"
  end
  if out.mv then
    out.tx, out.ty = coord(m.tx), coord(m.ty)
    out.f = int(m.f, 1, Protocol.MAX_FRAMES)
    if not (out.tx and out.ty and out.f) then return nil, "bad_pos" end
    -- a step is one cell (two for a ledge jump); anything longer is a warp
    -- dressed up as a step and is refused rather than animated
    if math.abs(out.tx - out.x) + math.abs(out.ty - out.y) > 2 then
      return nil, "bad_pos"
    end
  end
  return out
end

validators[Protocol.STATE] = function(m)
  if not BUSY[m.busy] then return nil, "bad_state" end
  return { type = m.type, busy = m.busy }
end

validators[Protocol.EMOTE] = function(m)
  if not EMOTES[m.e] then return nil, "bad_emote" end
  return { type = m.type, e = m.e }
end

validators[Protocol.ASK] = function(m)
  local id = int(m.id, 1, Protocol.MAX_REQUEST)
  if not (id and ACTS[m.act]) then return nil, "bad_ask" end
  local out = { type = m.type, id = id, act = m.act }
  -- the trainer(s) a trainer fight is against: one id, or a pair
  if m.t ~= nil then
    if type(m.t) ~= "table" or #m.t < 1 or #m.t > 2 then return nil, "bad_ask" end
    out.t = {}
    for i = 1, #m.t do
      out.t[i] = int(m.t[i], 1, 2 ^ 20)
      if not out.t[i] then return nil, "bad_ask" end
    end
  end
  return out
end

validators[Protocol.ANSWER] = function(m)
  local id = int(m.id, 1, Protocol.MAX_REQUEST)
  if not id then return nil, "bad_answer" end
  local ok = m.ok == true
  return { type = m.type, id = id, ok = ok,
           why = (not ok) and (DECLINES[m.why] and m.why or "no") or nil }
end

validators[Protocol.CANCEL] = function(m)
  local id = int(m.id, 1, Protocol.MAX_REQUEST)
  if not id then return nil, "bad_cancel" end
  return { type = m.type, id = id }
end

-- The inner message is handed on untouched: the engine's link Session runs
-- every message through src/link/Wire.lua sanitize before its battle and
-- trade code read it, the same as on the relay.  Only its envelope is
-- checked here.
validators[Protocol.LINK] = function(m)
  local c = int(m.c, 1, Protocol.MAX_REQUEST)
  local inner = m.m
  if not (c and type(inner) == "table" and type(inner.type) == "string"
          and #inner.type > 0 and #inner.type <= 64) then
    return nil, "bad_link"
  end
  return { type = m.type, c = c, m = inner }
end

validators[Protocol.NPC] = function(m)
  local map = str(m.m, Protocol.MAX_MAP, "^[%w_]+$")
  if not (map and type(m.n) == "table") or #m.n > Protocol.MAX_NPCS then return nil, "bad_npc" end
  local list = {}
  for i = 1, #m.n do
    local e = m.n[i]
    if type(e) ~= "table" then return nil, "bad_npc" end
    local out = { id = int(e.id, 1, Protocol.MAX_NPC_ID), x = coord(e.x), y = coord(e.y),
                  d = DIRS[e.d] and e.d or nil }
    if not (out.id and out.x and out.y and out.d) then return nil, "bad_npc" end
    if e.tx ~= nil then
      out.tx, out.ty, out.f = coord(e.tx), coord(e.ty), int(e.f, 1, Protocol.MAX_FRAMES)
      if not (out.tx and out.ty and out.f) then return nil, "bad_npc" end
      -- NPCs only ever walk one cell at a time
      if math.abs(out.tx - out.x) + math.abs(out.ty - out.y) ~= 1 then return nil, "bad_npc" end
    end
    list[i] = out
  end
  return { type = m.type, m = map, n = list }
end

local SL_KINDS = { enc = true, catch = true, miss = true, faint = true, nick = true }
local SL_HOW = { wild = true, static = true, gift = true }
local SL_WHY = { shiny = true, static = true, gift = true, over = true }
local SL_RULES = { "dupes", "shiny", "gift", "static", "enforce", "hard", "caps" }
local UID = "^%d+:%d+$"

local function slName(v)
  local n = str(v, 12)
  return n and (n:gsub("[^%w %-%.!?']", "?")) or nil
end

local function slEvent(e)
  if type(e) ~= "table" or not SL_KINDS[e.k] then return nil end
  local out = { k = e.k }
  if e.k == "enc" or e.k == "catch" or e.k == "miss" then
    out.a = int(e.a, 0, 1023)
    if not out.a then return nil end
  end
  if e.k == "enc" or e.k == "catch" then
    out.sc = e.sc == true or nil
    out.s = int(e.s, 1, 2047)
    if not out.s then return nil end
  end
  if e.k == "enc" then
    out.h = SL_HOW[e.h] and e.h or nil
    out.sh = e.sh == true or nil
    if not out.h then return nil end
  end
  if e.k == "catch" or e.k == "faint" or e.k == "nick" then
    out.u = str(e.u, 24, UID)
    if not out.u then return nil end
  end
  if e.k == "catch" then
    if e.x ~= nil then
      out.x = SL_WHY[e.x] and e.x or nil
      if not out.x then return nil end
    end
    out.nm = slName(e.nm)
  end
  if e.k == "nick" then
    out.nm = slName(e.nm)
    if not out.nm then return nil end
  end
  if e.k == "faint" then
    -- where and to what (optional)
    out.a = int(e.a, 0, 1023)
    local by = str(e.by, 24)
    out.by = by and (by:gsub("[^%w %-%.!?'&]", "?")) or nil
    out.lv = int(e.lv, 1, 100)
  end
  return out
end

validators[Protocol.SL] = function(m)
  local out = {
    type = m.type, hi = m.hi == true,
    run = str(m.run, 40, "^[%w_%-]+$"), tid = str(m.tid, 40, "^[%w_%-:]+$"),
    nm = slName(m.nm) or "?",
    from = int(m.from, 1, Protocol.MAX_SL_LOG), want = int(m.want, 1, Protocol.MAX_SL_LOG),
  }
  if m.pt ~= nil then
    out.pt = str(m.pt, 40, "^[%w_%-:]+$")
    if not out.pt then return nil, "bad_sl" end
  end
  if not (out.run and out.tid and out.from and out.want and type(m.rules) == "table") then
    return nil, "bad_sl"
  end
  out.rules = {}
  for _, k in ipairs(SL_RULES) do out.rules[k] = m.rules[k] == true end
  local ev = m.ev or {}
  if type(ev) ~= "table" or #ev > Protocol.MAX_SL_EVENTS then return nil, "bad_sl" end
  out.ev = {}
  for i = 1, #ev do
    local e = slEvent(ev[i])
    if not e then return nil, "bad_sl" end
    out.ev[i] = e
  end
  return out
end

validators[Protocol.TEAM] = function(m)
  local c = int(m.c, 1, Protocol.MAX_REQUEST)
  if not c then return nil, "bad_team" end
  local d, why = Protocol.unpackTree(m.d)
  if type(d) ~= "table" then return nil, why or "bad_team" end
  return { type = m.type, c = c, d = d }
end

validators[Protocol.CREDIT] = function(m)
  local ids = m.ids
  if type(ids) ~= "table" or #ids > Protocol.MAX_CREDIT_IDS then return nil, "bad_credit" end
  local out = {}
  for i = 1, #ids do
    local id = int(ids[i], 1, 2 ^ 20)
    if not id then return nil, "bad_credit" end
    out[i] = id
  end
  return { type = m.type, ids = out, fresh = m.fresh == true, joint = m.joint == true }
end

validators[Protocol.PROG] = function(m)
  local op = PROG_OPS[m.op] and m.op
  if not op then return nil, "bad_prog" end
  local out = { type = m.type, op = op }
  if op == "have" then
    if type(m.list) ~= "table" or #m.list > Protocol.MAX_PROG_LIST then return nil, "bad_prog" end
    out.list = {}
    for i = 1, #m.list do
      local e = m.list[i]
      if type(e) ~= "table" then return nil, "bad_prog" end
      local id = str(e.id, 128, PROG_ID)
      if not (id and PROG_STATUS[e.s]) then return nil, "bad_prog" end
      out.list[i] = { id = id, s = e.s, live = e.live == true or nil }
    end
    return out
  end
  out.id = str(m.id, 128, PROG_ID)
  if not out.id then return nil, "bad_prog" end
  if m.r ~= nil then
    if not PROG_RESULTS[m.r] then return nil, "bad_prog" end
    out.r = m.r
  end
  if m.d ~= nil then
    local d, why = Protocol.copyData(m.d)
    if type(d) ~= "table" then return nil, why or "bad_prog" end
    out.d = d
  end
  if (op == "prep" or op == "event") and not out.d then return nil, "bad_prog" end
  if op == "prepped" then
    out.ok = m.ok == true
    out.why = str(m.why, 32, "^[%w_]+$")
  end
  return out
end

validators[Protocol.BYE] = function(m)
  return { type = m.type, reason = str(m.reason, 32, "^[%w_]+$") or "left" }
end

-- a fresh, copied message, or nil plus a reason; unknown types are dropped
validators[Protocol.SCENE] = function(m)
  local key = str(m.key, 128, "^[%w_:]+$")
  local map = str(m.map, Protocol.MAX_MAP, "^[%w_]+$")
  local x, y = coord(m.x), coord(m.y)
  local facing = int(m.facing, 1, 4)
  local localId = m.localId == nil and 0 or int(m.localId, 0, Protocol.MAX_NPC_ID)
  if not (key and map and x and y and facing and localId) then return nil, "bad_scene" end
  return { type = m.type, key = key, map = map, x = x, y = y, facing = facing, localId = localId }
end

function Protocol.validate(m)
  if type(m) ~= "table" or type(m.type) ~= "string" then return nil, "not_a_message" end
  local check = validators[m.type]
  if not check then return nil, "unknown_type" end
  return check(m)
end

return Protocol
