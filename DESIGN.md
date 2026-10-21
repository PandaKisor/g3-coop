# Gen 3 shared-world co-op mod — design sketch

Status: 2026-10-18. **MVP implemented in `g3_coop/`** (see its README): LAN
presence for 2 players. Scope is fixed at two players.

**Updated goals (2026-10-20):** see the [campaign co-op addendum](#addendum-2026-10-20-campaign-co-op-goals).
It supersedes conflicting v1 scope decisions below and describes planned behavior,
not a claim that these features have shipped.

## Goal

Two players, each on their **own save**, see each other
walking around the same Gen 3 overworld, can talk to each other, and can start
a battle or trade on the spot. No shared story progression: each player's
flags, party, bag and save stay their own.

Explicitly out of scope for v1: shared progression, tag battles against the
game's trainers, one player's script/cutscene affecting the other's world.
Those need host-authoritative script state and are a separate, much larger
project.

## Independence from the Inclement port

The mod (working ID `g3_coop`) depends only on:

- the public mod API (`mod.hooks`, `mod.events`, `mod.world`, `mod.storage`),
- engine modules a sandboxed mod may `require` (`src.online.Client`,
  `src.core.game3.link.*`), and
- the `network` manifest permission (needed for `enet`).

It never requires anything from `inclement_battle_test`. It must work on
vanilla Emerald and FireRed/LeafGreen as well as the Inclement cart. The only
port-specific concern is **identity**: the port renames/re-indexes 268 shared
maps and adds 22, so:

- Maps are exchanged by **symbolic name** (e.g. `MAP_ROUTE101`), never by
  group/number.
- A session is only formed when both peers report the same game version **and**
  the same active cart `{id, version, hash}` (the same fields the arena
  profile uses: `src/online/ArenaData.lua`, `CartManifest.hash`). A vanilla
  player and an Inclement player never share a world; their maps differ.
- Different Inclement dev builds produce different cart hashes, so both
  players must run the same build. That's intended.

## What the engine already gives us

| Need | Existing piece | Notes |
| --- | --- | --- |
| Transport (LAN) | ENet, used by `src/link/LinkState.lua` | Sandbox allows `enet` with the `network` permission. |
| Transport (online) | `src/online/Client.lua` room sessions; `RoomSession:send/poll/take` forward arbitrary typed messages between seats | Rooms are battle-oriented today (see Blockers). |
| Moving an actor without locking input | `Handle:stepNow / placeAt / isMoving / setPassable` in `src/world/game3/WorldAPI.lua` (RFC 0014) | Only on objects that already exist; see Blockers. |
| A press on an actor | `world.talk` hook, called in `src/core/game3/field.lua:989` | Lets the mod own the dialogue for a ghost. |
| Link battle over an existing session | Gen 3 link battle (`src/core/game3/link/battle.lua`) already runs over `relay_transport.lua` for the Union Room | Single/double/multi modes exist. Cable rules: real party untouched. |
| Trade | `src/core/game3/link/trade.lua` | Same session reuse as battles. |
| Remote player avatars | Union Room virtual objects (`union_room.lua` `vobjId`, `plaza_wander.lua`) | Slot-fixed positions plus local wander, not live positions; useful reference for sprite selection/fallback (`Participant.wireAvatar`). |

## Blockers (must be solved first)

### B1. Gen 3 cannot spawn runtime objects — resolved without an engine change

The MVP draws the partner through `src/core/game3/virtual_objects.lua`, the
layer the Union Room uses for remote players. `Objects.forDraw` already draws
it (pixel position, walk animation, facing), and an entry only blocks the
player when `solid == true`. What it still lacks is `world.talk` (that hook
only fires for real event objects), so talking to the partner needs either
the seam below or a separate input check against the ghost's cell.

Original analysis:

`WorldAPI:spawnNpc` on Gen 3 returns `UNSUPPORTED`
(`src/world/game3/WorldAPI.lua:432`): event objects come only from the map's
extracted templates. Without a spawned object there is nothing to call
`stepNow` on and nothing for `world.talk` to target.

Options:

1. **Engine seam (recommended):** implement Gen 3 `spawnNpc` as a runtime
   object in `src.core.game3.objects`, in a reserved local-ID range (the way
   the Union Room allocates `vobjId`s), excluded from map scripts, trainer
   sight, and save. Propose it upstream as an RFC following the same
   "additive, guarded seam" convention as RFC 0014, with a modkit test.
   Small: probably a few hundred lines plus tests.
2. **Draw-only fallback:** render ghosts from a field draw hook with no object
   behind them. No collision, no `world.talk`; interaction goes through a
   START-menu entry instead. Unblocks M1 while the seam is pending.
   (To verify: which Gen 3 field draw hook/event is exposed to mods.)

### B2. The platform relay can't carry co-op traffic (confirmed)

`docs/link-security.md` ("The relay") states that the relay forwards a
`room_msg` only if its inner `msg.type` is on the engine's allowlist (engine
3: the `game3_*` set, each with a byte cap), only from a seated player, and
only while the room is `battling`. `coop_*` messages would be dropped. The
server (`pokeserver`) isn't public, so this needs its maintainers.

