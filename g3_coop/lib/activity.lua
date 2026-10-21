-- One battle or trade with the partner, run by the engine's own link code
-- over a co-op channel (lib/channel.lua).  Nothing about the battle or the
-- trade is reimplemented here: this opens the link the way the Cable Club
-- and Union Room do (src/core/game3/link/init.lua Link.open), waits for the
-- engine's handshake to accept the partner, then hands over to
--   battle: link/battle.lua startUnionRoomBattle, the Union Room battle (a
--           single battle, parties healed first and restored afterwards);
--   trade:  link/trade.lua startMenu, the Trade Center's trade screen, which
--           repeats until both players choose CANCEL.
--
-- Stages: "link" (handshake) -> "setup" (battle parties) -> "battle" /
-- "trade" -> "done".

local Activity = {}
Activity.__index = Activity

Activity.LINK_SECONDS = 15
Activity.SETUP_SECONDS = 30
Activity.LOCK = "g3coop"

-- opts: { kind = "battle"|"trade", seat = 0|1, channel, game, now,
--         E = engine modules { Link, LB, LT, Game3Link, Message, Field,
--         TradeMenu }, onEnd = fn(result, why) }
-- result: "win"/"lose"/"draw" for a battle, the number of mons traded for
-- a trade, nil when it never started (why says why)
function Activity.new(opts)
  return setmetatable({
    kind = opts.kind, seat = opts.seat, channel = opts.channel, game = opts.game,
    E = opts.E, now = opts.now, onEnd = opts.onEnd,
    stage = "new", startedAt = nil, live = nil, word = nil, traded = 0,
  }, Activity)
end

function Activity:start()
  local E = self.E
  self.startedAt = self.now()
  self.stage = "link"
  if E.Field then E.Field.lock(Activity.LOCK) end
  E.Message.show("Linking with your partner...\nPlease wait.", { stay = true })
  local L = E.Link
  local linkType = self.kind == "battle" and E.Game3Link.LINKTYPE.BATTLE
    or E.Game3Link.LINKTYPE.TRADE_SETUP
  local live, why = L.open({
    transport = self.channel, seat = self.seat, seats = 2,
    linkType = linkType, game = self.game,
  })
  if not live then return self:_end(nil, why or "no_link") end
  self.live = live
  return true
end

-- Take down the "Linking..." box and the field lock, once: later on, an
-- open message box belongs to the battle or the trade screen.
function Activity:_clearWait()
  if self._waitCleared then return end
  self._waitCleared = true
  local E = self.E
  if E.Message.isOpen() then E.Message.close() end
  if E.Field then E.Field.unlock(Activity.LOCK) end
end

function Activity:_begin()
  local E = self.E
  self:_clearWait()
  if self.kind == "battle" then
    local ok, err = E.LB.startUnionRoomBattle(function(word)
      self.word = word or "draw"
      self.stage = "ending"
    end)
    if not ok then return self:_end(nil, err or "setup_failed") end
    if self.stage == "ending" then
      -- refused before it began (the done callback already ran)
      return self:_end(nil, E.LB.endReason or "setup_failed")
    else
      self.stage, self.startedAt = "setup", self.now()
    end
  else
    -- a direct link has no relay to arbitrate the swap; both games compare
    -- the trade digests themselves (trade.lua tryLoopbackCommit)
    E.LT.loopbackCommit = true
    self.tradesBefore = E.LT.completed or 0
    E.LT.startMenu()
    self.stage = "trade"
  end
  return true
end

function Activity:step()
  local E = self.E
  local stage = self.stage
  if stage == "done" or stage == "new" then return end
  local t = self.now()
  if stage == "link" then
    local live = self.live
    if not live:isOpen() then
      return self:_end(nil, live.reason or "link_closed")
    end
    if live:isReady() then return self:_begin() end
    if t - self.startedAt > Activity.LINK_SECONDS then
      return self:_end(nil, "link_timeout")
    end
  elseif stage == "setup" then
    local LB = E.LB
    if LB.state == "setup" then LB.pumpUnionSetup() end
    -- a refused setup calls the battle's done callback ("error") on the spot
    if self.stage == "ending" and self.word == "error" then
      return self:_end(nil, LB.endReason or "setup_failed")
    end
    if self.stage == "setup" then
      if LB.state == "battle" then
        self.stage = "battle"
      elseif LB.state ~= "setup" then
        return self:_end(nil, LB.endReason or "setup_failed")
      elseif t - self.startedAt > Activity.SETUP_SECONDS then
        LB.refuse("timeout")
        return self:_end(nil, "setup_timeout")
      end
    end
  elseif stage == "battle" then
    -- the battle's done callback moves us on; this catches a battle that
    -- went away without calling it
    local st = E.LB.state
    if st == "off" or st == "done" then
      self.word = self.word or "draw"
      self.stage = "ending"
    end
  elseif stage == "trade" then
    local LT = E.LT
    self.traded = (LT.completed or 0) - (self.tradesBefore or 0)
    local menuOpen = E.TradeMenu and E.TradeMenu.isOpen and E.TradeMenu.isOpen()
    if LT.state == "off" or (LT.state == "exit" and not menuOpen) then
      self.stage = "ending"
    end
  end
  if self.stage == "ending" then
    if self.kind == "battle" then return self:_end(self.word) end
    return self:_end(self.traded)
  end
end

-- The partner left or the co-op connection went away mid-link: let the
-- engine wind its side down (it sees the channel close), then finish.
function Activity:abort(why)
  if self.stage == "done" then return end
  if self.stage == "link" or self.stage == "new" then return self:_end(nil, why or "aborted") end
  if self.stage == "setup" then
    if self.E.LB.state == "setup" then self.E.LB.refuse(why or "aborted") end
    return self:_end(nil, why or "aborted")
  end
end

function Activity:_end(result, why)
  if self.stage == "done" then return end
  self.stage = "done"
  local E = self.E
  self:_clearWait()
  if self.kind == "trade" and E.LT then
    if E.LT.state ~= "off" and not (E.LT._committed) then E.LT.state = "off" end
    E.LT.loopbackCommit = false
  end
  pcall(E.Link.closeLink, "coop_done")
  if self.channel then self.channel:close() end
  if self.onEnd then self.onEnd(result, why) end
end

function Activity:isDone()
  return self.stage == "done"
end

return Activity
