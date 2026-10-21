-- One co-op connection: the transport, the hello exchange, the outgoing
-- presence stream and the partner's ghost.  The transport is anything with
-- the src/link/Net.lua shape (update/poll/send/close, .paired/.closed/.error)
-- so tests run it over Net.loopbackPair() without LÖVE.
--
-- States: "waiting" (hosting with no partner yet, or dialing), "handshake"
-- (paired, hellos in flight), "connected", "refused", "closed".

local Session = {}
Session.__index = Session

-- Wall-clock seconds, not logic ticks: the tick rate is not a constant
-- (title screen, fast-forward, a busy frame), and a partner judged on ticks
-- was declared dead after three real seconds.
Session.STALE_SECONDS = 5
Session.TIMEOUT_SECONDS = 15
Session.HANDSHAKE_SECONDS = 10
-- sent whenever nothing else went out for this long, wherever the player
-- is: position updates only exist in the overworld, and a partner on the
-- title screen or in a menu must not look disconnected
Session.KEEPALIVE_SECONDS = 1
-- link messages held for a channel this side has not opened yet
Session.MAX_EARLY = 64

local function defaultClock()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

-- deps: { Protocol, Presence, Ghost, Channel, compat = fn(localHello,
--         remoteHello) -> ok, reason, now = optional clock in seconds }
function Session.new(net, role, localHello, deps)
  local now = deps.now or defaultClock
  local t = now()
  return setmetatable({
    net = net, role = role, localHello = localHello,
    P = deps.Protocol, compat = deps.compat, now = now, offsetOf = deps.offsetOf,
    Channel = deps.Channel, channels = {}, requests = {}, early = {}, earlyCount = 0,
    emotes = 0, lastEmote = nil, npcs = {}, sl = {}, teams = {}, credits = {},
    presence = deps.Presence.new(), ghost = deps.Ghost.new(),
    state = "waiting", reason = nil, peer = nil, peerBusy = "none", busy = "none",
    helloSent = false, lastHeard = t, lastSent = t, pairedAt = nil,
    dropped = 0,
  }, Session)
end

function Session:_send(msg)
  self.net:send(msg)
  self.lastSent = self.now()
end

function Session:_fail(state, reason)
  if self.state == "refused" or self.state == "closed" then return end
  self.state, self.reason = state, reason
  for c, ch in pairs(self.channels) do
    ch:fail("co-op connection lost")
    self.channels[c] = nil
  end
  -- free the port now rather than whenever the socket is collected
  pcall(self.net.close, self.net)
end

