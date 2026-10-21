-- Shared trainer credit (the 2026-10-20 addendum): ordinary trainers can be
-- fought alone, and a win counts in both games, so splitting up still moves
-- the campaign forward.  Rival, gym and story fights are joint fights and
-- are never credited this way.
--
-- Each game keeps the list of trainers it has credited (its own solo wins
-- and its partner's) in its save.  A new win goes to the partner at once;
-- on every connect the two whole lists cross, so wins made apart catch up.
-- Applying a credit sets the game's own trainer-beaten flag, nothing else.
--
-- Pure: main.lua supplies storage, the flags and the trainer's class.

local Credit = {}
Credit.__index = Credit

Credit.MAX_IDS = 4096
Credit.MAX_ID = 2 ^ 20

-- trainer classes that are joint fights: gym leaders, the League, team
-- admins and bosses, and the rival-style classes (PKMN TRAINER: the rival,
-- Wally, Steven).  A cart's mod can decide instead (main.lua storyTrainer).
local STORY = { "LEADER", "ELITE", "CHAMPION", "ADMIN", "PKMN TRAINER", "POKEMON TRAINER",
                "POK\195\137MON TRAINER", "RIVAL", "BOSS" }

function Credit.isStoryClass(className)
  local c = tostring(className or ""):upper()
  if c == "" then return false end
  for _, word in ipairs(STORY) do
    if c:find(word, 1, true) then return true end
  end
  return false
end

-- deps: { read = fn() -> list or nil, write = fn(list) }
function Credit.new(deps)
  return setmetatable({ d = deps }, Credit)
end

function Credit:list()
  local l = self.d.read()
  if type(l) ~= "table" then l = {} end
  return l
end

function Credit:has(id)
  for _, v in ipairs(self:list()) do if v == id then return true end end
  return false
end

-- record id; true when it wasn't there before
function Credit:add(id)
  id = tonumber(id)
  if not id or id < 1 or id > Credit.MAX_ID or id ~= math.floor(id) then return false end
  local l = self:list()
  for _, v in ipairs(l) do if v == id then return false end end
  if #l >= Credit.MAX_IDS then return false end
  l[#l + 1] = id
  self.d.write(l)
  return true
end

-- the list in pieces small enough for one message each
function Credit:chunks(size)
  size = size or 512
  local out, l = {}, self:list()
  for i = 1, #l, size do
    local c = {}
    for j = i, math.min(#l, i + size - 1) do c[#c + 1] = l[j] end
    out[#out + 1] = c
  end
  return out
end

return Credit
