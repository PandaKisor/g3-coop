-- Data-only options schema.  The launcher's settings screen reads this file
-- (manifest "options_schema"), which is the only place Gen 3 players can
-- reach mod options: the F10 in-game manager is Gen 1 only.  main.lua
-- defines the same rows at runtime so mod.options:get sees the defaults.
return {
  { key = "role", label = "CO-OP ROLE", type = "choice", default = "host",
    choices = { { "HOST", "host" }, { "JOIN", "join" } } },
  { key = "address", label = "HOST ADDRESS", type = "text", default = "127.0.0.1",
    maxLen = 40 },
  { key = "port", label = "PORT", type = "number", default = 7777,
    min = 1024, max = 65535, step = 1 },
  { key = "autoconnect", label = "CONNECT ON LOAD", type = "toggle", default = false },
  { key = "hud", label = "SHOW STATUS", type = "toggle", default = true },
  -- Soul Link (F7 shows the run).  Once two runs are linked, the host's
  -- rules apply to both.
  { key = "soullink", label = "SOUL LINK", type = "toggle", default = false },
  { key = "sl_enforce", label = "ENFORCE CATCH LIMITS", type = "toggle", default = false },
  -- catch limits too, plus: no reviving the dead, and dead POKeMON are
  -- sent to the PC and can't come back out
  { key = "sl_hard", label = "HARD RULES", type = "toggle", default = false },
  -- no POKeMON grows past the next gym leader's / rival's / boss's ace
  { key = "sl_caps", label = "LEVEL CAPS", type = "toggle", default = false },
  { key = "sl_dupes", label = "DUPES CLAUSE", type = "toggle", default = true },
  { key = "sl_shiny", label = "SHINY CLAUSE", type = "toggle", default = true },
  { key = "sl_gift", label = "GIFTS COUNT", type = "toggle", default = true },
  { key = "sl_static", label = "STATICS COUNT", type = "toggle", default = true },
}
