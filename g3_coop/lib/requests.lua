-- Talking to the partner: the WAVE / BATTLE / TRADE menu, the request sent
-- to the other game, its YES/NO prompt there, and the answer coming back.
-- When both agree, start(act, id) runs the activity (lib/activity.lua) on
-- channel `id` in both games.
--
-- The UI calls go through deps.ui so tests can drive them; main.lua backs
-- them with the game's own message box and choice menu.

local Requests = {}
Requests.__index = Requests

-- how long the asker waits for an answer
Requests.ANSWER_SECONDS = 30
-- a wild POKeMON is waiting: the asker stands frozen until the answer
Requests.ANSWER_SECONDS_FOR = { wild = 10, trainer = 10, joint = 15 }
-- acts the partner joins without being asked: a story fight is a joint
-- fight, and the gate already checked they're here and free
Requests.AUTO_ACCEPT = { joint = true }
-- how long a request may wait for the other player to be free to see it
-- (mid-step, in a menu, reading a sign) before it is turned down as busy
Requests.PROMPT_SECONDS = 8

Requests.MENU = { "WAVE", "BATTLE", "TRADE", "CANCEL" }
local MENU_ACT = { [0] = "wave", [1] = "battle", [2] = "trade" }
local ACT_WORD = { battle = "battle", trade = "trade", team = "team up against trainers",
                   wild = "battle the wild POKeMON they found together",
                   trainer = "battle a TRAINER together", joint = "start a fight you both have to be in" }

local DECLINE_TEXT = {
  no = "%s said no.",
  busy = "%s is busy right now.",
  no_mons = "%s doesn't have the POKeMON for that.",
  bad_egg = "%s can't link with a BAD EGG.",
  enigma_berry = "%s can't link holding an ENIGMA BERRY.",
  timeout = "%s didn't answer.",
  error = "%s couldn't start it.",
}

local OWN_TEXT = {
  no_mons = { battle = "You need a POKeMON that can battle.",
              trade = "You need at least two POKeMON to trade.",
              team = "You need a POKeMON that can battle.",
              wild = "You need a POKeMON that can battle.",
              trainer = "You need a POKeMON that can battle.",
              joint = "You need a POKeMON that can battle." },
  bad_egg = "You can't link with a BAD EGG.",
  enigma_berry = "You can't link holding an ENIGMA BERRY.",
}

-- deps: { session = fn() -> Session, now = clock, firstId = 1 or 2,
--         ui = { menu(text, labels, cb(index or nil)), ask(text, cb(yes)),
--                wait(text, onCancel), close(), toast(text) },
--         canPrompt = fn() -> bool, eligible = fn(act) -> ok, why,
--         wave = fn(), start = fn(act, id) }
function Requests.new(deps)
  return setmetatable({
    d = deps, nextId = deps.firstId or 1,
    outgoing = nil, incoming = nil, busy = false,
  }, Requests)
end

function Requests:_name()
  local s = self.d.session()
  return tostring(s and s.peer and s.peer.name or "Your partner")
end

local function ownText(why, act)
  local t = OWN_TEXT[why]
  if type(t) == "table" then t = t[act] end
  return t or ("You can't do that right now (" .. tostring(why) .. ").")
end

-- A pressed while facing the partner
function Requests:talk()
  if self.outgoing or self.incoming or self.busy then return false end
  local d = self.d
  self.menuOpen = true
  d.ui.menu("What do you want to do\nwith " .. self:_name() .. "?", Requests.MENU, function(index)
    self.menuOpen = false
    local act = MENU_ACT[index]
    if act == "wave" then
      d.wave()
    elseif act then
      self:request(act)
    end
  end)
  return true
end

-- onRefused (optional): called once if the request ends without the
-- partner agreeing -- a no, no answer in time, B to cancel, or the
-- connection dropping -- so the caller can go on alone
function Requests:request(act, onRefused, t)
  local d = self.d
  local s = d.session()
  if not (s and s.state == "connected") or self.outgoing or self.busy then return false end
  local ok, why = d.eligible(act)
  if not ok then
    d.ui.toast(ownText(why, act))
    return false
  end
  local id = self.nextId
  -- the two games number their requests on alternate ids, so a channel
  -- number is never claimed by both
  self.nextId = id + 2
  self.outgoing = { id = id, act = act, at = d.now(), onRefused = onRefused, t = t }
  s:ask(id, act, t)
  d.ui.wait("Waiting for " .. self:_name() .. "...\n(B to cancel)", function()
    local out = self.outgoing
    if not (out and out.id == id) then return end
    self.outgoing = nil
    s:cancelAsk(id)
    d.ui.close()
    d.ui.toast("You canceled.")
    if out.onRefused then out.onRefused() end
  end)
  return true
