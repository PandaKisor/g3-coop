-- The CO-OP > ADDRESS screen: the host's IPv4 address, the port, and what
-- to do on load, edited with the d-pad (or typed on a keyboard) and kept in
-- this player's save.  A sealed cart hands its mods only the cart's own
-- options, so the launcher's settings can't say which of two players hosts
-- or where the other one is; this screen can.
--
-- Logic only: lib/hud.lua draws it, main.lua routes the keys and stores
-- the result.

local ConnEdit = {}
ConnEdit.__index = ConnEdit

ConnEdit.ON_LOAD = { "OFF", "HOST", "JOIN" }
ConnEdit.MIN_PORT, ConnEdit.MAX_PORT = 1024, 65535

-- the fields, left to right
local FIELDS = {
  { key = 1, lo = 0, hi = 255 }, { key = 2, lo = 0, hi = 255 },
  { key = 3, lo = 0, hi = 255 }, { key = 4, lo = 0, hi = 255 },
  { key = "port", lo = ConnEdit.MIN_PORT, hi = ConnEdit.MAX_PORT, big = 100 },
  { key = "onload" },
}
ConnEdit.FIELDS = FIELDS

-- "a.b.c.d" -> {a, b, c, d}, or nil
function ConnEdit.parseIp(text)
  local a, b, c, d = tostring(text or ""):match("^%s*(%d+)%.(%d+)%.(%d+)%.(%d+)%s*$")
  local out = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
  for i = 1, 4 do
    if not out[i] or out[i] > 255 then return nil end
  end
  return out
end

-- s: { address = "a.b.c.d[:port]", port = n, onload = "OFF"|"HOST"|"JOIN" }
function ConnEdit.new(s)
  s = s or {}
  local addr = tostring(s.address or "")
  local port = tonumber(addr:match(":(%d+)%s*$")) or tonumber(s.port) or 7777
  local ip = ConnEdit.parseIp((addr:gsub(":%d+%s*$", ""))) or { 127, 0, 0, 1 }
  local onload = "OFF"
  for _, v in ipairs(ConnEdit.ON_LOAD) do if v == s.onload then onload = v end end
  return setmetatable({
    ip = ip, port = math.max(ConnEdit.MIN_PORT, math.min(ConnEdit.MAX_PORT, math.floor(port))),
    onload = onload, cursor = 1, fresh = true,
  }, ConnEdit)
end

function ConnEdit:field() return FIELDS[self.cursor] end

function ConnEdit:value(i)
  local f = FIELDS[i or self.cursor]
  if f.key == "port" then return self.port end
  if f.key == "onload" then return self.onload end
  return self.ip[f.key]
end

function ConnEdit:_set(v)
  local f = self:field()
  if f.key == "port" then self.port = v
  elseif type(f.key) == "number" then self.ip[f.key] = v end
end

function ConnEdit:_step(by)
  local f = self:field()
  if f.key == "onload" then
    local n = #ConnEdit.ON_LOAD
    for i, v in ipairs(ConnEdit.ON_LOAD) do
      if v == self.onload then
        self.onload = ConnEdit.ON_LOAD[((i - 1 + (by > 0 and 1 or -1)) % n) + 1]
        return
      end
    end
  end
  -- numbers wrap, so 0 -> 255 is one press
  local span = f.hi - f.lo + 1
  self:_set(f.lo + ((self:value() - f.lo + by) % span))
end

function ConnEdit:_digit(d)
  local f = self:field()
  if f.key == "onload" then return end
  local v = self.fresh and d or self:value() * 10 + d
  if v > f.hi then v = d end
  self:_set(v)
  self.fresh = false
end

-- key: "left"/"right"/"up"/"down"/"up10"/"down10"/"0".."9"/"back"/
-- "confirm"/"cancel".  Returns "save", "cancel" or nil.
function ConnEdit:press(key)
  local f = self:field()
  if key == "confirm" then return "save" end
  if key == "cancel" then return "cancel" end
  if key == "left" or key == "right" then
    self.cursor = ((self.cursor - 1 + (key == "right" and 1 or -1)) % #FIELDS) + 1
    self.fresh = true
  elseif key == "up" then self:_step(1); self.fresh = true
  elseif key == "down" then self:_step(-1); self.fresh = true
  elseif key == "up10" then self:_step(f.big or 10); self.fresh = true
  elseif key == "down10" then self:_step(-(f.big or 10)); self.fresh = true
  elseif key == "back" then
    if f.key ~= "onload" then
      -- a port may drop below the minimum while it's being typed;
      -- result() pulls it back up
      self:_set(math.floor(self:value() / 10))
      self.fresh = false
    end
  elseif type(key) == "string" and key:match("^%d$") then
    self:_digit(tonumber(key))
  end
  return nil
end

function ConnEdit:address()
  return table.concat(self.ip, ".")
end

-- what to store; a port typed below the minimum is pulled back up
function ConnEdit:result()
  local port = math.max(ConnEdit.MIN_PORT, math.min(ConnEdit.MAX_PORT, self.port))
  return { address = self:address(), port = port, onload = self.onload }
end

return ConnEdit
