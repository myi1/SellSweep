# Changelog

All notable changes to SellSweep are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/); version numbers match the
GitHub releases and the `.toc`.

## [1.11.0] - 2026-08-29
### Added
- **Sell set pieces** (opt-in): `/sweep sets` or the config toggle. Off by
  default (smart mode still protects every set piece). When on, a set piece **at
  or below an item-level cap** is judged by the normal smart rules — its affix
  must already be learned AND it must beat nothing you have equipped — so old
  leveling/crafted set junk clears while your tier gear stays protected.
- **Set-piece iLvl cap** — the slider in the config panel (or `/sweep setilvl
  <n>`, default 150). Set gear above the cap is always kept. The checkbox label
  shows the current cap, so the setting reads in words/numbers, not color.

## [1.10.0] - 2026-08-28
### Fixed
- Echo tomes ("Tome of Echo: ...") were still never sold by "Sell tomes I've
  already learned", even when learned. They report itemType **Recipe**, so the
  recipe keep-gate returned `keep("recipe")` before the tome logic ever ran —
  the toggle was unreachable for them. The tome check now runs **ahead of** the
  Quest / Recipe / Consumable gates, so echo tomes reach it regardless of their
  reported item type. (This is the bug 1.9.0 targeted but missed.)
- The learned check now also reads **"Already known"**, the line SellSweep's own
  background tooltip scan actually shows. (Some servers/addons render the
  per-character learned line only on the live tooltip — e.g. as "Already
  learned" — which a `SetBagItem` scan never receives.) Only echo tomes (name
  "Tome of Echo:" or an "Unlocks Echo:" line) can be sold this way, so ordinary
  crafting recipes are never touched.
### Added
- `/sweep tomediag` — writes a full per-tome diagnostic (item type, sell price,
  every detection result, the raw scanned tooltip lines, and the verdict) to
  `SellSweepDB.scans.tomediag`. Run it, then `/reload` to flush it to disk.

## [1.9.0] - 2026-08-28
### Fixed
- Learned echo tomes that are **named after their echo** — e.g. an item called
  "Arcane Burn" rather than "Tome of ..." — weren't recognized as tomes, so the
  "Sell tomes I've already learned" toggle never touched them. Detection and the
  learned check now read the item's own tooltip: `Unlocks Echo:` marks it as a
  tome, and an `Already learned` line marks the echo as owned (the game's own
  truth, so it works for every tome regardless of name). The Hub's learned-echo
  set stays as a secondary signal. As before, a tome only sells on a positive
  learned match — unread tomes are always kept.

## [1.8.0] - 2026-08-28
### Added
- **Auto-repair** on merchant open (`/sweep autorepair`, or the config toggle),
  plus `/sweep repair` on demand. Prefers guild funds when the guild allows it
  and the withdraw allowance covers the bill; otherwise your own gold.
### Removed
- The "sell affix gear at any learned rank" option. Affix selling is now always
  rank-aware: a copy at a rank you already own is a duplicate and sells, while a
  higher-rank copy you haven't learned is kept so you can still extract it.

## [1.7.0] - 2026-08-28
### Added
- **Sell already-learned tomes** (opt-in): `/sweep tomes` or the config toggle.
  Off by default; when on, a tome sells only when its echo is positively in your
  learned collection, resolved through EbonholdHub's echo data. Unknown /
  unlearned tomes are always kept.

## [1.6.0] - 2026-08-28
### Added
- **Blacklist** (always-sell) with two shift-click modes ("+ Shift = Keep" /
  "+ Shift = Sell") and a unified rules list; `/sweep addsell`, `/sweep
  blacklist`, `/sweep unblacklist`. Overrides the keep-list, consumable
  protection and quality toggles.
- **Affix rank awareness** + `/sweep affix` readout showing your learned rank vs
  each item's rank (HAVE / PARTIAL / NEED). Learned lookups go through the Hub's
  own snapshot, so SellSweep agrees with the EbonholdHub affix UI.

## [1.5.0] - 2026-08-28
### Added
- **Per-type consumable protection** — choose which consumable types to keep
  (Potion / Elixir / Flask / Food & Drink / Bandage / Scroll / Other).
### Changed
- Merchant "Cfg" button renamed to "Config".

## [1.4.0] - 2026-08-28
### Changed
- Config panel redesign: flat dark chrome, sectioned, colorblind-safe (state
  reads by word + swatch, never color alone).

## [1.3.0] - 2026-08-28
### Added
- Shift-click-to-keep mode — fewer clicks to build the keep-list.

## [1.2.1] - 2026-08-25
### Changed
- Smart mode now also covers epics (field audit found low-ilvl epics were never
  being cleared).

## [1.2.0] - 2026-08-25
### Added
- **Smart mode** — sells green/blue/epic armor and weapons whose affix is
  already learned (or absent) AND that beat nothing you have equipped. Tomes,
  unlearned affixes, uniques, sets and quest items are never touched.
- `/sweep preview` — dry run that prints a SELL/KEEP verdict for every bag item
  and sells nothing.

## [1.0.0] - 2026-08-23
- First release: quality-toggle vendor sweeping (gray/white/green/blue/epic)
  with a protected keep-list, consumable protection, auto-sell on merchant open,
  and staggered selling for large bags. Config panel with quality checkboxes and
  a keep-list manager added shortly after.
