-- What co-op draws over the game: the partner card (top right), the toasts
-- under it, and the Soul Link panel (F7).  Laid out on the whole window
-- (the Emerald field draws past the 240x160 frame, out to the edges) and
-- sized by the viewport scale, in the engine's bundled pixel face, Plain
-- Pixel, at a whole multiple of its 15px design size so it stays crisp.
-- Drawing only: main.lua decides what the card and panel say.

local Hud = {}
Hud.__index = Hud

Hud.FONT = "assets/fonts/plainpixel/PlainPixel-Regular.ttf"
Hud.FONT_EM = 15

local C = {
  bg = { 0.07, 0.08, 0.12, 0.9 }, edge = { 1, 1, 1, 0.14 }, row = { 1, 1, 1, 0.04 },
  text = { 1, 1, 1, 1 }, dim = { 0.66, 0.69, 0.78, 1 },
  coop = { 0.36, 0.82, 0.76, 1 }, sl = { 0.72, 0.56, 1, 1 },
  good = { 0.45, 0.9, 0.5, 1 }, warn = { 1, 0.78, 0.32, 1 }, bad = { 1, 0.42, 0.42, 1 },
}
Hud.COLORS = C

local DOT = { ok = C.good, wait = C.warn, bad = C.bad, off = C.dim }
local KIND = { coop = C.coop, sl = C.sl, bad = C.bad, good = C.good }
local PILL = { alive = { "ALIVE", C.good }, dead = { "DEAD", C.bad },
               broken = { "BROKEN", C.bad }, waiting = { "WAITING", C.dim } }

function Hud.new(gfx)
  return setmetatable({ gfx = gfx, fonts = {}, scroll = 0 }, Hud)
end

-- Split text into lines no wider than maxW (font:getWidth units), on
-- spaces and on "\n".  A single word wider than maxW gets a line to itself.
function Hud.wrap(width, text, maxW)
  local lines = {}
  for para in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      local try = line == "" and word or (line .. " " .. word)
      if line ~= "" and width(try) > maxW then
        lines[#lines + 1] = line
        line = word
      else
        line = try
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- The face for this viewport: Plain Pixel at 15, 30, 45... px, or the
-- current font drawn scaled when the TTF can't be loaded.  big: the panel's
-- larger size.
function Hud:_setup(vp, big)
  local scale = math.max(1, tonumber(vp.scale) or 2)
  local k = math.max(1, math.floor(scale / (big and 2.5 or 3.5) + 0.5))
  self.u = scale
  local font = self.fonts[k]
  if font == nil then
    local ok, f = pcall(self.gfx.newFont, Hud.FONT, Hud.FONT_EM * k)
    if ok and f then
      if f.setFilter then pcall(f.setFilter, f, "nearest", "nearest") end
      font = f
    else
      font = false
    end
    self.fonts[k] = font
  end
  if font then
    self.font, self.fs = font, 1
  else
    self.font, self.fs = self.gfx.getFont(), math.max(1, math.floor(scale / 2))
  end
  self.lh = math.floor(self.font:getHeight() * self.fs + 0.5)
  self.k = k
  self.gx, self.gy = 0, 0
  self.gw = vp.width or vp.gameWidth or 240 * scale
  self.gh = vp.height or vp.gameHeight or 160 * scale
end

function Hud:w(text) return self.font:getWidth(tostring(text)) * self.fs end

function Hud:_print(text, x, y, color, alpha)
  local g = self.gfx
  g.setFont(self.font)
  g.setColor(color[1], color[2], color[3], (color[4] or 1) * (alpha or 1))
  g.print(tostring(text), math.floor(x), math.floor(y), 0, self.fs, self.fs)
end

function Hud:_box(x, y, w, h, alpha, accent)
  local g = self.gfx
  local r = math.max(2, self.u)
  g.setColor(C.bg[1], C.bg[2], C.bg[3], C.bg[4] * (alpha or 1))
  g.rectangle("fill", x, y, w, h, r, r)
  g.setColor(C.edge[1], C.edge[2], C.edge[3], C.edge[4] * (alpha or 1))
  g.setLineWidth(1)
  g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, r, r)
  if accent then
    g.setColor(accent[1], accent[2], accent[3], (alpha or 1))
    g.rectangle("fill", x, y + r, math.max(2, math.floor(self.u / 2)), h - 2 * r)
  end