end

function Requests:_answerIncoming(yes, why)
  local inc = self.incoming
  if not inc then return end
  self.incoming = nil
  local s = self.d.session()
  if not s then return end
  s:answer(inc.id, yes, why)
  if yes then self:_start(inc.act, inc.id, inc.t) end
end

function Requests:_start(act, id, t)
  self.busy = true
  self.d.start(act, id, t)
end

-- the activity started by _start has ended
function Requests:finished()
  self.busy = false
end

function Requests:_onAsk(msg)
  local s = self.d.session()
  if self.incoming or self.outgoing or self.busy or self.menuOpen then
    -- both asked at once, or we are mid-activity: the simplest fair answer
    -- is "busy" on both sides; whoever asks again wins
    s:answer(msg.id, false, "busy")
    return
  end
  self.incoming = { id = msg.id, act = msg.act, at = self.d.now(), shown = false, t = msg.t }
end

function Requests:_onAnswer(msg)
  local out = self.outgoing
  if not (out and out.id == msg.id) then return end
  self.outgoing = nil
  local d = self.d
  d.ui.close()
  if msg.ok then
    self:_start(out.act, out.id, out.t)
  else
    d.ui.toast(DECLINE_TEXT[msg.why or "no"]:format(self:_name()))
    if out.onRefused then out.onRefused() end
  end
end

function Requests:_onCancel(msg)
  local inc = self.incoming
  if not (inc and inc.id == msg.id) then return end
  self.incoming = nil
  if inc.shown then self.d.ui.close() end
  self.d.ui.toast(self:_name() .. " canceled.")
end

function Requests:_showIncoming()
  local inc = self.incoming
  local d = self.d
  local ok, why = d.eligible(inc.act)
  if not ok then
    d.ui.toast(self:_name() .. " wanted to " .. ACT_WORD[inc.act] .. ". " .. ownText(why, inc.act))
    return self:_answerIncoming(false, why)
  end
  inc.shown = true
  if Requests.AUTO_ACCEPT[inc.act] then
    d.ui.toast("Joining " .. self:_name() .. "'s fight!")
    return self:_answerIncoming(true)
  end
  d.ui.ask(self:_name() .. " wants to " .. ACT_WORD[inc.act] .. ".\nIs that okay?", function(yes)
    if self.incoming ~= inc then return end
    d.ui.close()
    self:_answerIncoming(yes, yes and nil or "no")
  end)
end

-- one tick, while connected
function Requests:tick()
  local d = self.d
  local s = d.session()
  if not s then return end
  local P = s.P
  for _, msg in ipairs(s:takeRequests()) do
    if msg.type == P.ASK then
      self:_onAsk(msg)
    elseif msg.type == P.ANSWER then
      self:_onAnswer(msg)
    elseif msg.type == P.CANCEL then
      self:_onCancel(msg)
    end
  end
  local t = d.now()
  local inc = self.incoming
  if inc and not inc.shown then
    if d.canPrompt() then
      self:_showIncoming()
    elseif t - inc.at > Requests.PROMPT_SECONDS then
      self:_answerIncoming(false, "busy")
    end
  end
  local out = self.outgoing
  if out and t - out.at > (Requests.ANSWER_SECONDS_FOR[out.act] or Requests.ANSWER_SECONDS) then
    self.outgoing = nil
    s:cancelAsk(out.id)
    d.ui.close()
    d.ui.toast(DECLINE_TEXT.timeout:format(self:_name()))
    if out.onRefused then out.onRefused() end
  end
end

-- the co-op connection ended: take down whatever is on screen
function Requests:reset()
  if self.outgoing or (self.incoming and self.incoming.shown) or self.menuOpen then
    self.d.ui.close()
  end
  local out = self.outgoing
  self.outgoing, self.incoming, self.menuOpen = nil, nil, false
  if out and out.onRefused then out.onRefused() end
end

return Requests
