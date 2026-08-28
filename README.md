# SellSweep

One-click bag clearing at vendors for **Project Ebonhold** (WoW 3.3.5a). Sell by
quality with a protected keep-list — plus a **smart mode** that understands
Ebonhold's affix items and echo tomes, so it clears the junk without ever
touching the loot you're actually progressing.

## What makes it different

Most auto-sell addons only know item *quality*. On Ebonhold that's not enough —
a blue can be an affix you still need to extract, or a tome that teaches an echo
you don't own yet. SellSweep reads **EbonholdHub**'s live data to tell the
difference:

- **Affix items are rank-aware.** SellSweep parses the affix + rank on each item
  and checks it against what you've actually learned:
  - A copy at a rank you **already own** → duplicate → sold.
  - A **higher-rank** copy you haven't learned → **kept**, so you can still
    extract it and advance your collection.
  - An affix you've **never** learned → kept.
  It agrees with the EbonholdHub affix UI (same ownership data), and `/sweep
  affix` shows the per-item breakdown (HAVE / PARTIAL / NEED).
- **Tomes check your echo collection.** Opt in and SellSweep sells a tome only
  when its echo is already in your learned collection — unlearned tomes are
  always kept. Names resolve through the Hub, so `Tome of X - Rare` maps to echo
  `x` the way the game does.
- **Smart gear check.** In smart mode it sells green/blue/epic armor and weapons
  whose affix is learned/absent **and** that beat nothing you have equipped.
  Uniques and quest items are never touched. Set pieces are kept too by default;
  opt in with `/sweep sets` to clear low ones **under an item-level cap** (so old
  leveling/crafted set junk goes while your tier gear stays protected).
- **Dry-run first.** `/sweep preview` prints a SELL/KEEP verdict (with the
  reason) for every bag item and sells nothing — so you can trust it before you
  ever sell.
- **Colorblind-safe.** Every state reads by word + shape, never color alone.

## Everyday features

- **Quality toggles** — gray / white / green / blue / epic, each on/off.
- **Keep-list (whitelist)** and **Blacklist (always-sell)** — build both by
  turning on a mode and shift-clicking bag items. Blacklist overrides everything
  (great for dumping low-level potions while keeping the good ones).
- **Per-type consumable protection** — keep Potions but sell Scrolls, etc.
- **Auto-sell** on merchant open, and **auto-repair** (guild funds first when
  allowed, otherwise your gold).
- **Staggered selling** so large bags don't choke the client.
- A **Config** button on the merchant frame and a movable config panel.

## Slash commands

| Command | Effect |
| --- | --- |
| `/sweep` | sell now (at a merchant) |
| `/sweep config` | open the config panel |
| `/sweep preview` | dry run — SELL/KEEP verdict for every bag item, sells nothing |
| `/sweep affix` | why each affixed item is kept/sold (your learned rank vs the item's) |
| `/sweep gray\|white\|green\|blue\|epic` | toggle each quality |
| `/sweep smart` | one-off smart sweep |
| `/sweep add` / `addsell` | shift-click-to-Keep / shift-click-to-Sell mode |
| `/sweep keep` / `blacklist` `[shift-click item]` | add to keep-list / blacklist |
| `/sweep potions` | keep/sell all consumables (per-type in `/sweep config`) |
| `/sweep tomes` | toggle: sell tomes whose echo you've already learned |
| `/sweep sets` | toggle: sell set pieces at/below the iLvl cap (tier gear stays kept) |
| `/sweep setilvl <n>` | set the set-piece iLvl cap (default 150) |
| `/sweep auto` / `autorepair` | toggle auto-sell / auto-repair on merchant open |
| `/sweep repair` | repair all gear now |
| `/sweep status` | current settings |

## Install

1. Download the zip from the [latest release](https://github.com/myi1/SellSweep/releases/latest).
2. Extract the `SellSweep` folder into `World of Warcraft\Interface\AddOns\`.
3. `/reload` (or restart) — type `/sweep` in-game for all commands.

The affix/tome intelligence needs **[EbonholdHub](https://ebonholdhub.icu)**
loaded; without it, SellSweep still works as a quality-toggle sweeper and keeps
every affixed item to be safe.

See [CHANGELOG.md](CHANGELOG.md) for the per-version history. Client-side only,
no server changes; not affiliated with the Ebonhold team.
