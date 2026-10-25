# Gen 3 Co-op

Two players, each on their own save, see each other walk the same Gen 3
overworld, and can battle and trade right where they stand. One player
hosts, the other joins by address. Works on vanilla
Emerald/Ruby/Sapphire/FireRed/LeafGreen and on modded builds such as the
Inclement Emerald port, as long as both players run the same game, the same
engine release and the same mods.

## What works

- Your partner appears in your overworld with their own sprite and walks
  and runs at their real speed. Ledge jumps arc. On the bike they show
  their bike sprite; surfing, they ride their POKeMON like you do.
- **Across map borders:** Hoenn's towns and routes are drawn together, and
  so is your partner. Standing in Littleroot you can watch them walk up
  Route 101, and they cross the border smoothly.
- Doors, warps and Fly move them instantly. When they're somewhere not on
  your screen, the partner card names the area they're in.
- **Talk to your partner:** stand still facing them and press A for
  **WAVE / BATTLE / TRADE / CANCEL**.
  - **WAVE:** your character hops on their screen, and both of you get a
    message.
  - **BATTLE:** your partner gets "NAME wants to battle. Is that okay?"
    On YES, the game's own link battle starts, with the Union Room's rules:
    a single battle, both teams set to level 50 and healed first, and
    your party put back exactly as it was afterwards. Both games then
    save, as after a Union Room battle.
  - **TRADE:** same question, then the game's own Trade Center screen.
    Pick a POKeMON, confirm, watch the trade, and the game saves. You
    can trade again or both choose CANCEL to go back to the overworld.
    Trades need at least two POKeMON, like the Cable Club.
  - While waiting for an answer, press **B** to call it off. A request
    nobody answers expires after 30 seconds. One that arrives while your
    partner is busy (a menu, a sign, mid-step) waits up to 8 seconds, then
    is turned down as busy.
  - If either player disconnects mid-battle, the battle ends as a draw on
    both sides. Mid-trade, an unfinished trade is called off.
- **Fighting together** (the Inclement cart, port 0.6.0-dev.23 or later):
  - A wild POKeMON found in the grass with your partner on the same map
    asks them to join. On YES you both face two wild POKeMON together;
    otherwise you fight it alone.
  - An ordinary TRAINER asks your partner the same way. You fight them
    together, and each of you gets the full prize. A TRAINER you beat
    alone counts as beaten in your partner's game too.
  - Rival, gym and story fights need you both while co-op is on. If your
    partner isn't there, a box tells you to wait, and you can walk away.
    With co-op off (START > CO-OP > STOP or LEAVE), every fight starts
    as usual, so the game plays fine solo, Soul Link run or not. When they are
    there, they're pulled in. Afterwards **both games play the fight's
    ending**: each of you gets your own badge, TM, gift and story changes.
    A partner who dropped out (or loaded an older save) gets that ending
    when you reconnect. If they're somewhere else, they're told where to
    go back to.
  - Scenes with several fights in a row (the Museum, the Space Center) are
    shared fight by fight: whoever started the scene leads, and the other
    player's game waits at each next fight so you fight it together. If one
    of you isn't there for a later fight, the other fights it and the win
    counts for both. In Steven's double battle your partner takes Steven's
    place.
  - If your partner drops mid-battle, you choose **CONTINUE ALONE** or
    **END THE BATTLE** (a draw). If either of you wins a story fight that
    you started together, the win counts for both: the other player gets
    the ending when you meet again. Until then, further story fights wait.
    If neither of you won it, it's called off and you can fight it again.
  - If your two games ever end a story fight differently, you're told the
    story is out of sync, and story fights stay on hold until you both
    load saves from before that fight.
- They never block you. You walk through them, so they can't jam a
  doorway or a puzzle. NPCs walk around them, as they walk around you.
- **Shared NPCs:** while you're both on the same map, the wandering
  townspeople stand and walk where the host's game has them, so you both
  see the same town. Trainers, NPCs in a cutscene, and NPCs one save
  shows but the other doesn't stay local to each game. Talking to an NPC
  works as usual; it catches up when you're done.
- **Reconnects by itself:** if the connection drops after you've been
  connected (your partner restarts the game, the Wi-Fi blinks), the status
  line says "reconnecting" and it keeps trying every 5 seconds until your
  partner is back. START > CO-OP > STOP (or F8) stops it. Leaving on
  purpose tells your partner not to wait for you.
- **START > CO-OP:** a CO-OP row in the start menu (works with a
  controller): **HOST / JOIN / SOUL LINK** when you're not connected,
  **LEAVE / SOUL LINK** when you are. F8 still connects or disconnects in
  one key, using CO-OP ROLE.
