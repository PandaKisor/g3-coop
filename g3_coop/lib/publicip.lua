-- The router's internet address, for the host's card: Net only knows this
-- PC's address on the home network, which a partner elsewhere can't reach.
-- Asked of a public "what is my IP" service, once per hosting, on a
-- background job.  The host's own address is all these services learn, and
-- with no answer the card just keeps the home address.

local PublicIp = {}
PublicIp.__index = PublicIp

-- the IPv4 answers only: ENet here joins IPv4 addresses
PublicIp.URLS = { "https://api.ipify.org", "https://ipv4.icanhazip.com" }

-- fetch: mod.fetch; parseIp: text -> a table, or nil if it isn't an IPv4
function PublicIp.new(fetch, parseIp)
  return setmetatable({ fetch = fetch, parseIp = parseIp, state = "idle", index = 0 }, PublicIp)
end

function PublicIp:_next()
  self.index = self.index + 1
  local url = self.URLS[self.index]
  local job = url and self.fetch and self.fetch:available() and self.fetch:get(url, { maxSeconds = 8 })
  self.job = job or nil
  self.state = job and "asking" or "failed"
end

function PublicIp:start()
  if self.state == "idle" then self:_next() end
end

-- every tick; poll never blocks
function PublicIp:update()
  if not self.job then return end
  local r = self.fetch:poll(self.job)
  if r.status == "pending" then return end
  self.fetch:release(self.job)
  self.job = nil
  local ip = r.status == "ok" and tostring(r.body or ""):match("^%s*(.-)%s*$") or nil
  if ip and self.parseIp(ip) then
    self.ip, self.state = ip, "found"
  else
    self:_next()
  end
end

-- hosting stopped: the next hosting asks again (the address may have changed)
function PublicIp:reset()
  if self.job then self.fetch:cancel(self.job) self.fetch:release(self.job) end
  self.job, self.ip, self.state, self.index = nil, nil, "idle", 0
end

-- lan: Net's "ip:port".  Returns "ip:port" on the internet, or nil.
function PublicIp:address(lan)
  local port = self.ip and tostring(lan or ""):match(":(%d+)$")
  return port and (self.ip .. ":" .. port) or nil
end

return PublicIp