What we'd ask them for: a `coop` room intent (2 seats, profile-matched like
other rooms, live as soon as both seats are filled), plus allowlist entries
`coop_hello` (≤4 KB), `coop_pos` (≤256 B), `coop_state` (≤64 B) and
`coop_bye` (≤64 B), within the existing per-connection lines/second cap
(the mod peaks around 16 msgs/s while running). Client side, the mod would
then wrap `Client.roomSession()` the way `relay_transport.lua` does. The
session already treats the transport as an interface.

Until then: direct ENet. Same LAN works out of the box; across the
internet the host forwards a UDP port, or both players use a virtual-LAN app.

## Architecture

```
g3_coop/
  manifest.json      permissions: ["network"]; targets: emerald, firered, leafgreen
  main.lua           wiring: hooks, events, update tick
  session.lua        transport abstraction: EnetTransport | RelayTransport
  protocol.lua       message encode/validate (pure, unit-testable)
  presence.lua       local player -> outgoing pos/state messages
  ghosts.lua         remote players -> spawned objects, step queue, visibility
  interact.lua       world.talk on a ghost -> menu (Battle / Trade / Wave)
  battle_bridge.lua  hands the session to the Gen 3 link battle/trade flows
```

One session object, two transports with the same `send/poll/close`
interface. `relay_transport.lua` already has the right shape, so the ENet
transport mirrors it.

## Protocol (original v1 sketch; see main README and lib/protocol.lua for what shipped)

All messages are small tables (`Json.lua` on ENet; native framing on the relay).
Every message has `v` (protocol version) and `t` (type).

| `t` | Fields | When |
| --- | --- | --- |
| `hello` | `game`, `cart{id,version,hash}`, `engineVersion`, `name`, `avatar` (gender/class), `caps` | On connect. Mismatch -> polite refusal naming the differing field. |
| `pos` | `seq`, `map` (symbol), `x`, `y`, `facing`, `mode` (walk/run/bike/surf/dive), `elev` | At the **start of each step** and on facing change. Not per frame. |
| `warp` | `seq`, `map`, `x`, `y`, `facing` | Map change (door, warp, fly, connection). Snap; no interpolation. |
| `state` | `busy` (none/menu/script/battle/trade), `hidden` | On change. |
| `hb` | `seq` | Every 1 s when idle. 5 s silence -> ghost greys out; 15 s -> removed. |
| `emote` / `chat` | `id` / short text (length-capped, charset-filtered) | User action. |
| `req` / `resp` | `kind` (battle/trade), `id`, `accept` | Challenge flow. |
| `bye` | `reason` | Clean disconnect. |

