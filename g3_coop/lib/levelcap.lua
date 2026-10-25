-- Level caps: no POKeMON may grow past the level of the next big fight's
-- ace (its highest-level POKeMON).  The big fights are each game's rivals,
-- gym leaders, villain bosses and admins, and the League, in story order.
-- Their levels come from the game's own trainer data, so a mod that
-- rebalances trainers (the Inclement port) moves the caps with it.
--
-- "Next" is the first fight after the last one beaten, so an optional
-- fight skipped (a rival you walked past) stops counting once a later boss
-- falls.  The cap never goes down: it is at least the ace of every fight
-- already won.  After the last fight there is no cap.
--
-- Pure: main.lua supplies resolve(name) -> trainer id or nil, beaten(id)
-- and ace(id) -> highest party level or nil.

local LevelCap = {}

local function rival(place, key)
  local names = {}
  for _, who in ipairs({ "BRENDAN", "MAY" }) do
    for _, mon in ipairs({ "MUDKIP", "TREECKO", "TORCHIC" }) do
      names[#names + 1] = ("TRAINER_%s_%s_%s"):format(who, key, mon)
    end
  end
  return { label = "RIVAL, " .. place, names = names }
end

-- An Emerald rival fight's label with the rival's name: a boy plays
-- against MAY, a girl against BRENDAN (gender 0 = boy)
function LevelCap.named(label, gender)
  if type(label) ~= "string" or label:sub(1, 7) ~= "RIVAL, " or gender == nil then return label end
  return (tonumber(gender) == 1 and "BRENDAN" or "MAY") .. label:sub(6)
end

local function kantoRival(place, key)
  local names = {}
  for _, mon in ipairs({ "SQUIRTLE", "BULBASAUR", "CHARMANDER" }) do
    names[#names + 1] = ("TRAINER_%s_%s"):format(key, mon)
  end
  return { label = place, names = names }
end

local function one(label, ...) return { label = label, names = { ... } } end

LevelCap.EMERALD = {
  rival("ROUTE 103", "ROUTE_103"),
  one("ROXANNE", "TRAINER_ROXANNE_1"),
  rival("RUSTBORO", "RUSTBORO"),
  one("BRAWLY", "TRAINER_BRAWLY_1"),
  rival("ROUTE 110", "ROUTE_110"),
  one("WALLY, MAUVILLE", "TRAINER_WALLY_MAUVILLE"),
  one("WATTSON", "TRAINER_WATTSON_1"),
  one("TABITHA, MT. CHIMNEY", "TRAINER_TABITHA_MT_CHIMNEY"),
  one("MAXIE, MT. CHIMNEY", "TRAINER_MAXIE_MT_CHIMNEY"),
  one("FLANNERY", "TRAINER_FLANNERY_1"),
  one("NORMAN", "TRAINER_NORMAN_1"),
  one("SHELLY, WEATHER INST.", "TRAINER_SHELLY_WEATHER_INSTITUTE"),
  rival("ROUTE 119", "ROUTE_119"),
  one("WINONA", "TRAINER_WINONA_1"),
  rival("LILYCOVE", "LILYCOVE"),
  one("TABITHA, MAGMA HIDEOUT", "TRAINER_TABITHA_MAGMA_HIDEOUT"),
  one("MAXIE, MAGMA HIDEOUT", "TRAINER_MAXIE_MAGMA_HIDEOUT"),
  one("MATT, AQUA HIDEOUT", "TRAINER_MATT"),
  one("MAXIE & TABITHA", "TRAINER_MAXIE_MOSSDEEP", "TRAINER_TABITHA_MOSSDEEP"),
  one("TATE & LIZA", "TRAINER_TATE_AND_LIZA_1"),
  one("SHELLY, SEAFLOOR CAVERN", "TRAINER_SHELLY_SEAFLOOR_CAVERN"),
  one("ARCHIE", "TRAINER_ARCHIE"),
  one("JUAN", "TRAINER_JUAN_1"),
  one("WALLY, VICTORY ROAD", "TRAINER_WALLY_VR_1"),
  one("SIDNEY", "TRAINER_SIDNEY"),
  one("PHOEBE", "TRAINER_PHOEBE"),
  one("GLACIA", "TRAINER_GLACIA"),
  one("DRAKE", "TRAINER_DRAKE"),
  one("WALLACE", "TRAINER_WALLACE"),
}

-- Ruby/Sapphire: the gyms and the League (their story fights' constants
-- don't say where each one happens)
LevelCap.RUBY = {
  one("ROXANNE", "TRAINER_ROXANNE"),
  one("BRAWLY", "TRAINER_BRAWLY"),
  one("WATTSON", "TRAINER_WATTSON"),
  one("FLANNERY", "TRAINER_FLANNERY"),
  one("NORMAN", "TRAINER_NORMAN"),
  one("WINONA", "TRAINER_WINONA"),
  one("TATE & LIZA", "TRAINER_TATE_AND_LIZA"),
  one("WALLACE", "TRAINER_WALLACE"),
  one("SIDNEY", "TRAINER_SIDNEY"),
  one("PHOEBE", "TRAINER_PHOEBE"),
  one("GLACIA", "TRAINER_GLACIA"),
  one("DRAKE", "TRAINER_DRAKE"),
  one("STEVEN", "TRAINER_STEVEN"),
}

LevelCap.FIRERED = {
  kantoRival("RIVAL, OAK'S LAB", "RIVAL_OAKS_LAB"),
  kantoRival("RIVAL, ROUTE 22", "RIVAL_ROUTE22_EARLY"),
  one("BROCK", "TRAINER_LEADER_BROCK"),
  kantoRival("RIVAL, CERULEAN", "RIVAL_CERULEAN"),
  one("MISTY", "TRAINER_LEADER_MISTY"),
  kantoRival("RIVAL, S.S. ANNE", "RIVAL_SS_ANNE"),
  one("LT. SURGE", "TRAINER_LEADER_LT_SURGE"),
  one("ERIKA", "TRAINER_LEADER_ERIKA"),
  one("GIOVANNI, HIDEOUT", "TRAINER_BOSS_GIOVANNI"),
  kantoRival("RIVAL, POKeMON TOWER", "RIVAL_POKEMON_TOWER"),
  one("KOGA", "TRAINER_LEADER_KOGA"),
  kantoRival("RIVAL, SILPH CO.", "RIVAL_SILPH"),
  one("GIOVANNI, SILPH CO.", "TRAINER_BOSS_GIOVANNI_2"),
  one("SABRINA", "TRAINER_LEADER_SABRINA"),
  one("BLAINE", "TRAINER_LEADER_BLAINE"),
  one("GIOVANNI", "TRAINER_LEADER_GIOVANNI"),
  kantoRival("RIVAL, ROUTE 22", "RIVAL_ROUTE22_LATE"),
  one("LORELEI", "TRAINER_ELITE_FOUR_LORELEI"),
  one("BRUNO", "TRAINER_ELITE_FOUR_BRUNO"),
  one("AGATHA", "TRAINER_ELITE_FOUR_AGATHA"),
  one("LANCE", "TRAINER_ELITE_FOUR_LANCE"),
  kantoRival("CHAMPION", "CHAMPION_FIRST"),
}

-- the list for a game version
function LevelCap.listFor(version)
  version = tostring(version or ""):lower()
  if version == "firered" or version == "leafgreen" then return LevelCap.FIRERED end
  if version == "ruby" or version == "sapphire" then return LevelCap.RUBY end
  return LevelCap.EMERALD
end

-- The cap right now: { cap = level or nil (no cap), label = the fight it
-- comes from, index }.  Milestones whose trainers this game doesn't have
-- are skipped.
function LevelCap.compute(list, resolve, beaten, ace)
  local rows = {}
  for _, m in ipairs(list) do
    local ids, top = {}, nil
    for _, name in ipairs(m.names) do
      local id = resolve(name)
      if id then
        ids[#ids + 1] = id
        local lv = ace(id)
        if lv and (not top or lv > top) then top = lv end
      end
    end
    if #ids > 0 and top then rows[#rows + 1] = { label = m.label, ids = ids, ace = top } end
  end
  local last, floor = 0, nil
  for i, r in ipairs(rows) do
    for _, id in ipairs(r.ids) do
      if beaten(id) then
        last = i
        if not floor or r.ace > floor then floor = r.ace end
        break
      end
    end
  end
  local nxt = rows[last + 1]
  if not nxt then return { cap = nil, label = nil, index = nil } end
  return { cap = math.max(nxt.ace, floor or 0), label = nxt.label, index = last + 1 }
end

-- How much of `amount` EXP a POKeMON may take: up to reaching the cap's
-- level, and none once it is there.  expAt(level) -> total EXP at a level.
function LevelCap.clampExp(level, exp, amount, cap, expAt)
  if not cap then return amount end
  level, exp = tonumber(level) or 1, tonumber(exp) or 0
  if level >= cap then return 0 end
  local room = expAt(cap) - exp
  return math.max(0, math.min(amount, room))
end

return LevelCap
