-- Exercise the launcher's real ZIP installer on the release archive, with an
-- in-memory filesystem (same approach as porting/battle_lab/verify_import.lua),
-- then load the extracted archive through the real mod loader on a Gen 3 boot.
--   cd Gen3Mod/inclement-engine
--   luajit ../coop/tests/verify_zip.lua ../g3-coop-0.1.0.zip <entries.json> <extracted dir>
-- entries.json maps each archive path to its bytes (written by verify_zip.py).
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.modkit")
local Json = require("src.link.Json")
local f = assert(io.open(arg[2], "rb"))
local entries = assert(Json.decode(f:read("*a")))
f:close()

local files = {}
local fs = T.sdk.memfs(files)
fs.mount = function(_, mount)
  for name, bytes in pairs(entries) do files[mount .. "/" .. name] = bytes end
  return true
end
fs.unmount = function()
  for path in pairs(files) do
    if path:sub(1, 17) == "mod_import_mount/" then files[path] = nil end
  end
  return true
end
fs.remove = function(path) files[path] = nil return true end
fs.createDirectory = function() return true end
love = love or {}
love.filesystem = fs
local CacheFs = require("src.import.CacheFs")
CacheFs.write = fs.write

local LauncherMods = require("src.mods.LauncherMods")
local ok, id = LauncherMods.installZip(arg[1])
T.check(ok, "the launcher installer accepts the zip: " .. tostring(id))
T.eq(id, "g3_coop", "and recognizes the mod")
local count = 0
for name, bytes in pairs(entries) do
  if not name:match("^%.modkit/") then
    count = count + 1
    T.eq(files["mods/g3_coop/" .. name], bytes, "installed byte-for-byte: " .. name)
  end
end
T.check(count >= 7, "every mod file is in the archive")
T.eq(entries["tests/run.lua"], nil, "development tests are not shipped")

-- the launcher's settings screen is the only way to reach mod options in a
-- Gen 3 game (the F10 manager is Gen 1 only); it must list ours
local SaveData = require("src.core.SaveData")
local launcherOpts = {}
SaveData.loadOptions = function() return launcherOpts end
local LauncherSettings = require("src.import.LauncherSettings")
local okOpen, model = pcall(LauncherSettings.open, {}, "emerald")
T.check(okOpen, "launcher settings open: " .. tostring(model))
local section
for _, sec in ipairs(okOpen and model.sections or {}) do
  if sec.title == "Gen 3 Co-op" then section = sec end
end
T.check(section ~= nil, "launcher settings list a Gen 3 Co-op section")
local rows = {}
for _, row in ipairs(section and section.rows or {}) do rows[row.label] = row end
for _, label in ipairs({ "CO-OP ROLE", "HOST ADDRESS", "PORT", "CONNECT ON LOAD", "SHOW STATUS" }) do
  T.check(rows[label] ~= nil, "with the " .. label .. " row")
end
if rows["CO-OP ROLE"] then
  T.eq(rows["CO-OP ROLE"].value(), "HOST", "role defaults to HOST")
  rows["CO-OP ROLE"].step(1)
  T.eq(launcherOpts.modOptions and launcherOpts.modOptions.g3_coop
    and launcherOpts.modOptions.g3_coop.role, "join",
    "changing it writes options.modOptions.g3_coop, which the game reads on boot")
end

local Runtime = require("src.mods.Runtime")
local root, dir = arg[3]:match("^(.*)/([^/]+)$")
local run = T.sdk.loadMod(dir, { root = root, generation = 3, data = T.sdk.gen3Data() })
T.eq(#run.errors, 0, "the extracted zip loads clean (" .. tostring(run.errors[1]) .. ")")
T.check(Runtime.wantsHook("input.step") and Runtime.wantsHook("input.key")
  and Runtime.wantsHook("render.hud"), "and registers its hooks")
run.release()
T.finish("g3_coop release archive")