Rates: walking produces ~4 `pos`/s and running ~8/s, which is trivial
bandwidth. Cap outgoing at 15 msgs/s, drop anything older than the last
applied `seq`.

## Ghost behavior

- **Visibility:** shown only when the remote `map` equals the local active map.
  (Later: neighbor maps via `WorldAPI:liveMaps()` offsets.)
- **Movement:** each `pos` enqueues the step; the ghost runs `stepNow(dir)`
  when `not isMoving()`. Backlog > 2 steps, a non-adjacent target, or a
  `warp` -> `placeAt`. No collision re-judging locally (RFC 0014's rule: the
  sender's game already decided the move was legal).
- **Passable:** `setPassable(true)`, so ghosts never block doorways, puzzles,
  boulders or ledges in the other player's world.
- **Isolation:** ghosts must not appear in trainer line of sight, script
  object lookups, `Ghosts.capture/adopt` (the engine's existing map-transition
  object pool, unrelated to this mod), or saves. That's part of B1's seam.
- **Busy states:** while the remote player is in a menu/script/battle the ghost
  stands still with an indicator bubble, and challenges are auto-declined.
- **Local cutscenes:** hide all ghosts while the local player's script/cutscene
  runs (`scriptMoves` non-empty / script context active), restore after.
- **Sprites:** reuse the Union Room's avatar selection and fallback rules.
  Bike/surf need the matching overworld sprite sets; walk-only is fine for M1.

## Interactions

**As built (0.3.0).** The engine's link stack runs unmodified over a
*channel* inside the co-op connection (`lib/channel.lua`): a transport with
the `Net.lua` shape whose messages travel as `coop_link {c, m}` envelopes.
The co-op validator checks only the envelope; the engine's own link
`Session` runs `Wire.sanitize` on the inner message, as it does on the relay.
`lib/requests.lua` runs `coop_ask` / `coop_answer` / `coop_cancel` (ids
alternate odd/even between host and guest, and the id is also the channel
number). `lib/activity.lua` then calls `Link.open` on the channel (co-op host
= seat 0), waits for `Game3Link`'s own handshake verdict, and hands off:

- battle: `link/battle.lua` `startUnionRoomBattle` + `pumpUnionSetup`, the
  same entry the launcher's native arena uses outside the Union Room;
- trade: `link/trade.lua` `startMenu` with `loopbackCommit = true`. With no
  relay to issue `trade_commit`, the two games compare trade digests
  themselves (`tryLoopbackCommit`). The flag is restored when the trade ends.

Link messages that arrive before this side has opened the channel (the
acceptor's hello lands in the same batch as its answer) are held, up to 64.
Protocol version 2, so a 0.2.x partner is refused by name.

**Original sketch:**

- A on a ghost -> `world.talk` -> a small menu: **Battle**, **Trade**,
  **Wave**, Cancel.
- Battle: `req` -> peer sees "X wants to battle" -> on accept both enter the
  Gen 3 link battle over the **same session** (the Union Room relay path is
  the reference). Cable rules: no lasting party/HP changes, matching vanilla
  link play. Inclement rules apply automatically when both run the cart,
  provided the cart's battle RNG stays on `link_guard` (it currently does).
- Trade: same flow into `link/trade.lua`. Trades are permanent and are written
  to each player's own save by the existing trade code.

## Security

This is a second place where the game reads bytes from someone else. Follow
`docs/link-security.md`: validate every field's type and range, clamp
coordinates to the active map's layout, ignore unknown map symbols, cap string
lengths, rate-limit per peer, never `load` or execute received data, and never
let a message write to the local save outside the existing trade path.

## Milestones (rough, for one developer)

| # | Deliverable | Estimate |
| --- | --- | --- |
| ~~M0~~ done | Spike: two local instances, ENet `hello` + `pos` printed to log | 2–3 days |
| ~~M1~~ done | Ghosts on the same map, smooth movement, warp snapping, timeout (B1 seam or draw-only fallback) | 1–1.5 weeks |
| ~~M2~~ done (chat deferred) | Talk menu (A facing partner): WAVE / BATTLE / TRADE; toasts, neighbour-map drawing, seam crossing, ledge arcs | ~1 week |
| ~~M3~~ done for vanilla (0.3.0) | Battle and trade over the session. Verified on vanilla Emerald with two real games: battle (both sides agree on the result), trade (swap saved on both sides), disconnect mid-battle (draw on both), request cancel. Inclement cart not yet tried | 1–2 weeks |
| ~~M3.5~~ done (0.4.0) | End-to-end polish for a full playthrough: surf blob under the partner (bike sprite confirmed), automatic reconnect, host-driven wandering NPCs on a shared map (`lib/npcs.lua`, `coop_npc`). Real-game checks: NPC positions matched across both games over 30 s; reconnect in both directions | — |
| ~~M3.6~~ done (0.5.0) | Soul Link as a shared co-op record (`lib/soullink.lua` rules, `lib/tracker.lua`, `coop_sl`): areas by MAPSEC (towns included), dupes/shiny/gift/static clauses, enforced catch limits through the bag's own refusal path, deaths and broken links propagated between games, per-playthrough `mod.storage`. Real-game checks: linked catches, refused ball not consumed, static detection, a faint killing the partner's mon on the other machine | — |
| ~~M3.7~~ done (0.6.0) | Nicer UI and hard Soul Link rules: START > CO-OP menu (host/join/leave/Soul Link), partner card with ping and area, wrapped fading toasts, Soul Link panel with icons, status pills and scrolling (`lib/hud.lua`); hard rules (faints recorded on `battle.fainted`, revives refused, dead/not-allowed catches auto-boxed, run over). Real-game checks: start menu row and menu, panel, a whiteout boxing the dead mon, a withdrawn dead mon bouncing back, the partner's linked mon boxed on the other machine | — |
| ~~M3.8~~ done (0.7.0) | Soul Link level caps (`lib/levelcap.lua`): the next big fight's ace, from the game's trainer data and trainer flags, story-ordered lists for Emerald, RS and FRLG; battle EXP clamped through `exp.gain`, RARE CANDY refused. Real-game checks: cap from the save, EXP stopping exactly at the cap, candy refused, cap moving after a beaten boss | — |
| M4 | Online via relay: needs the server change in B2, then ~2–3 days client side | blocked on maintainers |
| M5 | Polish: neighbor maps, ledge-jump arc, reconnect | ongoing |

Total to a solid LAN v1 (M0–M3): about **4–6 weeks**. Online adds M4.

## Requests to the porting agent (low cost, protects co-op later)

1. Keep all battle randomness on `link_guard` / seeded sources, never bare
   `math.random` / `os.time` (cosmetic animation randomness is fine).
2. Keep map **symbols** stable once assigned; renumbering is fine,
   renaming is not.
3. Don't reuse the reserved runtime-object local-ID range chosen for B1.
4. (2026-10-21) Pin `g3_coop` in the cart. `inclement_emerald.g1rcart` is
   `sealed`, so the loader disables every mod the cart does not list. Add it
   after the port in both `mods` and `load_order`:
   `{ id = "g3_coop", source = "local", version = "<installed co-op version>" }`.
   A sealed cart also hands pinned mods only the cart's own `options`, never
   the player's launcher settings, so per-player settings (role, host
   address) cannot come from the launcher on this cart. That part is co-op's
   to solve, not the cart's.

## Results on the Inclement cart (2026-10-21, 0.7.2 vs 0.6.0-dev.19)

Two hidden copies of the dev.19 playtest app (Oldale), with a test-only cart
copy that pins `g3_coop` and passes host/join through pin options:

- Connect, version check, partner card, walking ghost: work.
- Co-op battle: runs to the end and both sides agree (one win, one loss). It
  uses the engine's link battle (level 50, Union Room trainer class); the
  port's `turn_rules.lua` has explicit link-battle branches.
- Trade: swap shown on both screens and saved on both sides.
- Soul Link: runs link and the host's rules sync.
- Level caps: wrong on this cart. It read "cap 5 (RIVAL, ROUTE 103)" for a
  level-8 party, because `lib/levelcap.lua` uses vanilla Emerald's story list
  and static trainer levels, while the port scales trainer levels. Needs the
  campaign's own cap schedule (see the addendum).

## Open questions / to verify

- Which Gen 3 field draw hook/event is available to mods (affects the B1 fallback).
- Whether a booted overworld game can hold a relay room session without the
  launcher's arena flow (`ArenaBoot`), or only the Union Room path does today.
- Relay message rate limits and room lifetime rules in `pokeserver`.
- Whether the Gen 3 link battle can start from an arbitrary map (the Union
  Room flow expects its own room/map context; `cable_entry.lua`/`union_room.lua`
  show what state it assumes).

## Addendum: 2026-10-20 campaign co-op goals

This section records the user's clarified goals for a personal campaign played
by two experienced friends. It supersedes earlier exclusions of shared campaign
progression and cooperative battles against NPCs. The earlier implementation
notes and milestones remain historical records. These goals still require
implementation and validation; this update changes documentation only.

### Campaign foundation and challenge

- Keep Inclement Emerald as the campaign's content foundation. It was chosen
  for both its expanded roster/mechanics and its harder, redesigned trainer
  teams. Retain those benefits and adapt encounters and strategies for doubles.
- Replace player-level-based enemy scaling with fixed trainer levels and fixed
  wild encounter level ranges. Enemy levels must not follow either player's
  party. Inclement's trainer offsets need an authored replacement level curve;
  disabling scaling alone does not provide that curve.
- Use player level caps tied to major fights in both full co-op and Soul Link.
  These caps are separate from enemy scaling. The exact progression of caps
  still needs to be specified for the redesigned campaign.
- Build one challenging cooperative campaign with two rulesets: full co-op
  with normal catching/recovery, and optional Soul Link with encounter pairing
  and permanent linked losses. A broad public-facing difficulty/configuration
  system is not a goal of this personal project.
- Avoiding usable bag items during battle is an honor rule. Held items are
  allowed; the intended rules do not require a blanket bag-item prohibition.

### Battle format, parties and faint allowances

All campaign battles use the doubles/cooperative format, including wild,
ordinary trainer, rival, gym and story encounters. Solo play retains doubles;
it does not return to the single-battle campaign. Deliberately designed 2v1
encounters are an allowed exception to having two opponents.

| Situation | Control and available party | Faint allowance |
| --- | --- | --- |
| Solo | One player controls both active positions using their own six Pokémon. | No three-faint limit; all usable party members remain available. |
| Shared co-op | Each player controls their own active Pokémon and may switch among their own six. | Each player is eliminated from the battle on their third faint, even if they have healthy reserves. |
| Disconnect fallback | After a pause, the remaining player may continue with both active positions using only their own team. | The three-faint limit is lifted; all of their usable Pokémon are available. |

- The co-op limit counts faints, not three preselected Pokémon. Players bring
  six and can use any of them before reaching the limit.
- When a solo battle becomes shared, the three-faint allowance starts when
  co-op begins. Faints that happened earlier in solo play do not count toward
  that allowance.
- If one player reaches three faints, that player cannot send further
  replacements. Their partner may finish the fight. Battle elimination and a
  network disconnect are distinct cases; only the latter has the agreed solo
  fallback described above.
- Solo support and disconnect fallback do not give the remaining player
  control of the absent friend's party and do not require an AI partner.

### Proximity, invitations and concurrent battles

- The initial joining range is the **same map**, rather than a screen-sized
  radius. Range may expand after playtesting. This joining rule is separate
  from the area identity used to pair Soul Link encounters.
- Players outside joining range can fight independently. Supporting two
  simultaneous battles is a required goal, not a single shared battle lock for
  the whole session.
- A nearby player can request entry into an ongoing battle. Prompt the player
  already battling to accept or decline; being in battle must not simply
  reject this cooperative join request as busy.
- If the request is declined, the newcomer can receive a separate wild battle
  when the location has a wild encounter table. Use that table; do not invent
  a wild encounter in a location without one.
- Mid-battle joining is part of the goal. The turn boundary, active-position
  handoff and rejoining details need implementation design; an earlier idea
  that participants would always be fixed at battle start is superseded.

### Shared progress and mandatory joint fights

- Ordinary route trainers can be fought solo. Their defeats grant shared
  trainer credit, so splitting up contributes to the same campaign progress.
- Rival, gym and story battles require both players to start together. Solo
  activity must not independently advance the main campaign through those
  gates.
- Each player keeps ownership of their own Pokémon and team choices. Shared
  trainer/story credit adds synchronized progression to the earlier model of
  entirely separate story flags.
- The broader script/save synchronization design remains implementation work;
  the old no-shared-progression scope restriction no longer describes the
  intended campaign.

### Disconnects and story-fight completion

- Pause a shared battle for reconnection when a player disconnects. Offer the
  remaining player the option to continue under the solo fallback rules:
  their own team only, two active positions, and no three-faint limit.
- If a rival, gym or story fight began with both players, a victory achieved
  through this fallback still counts. Preserve its rewards and shared victory
  credit rather than requiring the fight to be replayed.
- Further story progression waits for the partner to reconnect and the shared
  result to be synchronized. This is the agreed exception for finishing an
  already-started joint fight, not permission to start subsequent mandatory
  fights alone.

### Wild encounters, ownership and Soul Link eligibility

- Normal wild encounters have two opponents. Nearby players can share the
  encounter; separated players can have their own wild battles.
- In Soul Link, first-encounter eligibility belongs to each player separately
  in each encounter area. An encounter that happens outside the friend's
  joining range does not consume the friend's first encounter.
- If both players are eligible when they share their first wild battle, that
  battle supplies both first encounters and their catches become linked.
- If first encounters happen separately in the same area, the catches become
  linked once both exist. Simultaneous catching is not required.
- If one player has already used the area's encounter before a shared wild
  fight starts, the other player can still make their eligible catch. The
  player who has used their encounter does not gain another one by joining.
- Eligible players freely decide which opponent each catches. Targets are not
  assigned by player number or battlefield position; this freedom is intended
  to support team building. A sole eligible player may choose either target.
- If either player fails their eligible encounter, that area is a no-go for
  both: no retry encounter, and an already-caught counterpart becomes
  unusable. Apply the ongoing-battle deferral below when necessary.
- These encounter limits belong to Soul Link. Full co-op retains normal
  catching rather than inheriting the first-encounter restriction.

### Linked deaths, overlapping battles and losses

- In Soul Link, a faint causes a permanent loss and the linked partner is
  lost after battle. Do not immediately remove the linked partner during an
  ongoing fight.
- If the players are in separate battles and one finishes first, a linked
  Pokémon in the other's ongoing battle remains usable until that player's
  own battle ends. The end of the originating battle does not interrupt or
  invalidate actions in the other player's fight.
- In a shared battle, resolve linked partner losses after that shared battle
  ends. This timing also avoids linked deaths immediately eliminating both
  active Pokémon mid-turn.
- Losing a battle causes a whiteout. In Soul Link, the players can continue
  with eligible survivors from the boxes and decide at the time whether to
  continue the run. Do not automatically reset the run or impose an
  irreversible run-ending lock solely because a battle was lost.

### Legendary encounters and occasional 2v1 bosses

- Two opponents are the preferred default, including legendary encounters.
  Discussed designs include a forced double-legendary spawn, or one guaranteed
  static legendary plus a companion rolled from a suitable encounter pool.
  Exact pairings and companion tables remain encounter-design decisions.
- Players freely choose catch ownership here too. A legendary and its
  companion can become the area's Soul Link pair when both players have
  eligible encounters; a sole eligible player can choose which to catch.
- A few deliberately designed 2v1 encounters are welcome: both active player
  positions face one stronger Pokémon at a fixed higher level. These are
  authored exceptions rather than the default legendary solution.
- Where a boss is intended to exceed player levels, specify its level and the
  player cap separately. Tune its moves, durability and damage for facing two
  attackers; do not reintroduce party-based level scaling.

### Remaining design and validation work

The agreed goals above are sufficient to guide the next implementation
discussion. Remaining details include safe mid-battle entry and re-entry,
reconnect timing, consistent save/progression updates across two concurrent
battles, the exact level-cap schedule, and encounter-specific team/catch
behavior. Validate transitions between solo, shared and disconnect-fallback
battles, plus deferred Soul Link losses and story gates. The same-map range
and encounter difficulty should be revisited through playtesting with the two
intended players.

## Doubles plan (2026-10-21, investigation only; nothing built)

### What the engine already has

The Battle Tower link multi (`src/core/game3/link/tower_link.lua`) is two
linked humans against two AI trainers, running in lockstep:

- `LB.beginMulti(setups, onDone, { battle = opts })` starts a 2v2 link battle;
  `opts` passes through to `BattleBridge.start`.
- `LB.setVirtual({ seats = { [seat] = { action = fn, switch = fn } } })`
  makes a seat AI-driven. Only the host (seat 0) runs the AI and sends the
  moves as that seat's link actions, so both games see the same choices.
- Seat 0's setup carries the foe parties and the shared seed; both games
  simulate from `LB.makeRng(seed)`. `link_guard` raises on any other RNG, and
  the AI (`ai.lua`) and the port's `damage.lua` both use the battle RNG.
- Party ownership is a per-slot owner list (`multiLayout`,
  `State.ownsSlot`), not hard-coded to three each.

### Gaps between a Tower link multi and a campaign battle

| Gap | Today | Campaign needs |
| --- | --- | --- |
| Persistence | Link battles use copies; real party untouched; `noExp.link` | EXP, levels, moves, evolution, HP/PP/status, held-item use and money written back to each player's own party and save |
| Party size | `LB.MULTI_PARTY_SIZE = 3` each | Six each, three-faint elimination (co-op only) |
| Foes | Frontier trainers from seat 0's setup | Campaign trainers (port data: custom moves, spreads, abilities), fixed levels, single-trainer doubles, two-trainer doubles, authored 2v1 |
| Wild | Not possible in link mode; no bag | Two wild foes, balls allowed, each player catches into their own party, Soul Link per player |
| Interactive post-turn events | None in link battles | Level-up move learning and evolution are local UI; lockstep must wait for both |
| Start | Tower script | Trainer sight/approach on the field with two players, same-map rule, story gates |
| Shared credit | — | Trainer-defeated flags synced to both saves |
| Disconnect | Battle ends as a draw | Pause, then a solo fallback the remaining player can finish |

### Proposed order

1. **D1: solo doubles everywhere (no network).** Every trainer and wild
   battle is a double; the solo player controls both positions with their
   own six. Needs content decisions for trainers with one Pokémon and for
   wild pairs. This is the base everything else stands on.
2. **D2: co-op trainer double, both present at start.** Tower-style lockstep
   (host runs foe AI), six each, three-faint limit, results written back to
   both saves, shared trainer credit. Mandatory fights require this.
3. **D3: co-op wild double.** Two wild foes, catching, Soul Link pairing per
   player.
4. **D4: disconnect pause and solo fallback**, including story-fight credit.
5. **D5: joining a battle already in progress, and two concurrent
   battles.** The hardest step; designed after D2 to D4 have been played.

### Ownership risk

The port already overlays `battle/init.lua`, `battle/engine.lua`,
`battle/ui.lua`, `party.lua` and the party menu, which are exactly the files
D1 to D3 change. Two agents editing the same overlay files will collide, so
ownership has to be agreed before any engine work starts.

### Prototype status (2026-10-21, 0.8.0-dev.1)

D2's core runs without engine changes (`lib/teambattle.lua`); tested on the
dev.19 cart with two real games:

| Check | Result |
| --- | --- |
| Win vs the port's Calvin + Rick (species 559/593/789), 8 turns | Identical HP both games every turn; guard never tripped |
| Faint and replacement | Works (the partner's party menu shows the multi layout) |
| Writeback | Each player's own mons only, HP/status per slot |
| Shared trainer credit | Both trainer flags set in both saves on a win |
| Loss | Both games lose; both white out (money halved, healed, at the Center) |
| 4 + 4 parties (8 on the player side) | Battle runs and writes back; in-battle menu past six not exercised |

Not done, and why: EXP (engine, CODEX-REQUESTS.md 3), three-faint limit
(engine, 4), wild doubles and catching (engine, 5), prize money (needs a
split decision), a menu entry and trainer sight start (co-op side, next),
disconnect pause/fallback (D4), mid-battle join (D5).

### Shared story progression (0.8.0-dev.7, port dev.23)

Codex's design (a): each game runs the fight's own post-battle script
against its own save. See `porting/full_port/COOP-PROGRESSION.md` for the
contract. `lib/progress.lua` does the co-op half (protocol 10,
`coop_prog`):

1. The initiator's script stops at the story trainer's battle with
   `opts.coopContinuation`. Co-op calls `prepare(id, d, true)` and sends
   `prep`; the partner calls `prepare(id, d, false)` and answers
   `prepped`. Only then is the joint request sent. A refusal or no answer
   within 8 s calls the fight off with `cancel`.
2. At `battle.ended` each game resolves its own result (win / lose; any
   other ending is `cancel`), before whiteout and before the script
   resumes. It then sends `event` (id, descriptor, result).
3. The initiator's script runs its own continuation. The partner calls
   `replay(id)` when the field is idle and on the event's map, retrying
   while the field is busy and saying where to go if they're elsewhere.
4. `coop.progress` `done` sends `done`; the other game calls `ack` once it
   is done too.
5. On every connect both games send `have` (every receipt and its
   status). A result the other side lacks is resent. A receipt nobody
   finished is cancelled. A finished one whose partner lost or called it
   off is acknowledged, and each keeps its own result.

Ids are `g3c:<OT>.<SID>:<counter>:<time>`, with the counter in
`mod.storage`. Descriptors travel unchanged: `Protocol.copyData` bounds
depth, nodes and string length, and refuses data that is too big rather
than shortening it. Joint credit no longer sets a story trainer's flag
(the event does), but it still pays the prize.

A story fight the port can't share (`coopContinuationError`, or no
descriptor, as for Norman, Wallace, Archie, the Museum and Space Center
fights) is fought alone by the initiator, with a toast. It isn't credited
to the partner.

Verified with two real games on dev.23 against the real Roxanne script:
- a joint win gives each player a badge and a TM, with done and ack on
  both sides;
- with the partner dropped, the initiator wins alone; the partner restarts
  from an older save and gets the ending on reconnect;
- with the partner gone during the handshake, the fight is called off
  (cancelled, Roxanne still unbeaten), and the retry wins.

### Decisions (user, 2026-10-21)

- Prize money in a team battle: each player receives the full prize for
  both trainers, as if they had won alone (no split).
- Mandatory joint fights: when the partner isn't there to fight together
  (including offline), the battle doesn't start. A text box says to wait for
  the partner, and the player can cancel and walk away without the dialog
  sticking on screen.
- Disconnect mid team battle: pause and offer "continue alone" or "end the
  battle" (a draw) right away. The engine can't resume a broken link battle.
