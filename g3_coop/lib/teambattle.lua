-- A team battle: both players side by side against two of the game's own
-- trainers.  Nothing about the battle itself is reimplemented here: it is
-- the engine's link multi battle, run the way the Battle Tower's link multi
-- runs it (src/core/game3/link/tower_link.lua) --
--   * the host (link seat 0) picks the foes, builds their parties with the
--     game's own trainer code and deals the seed;
--   * the two foe seats are "virtual": only the host runs their AI and sends
--     the choices as those seats' link actions, so both games see the same
--     moves (LB.setVirtual, TowerLink.aiAction);
--   * both games run the same battle from the shared seed, comparing turn
--     hashes as every link battle does.
--
-- What differs from the Tower is the parties.  A link battle's parties
-- travel in the vanilla Gen 3 format (Protocol.packMon3), which refuses
-- anything past move 354 / species 411 / item 374 and drops stored natures
-- and third abilities.  A cart that adds moves (the expanded port's
-- Disarming Voice is 574) can't link that way, so here every party travels
-- whole over the co-op session (coop_team) and is handed to LB.beginMulti in
-- place of the usual unpacking.  Both games run the same cart and mods (the
-- hello checks), so a mon one game built is a mon the other can battle.
--
-- After the battle, each player's own mons are written back to their own
-- party from the battle's final state, like a normal trainer battle and
-- unlike a cable battle, and a win marks both trainers beaten in both games.
--
-- With the port's dev.20 engine (porting/full_port/COOP.md) the battle opts
-- in with coopTeam: shared EXP for every player-side mon, owner-only level-up
-- screens and move choices after the battle, the three-faint elimination
-- mark, and wild doubles where balls travel as link actions.  Without that
-- engine the flag is ignored and the battle runs as before (no EXP).

local TeamBattle = {}

-- link seat -> battle seat, and the foe seats, as the Tower lays them out
-- (pokeemerald/src/battle_main.c:1197, battle_controller_opponent.c:1271)
TeamBattle.SEAT_OF_PLAYER = { [0] = 0, [1] = 2 }
TeamBattle.FOE_SEATS = { 3, 1 }
TeamBattle.MAX_PARTY = 6

-- the fields a battle may change on one of the player's mons
-- (src/core/game3/battle_bridge.lua writeback)
local WRITEBACK = {
  "hp", "maxHp", "status", "sleep", "level", "exp", "pp", "maxPp", "ppBonusesPacked",
  "moves", "species", "speciesId", "name", "growthRate", "evs", "friendship", "pokerus",
  "ability", "abilityId",
}
local STATS = {
  { "attack", "atk" }, { "defense", "def" }, { "speed", "spe" },
  { "spAtk", "spa" }, { "spDef", "spd" },
}

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

-- E: { LB, TowerLink, Trainers, TextIR } (main.lua teamEngine)

