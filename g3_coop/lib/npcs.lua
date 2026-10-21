-- Wandering NPCs, kept where the host's game has them.  Each game moves its
-- own NPCs with its own random numbers, so left alone the two screens
-- disagree within seconds.  While both players stand on the same map, the
-- host (the leader) reports its wanderers' steps and facings, and the
-- joiner (the follower) parks its copies (movement STAY, so the engine's
-- idle mover leaves them alone) and walks them through the host's steps.
--
-- Only the plain wanderers are shared: WALK, LOOK, LOOK_AROUND, BACK_FORTH
-- and SEQUENCE.  Trainers (sight > 0) stay local, as do NPCs a script is
-- moving, NPCs one save shows and the other hides, and everything on a
-- connected neighbour map.  O is src/core/game3/objects.lua.

local Npcs = {}
Npcs.__index = Npcs

-- a full report this often, so a follower that missed a step catches up
Npcs.HEARTBEAT_TICKS = 90
-- the follower gives its NPCs back after this long without a report
-- (the host went into a battle or a menu, or left the map)
Npcs.RELEASE_SECONDS = 3
Npcs.MAX = 32
Npcs.MAX_ID = 255
Npcs.SYNCED = { WALK = true, LOOK = true, LOOK_AROUND = true, BACK_FORTH = true, SEQUENCE = true }

local CELL = 16
local DIR_OF = { ["0,-1"] = "up", ["0,1"] = "down", ["-1,0"] = "left", ["1,0"] = "right" }

function Npcs.new(now)
  return setmetatable({ now = now, map = nil, last = {}, since = 0,
                        held = {}, pending = {}, heardAt = nil }, Npcs)
end

local function movementOf(eo)
  return tostring(eo._g3coopMovement or eo.movement or ""):upper()
end

function Npcs.eligible(eo)
  if type(eo) ~= "table" or eo.foreignMap or eo.hidden or eo.visible == false then return false end
  local lid = tonumber(eo.localId) or 0
  if lid < 1 or lid > Npcs.MAX_ID then return false end
  if (tonumber(eo.sight) or 0) > 0 then return false end
  return Npcs.SYNCED[movementOf(eo)] == true
end

-- ------------------------------------------------------------------ leader

-- The entries worth sending this tick for map mapId: the NPCs whose step
-- or facing changed, or all of them on a heartbeat.
function Npcs:collect(O, mapId)
  if mapId ~= self.map then
    self.map, self.last, self.since = mapId, {}, Npcs.HEARTBEAT_TICKS
  end
  self.since = self.since + 1
  local full = self.since >= Npcs.HEARTBEAT_TICKS
  if full then self.since = 0 end
  local out = {}
  for _, lid in ipairs(O._order or {}) do
    local eo = O._byId[lid]
    if Npcs.eligible(eo) and not eo.scriptBusy and not (O._tracks and O._tracks[lid]) then
      local e = { id = lid, x = eo.cellX, y = eo.cellY, d = eo.facing or "down" }
      if eo.moving and eo.targetX and (eo.targetX ~= eo.cellX or eo.targetY ~= eo.cellY) then
        e.tx, e.ty, e.f = eo.targetX, eo.targetY, eo.stepFrames or 16
      end
      local key = e.x .. "," .. e.y .. "," .. e.d .. "," .. tostring(e.tx) .. "," .. tostring(e.ty)
      if (full or self.last[lid] ~= key) and #out < Npcs.MAX then
        out[#out + 1] = e
        self.last[lid] = key
      end
    end
  end
  return out
end

-- the partner left the map: report everything afresh when they return
function Npcs:forget()
  self.map, self.last = nil, {}
end

-- ---------------------------------------------------------------- follower

function Npcs:_hold(eo)
  if eo._g3coopMovement then return end
  eo._g3coopMovement = eo.movement
  eo.movement = "STAY"
  self.held[eo] = true
end

-- Give every parked NPC back to the engine's own idle mover.
function Npcs:release()
  for eo in pairs(self.held) do
    -- a script that gave it a new movement meanwhile wins
    if eo.movement == "STAY" then eo.movement = eo._g3coopMovement end
    eo._g3coopMovement = nil
  end
  self.held, self.pending, self.heardAt = {}, {}, nil
end

-- msg: a validated coop_npc for the map we are on
function Npcs:receive(O, msg)
  if msg.m ~= self.map then
    self:release()
    self.map = msg.m
  end
  self.heardAt = self.now()
  for _, e in ipairs(msg.n) do
    local eo = O._byId and O._byId[e.id]
    if Npcs.eligible(eo) then
      self:_hold(eo)
      self.pending[eo] = e
    end
  end
end

local function place(eo, x, y)
  eo.cellX, eo.cellY = x, y
  eo.px, eo.py = x * CELL, y * CELL
  eo.targetX, eo.targetY = x, y
  eo.moving, eo.progress = false, 0
  if eo.def then eo.def.x, eo.def.y = x, y end
end

-- One tick on the follower.  canMove() is false while a script or a menu
-- has the field (an NPC we're talking to keeps facing us); blocked(x, y)
-- is true where our own player stands.
function Npcs:update(O, mapId, canMove, blocked)
  if next(self.held) == nil then return end
  if mapId ~= self.map or (self.heardAt and self.now() - self.heardAt > Npcs.RELEASE_SECONDS) then
    return self:release()
  end
  for eo in pairs(self.held) do
    if eo.movement ~= "STAY" or O._byId[eo.localId] ~= eo then
      -- a script changed its movement, or the map reloaded its objects
      if eo.movement == "STAY" then eo.movement = eo._g3coopMovement end
      eo._g3coopMovement = nil
      self.held[eo], self.pending[eo] = nil, nil
    end
  end
  if not canMove() then return end
  for eo, e in pairs(self.pending) do
    if not eo.moving and not eo.scriptBusy then
      self.pending[eo] = nil
      if eo.cellX ~= e.x or eo.cellY ~= e.y then
        if not blocked(e.x, e.y) then place(eo, e.x, e.y) end
      end
      if e.tx and eo.cellX == e.x and eo.cellY == e.y and not blocked(e.tx, e.ty) then
        local dir = DIR_OF[(e.tx - e.x) .. "," .. (e.ty - e.y)]
        O.pushStep(eo, dir, e.f)
      else
        eo.facing = e.d
      end
    end
  end
end

return Npcs
