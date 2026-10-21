-- Trading whole mons.  The engine's trade (src/core/game3/link/trade.lua)
-- sends each mon in the vanilla Gen 3 format and reads it back with a
-- strict unpack that refuses anything past move 354 / species 411 / item
-- 374: on a cart that adds moves (the Inclement port's Disarming Voice is
-- 574), one such mon in either party closes the trade screen for both.
--
-- During a co-op trade both games first send their whole parties over the
-- co-op session (coop_team, like a team battle).  The trade itself runs
-- unchanged -- what is shown, the "is this the mon that was shown" check,
-- the digests both games compare before committing all still use the Gen 3
-- packets -- except that LT.unpackMon, the one place a received mon is
-- rebuilt, hands back the whole mon with the same personality and trainer
-- id instead.  A mon the lookup doesn't know (nothing should be missing)
-- falls back to the engine's own unpacking.

local TradeFull = {}

local function plainCopy(v, depth)
  depth = depth or 0
  if type(v) ~= "table" then
    if type(v) == "function" or type(v) == "userdata" or type(v) == "thread" then return nil end
    return v
  end
  if depth > 6 then return nil end
  local out = {}
  for k, val in pairs(v) do
    if type(k) == "string" or type(k) == "number" then out[k] = plainCopy(val, depth + 1) end
  end
  return out
end
TradeFull.copy = plainCopy

-- the identity Protocol.packMon3 keeps: personality and the full 32-bit
-- trainer id (otId's low half plus otSecretId)
function TradeFull.key(mon)
  if type(mon) ~= "table" or mon.personality == nil then return nil end
  local otFull = math.floor(tonumber(mon.otId) or 0) % 4294967296
  local secret = tonumber(mon.otSecretId)
  if secret == nil then secret = math.floor(otFull / 65536) end
  return ("%d:%d:%d"):format(math.floor(tonumber(mon.personality) or 0) % 4294967296,
    otFull % 65536, math.floor(secret) % 65536)
end

-- what this game sends: every mon it could offer
function TradeFull.side(session)
  local party = {}
  for i, mon in ipairs(session and session.party or {}) do
    if i > 6 then break end
    party[#party + 1] = plainCopy(mon)
  end
  return { tradeParty = party }
end

-- A lookup from both parties: the partner's, and this game's own (a mon
-- this game trades away can come back in a later round).
function TradeFull.lookup(mine, theirs)
  local byKey = {}
  for _, side in ipairs({ mine, theirs }) do
    for _, mon in ipairs(side and side.tradeParty or {}) do
      local k = TradeFull.key(mon)
      if k and type(mon.moves) == "table" and #mon.moves > 0 then byKey[k] = mon end
    end
  end
  return byKey
end

-- Swap LT.unpackMon for the length of one trade.  Returns the function that
-- puts the engine's back.
function TradeFull.install(LT, byKey)
  local original = LT.unpackMon
  LT.unpackMon = function(packed)
    local whole = byKey[TradeFull.key(packed)]
    if whole then return plainCopy(whole) end
    return original(packed)
  end
  return function()
    if LT.unpackMon ~= original then LT.unpackMon = original end
  end
end

-- The same for a co-op battle (link/battle.lua): both parties are read
-- through LB.unpackParty.  Each packet's battle state (HP, status, PP: the
-- link battle heals parties before packing them) goes onto the whole mon,
-- and a forced level (the link battle's level 50) is applied the way the
-- strict unpack applies it, with stats worked out again at that level.
-- E: { Pokemon, SummaryData }.  Any mon the lookup doesn't know sends the
-- whole party through the engine's unpack.
function TradeFull.installBattle(LB, byKey, E)
  local original = LB.unpackParty
  LB.unpackParty = function(packed, opts)
    if type(packed) ~= "table" or #packed == 0 or #packed > 6 then return original(packed, opts) end
    opts = opts or (LB.unpackOpts and LB.unpackOpts()) or {}
    local out = {}
    for i = 1, #packed do
      local p = packed[i]
      local whole = byKey[TradeFull.key(p)]
      if not whole then return original(packed, opts) end
      local m = plainCopy(whole)
      m.hp, m.status = tonumber(p.hp) or m.hp, p.status
      if p.status == "" then m.status = nil end
      for slot, entry in ipairs(type(p.moves) == "table" and p.moves or {}) do
        if type(m.pp) == "table" and type(entry) == "table" and tonumber(entry.pp) then m.pp[slot] = entry.pp end
      end
      local force = tonumber(opts.forceLevel)
      if force and E.Pokemon and E.Pokemon.applyStats then
        m.level = math.max(1, math.min(100, math.floor(force)))
        if E.SummaryData and E.Pokemon.growthRate then
          m.exp = E.SummaryData.expForLevel(E.Pokemon.growthRate(m.species), m.level)
        end
        E.Pokemon.applyStats(m)
        m.hp = m.maxHp
      end
      local item = tonumber(m.item or m.heldItem) or 0
      m.item, m.heldItem = item, item
      if LB.applyLinkStats then
        local linked = LB.applyLinkStats(m)
        if not linked then return original(packed, opts) end
        m = linked
      end
      out[i] = m
    end
    return out
  end
  return function()
    if LB.unpackParty ~= original then LB.unpackParty = original end
  end
end

return TradeFull