function Session:_receive(raw)
  local P = self.P
  local msg, why = P.validate(raw)
  if not msg then
    -- a partner on another protocol version would otherwise just look silent
    if why == "protocol_version" and self.state == "handshake" then
      self:_send(P.bye("protocol_version"))
      self:_fail("refused", "protocol_version")
    end
    self.dropped = self.dropped + 1
    return
  end
  self.lastHeard = self.now()
  if msg.type == P.HELLO then
    if self.state ~= "handshake" then return end
    local ok, reason = self.compat(self.localHello, msg)
    if not ok then
      self:_send(P.bye(reason))
      self:_fail("refused", reason)
      return
    end
    self.peer = { name = msg.name, game = msg.game }
    self.state = "connected"
    -- the partner has no picture of us yet; send one on the next tick
    self.presence:reset()
  elseif msg.type == P.BYE then
    self:_fail("closed", msg.reason == "left" and "partner_left" or msg.reason)
  elseif self.state == "connected" then
    if msg.type == P.POS then
      self.ghost:apply(msg, self.offsetOf)
    elseif msg.type == P.STATE then
      self.peerBusy = msg.busy
    elseif msg.type == P.EMOTE then
      -- counted so the HUD can notice a new one; the ghost acts it out
      self.emotes, self.lastEmote = self.emotes + 1, msg.e
      if msg.e == "wave" then self.ghost:wave() end
    elseif msg.type == P.LINK then
      local ch = self.channels[msg.c]
      if ch then
        ch:push(msg.m)
      elseif self.earlyCount < Session.MAX_EARLY then
        -- the partner opens its end as it answers, so its first link
        -- messages land in the same batch as the answer, before main.lua
        -- has read the answer and opened ours; hold them for openChannel
        local q = self.early[msg.c] or {}
        q[#q + 1] = msg.m
        self.early[msg.c] = q
        self.earlyCount = self.earlyCount + 1
      end
    elseif msg.type == P.CREDIT then
      if #self.credits < 64 then self.credits[#self.credits + 1] = msg end
    elseif msg.type == P.TEAM then
      -- one setup per channel; a second one for the same number is ignored
      if self.teams[msg.c] == nil then self.teams[msg.c] = msg.d end
    elseif msg.type == P.SL then
      if #self.sl < 64 then self.sl[#self.sl + 1] = msg end
    elseif msg.type == P.NPC then
      -- main.lua applies these each tick; a backlog only needs the newest
      if #self.npcs >= 8 then table.remove(self.npcs, 1) end
      self.npcs[#self.npcs + 1] = msg
    elseif msg.type == P.ASK or msg.type == P.ANSWER or msg.type == P.CANCEL then
      -- main.lua owns the prompts; it drains these each tick
      self.requests[#self.requests + 1] = msg
    end
  end
end

-- one logic tick.  snap: Presence.sample(...) for the local player, or nil
-- when there is no overworld to report (title screen, boot)
function Session:tick(snap)
  local net = self.net
  if self.state == "refused" or self.state == "closed" then return end
  net:update()
  local t = self.now()
  if net.paired and self.state == "waiting" then
    self.state, self.pairedAt, self.lastHeard = "handshake", t, t
  end
  if self.state == "handshake" and not self.helloSent then
    self:_send(self.localHello)
    self.helloSent = true
  end
  for _, raw in ipairs(net:poll()) do
    self:_receive(raw)
    if self.state == "refused" or self.state == "closed" then return end
  end
  if net.closed then
    self.netError = net.error
    self:_fail("closed", net.error and "network_error" or "partner_left")
    return
  end
  t = self.now()
  if self.state == "handshake" and t - self.pairedAt > Session.HANDSHAKE_SECONDS then
    self:_fail("closed", "no_hello")
    return
  end
  if self.state ~= "connected" then return end
  if t - self.lastHeard > Session.TIMEOUT_SECONDS then
    self:_fail("closed", "timeout")
    return
  end
  if snap then
    local seq, out = self.presence:tick(snap)
    if seq then self:_send(self.P.pos(seq, out)) end
  end
  if self.now() - self.lastSent >= Session.KEEPALIVE_SECONDS then
    self:_send(self.P.state(self.busy))
  end
  self.ghost:tick()
end

function Session:setBusy(busy)
  self.busy = busy
  if self.state == "connected" then self:_send(self.P.state(busy)) end
end

function Session:emote(e)
  if self.state == "connected" then self:_send(self.P.emote(e)) end
end

-- requests, answers and cancels received since the last call
function Session:takeRequests()
  local list = self.requests
  self.requests = {}
  return list
end

-- coop_npc messages received since the last call
function Session:takeNpcs()
  local list = self.npcs
  self.npcs = {}
  return list
end

-- Soul Link messages received since the last call
function Session:takeSoulLink()
  local list = self.sl
  self.sl = {}
  return list
end

function Session:sendSoulLink(fields)
  if self.state == "connected" then self:_send(self.P.sl(fields)) end
end

function Session:sendNpcs(map, list)
  if self.state == "connected" then self:_send(self.P.npc(map, list)) end
end

function Session:ask(id, act)
  if self.state == "connected" then self:_send(self.P.ask(id, act)) end
end

function Session:answer(id, ok, why)
  if self.state == "connected" then self:_send(self.P.answer(id, ok, why)) end
end

function Session:cancelAsk(id)
  if self.state == "connected" then self:_send(self.P.cancel(id)) end
end

-- shared trainer credit (lib/credit.lua)
function Session:sendCredit(ids, fresh, joint)
  if self.state == "connected" then self:_send(self.P.credit(ids, fresh, joint)) end
end

function Session:takeCredits()
  local list = self.credits
  self.credits = {}
  return list
end

-- Team battle setups (lib/teambattle.lua) for channel c
function Session:sendTeam(c, data)
  if self.state == "connected" then self:_send(self.P.team(c, self.P.packTree(data))) end
end

function Session:takeTeam(c)
  local d = self.teams[c]
  self.teams[c] = nil
  return d
end

-- A link transport for activity c (see lib/channel.lua).  Opening a number
-- that is already open replaces it.
function Session:openChannel(c)
  local old = self.channels[c]
  if old then old:close() end
  local ch = self.Channel.new(c, function(n, m)
    if self.state == "connected" then self:_send(self.P.link(n, m)) end
  end)
  self.channels[c] = ch
  local early = self.early[c]
  if early then
    for _, m in ipairs(early) do ch:push(m) end
    self.earlyCount = self.earlyCount - #early
  end
  -- anything held for other numbers belongs to requests that are over
  self.early, self.earlyCount = {}, 0
  return ch
end

function Session:closeChannel(c)
  local ch = self.channels[c]
  if ch then ch:close() end
  self.channels[c] = nil
end

function Session:stale()
  return self.state == "connected" and self.now() - self.lastHeard > Session.STALE_SECONDS
end

function Session:close(reason)
  if self.state ~= "closed" and self.state ~= "refused" and self.net.paired then
    self:_send(self.P.bye(reason or "left"))
  end
  self:_fail("closed", reason or "left")
end

return Session