- **Partner card** (top right): their name and ping, where they are ("Here
  with you", "Just nearby", or the area's name), whether they're battling
  or trading, and the Soul Link tally. While hosting it shows the address
  your partner should type. It turns red after 5 seconds of silence ("no
  signal"); the session closes after 15. Messages appear under it and fade
  out; Soul Link's are purple, deaths red.
- Mismatched installs are refused with a reason: different game, different
  mods, different engine release, different game data, or different co-op
  version.

## Soul Link

Turn on **SOUL LINK** in the launcher's Settings (Gen 3 Co-op section),
both of you. The run is one shared record for your two saves: each game
records what happens to it, and the two records are swapped whenever
you're connected (playing apart is fine; it catches up when you reconnect).
Press **F7** (or START > CO-OP > SOUL LINK) to see it: every area, your
POKeMON and your partner's with their icons, and which pairs are alive,
dead, broken or waiting. Up/down (or the D-pad, or the mouse wheel)
scrolls; F7, B or Esc closes it.

- **Areas:** every route **and every town** is an area (the name the map
  popup shows; a cave's floors or a town's buildings share one). You each
  get one encounter per area, and your two encounters in the same area are
  linked.
- **Linked fate:** if one of a pair faints, both are gone. If either of
  you misses an area's encounter (it ran, you KO'd it, you ran), the
  link is broken and the other one's catch is gone too.
- **Clauses** (each a setting, all on by default): **dupes** (an
  encounter whose evolution line either of you has already caught doesn't
  count; the next one does), **shiny** (always catchable, outside the
  links), **gifts count** (gifts and eggs are their area's encounter, so
  your starter is your ROUTE 101 one), **statics count** (scripted
  battles such as legendaries are their area's encounter).
- **ENFORCE CATCH LIMITS:** when on, a ball that would break the rules is
  refused in the bag ("SOUL LINK: you already had your encounter here."),
  and the ball is not used up.
- **HARD RULES:** catch limits enforced, plus the dead stay dead:
  - a faint counts the moment it happens, in any battle except co-op ones
    (so a whiteout can't heal it away);
  - REVIVE, MAX REVIVE, REVIVAL HERB and SACRED ASH have no effect on a dead
    run POKeMON, in battle or out;
  - dead POKeMON, and catches made against the rules, are sent to the PC
    as soon as you're back in the overworld, and go straight back if
    taken out (from the PC, the Day Care or a trade). If the dead one was
    the last that could battle, a living one from the PC takes its place;
  - with nothing left anywhere that can battle, the run is over (red on
    F7 and on the card).
- **LEVEL CAPS:** no POKeMON grows past the level of the next big fight's
  ace (its highest-level POKeMON). The big fights, in story order: your
  rival's battles, every gym leader, Team Magma/Aqua's bosses and admins,
  Wally, and the League (Emerald; Ruby/Sapphire use the gyms and the
  League; FireRed/LeafGreen the rival, gyms, Giovanni and the League).
  Levels come from the game's own trainer data, so a mod that rebalances
  trainers moves the caps with it. Battle EXP stops exactly at the cap,
  and a RARE CANDY has no effect there. Beating that fight lifts the cap to
  the next one; skipping an optional fight (a rival you walked past) stops
  it counting once you beat a later boss, and the cap never goes down. The
  cap shows on F7 and on the partner card, and a message says when it
  changes. Day Care EXP isn't capped.
- **Rules:** once your two runs are linked, the host's settings apply to
  both games.
- **No take-backs:** the run is kept in the mod's own per-playthrough
  storage, which reloading a save doesn't rewind. An encounter cut short by
  a reset counts as missed.
- Starting Soul Link on a save that already has POKeMON: those don't
  count and aren't linked.
- Without HARD RULES, dead POKeMON are only marked (red on F7); box them
  yourselves.

Not yet: double battles, chat, shared progression, online/relay play.
See `../DESIGN.md`.

**Battles need the identical engine release on both sides** (the same rule
as the Cable Club: the two games run the battle in lockstep). Walking
around together and trading only need matching game data. If a battle
can't start, the toast says why (for example "different engine release").

## Install

Import **`g3_coop-0.8.2.zip`** (from https://github.com/PandaKisor/g3-coop/releases)
from the launcher's **MODS** import screen, then enable it. On the Emerald
Doubles Soul Link cart you don't need to: importing the cart downloads it. Both players need
the mod, and the same version of it: 0.7.x refuses to connect to 0.6.x
or older and says "different co-op version". AUTOCONNECT now waits until
you are in the overworld (0.7.2), so your partner sees your trainer name and
Soul Link links straight away.

**Version:** works on Gen1Recomp **0.3.73**. No update is needed. The two
players don't even have to be on the identical release, as long as their
game data matches (same ROM, same mods). Different game data or a
different engine major version is refused with a reason.

## Play

1. Both start the game and load a save. The host picks **START > CO-OP >
   HOST**; the card shows the address to give the partner.
2. The partner picks **START > CO-OP > ADDRESS**, enters the host's address
   and port (d-pad: LEFT/RIGHT picks a number, UP/DOWN changes it, L/R by
   10; or type digits), and saves with A. Then **START > CO-OP > JOIN**.
3. **On load** on the same screen (OFF / HOST / JOIN) connects by itself
   whenever this save is loaded. **F8** connects or disconnects in one key.

These choices are kept in each player's own save. The launcher's
**Settings > Gen 3 Co-op** (ROLE, HOST ADDRESS, PORT, CONNECT ON LOAD) are
used until a player sets them in the game. A sealed cart (the Inclement
port) hands its mods only the cart's options, so on a cart the in-game
screen is the only way to set them per player.

### Connecting over the internet

The mod uses the platform's own networking: the same direct connection as
**START > LINK** (`src/link/Net.lua`). On the same home network it just
works, as long as the host's computer firewall lets UDP port 7777 in
(on Linux with ufw: `sudo ufw allow 7777/udp`; Windows asks the first time
the game hosts). Between two houses, the host's router has to let the connection in.
There are two ways to do that:

- **Port forward (recommended):** in the host's router settings, forward
  **UDP port 7777** (or whatever PORT you chose) to the host's computer.
  It's a one-time setting. The partner then joins using the host's
  *public* IP address (search "what is my IP" on the host's machine).
- **A "virtual LAN" app** such as Tailscale or ZeroTier, if you can't
  change router settings. Both players install it, and it makes the two
  computers act as if they were on the same home network. The partner then
  joins using the host's Tailscale/ZeroTier address. No router changes are
  needed.

**Why not the platform's ONLINE relay (no setup at all)?** The relay server
only forwards a fixed list of battle/trade message types, and only while a
battle is running (`docs/link-security.md`, "The relay"). Co-op position
updates would be dropped. Supporting co-op there needs a small server-side
change by the platform's maintainers. The mod's session code doesn't care
which transport it runs on, so it can switch over once that exists.

## Testing on one machine

Run two copies with separate identities, so their options and saves don't
collide. Each identity imports the ROM once.

```sh
POKEPORT_IDENTITY=coop-a love .   # ROLE = HOST, F8
POKEPORT_IDENTITY=coop-b love .   # ROLE = JOIN, address 127.0.0.1, F8
```

## Headless tests (development only; not in the zip)

```sh
cd Gen3Mod/gen1recomp-0.3.73 && luajit ../coop/tests/run.lua && luajit ../coop/tests/run_link.lua && luajit ../coop/tests/run_soullink.lua && luajit ../coop/tests/run_progress.lua
```

`run_progress.lua` covers shared story progression (`lib/progress.lua`):
the prepare/result/replay/completion exchange, duplicates, a called-off
fight, a dropped partner (either side, with a fallback win or none), an
older save, reconnecting, out-of-sync results and replays that can't play.

`run_link.lua` covers the battle/trade layer: request validation, the link
channel inside the co-op connection (including the engine's real
Game3Link handshake over it), the ask/answer/cancel/busy/timeout flow and
the activity runner.

The suite covers message validation, step replay, the real virtual-object
draw list, a full session over the engine's loopback transport (connect,
movement, busy state, malformed input, partner leaving, refusals,
timeouts), and loading through the real mod loader on a Gen 3 boot. It
also passes when run from the Inclement development engine
(`porting/full_port/generated/engine`).

## How it fits in the engine (no engine changes)

| Piece | Engine seam |
| --- | --- |
| Transport | `src/link/Net.lua` (ENet; the same one LAN link play uses) |
| Compatibility | `src/link/Handshake.lua` `hello`/`checkCompat`, plus an exact mod list |
| Partner avatar | an entry appended to `Objects.forDraw`'s list (virtual-object shape), placed by `Map.world` offsets |
| Local avatar | `src.core.game3.player`, `ow_sprites.playerGraphicsId` |
| Tick / key / HUD | `input.step`, `input.key`, `input.gamepad`, `input.wheel`, `render.hud` hooks; Plain Pixel (`assets/fonts/plainpixel`), `pokemon.icon` |
| START > CO-OP | `ui.start_menu.items` hook |
| Battle / trade | `src/core/game3/link` `Link.open` over a co-op channel; `link/battle.lua` `startUnionRoomBattle`, `link/trade.lua` `startMenu` |
| Surf blob under the partner | `field_effects.lua` `drawBehind` (wrapped), `loadSheet("surf_blob")` |
| Shared NPCs | `objects.lua` `_order`/`_byId`, `pushStep`; `playerBlocks` (wrapped) |
| Soul Link events | `battle.started`, `pokemon.caught`, `battle.fainted`, `battle.ended` events; `battle_bridge.startWild` (wrapped, to tell statics from wild) |
| Hard rules | `item_use.revive` (wrapped); `storage.findOpenSlot` / `moveMon` |
| Level caps | `exp.gain` hook; `item_use.useRareCandy` (wrapped); `scripting/trainers` parties, `scripting/flags` trainer flags, `constants` trainer ids |
| Soul Link refusals | `bag_menu.partyAndStorageFull` (wrapped) with `rom_text` overrides; `battle_text.get` (Safari); `catch.rate` hook as backstop |
| Soul Link record | `mod.storage` (per playthrough, not rewound by reloads); area names from `ui/game3/rse/mapsec` or `map_sections_extract` |
| Talk menu / prompts | `src/ui/game3/message.lua`, `choice.lua` (driven by the field HUD) |
