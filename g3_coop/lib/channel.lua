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

local Channel = {}
Channel.__index = Channel

-- send(c, msg): how the owning session puts an envelope on the wire
function Channel.new(c, send)
  return setmetatable({
    c = c, _send = send, inbox = {},
    paired = true, closed = false, error = nil,
  }, Channel)
end

function Channel:update() end

function Channel:poll()
  local msgs = self.inbox
  self.inbox = {}
  return msgs
end

function Channel:send(msg)
  if self.closed then return end
  self._send(self.c, msg)
end

-- from the session: one inner message that arrived for this channel
function Channel:push(msg)
  if not self.closed then self.inbox[#self.inbox + 1] = msg end
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
