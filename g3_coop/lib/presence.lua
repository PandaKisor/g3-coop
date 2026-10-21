-- The local player, as the partner needs to see them.  sample() reads the
-- live avatar; tick() decides whether that is worth a message.  A step is
-- announced once, when it starts, with its destination and frame count, so
-- the partner's copy walks the same step at the same speed instead of
-- chasing a stream of pixel positions.

local Presence = {}
Presence.__index = Presence

-- a full snapshot every second even when nothing changed: it repairs a
-- partner that joined late, reloaded the map, or dropped a ghost
Presence.HEARTBEAT_TICKS = 60

function Presence.new()
  return setmetatable({ seq = 0, last = nil, sinceSend = 0 }, Presence)
end

-- player: the game3 Player module (or a table shaped like it)
function Presence.sample(player, mapId, gfx, visible)
  local P = player
  local snap = {
    m = mapId, x = P.cellX, y = P.cellY, d = P.facing or "down",
    mv = P.moving == true, g = gfx or 0, e = P.elevation or 3,
    vis = visible ~= false and P.visible ~= false,
    -- riding a surfing POKeMON (including the hop on and off): the partner
    -- draws the blob under the ghost, which the field only does for its
    -- own player
    sf = (P.surfing or P.surfHopping or P.dismounting) and not P.underwater or false,
  }
  if snap.mv then
    snap.tx, snap.ty, snap.f = P.targetX, P.targetY, P.stepFrames or 16
  end
  return snap
end

local KEYS = { "m", "x", "y", "d", "mv", "tx", "ty", "f", "g", "e", "vis", "sf" }

local function same(a, b)
  if not (a and b) then return false end
  for _, k in ipairs(KEYS) do
    if a[k] ~= b[k] then return false end
  end
  return true
end

-- the snapshot to send this tick, with its sequence number, or nil
function Presence:tick(snap)
  self.sinceSend = self.sinceSend + 1
  if snap.m == nil then return nil end
  if same(snap, self.last) and self.sinceSend < Presence.HEARTBEAT_TICKS then
    return nil
  end
  self.seq = self.seq + 1
  self.last = snap
  self.sinceSend = 0
  return self.seq, snap
end

function Presence:reset()
  self.last = nil
  self.sinceSend = 0
end

return Presence