-- this player's half: name, gender, trainer id and the mons that can go
-- into a battle, with the party slot each came from.  A story partner's
-- mons the engine lent for the fight (Steven's, marked stevenPartner) stay
-- out: in co-op the other player takes that partner's place.
function TeamBattle.mySide(E, session)
  local party, slots = {}, {}
  for i, mon in ipairs(session.party or {}) do
    if #party < TeamBattle.MAX_PARTY and E.LB.eligible(mon) and not mon.stevenPartner then
      party[#party + 1] = plainCopy(mon)
      slots[#party] = i
    end
  end
  local gender = session.gender
  gender = (gender == 1 or gender == "female" or gender == "F") and 1 or 0
  return {
    name = tostring(session.name or "PLAYER"),
    gender = gender,
    trainerId = tonumber(session.trainerId) or 0,
    -- the full id travels for EXP's traded-mon bonus (COOP.md coopTrainers)
    secretId = tonumber(session.secretId) or nil,
    party = party, slots = slots,
  }
end

local function plainText(E, ir)
  if type(ir) == "string" then return ir end
  if type(ir) ~= "table" or not (E.TextIR and E.TextIR.toPlain) then return nil end
  local ok, text = pcall(E.TextIR.toPlain, ir, {})
  return ok and text or nil
end

-- A trainer's mon as the battle would finish it (battle/init.lua
-- foe_mon_from): the vanilla trainer code leaves personality and IVs to be
-- rolled when the battle starts, which in a shared battle has to happen
-- once, here on the host, before the party goes to the partner.
function TeamBattle.completeFoeMon(E, m)
  local Rng, Pokemon = E.Rng, E.Pokemon
  if m.personality == nil then m.personality = Rng.Random32() end
  if type(m.ivs) ~= "table" then
    local iv = tonumber(m.iv)
    if iv == nil and tonumber(m.rawIv) then iv = math.floor(tonumber(m.rawIv) * 31 / 255) end
    if iv then
      m.ivs = { hp = iv, atk = iv, def = iv, spa = iv, spd = iv, spe = iv }
    else
      local iv1, iv2 = Rng.Random(), Rng.Random()
      m.ivs = {
        hp = iv1 % 32, atk = math.floor(iv1 / 32) % 32, def = math.floor(iv1 / 1024) % 32,
        spe = iv2 % 32, spa = math.floor(iv2 / 32) % 32, spd = math.floor(iv2 / 1024) % 32,
      }
    end
  end
  if type(m.evs) ~= "table" then m.evs = { hp = 0, atk = 0, def = 0, spa = 0, spd = 0, spe = 0 } end
  local species = tonumber(m.species or m.id) or 0
  m.species = species
  if m.gender ~= "M" and m.gender ~= "F" and m.gender ~= "U" and Pokemon and Pokemon.gender then
    m.gender = Pokemon.gender(species, m.personality)
  end
  if m.nature == nil and Pokemon and Pokemon.natureId then m.nature = Pokemon.natureId(m.personality) end
  m.level = tonumber(m.level) or 5
  if (type(m.moves) ~= "table" or #m.moves == 0) and Pokemon and Pokemon.movesAtLevel then
    -- pokefirered/src/pokemon.c:2265 a trainer mon with no moveset knows
    -- the last four it learned by its level
    local moves, pp, maxPp = Pokemon.movesAtLevel(species, m.level)
    if moves and #moves > 0 then m.moves, m.pp, m.maxPp = moves, pp, maxPp end
  end
  m.item = tonumber(m.item or m.heldItem) or 0
  m.heldItem = m.item
  if E.Damage and E.Damage.ensureStats and not (tonumber(m.maxHp) and m.maxHp > 0) then
    E.Damage.ensureStats(m, m.level)
    m.hp = m.maxHp
  end
  return m
end

-- One foe trainer, built by the game's own trainer code (a cart may replace
-- Trainers.foeFromId; the expanded port does, with its own teams, spreads
-- and levels).  nil plus a reason when the id has no party.
function TeamBattle.foe(E, trainerId)
  local tid = tonumber(trainerId)
  if not tid then return nil, "no_trainer" end
  local ok, foe = pcall(E.Trainers.foeFromId, tid)
  if not ok or type(foe) ~= "table" or type(foe.party) ~= "table" or #foe.party == 0 then
    return nil, "no_party"
  end
  local okI, info = pcall(E.Trainers.info, tid)
  info = okI and type(info) == "table" and info or {}
  local party = {}
  for i, mon in ipairs(foe.party) do
    if i > TeamBattle.MAX_PARTY then break end
    party[#party + 1] = TeamBattle.completeFoeMon(E, plainCopy(mon))
  end
  local dialogs = info.dialogs or {}
  return {
    trainerId = tid,
    name = tostring(foe.trainerName or info.name or "TRAINER"),
    class = tonumber(foe.trainerClass or info.class),
    className = foe.trainerClassName or info.className,
    pic = tonumber(foe.trainerPicId or foe.trainerPic or info.pic),
    gender = (foe.gender == 1 or foe.gender == "F") and 1 or 0,
    aiFlags = tonumber(foe.aiFlags) or 0,
    defeatText = plainText(E, dialogs.defeat),
    party = party,
  }
end

-- the host's area, for EXP's location-dependent friendship: both games
-- must use the same one (COOP.md coopMapSec)
local function hostMapSec(E, session)
  if not (E.Pokemon and E.Pokemon.currentMapSec) then return nil end
  local ok, sec = pcall(E.Pokemon.currentMapSec, session)
  return ok and tonumber(sec) or nil
end

-- The host's setup also carries the foes and the seed.  With no second
-- trainer, one trainer commands both enemy positions from one shared party
-- (dev.22 coopSharedFoe, COOP.md "One trainer, two enemy positions").
function TeamBattle.hostSetup(E, session, trainerA, trainerB, seed)
  local side = TeamBattle.mySide(E, session)
  local a, whyA = TeamBattle.foe(E, trainerA)
  if not a then return nil, whyA end
  if trainerB == nil then
    side.foes = { a }
    side.sharedFoe = true
    side.seed = math.floor(tonumber(seed) or 0) % 4294967296
    side.mapSec = hostMapSec(E, session)
    return side
  end
  local b, whyB = TeamBattle.foe(E, trainerB)
  if not b then return nil, whyB end
  side.foes = { a, b }
  side.seed = math.floor(tonumber(seed) or 0) % 4294967296
  side.mapSec = hostMapSec(E, session)
  return side
end

-- One wild mon from an encounter roll ({ species, level, item? }), finished
-- on the host the way the battle would finish it.
function TeamBattle.wildMon(E, enc)
  if type(enc) ~= "table" or not tonumber(enc.species) then return nil end
  local m = { species = tonumber(enc.species), level = tonumber(enc.level) or 5,
              item = tonumber(enc.item) or 0, personality = enc.personality, ivs = enc.ivs,
              moves = enc.moves }
  m = TeamBattle.completeFoeMon(E, m)
  -- a cart with its own ability slots (the expanded port) fills them here
  local refresh = E.Pokemon and E.Pokemon._expandedAbilities and E.Pokemon._expandedAbilities.refresh
  if refresh then pcall(refresh, m, m.abilityNum) end
  return m
end

-- A wild double: two encounters rolled on the host's map, each a
-- one-mon foe party.  nil plus a reason when the map has no wild table.
-- pick(encs, roll): optional, may swap rolls (Soul Link's first encounters,
-- lib/tracker.lua pickFirstEncounters).
function TeamBattle.hostWildSetup(E, session, mapId, seed, pick)
  local side = TeamBattle.mySide(E, session)
  -- Sweet Scent's roll: always an encounter from the land table (the
  -- step roll would also test the encounter rate)
  local function roll()
    local ok, enc = pcall(E.Encounters.rollSweetScent, mapId, "land")
    return ok and type(enc) == "table" and enc or nil
  end
  local encs = {}
  for i = 1, 2 do
    encs[i] = roll()
    if not encs[i] then return nil, "no_wild" end
  end
  if pick then
    local ok, picked = pcall(pick, encs, roll)
    if ok and type(picked) == "table" and #picked == 2 then encs = picked end
  end
  local foes = {}
  for i = 1, 2 do
    local m = TeamBattle.wildMon(E, encs[i])
    if not m then return nil, "no_wild" end
    foes[i] = { name = "", wild = true, party = { m } }
  end
  side.foes = foes
  side.wild = true
  side.seed = math.floor(tonumber(seed) or 0) % 4294967296
  side.mapSec = hostMapSec(E, session)
  return side
end

local function hasLiving(E, party)
  for _, mon in ipairs(party or {}) do
    if E.LB.eligible(mon) and (tonumber(mon.hp) or 0) > 0 then return true end
  end
  return false
end

-- A received half or foe, checked enough for the battle code to take it:
-- every mon a table with a species, moves and the fields link_mon_from
-- insists on.
local function checkParty(E, party)
  if type(party) ~= "table" or #party == 0 or #party > TeamBattle.MAX_PARTY then return nil, "bad_party" end
  for i, mon in ipairs(party) do
    if type(mon) ~= "table" then return nil, "bad_mon " .. i end
    if type(mon.moves) ~= "table" or #mon.moves == 0 then return nil, "bad_mon " .. i .. " moves" end
    if mon.personality == nil then return nil, "bad_mon " .. i .. " personality" end
    if type(mon.ivs) ~= "table" then return nil, "bad_mon " .. i .. " ivs" end
    mon.item = tonumber(mon.item or mon.heldItem) or 0
  end
  if not hasLiving(E, party) then return nil, "no_mons" end
  return party
end

-- Start the battle.  mine/peer: the two setups (one of them the host's,
-- with foes and seed); linkSeat: 0 host, 1 join.  onDone(word) gets
-- "win"/"lose"/"draw".  Returns true, or nil plus a reason.
function TeamBattle.begin(E, mine, peer, linkSeat, onDone)
  local LB, TL = E.LB, E.TowerLink
  local host = linkSeat == 0 and mine or peer
  local guest = linkSeat == 0 and peer or mine
  local shared = host.sharedFoe == true
  if type(host.foes) ~= "table" or #host.foes ~= (shared and 1 or 2) then return nil, "no_foes" end
  local seed = math.floor(tonumber(host.seed) or 0) % 4294967296
  local parties = {}
  for _, side in ipairs({ host, guest, host.foes[1], host.foes[2] or false }) do
    if side then
      local party, why = checkParty(E, side.party)
      if not party then return nil, tostring(side.name) .. ": " .. tostring(why) end
      parties[side] = party
    end
  end
  local function seatSetup(side, party)
    return { name = side.name, gender = side.gender, trainerId = side.trainerId, party = party or parties[side] }
  end
  local setups = {
    [TeamBattle.SEAT_OF_PLAYER[0]] = seatSetup(host),
    [TeamBattle.SEAT_OF_PLAYER[1]] = seatSetup(guest),
  }
  if shared then
    -- one trainer's party across both enemy seats: its first mon in seat 3,
    -- the rest (possibly none) in seat 1; both positions draw from the whole
    local all = parties[host.foes[1]]
    local rest = {}
    for i = 2, #all do rest[#rest + 1] = all[i] end
    setups[TeamBattle.FOE_SEATS[1]] = seatSetup(host.foes[1], { all[1] })
    setups[TeamBattle.FOE_SEATS[2]] = seatSetup(host.foes[1], rest)
  else
    setups[TeamBattle.FOE_SEATS[1]] = seatSetup(host.foes[1])
    setups[TeamBattle.FOE_SEATS[2]] = seatSetup(host.foes[2])
  end

  -- the AI's own stream: only the host draws from it, so it must never be
  -- the battle's (tower_link.lua withAiRng)
  TL.battle = { aiRng = LB.makeRng((seed + 0x5EED) % 4294967296), aiFlags = host.foes[1].aiFlags }
  LB.freshBattle()
  LB.mode = LB.MODE_OF.multi
  LB.unionRoom = false
  LB.seed = seed
  LB.seat = linkSeat
  LB._myPacked = {}
  LB._myParty = parties[mine]
  local virtual = { seats = {}, seatMap = TeamBattle.SEAT_OF_PLAYER, unpack = { strict = true } }
  for _, s in ipairs(TeamBattle.FOE_SEATS) do
    virtual.seats[s] = linkSeat == 0 and {
      action = function() return TL.aiAction(s) end,
      switch = function() return TL.aiSwitch(s) end,
    } or {}
  end
  LB.setVirtual(virtual)
  LB.state = "setup"

  local foeA, foeB = host.foes[1], host.foes[2]
  local function row(f) return { class = f.class, className = f.className, name = f.name, pic = f.pic } end
  local function who(side)
    return { name = side.name, trainerId = side.trainerId, secretId = side.secretId }
  end
  local opts = {
    coopTeam = true,
    -- a dropped partner pauses the battle; main.lua offers continue alone
    -- or end (porting/full_port/COOP.md, dev.21)
    coopDisconnect = "pause",
    -- by battler owner: the host is 0 and the guest 2 in both games
    coopTrainers = { [0] = who(host), [2] = who(guest) },
    coopMapSec = host.mapSec,
    scriptedLoss = true,
  }
  if host.wild then
    opts.wild = true
  elseif shared then
    opts.coopSharedFoe = true
    opts.towerLinkMulti = true
    opts.aiFlags = foeA.aiFlags
    opts.trainerItems = { 0, 0, 0, 0 }
    opts.trainerName = foeA.name
    opts.trainerPicId = foeA.pic
    opts.frontierTrainer = row(foeA)
    opts.defeatText = foeA.defeatText
  else
    opts.towerLinkMulti = true
    opts.aiFlags = foeA.aiFlags
    opts.trainerItems = { 0, 0, 0, 0 }
    opts.trainerName = foeA.name
    opts.trainerPicId = foeA.pic
    opts.frontierTrainer = row(foeA)
    opts.frontierTrainerB = row(foeB)
    opts.defeatText = foeA.defeatText
    opts.defeatTextB = foeB.defeatText
  end

  -- LB.beginMulti reads the other seats' parties through unpackMultiParty
  -- (the Gen 3 wire format) and caps each at MULTI_PARTY_SIZE; for this one
  -- call they are the parties above, already whole
  local savedUnpack, savedSize = LB.unpackMultiParty, LB.MULTI_PARTY_SIZE
  LB.unpackMultiParty = function(p)
    if type(p) == "table" and hasLiving(E, p) then return p end
    -- a one-mon trainer leaves the second enemy seat empty
    if shared and type(p) == "table" and #p == 0 then return p end
    return nil, "no_mons"
  end
  LB.MULTI_PARTY_SIZE = TeamBattle.MAX_PARTY
  local ok, started, err = pcall(LB.beginMulti, setups, function(word)
    TL.battle = nil
    if LB.setVirtual then LB.setVirtual(nil) end
    LB._offField = nil
    if onDone then onDone(word) end
  end, { offField = true, battle = opts })
  LB.unpackMultiParty, LB.MULTI_PARTY_SIZE = savedUnpack, savedSize
  if not ok then
    TL.battle = nil
    return nil, tostring(started)
  end
  if started == false then return nil, err or LB.endReason or "start_failed" end
  return true
end

-- The battle's final state -> this player's own party.  st: the battle
-- state (battle.ended); own: this game's battler on the player side;
-- slots: party slot of each mon this player brought, in order.
function TeamBattle.writeback(E, session, st, slots)
  local battleParty = st and st.playerParty
  local owners = st and st.partyOwner and st.partyOwner.player
  local own = st and st.linkOwn
  if type(battleParty) ~= "table" or type(owners) ~= "table" or own == nil then return 0 end
  local n, written = 0, 0
  for i, src in ipairs(battleParty) do
    if owners[i] == own then
      n = n + 1
      local slot = slots and slots[n]
      local mon = slot and session.party and session.party[slot]
      if mon then
        local fields = { _allowMoveRewrite = true }
        for _, k in ipairs(WRITEBACK) do fields[k] = src[k] end
        for _, pair in ipairs(STATS) do
          local v = src[pair[1]] or src[pair[2]]
          fields[pair[1]], fields[pair[2]] = v, v
        end
        E.Party.applyBattleFields(mon, fields)
        if src.status == nil or src.status == 0 then
          mon.status, mon.sleep = nil, src.sleep
          if mon.statusNum then mon.statusNum = 0 end
        end
        local held = src.item or src.heldItem
        if held == 0 or held == "" then held = nil end
        mon.item, mon.heldItem = held, held
        written = written + 1
      end
    end
  end
  return written
end

-- The three-faint limit (campaign co-op): count faints by the battler
-- position that owns them (0 the host, 2 the guest, the same in both
-- games), and on the third mark that owner out; the engine then skips its
-- replacements and the partner fights on.  counts: per-battle table.
-- Returns true when this faint eliminated the owner.
TeamBattle.FAINT_LIMIT = 3
function TeamBattle.onFainted(counts, ev)
  local st = type(ev) == "table" and ev.battle
  local id = type(ev) == "table" and tonumber(ev.battlerId)
  if not (st and st.coopTeam and type(st.eliminated) == "table") then return false end
  -- continuing alone after a disconnect lifts the limit
  if st.coopSoloRequested or st.coopSolo then return false end
  if id ~= 0 and id ~= 2 then return false end
  counts[id] = (counts[id] or 0) + 1
  if counts[id] >= TeamBattle.FAINT_LIMIT and not st.eliminated[id] then
    st.eliminated[id] = true
    return true
  end
  return false
end

-- A win's prize money (user, 2026-10-21): each player gets the full prize
-- for both trainers, as if each had beaten them alone.  The amounts come
-- from the game's own prize rule (a cart's may differ; the expanded port's
-- uses the highest party level).  Returns the amount added.
function TeamBattle.prize(E, session, foes, multiplier)
  local Prize = E.Prize
  if not (Prize and Prize.calcRse and Prize.apply and session) then return 0 end
  local total = 0
  for _, f in ipairs(foes or {}) do
    local tid = tonumber(f.trainerId)
    if tid then
      local ok, amount = pcall(Prize.calcRse, tid, { moneyMultiplier = multiplier or 1 })
      if ok and tonumber(amount) then total = total + amount end
    end
  end
  if total <= 0 then return 0 end
  return (Prize.apply(session, total))
end

-- The same, paid at most once per trainer.  receipts: a list of trainer
-- ids already paid (kept in the save by main.lua), updated in place.
function TeamBattle.settlePrize(E, session, ids, receipts, multiplier)
  local paid = {}
  for _, id in ipairs(receipts) do paid[id] = true end
  local due = {}
  for _, id in ipairs(ids or {}) do
    id = tonumber(id)
    if id and not paid[id] then
      paid[id] = true
      due[#due + 1] = { trainerId = id }
    end
  end
  if #due == 0 then return 0 end
  local got = TeamBattle.prize(E, session, due, multiplier)
  for _, f in ipairs(due) do receipts[#receipts + 1] = f.trainerId end
  return got
end

-- a win: both trainers count as beaten in this game
function TeamBattle.markBeaten(E, foes)
  local Space, Flags = E.Space, E.Flags
  if not (Space and Space.store and Flags) then return false end
  local ctx = Space.vm and Space.vm.ctx
  for _, f in ipairs(foes or {}) do
    local tid = tonumber(f.trainerId)
    if tid then pcall(Flags.setFlag, Space.store, ctx, Flags.trainerFlagId(tid), true) end
  end
  return true
end

return TeamBattle