end

function Hud:_dot(x, y, color, alpha)
  local g = self.gfx
  local r = math.max(2, math.floor(self.lh / 5))
  g.setColor(color[1], color[2], color[3], alpha or 1)
  g.circle("fill", x + r, y + self.lh / 2, r)
  return r * 2
end

-- ---------------------------------------------------------------- the card

-- card: { dot = "ok"|"wait"|"bad"|"off", title, right, lines = { text or
-- { text, color } } }.  Returns the y below it.
function Hud:drawCard(vp, card)
  self:_setup(vp)
  local pad = math.max(3, self.u * 2)
  local maxW = math.floor(self.gw * 0.5)
  local lines = {}
  for _, l in ipairs(card.lines or {}) do
    local text, color = l, C.dim
    if type(l) == "table" then text, color = l[1], l[2] end
    for _, w in ipairs(Hud.wrap(function(t) return self:w(t) end, text, maxW)) do
      lines[#lines + 1] = { w, color }
    end
  end
  local dotW = self.lh / 2.5 + pad
  local titleW = dotW + self:w(card.title) + (card.right and (pad * 2 + self:w(card.right)) or 0)
  local width = titleW
  for _, l in ipairs(lines) do width = math.max(width, self:w(l[1])) end
  width = math.min(width, maxW) + pad * 2
  local height = self.lh * (1 + #lines) + pad * 2
  local x = self.gx + self.gw - width - pad
  local y = self.gy + pad
  self:_box(x, y, width, height)
  local cx, cy = x + pad, y + pad
  self:_dot(cx, cy, DOT[card.dot] or C.dim)
  self:_print(card.title, cx + dotW, cy, C.text)
  if card.right then
    self:_print(card.right, x + width - pad - self:w(card.right), cy, C.dim)
  end
  for i, l in ipairs(lines) do self:_print(l[1], cx, cy + i * self.lh, l[2]) end
  return y + height + pad / 2
end

-- -------------------------------------------------------------- the toasts

-- toasts: { text, label, kind, born, untilT }; drawn from y down, right
-- aligned, fading in and out.
function Hud:drawToasts(vp, toasts, y, now)
  self:_setup(vp)
  local pad = math.max(3, self.u * 2)
  local maxW = math.floor(self.gw * 0.55)
  y = y or (self.gy + pad)
  for _, t in ipairs(toasts) do
    local alpha = math.min(1, (now - (t.born or now)) / 0.15, (t.untilT - now) / 0.4)
    if alpha > 0 then
      local accent = KIND[t.kind] or C.coop
      local lines = Hud.wrap(function(s) return self:w(s) end, t.text, maxW - pad * 3)
      local width = 0
      for _, l in ipairs(lines) do width = math.max(width, self:w(l)) end
      if t.label then width = math.max(width, self:w(t.label)) end
      width = width + pad * 3
      local rows = #lines + (t.label and 1 or 0)
      local height = rows * self.lh + pad * 2
      local x = self.gx + self.gw - width - pad
      self:_box(x, y, width, height, alpha, accent)
      local ty = y + pad
      if t.label then
        self:_print(t.label, x + pad * 2, ty, accent, alpha)
        ty = ty + self.lh
      end
      for _, l in ipairs(lines) do
        self:_print(l, x + pad * 2, ty, C.text, alpha)
        ty = ty + self.lh
      end
      y = y + height + pad / 2
    end
  end
  return y
end

-- ------------------------------------------------------- the Soul Link panel

Hud.TABS = { "LINKS", "FALLEN", "RUN", "RULES" }

-- data: Tracker:panel() (nil when Soul Link is off).  iconFor(species) ->
-- { image, quads } or nil.  view: { tab = one of Hud.TABS, rules = {
-- { label, on, locked } ... }, sel = the RULES cursor, locked = text or
-- nil, nextFight = { label, ace, cap } or nil }.  Returns the largest
-- useful scroll value.
function Hud:drawPanel(vp, data, iconFor, view)
  view = view or {}
  self:_setup(vp, true)
  local g = self.gfx
  local pad = math.max(4, self.u * 3)
  local width = math.min(self.gw - pad * 2, math.max(self.lh * 40, math.floor(self.gw * 0.7)))
  local height = self.gh - pad * 2
  local x, y = self.gx + math.floor((self.gw - width) / 2), self.gy + pad
  self:_box(x, y, width, height, 1, C.sl)
  local cx, cy = x + pad * 1.5, y + pad
  local right = x + width - pad
  local cp = math.max(2, self.u)
  local tab = view.tab or "LINKS"
  if not data then tab = "RULES" end

  -- header: title, partner, tally
  self:_print("SOUL LINK", cx, cy, C.sl)
  local tx = cx + self:w("SOUL LINK ")
  if data then
    self:_print(data.partner and ("with " .. data.partner) or "no partner yet", tx, cy, C.text)
    local tally = ("%d alive  %d gone"):format(data.alive, data.gone)
    self:_print(tally, right - self:w(tally), cy, C.dim)
  else
    self:_print("is off", tx, cy, C.dim)
  end
  cy = cy + self.lh + pad / 2

  -- the tabs
  local tabX = cx
  for _, name in ipairs(Hud.TABS) do
    local w = self:w(name) + cp * 4
    local on = name == tab
    local usable = data ~= nil or name == "RULES"
    g.setColor(C.sl[1], C.sl[2], C.sl[3], on and 0.4 or 0.12)
    g.rectangle("fill", tabX, cy, w, self.lh + cp, cp, cp)
    self:_print(name, tabX + cp * 2, cy + cp / 2, on and C.text or usable and C.sl or C.dim)
    tabX = tabX + w + cp * 2
  end
  cy = cy + self.lh + cp + pad / 2

  if data and data.over then
    g.setColor(C.bad[1], C.bad[2], C.bad[3], 0.25)
    g.rectangle("fill", x + pad, cy, width - pad * 2, self.lh + cp * 2, cp, cp)
    local msg = "NO POKeMON left that can battle"
    self:_print(msg, x + (width - self:w(msg)) / 2, cy + cp, C.bad)
    cy = cy + self.lh + cp * 2 + pad / 2
  end

  local function clip(text, w)
    text = tostring(text)
    if self:w(text) <= w then return text end
    while #text > 1 and self:w(text .. ".") > w do text = text:sub(1, -2) end
    return text .. "."
  end
  local iconS = math.max(1, math.floor(self.lh / 13))
  local function icon(c, px, py, rowH)
    local ic = c.s and iconFor and iconFor(c.s)
    if not (ic and ic.image and ic.quads and ic.quads[0]) then return 0 end
    if c.dead then g.setColor(0.55, 0.45, 0.45, 0.55) else g.setColor(1, 1, 1, 1) end
    -- the 32x32 frame's mon sits in its lower part
    g.draw(ic.image, ic.quads[0], px, py + math.floor((rowH - 32 * iconS) / 2) - 2 * iconS, 0, iconS, iconS)
    return 32 * iconS
  end
  local function strike(px, ty, text)
    g.setColor(C.bad[1], C.bad[2], C.bad[3], 0.9)
    local th = math.max(2, math.floor(self.lh / 10))
    g.rectangle("fill", px, math.floor(ty + self.lh / 2 - th / 2), self:w(text), th)
  end

  local bottom = y + height - pad - self.lh - cp
  local items, rowH, drawRow, foot = {}, math.max(math.floor(self.lh * 1.6), 28 * iconS), nil, nil

  if tab == "LINKS" then
    local areaW = 0
    for _, r in ipairs(data.rows) do areaW = math.max(areaW, self:w(r.area)) end
    areaW = math.min(math.max(areaW, self:w("AREA")), math.floor(width * 0.3))
    local pillW = self:w("WAITING") + cp * 2
    local colW = math.floor((width - pad * 3 - areaW - pillW - pad * 3) / 2)
    local colA, colM = cx, cx + areaW + pad
    local colT, colP = colM + colW + pad, right - pillW
    self:_print("AREA", colA, cy, C.dim)
    self:_print("YOU", colM, cy, C.dim)
    self:_print(data.partner or "PARTNER", colT, cy, C.dim)
    cy = cy + self.lh + cp
    for _, r in ipairs(data.rows) do items[#items + 1] = r end
    if #data.extras > 0 then
      items[#items + 1] = { heading = "OUTSIDE THE LINKS" }
      for _, e in ipairs(data.extras) do items[#items + 1] = { extra = e } end
    end
    if #items == 0 then
      self:_print("No encounters yet. Your first one in each area counts.", colA, cy + cp, C.dim)
    end
    local function monCell(c, px, py, w)
      if not c then
        self:_print("-", px, py + (rowH - self.lh) / 2, C.dim)
        return
      end
      local iw = c.state == "caught" and icon(c, px, py, rowH) or 0
      local col = c.state ~= "caught" and C.dim or c.dead and C.bad or C.text
      local name = clip(c.state == "caught" and c.name or ("(" .. c.name .. ")"), w - iw)
      local ty = py + (rowH - self.lh) / 2
      self:_print(name, px + iw, ty, col)
      if c.dead then strike(px + iw, ty, name) end
    end
    drawRow = function(it, ry)
      local ty = ry + (rowH - self.lh) / 2
      if it.heading then
        self:_print(it.heading, colA, ty, C.sl)
      elseif it.extra then
        local e = it.extra
        monCell({ name = e.name, s = e.s, state = "caught", dead = e.dead }, colM, ry, colW)
        local why = e.why == "over" and "not allowed" or e.why
        self:_print(why, colT, ty, e.why == "over" and C.bad or C.dim)
      else
        self:_print(clip(it.area, areaW), colA, ty, C.text)
        monCell(it.mine, colM, ry, colW)
        monCell(it.theirs, colT, ry, colW)
        local p = PILL[it.status] or PILL.waiting
        local col = p[2]
        g.setColor(col[1], col[2], col[3], 0.2)
        g.rectangle("fill", colP, ty, pillW, self.lh, cp, cp)
        self:_print(p[1], colP + (pillW - self:w(p[1])) / 2, ty, col)
      end
    end

  elseif tab == "FALLEN" then
    rowH = math.max(math.floor(self.lh * 2.6), 30 * iconS)
    local areaW = math.min(math.max(self:w("AREA"), math.floor(width * 0.2)), math.floor(width * 0.25))
    local colW = math.floor((width - pad * 4 - areaW) / 2)
    local colA, colM = cx, cx + areaW + pad
    local colT = colM + colW + pad
    self:_print("AREA", colA, cy, C.dim)
    self:_print("YOU", colM, cy, C.dim)
    self:_print(data.partner or "PARTNER", colT, cy, C.dim)
    cy = cy + self.lh + cp
    for _, r in ipairs(data.fallen or {}) do items[#items + 1] = r end
    if #items == 0 then self:_print("Nobody has fallen yet.", colA, cy + cp, C.good) end
    local function cell(c, px, py, w)
      if not c then
        self:_print("-", px, py + (rowH - self.lh) / 2, C.dim)
        return
      end
      local iw = not c.missed and icon({ s = c.s, dead = true }, px, py, rowH) or 0
      local ty = py + math.floor((rowH - self.lh * 2) / 2)
      local name = clip(c.name, w - iw)
      self:_print(name, px + iw, ty, c.missed and C.dim or C.bad)
      if not c.missed then strike(px + iw, ty, name) end
      self:_print(clip(c.why, w - iw), px + iw, ty + self.lh, C.dim)
    end
    drawRow = function(it, ry)
      local ty = ry + (rowH - self.lh * 2) / 2
      self:_print(clip(it.area, areaW), colA, ty, C.text)
      local label = it.status == "broken" and "BROKEN" or it.status == "extra" and "FREE CATCH" or "DEAD"
      self:_print(label, colA, ty + self.lh, it.status == "extra" and C.dim or C.bad)
      cell(it.mine, colM, ry, colW)
      cell(it.theirs, colT, ry, colW)
    end

  elseif tab == "RUN" then
    rowH = math.floor(self.lh * 1.4)
    local st = data.stats or {}
    local partner = data.partner or "Partner"
    local function pair(t) return t and ("you %d   %s %d"):format(t[1] or 0, partner, t[2] or 0) or "-" end
    local nf = view.nextFight
    items = {
      { "Links", ("%d alive   %d dead   %d broken   %d waiting"):format(st.alive or 0, st.dead or 0,
        st.broken or 0, st.waiting or 0), C.text },
      { "Areas used", tostring(st.areas or 0), C.text },
      { "Linked catches", pair(st.caught), C.text },
      { "Free catches", pair(st.extra), C.text },
      { "Fainted", pair(st.fainted), (st.fainted and (st.fainted[1] + st.fainted[2]) > 0) and C.bad or C.text },
      { "Encounters missed", pair(st.missed), C.text },
      { "Last to fall", st.lastFall and (st.lastFall.name .. " (" .. st.lastFall.why .. ")") or "nobody yet",
        st.lastFall and C.bad or C.good },
      { "Next big fight", nf and (nf.label .. " (ace Lv" .. tostring(nf.ace) .. ")") or "none left", C.warn },
      { "Level cap", (nf and nf.cap) and tostring(nf.cap) or "off", nf and nf.cap and C.warn or C.dim },
      { "Rules", #data.rules > 0 and table.concat(data.rules, "  ") or "none", C.sl },
    }
    local keyW = 0
    for _, it in ipairs(items) do keyW = math.max(keyW, self:w(it[1])) end
    drawRow = function(it, ry)
      self:_print(it[1], cx, ry, C.dim)
      self:_print(clip(it[2], right - cx - keyW - pad * 2), cx + keyW + pad * 2, ry, it[3])
    end

  else -- RULES
    rowH = math.floor(self.lh * 1.5)
    if view.locked then
      self:_print(clip(view.locked, right - cx), cx, cy, C.warn)
      cy = cy + self.lh + cp
    end
    items = view.rules or {}
    local pillW = self:w("OFF") + cp * 4
    drawRow = function(it, ry, i)
      local sel = i == view.sel
      if sel then
        g.setColor(C.sl[1], C.sl[2], C.sl[3], 0.2)
        g.rectangle("fill", x + pad / 2, ry, width - pad, rowH)
        self:_print(">", cx, ry + (rowH - self.lh) / 2, C.sl)
      end
      local dim = it.locked
      self:_print(it.label, cx + self:w("> "), ry + (rowH - self.lh) / 2, dim and C.dim or C.text)
      if it.note then
        self:_print(clip(it.note, right - pillW - pad * 2 - cx - self:w("> " .. it.label .. "  ")),
          cx + self:w("> " .. it.label .. "  "), ry + (rowH - self.lh) / 2, C.dim)
      end
      local col = it.on and C.good or C.dim
      local px = right - pillW
      g.setColor(col[1], col[2], col[3], dim and 0.1 or 0.25)
      g.rectangle("fill", px, ry + (rowH - self.lh) / 2, pillW, self.lh, cp, cp)
      local word = it.on and "ON" or "OFF"
      self:_print(word, px + (pillW - self:w(word)) / 2, ry + (rowH - self.lh) / 2, col)
    end
    foot = "UP/DOWN pick   A toggles   LEFT/RIGHT tabs   F7 closes"
  end

  local fit = math.max(1, math.floor((bottom - cy) / rowH))
  local maxScroll = math.max(0, #items - fit)
  if tab == "RULES" then
    -- keep the cursor on screen
    local sel = view.sel or 1
    if sel - self.scroll > fit then self.scroll = sel - fit end
    if sel <= self.scroll then self.scroll = sel - 1 end
  end
  self.scroll = math.max(0, math.min(self.scroll, maxScroll))
  for i = 1, fit do
    local idx = i + self.scroll
    local it = items[idx]
    if not it then break end
    local ry = cy + (i - 1) * rowH
    if i % 2 == 0 and tab ~= "RULES" then
      g.setColor(C.row)
      g.rectangle("fill", x + pad / 2, ry, width - pad, rowH)
    end
    drawRow(it, ry, idx)
  end

  if not foot then
    foot = "LEFT/RIGHT tabs   F7 closes"
    if maxScroll > 0 then
      foot = ("UP/DOWN scroll (%d-%d of %d)   "):format(self.scroll + 1, math.min(#items, self.scroll + fit), #items) .. foot
    end
  end
  self:_print(foot, cx, y + height - pad - self.lh, C.dim)
  return maxScroll
end

-- ------------------------------------------------------- choice panel

-- A small box in the middle of the window over whatever is showing (the
-- battle screen too): a title, lines, and options with one selected.
function Hud:drawChoice(vp, title, lines, options, selected)
  self:_setup(vp, true)
  local g = self.gfx
  local pad = math.max(4, self.u * 3)
  local cp = math.max(2, self.u)
  local width = math.min(self.gw - pad * 2, math.max(self.lh * 24, math.floor(self.gw * 0.5)))
  local inner = width - pad * 3
  local wrapped = {}
  for _, l in ipairs(lines or {}) do
    for _, w in ipairs(Hud.wrap(function(s) return self:w(s) end, l, inner)) do wrapped[#wrapped + 1] = w end
  end
  local height = self.lh * (2.2 + #wrapped * 1.15 + #options * 1.4 + 0.6) + pad * 2
  local x = self.gx + math.floor((self.gw - width) / 2)
  local y = self.gy + math.floor((self.gh - height) / 2)
  self:_box(x, y, width, height, 1, C.warn)
  local cx, cy = x + pad * 1.5, y + pad
  self:_print(title, cx, cy, C.warn)
  cy = cy + self.lh * 1.6
  for _, l in ipairs(wrapped) do
    self:_print(l, cx, cy, C.dim)
    cy = cy + self.lh * 1.15
  end
  cy = cy + self.lh * 0.6
  for i, o in ipairs(options) do
    local w = self:w(o) + cp * 2
    if i == selected then
      g.setColor(C.warn[1], C.warn[2], C.warn[3], 0.3)
      g.rectangle("fill", cx, cy, w, self.lh, cp, cp)
    end
    self:_print(o, cx + cp, cy, i == selected and C.text or C.dim)
    cy = cy + self.lh * 1.4
  end
end

-- ------------------------------------------------------- CO-OP > ADDRESS

-- ed: a lib/connedit.lua editor.  One box in the middle of the window: the
-- host's address and port as fields, the selected one highlighted, then
-- what happens on load and the controls.
function Hud:drawEditor(vp, ed, fieldCount)
  self:_setup(vp, true)
  local g = self.gfx
  local pad = math.max(4, self.u * 3)
  local cp = math.max(2, self.u)
  local width = math.min(self.gw - pad * 2, math.max(self.lh * 26, math.floor(self.gw * 0.55)))
  local height = self.lh * 9 + pad * 2
  local x = self.gx + math.floor((self.gw - width) / 2)
  local y = self.gy + math.floor((self.gh - height) / 2)
  self:_box(x, y, width, height, 1, C.coop)
  local cx, cy = x + pad * 1.5, y + pad
  self:_print("CO-OP CONNECTION", cx, cy, C.coop)
  cy = cy + self.lh * 1.6
  self:_print("Host's address (joining) and port", cx, cy, C.dim)
  cy = cy + self.lh * 1.3

  local function field(i, text, fx)
    local w = self:w(text) + cp * 2
    if ed.cursor == i then
      g.setColor(C.coop[1], C.coop[2], C.coop[3], 0.3)
      g.rectangle("fill", fx, cy, w, self.lh, cp, cp)
    end
    self:_print(text, fx + cp, cy, ed.cursor == i and C.text or C.dim)
    return fx + w
  end
  local fx = cx
  for i = 1, 4 do
    fx = field(i, tostring(ed:value(i)), fx)
    self:_print(i < 4 and "." or ":", fx, cy, C.dim)
    fx = fx + self:w(i < 4 and "." or ":")
  end
  field(5, tostring(ed:value(5)), fx)
  cy = cy + self.lh * 1.8

  self:_print("On load:", cx, cy, C.dim)
  local ox = cx + self:w("On load: ")
  local onload = ed:value(fieldCount)
  ox = field(fieldCount, onload, ox)
  local note = onload == "HOST" and "  host when the game loads"
    or onload == "JOIN" and "  join this address when the game loads"
    or "  connect from START > CO-OP"
  self:_print(note, ox, cy, C.dim)
  cy = cy + self.lh * 1.8

  for _, l in ipairs({ "LEFT/RIGHT field, UP/DOWN change (L/R by 10), or type digits",
                       "A / Enter: save     B / Esc: cancel" }) do
    self:_print(l, cx, cy, C.dim)
    cy = cy + self.lh * 1.1
  end
end

return Hud
