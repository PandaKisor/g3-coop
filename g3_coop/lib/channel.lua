-- A link transport carried inside the co-op connection.  The engine's
-- Game3Link (and the battle and trade code on top of it) wants a transport
-- of its own with the src/link/Net.lua shape; the co-op session already owns
-- the only socket.  A Channel is that shape: what the engine sends goes out
-- wrapped in coop_link messages on this channel's number, and what arrives
-- for the number is queued for the engine to poll.
--
-- Closing a channel ends only the activity on it.  When the co-op session
-- itself dies, it fails every open channel, which the engine sees as the
-- partner dropping (a battle ends as a draw, an unfinished trade aborts).
--
-- A resumable channel (a team battle) outlives a connection that drops without
-- a goodbye: it suspends instead of failing, every message carries a number
-- and an ack, and a new session resends what the partner never got. The engine
-- just sees a slow partner.

local Channel = {}
Channel.__index = Channel

-- send(c, msg): how the owning session puts an envelope on the wire
function Channel.new(c, send)
  return setmetatable({
    c = c, _send = send, inbox = {},
    paired = true, closed = false, error = nil,
    seq = 0, got = 0, outbox = {},
  }, Channel)
end

function Channel:update() end

function Channel:poll()
  local msgs = self.inbox
  self.inbox = {}
  return msgs
end

Channel.MAX_OUTBOX = 4096

function Channel:send(msg)
  if self.closed then return end
  self.seq = self.seq + 1
  local box = self.outbox
  box[#box + 1] = { self.seq, msg }
  if #box > Channel.MAX_OUTBOX then table.remove(box, 1) end
  if not self.suspended then self._send(self.c, msg, self.seq, self.got) end
end

-- the partner has everything up to `n`
function Channel:acked(n)
  local box, i = self.outbox, 1
  while box[i] and box[i][1] <= n do i = i + 1 end
  if i > 1 then
    local kept = {}
    for j = i, #box do kept[#kept + 1] = box[j] end
    self.outbox = kept
  end
end

function Channel:suspend() self.suspended = true end

-- a new session's sender; nothing goes out until the partner says what it has
function Channel:rebind(send) self._send = send end

function Channel:resend(peerGot)
  self:acked(tonumber(peerGot) or 0)
  self.suspended = false
  for _, row in ipairs(self.outbox) do self._send(self.c, row[2], row[1], self.got) end
end

-- from the session: one inner message that arrived for this channel.
-- With peerSeat set (a team battle), a message that names no seat gets the
-- partner's: the relay stamps every message with its sender's seat
-- (relay_transport.lua), and the link multi battle files each action under
-- that seat; a direct link has no relay to do it.
function Channel:push(msg, seq, ack)
  if self.closed then return end
  if ack then self:acked(ack) end
  if seq then
    if seq <= self.got then return end
    self.got = seq
  end
  if self.peerSeat ~= nil and type(msg) == "table" and msg.seat == nil then msg.seat = self.peerSeat end
  self.inbox[#self.inbox + 1] = msg
end

function Channel:close()
  self.closed = true
end

-- from the session: the connection underneath is gone
function Channel:fail(err)
  if self.closed then return end
  self.error = err or "co-op connection lost"
  self.closed = true
end

return Channel
