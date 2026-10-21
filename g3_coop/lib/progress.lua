-- Shared story progression (C9 / the port's COOP-PROGRESSION.md, API 1).
-- A rival, gym or story fight runs its post-battle script in both games:
-- the initiator's own script carries on after the battle, and the partner's
-- game replays the same continuation against its own bag, party and story
-- (porting/full_port/COOP-PROGRESSION.md "Required co-op sequence").
--
-- Each event has a saved receipt in both games (the port keeps them, in
-- the save).  This module moves the receipts between the games:
--
--   prep     initiator -> partner: id + descriptor, before the battle
--   prepped  partner -> initiator: ok, or why not
--   event    either way: id + descriptor + result (after the battle, on a
--            called-off fight, and to catch a partner up on reconnect)
--   done     "my continuation finished"; the other game then acknowledges
--   have     on connect: every saved receipt and its status, so events
--            made apart (a dropped partner, an older save) catch up
--
-- Results: "win", "lose" or "cancel" (a fight called off or abandoned).  A
-- game that was dropped from the battle and ended it leaves its receipt
-- unresolved: the partner who carried on alone decides it on reconnect.
--
-- Pure: main.lua supplies the port's API, the transport and the field.

local Progress = {}
Progress.__index = Progress

-- how long the initiator waits for the partner to prepare
Progress.PREP_SECONDS = 8
-- how often a queued replay is tried while the field is busy
Progress.RETRY_SECONDS = 0.5
-- a prepared receipt the partner never fought (no battle started) is
-- linked to the next joint battle only this long
Progress.EXPECT_SECONDS = 30

local DIFFERENT = "Your partner's game ended that fight differently: each of you keeps your own result."

-- replay() refusals that clear on their own
local WAIT = { script_busy = true, battle_busy = true, ui_busy = true }

-- deps: { api = fn() -> coopProgress API 1 or nil, send = fn(fields) (only
--         while connected; nil otherwise), connected = fn() -> bool,
--         now = clock, toast = fn(text, secs), newId = fn() -> string,
--         canJoin = fn() -> bool (free to take a partner's fight),
--         idle = fn() -> bool (the field can start a scene),
--         held = fn() -> id of the initiator's own held event or nil,
--         mapName = fn(mapId) -> words, log = fn(fmt, ...) }
function Progress.new(deps)
  return setmetatable({
    d = deps, prep = nil, expect = nil, live = {}, peerDone = {}, told = {},
    running = {}, nextTry = 0,
  }, Progress)
end

function Progress:api()
  local a = self.d.api()
  if type(a) == "table" and a.API == 1 then return a end
  return nil
end

function Progress:_send(fields)
  if self.d.connected() then self.d.send(fields) end
end

-- say something about event id once per reason
function Progress:_tell(id, why, text, secs)
  local key = tostring(id) .. "|" .. tostring(why)
  if self.told[key] then return end
  self.told[key] = true
  self.d.toast(text, secs or 6)
end

-- the whole saved receipt, as the port gives it
function Progress:_event(id, result)
  local a = self:api()
  local r = a and a.get(id)
  if type(r) ~= "table" then return nil end
  return { op = "event", id = id, d = r.descriptor, r = result or r.result }
end

-- ----------------------------------------------------- the initiator side

-- Prepare the held fight's event and ask the partner to prepare it too.
-- ready(id) runs once both games have it; failed(why) once it can't be.
-- Returns the event id, or nil plus why (nothing was sent).
function Progress:begin(descriptor, ready, failed)
  local a = self:api()
  if not a then return nil, "no_api" end
  if self.prep then return nil, "busy" end
  local id = self.d.newId()
  local ok, why = a.prepare(id, descriptor, true)
  if not ok then return nil, why end
  self.prep = { id = id, at = self.d.now(), ready = ready, failed = failed }
  self.live[id] = true
  self:_send({ op = "prep", id = id, d = descriptor })
  return id
end

-- refused: the partner said why, so it has no receipt to call off
function Progress:_prepFailed(why, refused)
  local p = self.prep
  self.prep = nil
  if not p then return end
  self:finish(p.id, "cancel", refused)
  if p.failed then p.failed(why) end
end

-- A local result for event id: "win", "lose", "cancel", or nil (this game
-- was dropped and ended the fight: the partner decides).  Resolving twice
-- with the same word is harmless.  quiet: don't tell the partner.  Returns
-- the port's status.
function Progress:finish(id, result, quiet)
  local a = self:api()
  if not (a and id) then return nil end
  self.live[id] = nil
  if self.expect and self.expect.id == id then self.expect = nil end
  if result == nil then return a.status(id) end
  local ok, st = a.resolve(id, result)
  if not ok then
    self.d.log("progress %s: resolve %s: %s", id, tostring(result), tostring(st))
    return a.status(id)
  end
  local msg = not quiet and self:_event(id, result)
  if msg then self:_send(msg) end
  return st
end

-- the initiator's own script was released with a winning result: its
-- continuation is running now (the port finishes it with coop.progress)
function Progress:started(id)
  if id then self.running[id] = true end
end

-- ------------------------------------------------------ the partner side

-- the event the partner just prepared, for the joint battle starting now
function Progress:expected()
  local e = self.expect
  if not e then return nil end
  self.expect = nil
  if self.d.now() - e.at > Progress.EXPECT_SECONDS then return nil end
  self.live[e.id] = true
  return e.id
end

function Progress:_onPrep(m)
  local a = self:api()
  if not a then
    self:_send({ op = "prepped", id = m.id, ok = false, why = "no_api" })
    return
  end
  if not self.d.canJoin() then
    self:_send({ op = "prepped", id = m.id, ok = false, why = "busy" })
    return
  end
  local ok, why = a.prepare(m.id, m.d, false)
  if ok then self.expect = { id = m.id, at = self.d.now() } end
  self:_send({ op = "prepped", id = m.id, ok = ok == true, why = not ok and tostring(why) or nil })
end

function Progress:_onPrepped(m)
  local p = self.prep
  if not (p and p.id == m.id) then return end
  if m.ok then
    self.prep = nil
    if p.ready then p.ready(p.id) end
  else
    self:_prepFailed(m.why or "error", true)
  end
end

-- a partner's receipt: prepare it here if it's new, take its result
function Progress:_onEvent(m)
  local a = self:api()
  if not a then return end
  local st = a.status(m.id)
  if st == "unknown" then
    if type(m.d) ~= "table" then return end
    local ok, why = a.prepare(m.id, m.d, false)
    if not ok then
      self.d.log("progress %s: prepare: %s", m.id, tostring(why))
      self:_tell(m.id, why, "Couldn't take the story event from your partner (" .. tostring(why) .. ").")
      return
    end
  end
  if m.r then
    local ok, why = a.resolve(m.id, m.r)
    if not ok then
      self.d.log("progress %s: resolve %s: %s", m.id, tostring(m.r), tostring(why))
      if why == "result_conflict" then
        -- the games ended the fight differently (each player carried on
        -- alone): each keeps its own; a finished one needn't wait
        if a.status(m.id) == "done" and m.r ~= "win" then a.ack(m.id) end
        self:_tell(m.id, "conflict", DIFFERENT, 7)
      end
      return
    end
    self.live[m.id] = nil
    if self.expect and self.expect.id == m.id then self.expect = nil end
  end
  -- they may be waiting to hear we finished
  if a.status(m.id) == "done" then self:_send({ op = "done", id = m.id }) end
end

function Progress:_onDone(m)
  local a = self:api()
  if not a then return end
  if a.status(m.id) == "done" then a.ack(m.id) else self.peerDone[m.id] = true end
end

-- ------------------------------------------------------------ reconnect

function Progress:connected()
  local a = self:api()
  if not a then return end
  local list = {}
  for _, id in ipairs(a.history()) do
    local st = a.status(id)
    list[#list + 1] = { id = id, s = st, live = self.live[id] or nil }
  end
  self:_send({ op = "have", list = list })
end

function Progress:_onHave(m)
  local a = self:api()
  if not a then return end
  local peer = {}
  for _, e in ipairs(m.list or {}) do peer[e.id] = e end
  for _, id in ipairs(a.history()) do
    local st, acked = a.status(id)
    local e = peer[id]
    if st == "battle" then
      -- unresolved here: nobody fought it to the end, unless they did
      local mine = self.live[id] or (self.prep and self.prep.id == id)
      if not mine and (e == nil or e.s == "cancelled" or (e.s == "battle" and not e.live)) then
        self:finish(id, "cancel")
      end
    elseif e == nil or e.s == "battle" then
      -- they don't have its result: send it (an ended fight they never saw
      -- the end of, or an older save)
      if not (e and e.live) and not (e == nil and st == "cancelled") then
        local msg = self:_event(id)
        if msg then self:_send(msg) end
      end
    elseif st == "done" and not acked then
      if e.s == "done" then a.ack(id)
      elseif e.s == "cancelled" then
        -- each carried on alone and the fight ended differently: each
        -- keeps its own result, and this one needn't wait
        a.ack(id)
        self:_tell(id, "conflict", DIFFERENT, 7)
      end
    elseif st == "cancelled" and (e.s == "done" or e.s == "queued" or e.s == "running") then
      self:_tell(id, "conflict", DIFFERENT, 7)
    end
    if st == "done" and not acked then self:_send({ op = "done", id = id }) end
  end
end

-- a coop_prog message from the partner (validated by lib/protocol.lua)
function Progress:onMessage(m)
  if m.op == "prep" then self:_onPrep(m)
  elseif m.op == "prepped" then self:_onPrepped(m)
  elseif m.op == "event" then self:_onEvent(m)
  elseif m.op == "done" then self:_onDone(m)
  elseif m.op == "have" then self:_onHave(m)
  end
end

-- the port's coop.progress event: { id, status, result, replay }
function Progress:onStatus(ev)
  if type(ev) ~= "table" or not ev.id then return end
  local a = self:api()
  if not a then return end
  if ev.status == "running" then
    self.running[ev.id] = true
    return
  end
  self.running[ev.id] = nil
  if ev.status == "done" then
    self:_send({ op = "done", id = ev.id })
    if self.peerDone[ev.id] then
      self.peerDone[ev.id] = nil
      a.ack(ev.id)
    end
  elseif ev.status == "failed" then
    self:_tell(ev.id, "failed", "The story scene failed. Reload your last save before going on.", 10)
  end
end

-- a story scene is playing in this game (incoming NPC moves wait)
function Progress:busy()
  return next(self.running) ~= nil or self.prep ~= nil
end

-- ------------------------------------------------------------ each tick

function Progress:tick()
  local now = self.d.now()
  local p = self.prep
  if p and now - p.at > Progress.PREP_SECONDS then self:_prepFailed("no_reply") end
  if now < self.nextTry then return end
  self.nextTry = now + Progress.RETRY_SECONDS
  local a = self:api()
  if not a then return end
  local held = self.d.held()
  for _, id in ipairs(a.pending()) do
    local st = a.status(id)
    if st == "queued" and id ~= held and not self.running[id] and self.d.idle() then
      local ok, why = a.replay(id)
      if ok then
        self.running[id] = a.status(id) == "running" or nil
      elseif why == "return_to_map" then
        local r = a.get(id)
        local where = r and r.descriptor and self.d.mapName(r.descriptor.map) or "where the fight was"
        self:_tell(id, why, "Go back to " .. tostring(where) .. " to finish the story event with your partner.", 8)
      elseif not WAIT[why] then
        self.d.log("progress %s: replay: %s", id, tostring(why))
        self:_tell(id, why, "The story event couldn't play here (" .. tostring(why) .. ").", 8)
      end
      return
    elseif st == "failed" then
      self:_tell(id, "failed", "The story scene failed. Reload your last save before going on.", 10)
    end
  end
end

return Progress
