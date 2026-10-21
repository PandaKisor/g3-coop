-- The partner's avatar on this machine.  Positions arrive as validated
-- coop_pos messages; the ghost replays each announced step at its own frame
-- count, so it walks rather than teleports.  It never consults collision:
-- the partner's game already decided the step was legal, and re-judging it
-- here would let the two copies disagree (RFC 0014's rule for stepNow).
--
-- Drawing: drawInto() fills a record shaped like the virtual-object entries
-- Objects.forDraw already hands the field renderer (the Union Room's remote
-- players), in the local player's active-map cells.  main.lua appends it to
-- that draw list, so the partner is drawn by the stock renderer, is never
-- solid, and can stand on a connected neighbour map (the virtual-object
-- layer itself culls anything outside the active map).

local Ghost = {}
Ghost.__index = Ghost

Ghost.CELL = 16
-- a backlog longer than this means we fell behind (a hitch, a long frame);
-- snap to the newest position rather than replaying old steps in fast motion
Ghost.MAX_QUEUE = 3
-- outside the Union Room's 0x40 slots and the link players' 0x7E00/0x7F00
Ghost.VOBJ_ID = 0x6300
-- the wave: two hops of HOP_FRAMES each, HOP_HEIGHT pixels high
Ghost.HOP_FRAMES = 16
Ghost.HOP_HEIGHT = 6
-- peak of a two-cell (ledge) jump, in pixels
Ghost.JUMP_HEIGHT = 10

-- src/core/game3/objects.lua VIRT_DIR_FACE
local DIR_NUM = { down = 1, up = 2, left = 3, right = 4 }
Ghost.DIR_NUM = DIR_NUM

function Ghost.new()
  return setmetatable({
    known = false, map = nil, cellX = 0, cellY = 0, facing = "down",
    moving = false, targetX = nil, targetY = nil, progress = 0, frames = 16,
    animClock = 0, stepFlip = false, gfx = 0, elevation = 3, visible = true,
    queue = {}, lastStepKey = nil, px = nil, py = nil, hop = 0, raiseY = 0,
  }, Ghost)
end

local function stepKey(m)
  return m.x .. "," .. m.y .. ">" .. m.tx .. "," .. m.ty
end

function Ghost:placeAt(x, y, facing)
  self.cellX, self.cellY = x, y
  self.moving, self.progress = false, 0
  self.targetX, self.targetY, self.px, self.py = nil, nil, nil, nil
  if facing then self.facing = facing end
end

-- Shift everything the ghost knows by (dx, dy) cells: the same spot,
-- expressed in another map's coordinates.
function Ghost:_rebase(dx, dy)
  self.cellX, self.cellY = self.cellX + dx, self.cellY + dy
  if self.targetX then self.targetX, self.targetY = self.targetX + dx, self.targetY + dy end
  if self.px then self.px, self.py = self.px + dx * Ghost.CELL, self.py + dy * Ghost.CELL end
  for _, e in ipairs(self.queue) do
    e.x, e.y = e.x + dx, e.y + dy
    if e.tx then e.tx, e.ty = e.tx + dx, e.ty + dy end
  end
end

-- msg: a validated coop_pos.  offsetOf(mapId) -> ox, oy (cells, relative to
-- the local active map) for maps drawn on this screen, else nil.
function Ghost:apply(msg, offsetOf)
  self.gfx, self.elevation, self.visible = msg.g, msg.e, msg.vis
  self.surfing = msg.sf == true
  if self.known and msg.m ~= self.map and offsetOf then
    -- walking across a map seam: both maps are on screen here, so carry the
    -- ghost (and any step in flight) over instead of snapping
    local ox1, oy1 = offsetOf(self.map)
    local ox2, oy2 = offsetOf(msg.m)
    if ox1 and ox2 then
      self:_rebase(ox1 - ox2, oy1 - oy2)
      self.map, self.lastStepKey = msg.m, nil
    end
  end
  if not self.known or msg.m ~= self.map then
    -- first sight, or the partner changed maps: a warp, never a walk
    self.known, self.map = true, msg.m
    self.queue, self.lastStepKey = {}, nil
    self:placeAt(msg.x, msg.y, msg.d)
    if msg.mv then self:_enqueueStep(msg) end
    return
  end
  if msg.mv then
    self:_enqueueStep(msg)
  else
    -- heartbeats repeat a rest; only a changed one is worth queueing
    local tail = self.queue[#self.queue]
    if not (tail and tail.kind == "rest" and tail.x == msg.x and tail.y == msg.y
            and tail.d == msg.d) then
      self.queue[#self.queue + 1] = { kind = "rest", x = msg.x, y = msg.y, d = msg.d }
    end
    self.lastStepKey = nil
  end
  if #self.queue > Ghost.MAX_QUEUE then
    local newest = self.queue[#self.queue]
    self:placeAt(newest.x, newest.y, newest.d)
    self.queue = newest.kind == "step" and { newest } or {}
  end
end

function Ghost:_enqueueStep(msg)
  -- a heartbeat sent mid-step repeats the step it is in; walking it again
  -- would drag the ghost back to the start
  local key = stepKey(msg)
  if key == self.lastStepKey then return end
  self.lastStepKey = key
  self.queue[#self.queue + 1] = { kind = "step", x = msg.x, y = msg.y, d = msg.d,
                                  tx = msg.tx, ty = msg.ty, f = msg.f }
end

function Ghost:_next()
  local entry = table.remove(self.queue, 1)
  if not entry then return end
  if entry.kind == "rest" then
    self:placeAt(entry.x, entry.y, entry.d)
    return
  end
  if self.cellX ~= entry.x or self.cellY ~= entry.y then
    self:placeAt(entry.x, entry.y)
  end
  self.facing = entry.d
  self.moving, self.progress, self.frames = true, 0, entry.f
  self.targetX, self.targetY = entry.tx, entry.ty
  self.animClock = 0
end

function Ghost:wave()
  self.hop = Ghost.HOP_FRAMES * 2
end

-- one game logic tick
function Ghost:tick()
  local raise = 0
  if self.hop > 0 then
    self.hop = self.hop - 1
    local phase = (self.hop % Ghost.HOP_FRAMES) / Ghost.HOP_FRAMES
    raise = -math.floor(math.sin(math.pi * phase) * Ghost.HOP_HEIGHT + 0.5)
  end
  self.raiseY = raise
  if not self.moving then self:_next() end
  if not self.moving then return end
  self.progress = self.progress + 1
  self.animClock = self.animClock + 1
  local dx, dy = self.targetX - self.cellX, self.targetY - self.cellY
  -- same interpolation as Player.tick (src/core/game3/player.lua)
  local span = math.max(math.abs(dx), math.abs(dy), 1)
  local adv = math.floor(self.progress * Ghost.CELL * span / self.frames)
  self.px = self.cellX * Ghost.CELL + (dx / span) * adv
  self.py = self.cellY * Ghost.CELL + (dy / span) * adv
  if span > 1 then
    -- a two-cell step is a ledge jump: arc over it
    self.raiseY = raise - math.floor(math.sin(math.pi * self.progress / self.frames) * Ghost.JUMP_HEIGHT + 0.5)
  end
  if self.progress >= self.frames then
    self.cellX, self.cellY = self.targetX, self.targetY
    self.moving, self.progress = false, 0
    self.targetX, self.targetY, self.px, self.py = nil, nil, nil, nil
    self.stepFlip = not self.stepFlip
    -- start the next step on this same tick so a held direction has no gap
    self:_next()
  end
end

function Ghost:shownOn(mapId)
  return self.known and self.visible and mapId ~= nil and self.map == mapId
end

-- The cell the partner occupies (or is stepping onto) on the local screen,
-- or nil when they are not drawn here.
function Ghost:screenCell(offsetOf)
  if not (self.known and self.visible and offsetOf) then return nil end
  local ox, oy = offsetOf(self.map)
  if not ox then return nil end
  local x, y = self.cellX, self.cellY
  if self.moving then x, y = self.targetX, self.targetY end
  return x + ox, y + oy
end

-- Fill rec (reused across frames) with a draw entry in the shape
-- Objects.forDraw gives the field renderer; nil when not on this screen.
-- spriteFor: GfxIds.spriteFor, mapping a graphics id to a sprite name.
function Ghost:drawInto(rec, offsetOf, spriteFor)
  if not (self.known and self.visible and offsetOf) then return nil end
  local ox, oy = offsetOf(self.map)
  if not ox then return nil end
  rec.virtualId = Ghost.VOBJ_ID
  rec.visible, rec.hidden = true, false
  rec.cellX, rec.cellY = self.cellX + ox, self.cellY + oy
  rec.elevation = self.elevation
  rec.facing = self.facing
  rec.graphicsId = self.gfx
  rec.sprite = spriteFor and spriteFor(self.gfx) or nil
  rec.raiseY = self.raiseY
  rec.moving = self.moving
  rec.px = self.px and self.px + ox * Ghost.CELL or nil
  rec.py = self.py and self.py + oy * Ghost.CELL or nil
  rec.targetX = self.targetX and self.targetX + ox or nil
  rec.targetY = self.targetY and self.targetY + oy or nil
  rec.animClock, rec.stepFrames, rec.stepFlip = self.animClock, self.frames, self.stepFlip
  return rec
end

-- Where the surf blob goes when the partner is surfing on this screen: the
-- ghost's top-left pixel in active-map pixels, and its facing; else nil.
function Ghost:surfBlob(offsetOf)
  if not (self.surfing and self.known and self.visible and offsetOf) then return nil end
  local ox, oy = offsetOf(self.map)
  if not ox then return nil end
  local px = (self.px or self.cellX * Ghost.CELL) + ox * Ghost.CELL
  local py = (self.py or self.cellY * Ghost.CELL) + oy * Ghost.CELL
  return px, py, self.facing
end

return Ghost
