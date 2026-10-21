# Co-op requests for the port (2026-10-21)

From the co-op mod (`Gen3Mod/coop`, g3_coop 0.8.0-dev.1). Co-op stays in its
own tree and does not edit `porting/` or the engine overlays; these are the
engine-side pieces it cannot do from a mod.

## Already working, keep stable

A team battle (both players against two of the game's trainers) runs today on
the dev.19 cart with no engine changes. It uses the Battle Tower link multi:
the host builds both foe parties with `Trainers.foeFromId` (the port's
override, so Inclement teams, spreads and levels apply) and runs their AI as
virtual seats; both games run in lockstep from one seed. Tested: 8 turns
against Calvin + Rick (species 559/593/789), identical HP every turn, faint
and replacement, a loss whiting out both players, 4 + 4 parties.

Co-op depends on these. Please keep their names and behavior, or tell us
when they change:

- `LB.beginMulti`, `LB.setVirtual`, `LB.unpackMultiParty`,
  `LB.MULTI_PARTY_SIZE`, `LB.freshBattle`, `LB.makeRng`
- `TowerLink.aiAction`, `TowerLink.aiSwitch`, `TowerLink.battle`
- `Trainers.foeFromId(id)` returning a complete party
- the `battle.ended` event's `battle` state: `playerParty`,
  `partyOwner.player`, `linkOwn`
- `Party.applyBattleFields`, `BattleBridge.applyWhiteoutMoneyLoss`,
  `Field.respawnAtHeal`

## 1. Pin g3_coop in the cart (small)

`inclement_emerald.g1rcart` is `sealed`, so every unlisted mod is switched
off. Add after the port, in `mods` and `load_order`:
`{ id = "g3_coop", source = "local", version = "0.8.0-dev.1" }`.

## 2. Keep battle randomness on the battle RNG (ongoing)

Link battles only stay in sync because every random roll comes from
`st.rng`. `link_guard` raises "link battle rng fallback" on anything else.
New Inclement abilities, items and move effects must take the battle's RNG
too, never `math.random` or `Rng.Random` directly. The guard never fired in
our tests.

## 3. EXP in co-op battles (needed for D2)

Today a link battle gives no EXP (`profile.lua` `noExp.link`).

- Allow EXP when the battle is a co-op team battle. Co-op can pass a flag in
  `opts.battle`, for example `coopTeam = true` -> `st.coopTeam`.
- `Experience.awardFoe` loops party slots 1 to 6; the co-op player side holds
  up to 12. Loop over the whole `st.playerParty`.
- Both games must apply the same EXP, levels and stats to every player-side
  mon, the partner's included, or the next turn desyncs. Show the EXP bar and
  level-up screens only for mons owned by `st.linkOwn`, and apply the
  partner's silently.
- Learning a move into an empty slot is deterministic, so apply it on both.
  With four moves already known, don't prompt during the battle; queue the
  choice for after the battle on the owner's game (as evolution already is).

## 4. Three-faint limit (needed for D2)

In a shared battle, a player is out after their third faint even with
healthy mons left. We need an engine-side "eliminated" mark per owner, for
example `st.eliminated[battler] = true`, that:

- skips the forced replacement for that owner, leaving their position empty
  (the partner fights on with one active position);
- counts the side as lost only when every owner is eliminated or has no
  usable mons.

Co-op would set the mark from `battle.fainted` on both games at the same
point in the turn.

## 5. Wild double battles in co-op (needed for D3)

- A link multi battle that is also wild: two wild foes the host generates,
  with no trainer AI beyond the usual wild behavior.
- Allow throwing a ball in that battle. A link action `kind = "ball"` with
  the item id; `multi_turn_step` currently rejects `bag`/`item` actions as a
  protocol error. The catch roll uses `st.rng`. The caught mon goes to the
  thrower's party or PC and Pokédex only; the other game just removes it.

## 6. More than six on the player side (D2 polish)

The battle itself ran with 4 + 4. The in-battle party menu in a multi battle
lays out 3 + 3. Please make it list the local player's own mons, up to six,
when `st.multi` is set.

## Notes

- Foe parties are built on the host, so whatever level rule the port uses
  applies to both players. Today that's the host's highest level; the fixed
  levels planned for the campaign will apply automatically.
- Prize money for team battles is not paid yet. Co-op can do that itself
  (`Prize.calcRse`) once the split between the two players is decided.
