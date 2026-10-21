-- Headless suite for g3_coop's battle/trade layer: the request messages, the
-- link channel inside the co-op connection, the engine's own Game3Link
-- handshake over it, the ask/answer flow and the activity runner.
--   cd Gen3Mod/gen1recomp-0.3.73 && luajit ../coop/tests/run_link.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local coop = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
local here = coop .. "/g3_coop"
local function lib(name) return dofile(here .. "/lib/" .. name .. ".lua") end

local failures, checks = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. tostring(label))
  end
  return ok
end
local function eq(got, want, label)
  return check(got == want, tostring(label) .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
end

local Protocol = lib("protocol")
local Presence = lib("presence")
local Ghost = lib("ghost")
local Session = lib("session")
local Channel = lib("channel")
local Requests = lib("requests")
local Activity = lib("activity")

local Net = require("src.link.Net")
local Game3Link = require("src.link.Game3Link")

-- ------- protocol

check(Protocol.validate(Protocol.ask(1, "battle")) ~= nil, "a battle request validates")
check(Protocol.validate(Protocol.ask(2, "trade")) ~= nil, "a trade request validates")
eq(Protocol.validate(Protocol.ask(1, "contest")), nil, "unknown activities are refused")
eq(Protocol.validate(Protocol.ask(0, "battle")), nil, "request ids start at 1")
eq(Protocol.validate(Protocol.ask(1.5, "battle")), nil, "request ids are integers")
local ans = Protocol.validate(Protocol.answer(3, false, "rm -rf"))
eq(ans and ans.why, "no", "an unknown decline reason reads as a plain no")
ans = Protocol.validate(Protocol.answer(3, true, "busy"))
check(ans and ans.ok and ans.why == nil, "an accept carries no reason")
check(Protocol.validate(Protocol.cancel(3)) ~= nil, "a cancel validates")
local lk = Protocol.validate(Protocol.link(5, { type = "game3_hello", name = "MAY" }))
check(lk and lk.c == 5 and lk.m.type == "game3_hello", "a link envelope validates and keeps its message")
eq(Protocol.validate(Protocol.link(5, "game3_hello")), nil, "a link envelope must carry a message table")
eq(Protocol.validate(Protocol.link(5, { type = string.rep("x", 65) })), nil, "inner message types are length-capped")
eq(Protocol.validate(Protocol.link(5, { name = "x" })), nil, "inner messages need a type")
check(Protocol.validate(Protocol.state("trade")) ~= nil, "trading is a busy state")

-- ------- channel

do
  local out = {}
  local ch = Channel.new(4, function(c, m) out[#out + 1] = { c, m } end)
  check(ch.paired and not ch.closed, "a channel starts paired")
  ch:send({ type = "x" })
  eq(#out, 1, "sending goes through the session")
  eq(out[1][1], 4, "on the channel's number")
  ch:push({ type = "y" })
  eq(#ch:poll(), 1, "pushed messages come out of poll")
  eq(#ch:poll(), 0, "once")
  ch:fail()
  check(ch.closed and ch.error, "a failed channel is closed with an error")
  ch:send({ type = "z" })
  eq(#out, 1, "a closed channel sends nothing")
end

-- ------- sessions with channels over the engine's loopback transport

local clock = 5000
local function now() return clock end
local deps = { Protocol = Protocol, Presence = Presence, Ghost = Ghost, Channel = Channel,
               now = now, compat = function() return true end }

local function pair()
  local a, b = Net.loopbackPair()
  local sa = Session.new(a, "host", Protocol.hello("BRENDAN", "emerald", {}, ""), deps)
  local sb = Session.new(b, "join", Protocol.hello("MAY", "emerald", {}, ""), deps)
  for _ = 1, 3 do sa:tick(nil); sb:tick(nil) end
  return sa, sb
end

do
  local sa, sb = pair()
  eq(sa.state, "connected", "the pair connects")
  -- the guest opens its end first (it accepted), and its link hello goes
  -- out before the host has read the answer
  local cb = sb:openChannel(3)
  local lb = Game3Link.attach(cb, { seat = 1, seats = 2, linkType = Game3Link.LINKTYPE.BATTLE })
  sa:tick(nil)
  eq(sa.earlyCount, 1, "a link message for an unopened channel is held")
  local ca = sa:openChannel(3)
  eq(sa.earlyCount, 0, "and handed over when the channel opens")
  local la = Game3Link.attach(ca, { seat = 0, seats = 2, linkType = Game3Link.LINKTYPE.BATTLE })
  for _ = 1, 4 do
    sa:tick(nil); sb:tick(nil)
    la:update(0); lb:update(0)
  end
  eq(la.state, "ready", "the engine's own link handshake accepts the partner (host)")
  eq(lb.state, "ready", "the engine's own link handshake accepts the partner (guest)")
  eq(la:getSeat(), 0, "the co-op host is link seat 0")

  la:send({ type = "game3_trade_cmd", cmd = 1, cursor = 2 })
  sa:tick(nil); sb:tick(nil); lb:update(0)
  local got = lb:take("game3_trade_cmd")
  check(got and got.cmd == 1 and got.cursor == 2, "a link message crosses inside the co-op connection")

  -- presence keeps flowing beside the link
  sa:emote("wave")
  sb:tick(nil)
  eq(sb.emotes, 1, "co-op messages still arrive while a link is open")

  -- the activity ends: closing one link tells the other through the channel
  la:close("done")
  sa:closeChannel(3)
  sa:tick(nil); sb:tick(nil); lb:update(0)
  eq(lb.state, "closed", "closing the link ends the partner's side too")
  eq(lb.reason, "peer_left", "as the partner leaving")
  eq(sb.state, "connected", "the co-op connection itself stays up")

  -- a new activity on the next number works the same way
  local ca2, cb2 = sa:openChannel(5), sb:openChannel(5)
  local la2 = Game3Link.attach(ca2, { seat = 0, seats = 2, linkType = Game3Link.LINKTYPE.TRADE_SETUP })
  local lb2 = Game3Link.attach(cb2, { seat = 1, seats = 2, linkType = Game3Link.LINKTYPE.TRADE_SETUP })
  for _ = 1, 4 do sa:tick(nil); sb:tick(nil); la2:update(0); lb2:update(0) end
  eq(la2.state, "ready", "a second activity links again")

  -- the co-op connection dies mid-activity
  sb:close("left")
  sa:tick(nil)
  la2:update(0)
  eq(sa.state, "closed", "the partner leaving closes the session")
  check(ca2.closed, "and fails its open channels")
  eq(la2.state, "failed", "which the engine sees as the partner dropping")
end

do
  local sa, sb = pair()
  for i = 1, Session.MAX_EARLY + 10 do sb:_send(Protocol.link(1000 + i, { type = "junk" })) end
  sa:tick(nil)
  eq(sa.earlyCount, Session.MAX_EARLY, "held messages for unopened channels are capped")
  sa:openChannel(7)
  eq(sa.earlyCount, 0, "and dropped once any channel opens")
end

-- ------- requests: the ask / answer flow between two games

local function fakeUi(log)
  local ui = { shown = nil }
  function ui.menu(text, labels, cb) ui.shown = { kind = "menu", text = text, labels = labels, cb = cb } end
  function ui.ask(text, cb) ui.shown = { kind = "ask", text = text, cb = cb } end
  function ui.wait(text, onCancel) ui.shown = { kind = "wait", text = text, cb = onCancel } end
  function ui.close() ui.shown = nil end
  function ui.toast(text) log[#log + 1] = text end
  return ui
end

local function requestPair(opts)
  opts = opts or {}
  local sa, sb = pair()
  local A = { s = sa, toasts = {}, started = {}, free = true, ok = true }
  local B = { s = sb, toasts = {}, started = {}, free = true, ok = true }
  for i, side in ipairs({ A, B }) do
    side.ui = fakeUi(side.toasts)
    side.r = Requests.new({
      session = function() return side.s end, now = now, firstId = i, ui = side.ui,
      canPrompt = function() return side.free end,
      eligible = function(act) if side.ok then return true end return false, side.why or "no_mons" end,
      wave = function() side.waved = true end,
      start = function(act, id) side.started[#side.started + 1] = { act = act, id = id } end,
    })
  end
  function A.step() sa:tick(nil); A.r:tick() end
  function B.step() sb:tick(nil); B.r:tick() end
  local function both(n) for _ = 1, n or 1 do A.step(); B.step() end end
  return A, B, both
end

do
  local A, B, both = requestPair()
  A.r:talk()
  eq(A.ui.shown and A.ui.shown.kind, "menu", "talking opens the menu")
  eq(A.ui.shown.labels[1], "WAVE", "WAVE first")
  A.ui.shown.cb(0)
  check(A.waved, "WAVE waves")
  A.r:talk()
  A.ui.shown.cb(nil)
  check(A.r.outgoing == nil and not A.r.menuOpen, "B on the menu does nothing")

  A.r:talk()
  A.ui.shown.cb(1)
  eq(A.ui.shown and A.ui.shown.kind, "wait", "BATTLE asks the partner and waits")
  both(1)
  eq(B.ui.shown and B.ui.shown.kind, "ask", "the partner gets a YES/NO prompt")
  check(B.ui.shown.text:find("BRENDAN wants to battle", 1, true), "naming who and what: " .. tostring(B.ui.shown.text))
  B.ui.shown.cb(true)
  eq(#B.started, 1, "YES starts the battle on the partner's side")
  eq(B.started[1].act, "battle", "a battle")
  both(1)
  eq(#A.started, 1, "and on the asker's side when the answer arrives")
  eq(A.started[1].id, B.started[1].id, "on the same channel number")
  eq(A.ui.shown, nil, "the waiting box goes away")
  check(A.r.busy and B.r.busy, "both are busy until the activity ends")
  A.r:talk()
  eq(A.ui.shown, nil, "no menu while busy")
  A.r:finished(); B.r:finished()

  -- NO
  A.r:request("trade")
  both(1)
  B.ui.shown.cb(false)
  both(1)
  eq(#A.started, 1, "NO starts nothing")
  check(A.toasts[#A.toasts]:find("MAY said no", 1, true), "and the asker is told: " .. tostring(A.toasts[#A.toasts]))
  eq(A.r.outgoing, nil, "the request is over")

  -- ids alternate so the two games never claim the same channel
  A.r:request("trade"); B.r:finished()
  check(A.r.outgoing.id % 2 == 1, "the host's requests are odd")
  A.ui.shown.cb()   -- cancel the wait
  both(1)
  eq(B.ui.shown, nil, "canceling takes the prompt off the partner's screen")
  check(B.toasts[#B.toasts]:find("BRENDAN canceled", 1, true), "and tells them")
  B.r:request("battle")
  check(B.r.outgoing.id % 2 == 0, "the guest's requests are even")
  both(1)
  A.ui.shown.cb(false)
  both(1)
end

do
  -- the partner is mid-menu for too long
  local A, B, both = requestPair()
  B.free = false
  A.r:request("battle")
  both(1)
  eq(B.ui.shown, nil, "no prompt while the partner is busy")
  clock = clock + Requests.PROMPT_SECONDS + 1
  both(2)
  check(A.toasts[#A.toasts] and A.toasts[#A.toasts]:find("MAY is busy", 1, true), "turned down as busy")
end

do
  -- the partner can't take part
  local A, B, both = requestPair()
  B.ok, B.why = false, "no_mons"
  A.r:request("trade")
  both(2)
  eq(#B.started, 0, "an ineligible partner starts nothing")
  check(A.toasts[#A.toasts]:find("doesn't have the POKeMON", 1, true), "the asker hears why")
  check(B.toasts[#B.toasts]:find("two POKeMON", 1, true), "the partner hears why: " .. tostring(B.toasts[#B.toasts]))
  -- nor can we
  A.ok = false
  eq(A.r:request("battle"), false, "an ineligible asker sends nothing")
  check(A.toasts[#A.toasts]:find("POKeMON that can battle", 1, true), "and is told why")
end

do
  -- nobody answers
  local A, B, both = requestPair()
  A.r:request("battle")
  A.step()
  clock = clock + Requests.ANSWER_SECONDS + 1
  A.step()
  check(A.toasts[#A.toasts]:find("didn't answer", 1, true), "an unanswered request times out")
  eq(A.ui.shown, nil, "and the waiting box goes away")
end

do
  -- both ask at once
  local A, B, both = requestPair()
  A.r:request("battle")
  B.r:request("trade")
  both(2)
  eq(#A.started + #B.started, 0, "crossed requests start nothing")
  check(A.toasts[#A.toasts]:find("busy", 1, true) and B.toasts[#B.toasts]:find("busy", 1, true),
    "and both hear the other is busy")
end

-- ------- activity runner, against a scripted engine

local function fakeEngine()
  local E = { log = {} }
  local live = { open = true, ready = false, reason = nil }
  function live:isOpen() return self.open end
  function live:isReady() return self.ready end
  E.live = live
  E.Link = {
    open = function(opts) E.opened = opts return live end,
    closeLink = function(reason) E.closed = reason end,
  }
  E.Game3Link = Game3Link
  E.LB = { state = "off" }
  function E.LB.startUnionRoomBattle(onDone) E.LB.state = "setup" E.LB.done = onDone return true end
  function E.LB.pumpUnionSetup() if E.LB.peerSetup then E.LB.state = "battle" end end
  function E.LB.refuse(why) E.LB.state = "off" E.LB.endReason = why end
  E.LT = { state = "off", completed = 0, loopbackCommit = false }
  function E.LT.startMenu() E.LT.state = "menu" end
  E.Message = { open = false }
  function E.Message.show() E.Message.open = true end
  function E.Message.isOpen() return E.Message.open end
  function E.Message.close() E.Message.open = false end
  E.Field = { locks = 0 }
  function E.Field.lock() E.Field.locks = E.Field.locks + 1 end
  function E.Field.unlock() E.Field.locks = 0 end
  E.TradeMenu = { open = false, isOpen = function() return E.TradeMenu.open end }
  return E
end

do
  local E = fakeEngine()
  local ended
  local ch = Channel.new(1, function() end)
  local act = Activity.new({ kind = "battle", seat = 1, channel = ch, now = now, E = E,
    onEnd = function(r, why) ended = { r = r, why = why } end })
  act:start()
  eq(E.opened.transport, ch, "the link opens on the co-op channel")
  eq(E.opened.seat, 1, "in this game's seat")
  eq(E.opened.linkType, Game3Link.LINKTYPE.BATTLE, "as a battle link")
  check(E.Message.open and E.Field.locks > 0, "the field waits behind a message while linking")
  act:step()
  eq(act.stage, "link", "until the engine accepts the partner")
  E.live.ready = true
  act:step()
  eq(act.stage, "setup", "then the Union Room battle setup starts")
  check(not E.Message.open and E.Field.locks == 0, "and the field is released")
  act:step()
  eq(act.stage, "setup", "waiting for the partner's party")
  E.LB.peerSetup = true
  act:step()
  eq(act.stage, "battle", "the battle begins")
  E.LB.done("win")
  act:step()
  eq(ended and ended.r, "win", "the result comes back when it ends")
  eq(E.closed, "coop_done", "and the link is closed")
  check(ch.closed and act:isDone(), "with its channel")
end

do
  local E = fakeEngine()
  local ended
  local act = Activity.new({ kind = "battle", seat = 0, channel = Channel.new(1, function() end),
    now = now, E = E, onEnd = function(r, why) ended = { r = r, why = why } end })
  act:start()
  E.live.open, E.live.reason = false, "engine_release_mismatch"
  act:step()
  eq(ended and ended.r, nil, "a refused link never starts")
  eq(ended and ended.why, "engine_release_mismatch", "and says why")
  eq(E.Field.locks, 0, "the field is released")
end

do
  local E = fakeEngine()
  local ended
  local act = Activity.new({ kind = "battle", seat = 0, channel = Channel.new(1, function() end),
    now = now, E = E, onEnd = function(r, why) ended = { r = r, why = why } end })
  act:start()
  clock = clock + Activity.LINK_SECONDS + 1
  act:step()
  eq(ended and ended.why, "link_timeout", "a link that never comes up times out")
end

do
  local E = fakeEngine()
  local ended
  local act = Activity.new({ kind = "trade", seat = 0, channel = Channel.new(1, function() end),
    now = now, E = E, onEnd = function(r, why) ended = { r = r, why = why } end })
  act:start()
  eq(E.opened.linkType, Game3Link.LINKTYPE.TRADE_SETUP, "a trade opens a trade link")
  E.live.ready = true
  act:step()
  eq(E.LT.state, "menu", "the trade screen opens")
  check(E.LT.loopbackCommit, "with the two games settling the swap between themselves")
  E.TradeMenu.open = true
  E.LT.completed = 2
  E.LT.state = "menu"
  act:step()
  eq(ended, nil, "trading continues until both cancel")
  E.LT.state = "exit"
  act:step()
  eq(ended, nil, "the screen fades out first")
  E.TradeMenu.open = false
  act:step()
  eq(ended and ended.r, 2, "then it ends, counting the trades")
  eq(E.LT.state, "off", "and leaves the trade module idle")
  check(not E.LT.loopbackCommit, "and the commit mode as it found it")
end

print(("%d/%d checks passed%s  (g3_coop link)"):format(checks - failures, checks,
  failures > 0 and (", " .. failures .. " FAILURES") or ""))
os.exit(failures == 0 and 0 or 1)
