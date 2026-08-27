-- SellSweep SmartSweep: "provably useless" gear detection for smart mode and
-- the /sweep preview dry run.
--
-- Smart rule: a green/blue armor-or-weapon item is sellable when
--   (its affix is already LEARNED, or it carries no affix)
--   AND it is not a possible upgrade over equipped gear (item level or
--       Strength; rings/trinkets/1H weapons compare vs the weaker of the
--       pair; Int/Spirit-statted gear is never an upgrade for this build)
--   AND none of the hard protections apply (tome/teaching items, unlearned
--       affixes, keep-list, quest, recipes, consumables, uniques, set pieces).
--
-- Affix knowledge comes from EbonholdHub's live globals at runtime
-- (nil-guarded pcall integration only — nothing is copied from that addon).
-- Without the Hub, every affixed item stays KEEP. Conservative by design:
-- any parse doubt -> KEEP.
local SS = SellSweep

local EMBER  = "|cffd9694a"  -- SELL / removal
local DIM    = "|cffb4a586"  -- reasons, filler
local GOLD   = "|cffe0b352"  -- headers, totals
local BRIGHT = "|cfff6d888"  -- notable keeps
local VERD   = "|cff8aa96a"  -- ok / safe
local R = "|r"

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff58c9a8SellSweep|r: " .. tostring(msg))
end

-- ------------------------------------------------------------ tooltip scan

local scanTip
local function GetScanTip()
  if not scanTip then
    scanTip = CreateFrame("GameTooltip", "SellSweepScanTooltip", nil, "GameTooltipTemplate")
  end
  scanTip:SetOwner(UIParent, "ANCHOR_NONE")
  scanTip:ClearLines()
  return scanTip
end

local function TipLines()
  local lines = {}
  for i = 1, scanTip:NumLines() do
    local fsL = _G["SellSweepScanTooltipTextLeft" .. i]
    local txt = fsL and fsL:GetText()
    if txt and txt ~= "" then lines[#lines + 1] = txt end
  end
  return lines
end

local function BagLines(bag, slot)
  local tip = GetScanTip()
  tip:SetBagItem(bag, slot)
  return TipLines()
end

local function InvLines(invSlot)
  local tip = GetScanTip()
  tip:SetInventoryItem("player", invSlot)
  return TipLines()
end

-- ------------------------------------------------------------ line checks

local function FindPlain(lines, needleLower)
  for _, l in ipairs(lines) do
    if string.find(string.lower(l), needleLower, 1, true) then return l end
  end
  return nil
end

local function HasAffixMarker(lines)
  return FindPlain(lines, "@affix@") ~= nil
end

-- Tomes teach echoes; teaching items teach affix ranks / recipes. Kept by
-- default; only sold when "sell learned tomes" is on AND the echo is owned.
--
-- Ebonhold echo tomes are frequently NAMED after the echo they teach rather
-- than "Tome of ..." — e.g. an item literally called "Arcane Burn" whose
-- tooltip reads "Unlocks Echo:" and (once read) "Already learned", with no
-- "teaches" / "use: learn" line. The "unlocks echo" tooltip line catches those
-- so the learned-tome toggle can reach them at all (before this, IsTome()
-- returned false for such items and they never entered the tome branch).
local function IsTome(name, lines)
  if name and string.sub(name, 1, 4) == "Tome" then return true end
  if FindPlain(lines, "use: learn") then return true end
  if FindPlain(lines, "teaches") then return true end
  if FindPlain(lines, "unlocks echo") then return true end
  return false
end

-- Narrower than IsTome: specifically an Ebonhold ECHO tome — the only kind the
-- "sell learned tomes" toggle may ever sell. Echo tomes are named
-- "Tome of Echo: <EchoName>" and/or carry an "Unlocks Echo:" tooltip line.
-- Gating the learned-sell on THIS (never plain IsTome) keeps ordinary crafting
-- recipes — which also match IsTome via their "teaches" line and can likewise
-- show "Already known" — from ever being vendored.
local function IsEchoTome(name, lines)
  if name and string.find(string.lower(name), "tome of echo", 1, true) then return true end
  if FindPlain(lines, "unlocks echo") then return true end
  return false
end

-- Tooltip-based "have I read this echo tome?" check. A learned echo tome prints
-- a per-character line in the tooltip. SellSweep's own hidden scan tooltip
-- (SetBagItem) shows "Already known"; the live in-game tooltip may ADDITIONALLY
-- show an "Already learned" line injected by another addon (e.g. PallyPilot)
-- that our background scan never receives — so match BOTH, case-insensitively.
-- Confirmed via /sweep tomediag on "Tome of Echo: Arcane Surge": the scanned
-- lines contained "Already known", not "Already learned". Only meaningful when
-- gated behind IsEchoTome() (see the tome branch in Classify), so a non-echo
-- item that merely contains the phrase can never match.
local function TomeLearnedFromTip(lines)
  return FindPlain(lines, "already known") ~= nil
      or FindPlain(lines, "already learned") ~= nil
end

local function IsUnique(lines)
  for _, l in ipairs(lines) do
    if string.sub(l, 1, 6) == "Unique" then return true end
  end
  return false
end

-- Item-set pieces list the set header as "Set Name (n/m)".
local function IsSetPiece(lines)
  for _, l in ipairs(lines) do
    if string.match(l, "%(%d+/%d+%)%s*$") then return true end
  end
  return false
end

-- ------------------------------------------------------------ affix parsing

-- Ebonhold affix format: "<Base> of <Affix> <Roman I-VI>" (last 'of' wins).
-- Same technique as PallyPilot's GearAudit parser (ours).
local ROMAN = { I=1, II=2, III=3, IV=4, V=5, VI=6, VII=7, VIII=8, IX=9, X=10 }
local function ParseAffixName(itemName)
  if not itemName then return nil end
  local affix, roman = string.match(itemName, "^.*%s[oO]f%s(.-)%s([IVX]+)$")
  if affix and ROMAN[roman] then return affix, ROMAN[roman] end
  return nil
end

-- ------------------------------------------------------------ EbonholdHub

local function HubAvailable()
  local hub = _G.EbonholdHub
  if hub and hub.AffixData and hub.AffixOwnership
     and hub.AffixData.ReadAffixFromLink and hub.AffixOwnership.CollectSnapshot then
    return true
  end
  return false
end
SS.SmartHubAvailable = HubAvailable

local function HubReadAffix(link)
  if not HubAvailable() then return nil end
  local ok, entry = pcall(_G.EbonholdHub.AffixData.ReadAffixFromLink, link)
  if ok and type(entry) == "table" and entry.name then return entry end
  return nil
end

local function IsWeaponAffix(name)
  local hub = _G.EbonholdHub
  if not (hub and hub.AffixData and hub.AffixData.IsWeaponAffix) then return false end
  local ok, w = pcall(hub.AffixData.IsWeaponAffix, name)
  return ok and w == true
end

-- Reads the Hub's learned snapshot for one affix by name.
-- Returns found(bool), best(highest numeric learned rank, 0 if none), rankless(bool).
-- Returns nil when the Hub can't tell yet (unavailable / server data not loaded).
local function HubLearnedInfo(name)
  if not name or not HubAvailable() then return nil end
  local hub = _G.EbonholdHub
  local ok, snap = pcall(hub.AffixOwnership.CollectSnapshot)
  if not ok or type(snap) ~= "table" or type(snap.learned) ~= "table" then return nil end
  if next(snap.learned) == nil then return nil end  -- server data not loaded yet
  local e = snap.learned[name]
  if type(e) ~= "table" then return false, 0, false end
  local best = 0
  if type(e.ranks) == "table" then
    for r in pairs(e.ranks) do
      if type(r) == "number" and r > best then best = r end
    end
  end
  return true, best, (e.rankless == true or e.any == true)
end
SS.SmartHubLearnedInfo = HubLearnedInfo

-- true = counts as owned for selling, false = not owned (keep), nil = cannot tell.
-- Mirrors the Hub's own semantics: a learned rank >= the item's rank counts as
-- owned (sell the duplicate). A copy whose rank EXCEEDS your best learned rank is
-- only PARTIAL — it still advances your collection when extracted, so it is kept.
local function HubAffixLearned(name, rank)
  local found, best, rankless = HubLearnedInfo(name)
  if found == nil then return nil end      -- Hub can't tell
  if found == false then return false end  -- provably never learned at any rank
  if IsWeaponAffix(name) or not rank then
    if rankless or best > 0 then return true end
    return false
  end
  if best >= rank then return true end     -- learned at >= item rank -> duplicate
  return false                             -- higher rank than you own -> keep to extract
end

-- Is the echo a tome teaches already learned? Uses the Hub's discovered-echo
-- set (GetDiscoveredEchoes), keyed by the same normalized names the Hub UI
-- uses, so "Tome of X - Rare" resolves to echo "x". true = learned (dup, sell
-- ok), false = not learned (keep), nil = cannot tell (keep). Conservative: only
-- a positive match ever allows a sell.
local function TomeEchoOwned(name)
  if not name then return nil end
  local hub = _G.EbonholdHub
  if not (hub and hub.EchoOwnership and hub.EchoOwnership.NormalizeName) then return nil end
  local getset = hub.EchoOwnership.CollectTomeOwnedSets or hub.EchoOwnership.CollectOwnedSets
  if type(getset) ~= "function" then return nil end
  local ok, ownedLower = pcall(getset)
  if not ok or type(ownedLower) ~= "table" then return nil end
  local norm = hub.EchoOwnership.NormalizeName(name)
  if not norm or norm == "" then return nil end
  if ownedLower[norm] then return true end
  return false
end
SS.SmartTomeEchoOwned = TomeEchoOwned

-- ------------------------------------------------------------ stats & slots

local function StatsFromLines(lines)
  local str, int, spi = 0, 0, 0
  for _, l in ipairs(lines) do
    local n = string.match(l, "^%+(%d+) Strength$")
    if n then str = str + tonumber(n) end
    n = string.match(l, "^%+(%d+) Intellect$")
    if n then int = int + tonumber(n) end
    n = string.match(l, "^%+(%d+) Spirit$")
    if n then spi = spi + tonumber(n) end
  end
  return str, int, spi
end

-- GetItemStats exists in 3.3.5; tooltip lines are the fallback for
-- server-custom items. Take the max of both sources per stat.
local function ItemStats(link, lines)
  local aStr, aInt, aSpi = 0, 0, 0
  if GetItemStats then
    local ok, t = pcall(GetItemStats, link)
    if ok and type(t) == "table" then
      aStr = tonumber(t["ITEM_MOD_STRENGTH_SHORT"]) or 0
      aInt = tonumber(t["ITEM_MOD_INTELLECT_SHORT"]) or 0
      aSpi = tonumber(t["ITEM_MOD_SPIRIT_SHORT"]) or 0
    end
  end
  local lStr, lInt, lSpi = StatsFromLines(lines or {})
  return math.max(aStr, lStr), math.max(aInt, lInt), math.max(aSpi, lSpi)
end

local SLOTS_FOR = {
  INVTYPE_HEAD = {1}, INVTYPE_NECK = {2}, INVTYPE_SHOULDER = {3},
  INVTYPE_CHEST = {5}, INVTYPE_ROBE = {5}, INVTYPE_WAIST = {6},
  INVTYPE_LEGS = {7}, INVTYPE_FEET = {8}, INVTYPE_WRIST = {9},
  INVTYPE_HAND = {10}, INVTYPE_FINGER = {11, 12}, INVTYPE_TRINKET = {13, 14},
  INVTYPE_CLOAK = {15},
  INVTYPE_WEAPON = {16, 17}, INVTYPE_2HWEAPON = {16},
  INVTYPE_WEAPONMAINHAND = {16}, INVTYPE_WEAPONOFFHAND = {17},
  INVTYPE_HOLDABLE = {17}, INVTYPE_SHIELD = {17},
  INVTYPE_RANGED = {18}, INVTYPE_RANGEDRIGHT = {18},
  INVTYPE_THROWN = {18}, INVTYPE_RELIC = {18},
  -- INVTYPE_BODY (shirt) / INVTYPE_TABARD intentionally absent -> "slot?" -> KEEP.
}

local eqCache, eqCacheAt = {}, -10
local function EquippedInfo(invSlot)
  local now = GetTime and GetTime() or 0
  if (now - eqCacheAt) > 2 then eqCache = {}; eqCacheAt = now end
  local hit = eqCache[invSlot]
  if hit ~= nil then
    if hit == false then return nil end
    return hit
  end
  local link = GetInventoryItemLink("player", invSlot)
  if not link then
    eqCache[invSlot] = false
    return nil
  end
  local _, _, _, ilvl, _, _, _, _, equipLoc = GetItemInfo(link)
  local str = ItemStats(link, InvLines(invSlot))
  local info = { ilvl = ilvl or 0, str = str or 0,
                 twoHand = (equipLoc == "INVTYPE_2HWEAPON") }
  eqCache[invSlot] = info
  return info
end

-- "upgrade" = possible upgrade (keep), "not" = provably not, nil = unknown.
local function UpgradeVerdict(link, equipLoc, ilvl, lines, out)
  local slots = SLOTS_FOR[equipLoc or ""]
  if not slots then return nil end
  local cStr, cInt, cSpi = ItemStats(link, lines)
  out.str, out.int, out.spi = cStr, cInt, cSpi
  if cStr == 0 and (cInt > 0 or cSpi > 0) then
    return "not"  -- Int/Spirit gear is never an upgrade for the Strength build
  end
  local weakest
  for _, s in ipairs(slots) do
    local eq = EquippedInfo(s)
    if not eq and equipLoc == "INVTYPE_WEAPON" and s == 17 then
      -- A paladin with a 2H equipped has an "empty" OH that no 1H fills
      -- independently: compare the 1H candidate against the 2H instead.
      local mh = EquippedInfo(16)
      if mh and mh.twoHand then eq = mh end
    end
    if not eq then return "upgrade" end  -- genuinely empty slot: could help
    if not weakest or (eq.ilvl or 0) < (weakest.ilvl or 0)
       or ((eq.ilvl or 0) == (weakest.ilvl or 0) and (eq.str or 0) < (weakest.str or 0)) then
      weakest = eq
    end
  end
  if not weakest then return nil end
  if not ilvl then return nil end
  if ilvl > (weakest.ilvl or 0) then return "upgrade" end
  if cStr > (weakest.str or 0) then return "upgrade" end
  return "not"
end

-- ------------------------------------------------------------ classifier

-- Classify one bag slot. smartMode adds the known-affix non-upgrade rule on
-- top of the quality toggles. Returns nil for empty slots, else a verdict:
-- { action = "SELL"|"KEEP", reason, value, name, link, quality, ilvl, ... }
function SS.Classify(bag, slot, smartMode)
  local db = SS.db
  if not db then return nil end
  local link = GetContainerItemLink(bag, slot)
  if not link then return nil end
  local id = SS.ItemIdFromLink and SS.ItemIdFromLink(link) or nil
  local name, _, quality, ilvl, _, itemType, itemSubType, _, equipLoc, _, sellPrice = GetItemInfo(link)
  local _, count = GetContainerItemInfo(bag, slot)
  count = count or 1

  local v = { bag = bag, slot = slot, id = id, link = link, name = name,
              quality = quality, ilvl = ilvl, count = count, equipLoc = equipLoc }
  local function keep(reason) v.action = "KEEP"; v.reason = reason; return v end
  local function sell(reason)
    v.action = "SELL"; v.reason = reason
    v.value = (sellPrice or 0) * count
    return v
  end

  if not name or not id then return keep("no-info") end
  -- BLACKLIST wins over everything (keep-list, consumable protection, quality
  -- toggles) — you can only actually vendor items with a sell price.
  if db.blacklist and db.blacklist[id] then
    if sellPrice and sellPrice > 0 then return sell("blacklist") end
    return keep("no-price")
  end
  if db.keep[id] then return keep("keep-list") end
  if not sellPrice or sellPrice <= 0 then return keep("no-price") end

  -- Scan the tooltip up front: tomes/teaching items are governed by the tome
  -- logic below, NOT the generic Quest/Recipe/Consumable keep gates. This
  -- ordering is load-bearing: Ebonhold echo tomes report itemType "Recipe"
  -- (confirmed — "Tome of Echo: X" items scan as Recipe/Book), so if the Recipe
  -- gate ran first they'd be kept as "recipe" and the learned-tome toggle could
  -- NEVER reach them (the bug behind v1.10.0). Blacklist, keep-list and
  -- no-price above still take precedence.
  local lines = BagLines(bag, slot)
  if IsTome(name, lines) then
    -- Opt-in: dump echo tomes you've already read (duplicates). Only ECHO tomes
    -- (IsEchoTome) may sell, and only on a POSITIVE learned signal — the scan
    -- tooltip's "Already known"/"Already learned" line, or the Hub's learned-
    -- echo set. If nothing confirms it's learned, the tome is kept; an unread
    -- tome (or any non-echo teaching item / crafting recipe) is never vendored.
    if db.sellLearnedTomes and IsEchoTome(name, lines)
       and (TomeLearnedFromTip(lines) or TomeEchoOwned(name) == true) then
      return sell("tome-known")
    end
    return keep("tome")
  end

  if itemType == "Quest" then return keep("quest") end
  if itemType == "Recipe" then return keep("recipe") end
  -- Per-type consumable keep: protected types stay; unprotected ones fall
  -- through to the normal quality/keep rules below.
  if itemType == "Consumable" then
    local bucket = SS.ConsumableBucket and SS.ConsumableBucket(itemSubType) or "Other"
    if not db.consumableKeep or db.consumableKeep[bucket] ~= false then
      return keep("consum")
    end
  end
  if FindPlain(lines, "quest item") then return keep("quest") end

  -- Affix protection (green+): an UNLEARNED affix is affix progression —
  -- never sold, not even by the plain quality toggles.
  if quality and quality >= 2 then
    local entry = HubReadAffix(link)
    local pName, pRank = ParseAffixName(name)
    local marked = HasAffixMarker(lines)
    local aName, aRank
    if entry then
      aName, aRank = entry.name, entry.rank
    elseif pName then
      aName, aRank = pName, pRank
    end
    if aName or marked then
      v.affix = aName or "?"
      v.affixRank = aRank
      local learned = nil
      if aName then
        local _, best = HubLearnedInfo(aName)
        v.affixLearnedBest = best
        learned = HubAffixLearned(aName, aRank)
      end
      if learned == false then return keep("unlearned") end
      if learned == nil then return keep("affix?") end
      v.affixLearned = true
    end
  end

  -- Existing behavior: quality toggles.
  if db.qualities[quality or -1] then return sell("quality") end

  -- Smart path: green/blue/epic armor+weapons whose (learned-or-absent)
  -- affix and stats make them provably useless. Epics included as of v1.2.1
  -- (field audit 2026-08-25: ilvl-62 epics were immortal); the unlearned-affix
  -- gate, unique/set checks, and the upgrade verdict still protect keepers.
  if not smartMode then return keep("filtered") end
  if quality ~= 2 and quality ~= 3 and quality ~= 4 then return keep("filtered") end
  if itemType ~= "Armor" and itemType ~= "Weapon" then return keep("filtered") end
  if IsUnique(lines) then return keep("unique") end
  if IsSetPiece(lines) then return keep("set") end

  local up = UpgradeVerdict(link, equipLoc, ilvl, lines, v)
  v.upgrade = up
  if up == nil then return keep("slot?") end
  if up == "upgrade" then return keep("upgrade") end
  return sell("smart")
end

-- ------------------------------------------------------------ /sweep preview

-- Dry run: verdict for every bag item under the SMART rules (regardless of
-- the checkbox), printed compactly and written to SellSweepDB.scans.preview
-- so it can be analyzed offline after /reload.
function SS.Preview()
  local db = SS.db
  if not db then Print("Not loaded yet.") return end
  local hub = HubAvailable()
  Print(GOLD .. "PREVIEW" .. R .. " — dry run, nothing is sold. Smart rules applied"
    .. (db.smartSell and " (smart mode is ON)." or " (smart mode is OFF — this is what it WOULD do)."))
  if not hub then
    Print(EMBER .. "EbonholdHub not detected" .. R
      .. " — affix knowledge unavailable, every affixed item stays KEEP (affix?).")
  end

  local items = {}
  local sellN, keepN, sellValue = 0, 0, 0
  for bag = 0, 4 do
    for slot = 1, GetContainerNumSlots(bag) do
      local v = SS.Classify(bag, slot, true)
      if v then
        if v.action == "SELL" then
          sellN = sellN + 1
          sellValue = sellValue + (v.value or 0)
          DEFAULT_CHAT_FRAME:AddMessage("  " .. EMBER .. "SELL" .. R .. " "
            .. (v.link or tostring(v.name)) .. DIM .. " — " .. v.reason .. R)
        else
          keepN = keepN + 1
          DEFAULT_CHAT_FRAME:AddMessage("  " .. VERD .. "KEEP" .. R .. " "
            .. (v.link or tostring(v.name)) .. DIM .. " — " .. v.reason .. R)
        end
        items[#items + 1] = {
          bag = v.bag, slot = v.slot, id = v.id, name = v.name,
          quality = v.quality, ilvl = v.ilvl, count = v.count,
          equipLoc = v.equipLoc, action = v.action, reason = v.reason,
          value = v.value, affix = v.affix, affixRank = v.affixRank,
          affixLearned = v.affixLearned, affixLearnedBest = v.affixLearnedBest,
          upgrade = v.upgrade, str = v.str, int = v.int, spi = v.spi,
        }
      end
    end
  end

  if type(db.scans) ~= "table" then db.scans = {} end
  db.scans.preview = {
    at = (date and date("%Y-%m-%d %H:%M:%S")) or tostring(GetTime and GetTime() or 0),
    smartSetting = db.smartSell and true or false,
    hubDetected = hub,
    sellCount = sellN, keepCount = keepN, sellValue = sellValue,
    items = items,
  }

  local money = SS.Money and SS.Money(sellValue) or tostring(sellValue)
  Print(GOLD .. sellN .. R .. " would sell (" .. money .. "), "
    .. BRIGHT .. keepN .. R .. " kept. Full scan saved to SellSweepDB.scans.preview"
    .. DIM .. " (/reload to flush it to disk)." .. R)
end

-- ------------------------------------------------------------ /sweep affix

-- Per-affix-item readout: shows exactly why each affixed bag item is kept or
-- sold, with the Hub's learned rank next to the item's rank. Answers "I
-- extracted this — why isn't it selling?" (usually: learned at a LOWER rank).
function SS.AffixDiag()
  local db = SS.db
  if not db then Print("Not loaded yet.") return end
  if not HubAvailable() then
    Print(EMBER .. "EbonholdHub not detected" .. R
      .. " — affix knowledge unavailable; every affixed item stays KEEP.")
    return
  end
  Print(GOLD .. "AFFIX CHECK" .. R .. " — item rank vs. your learned rank."
    .. DIM .. " HAVE = duplicate (sell ok); PARTIAL/NEED = kept to extract." .. R)
  local n = 0
  for bag = 0, 4 do
    for slot = 1, GetContainerNumSlots(bag) do
      local link = GetContainerItemLink(bag, slot)
      local name = link and GetItemInfo(link)
      if name then
        local entry = HubReadAffix(link)
        local pName, pRank = ParseAffixName(name)
        local aName = (entry and entry.name) or pName
        local aRank = (entry and entry.rank) or pRank
        if aName then
          n = n + 1
          local found, best, rankless = HubLearnedInfo(aName)
          local weapon = IsWeaponAffix(aName)
          local learned = HubAffixLearned(aName, aRank)
          local state, col
          if found == false then state, col = "NEED (never learned)", EMBER
          elseif weapon or not aRank then
            state, col = (rankless or (best or 0) > 0) and "HAVE" or "NEED",
              (rankless or (best or 0) > 0) and VERD or EMBER
          elseif (best or 0) >= aRank then state, col = "HAVE (rank " .. best .. ")", VERD
          elseif (best or 0) > 0 then
            state, col = "PARTIAL (you have " .. best .. ", item is " .. aRank .. ")", BRIGHT
          else state, col = "NEED (item is " .. aRank .. ")", EMBER end
          local verdict = (learned == true) and (VERD .. "affix OK to sell" .. R)
            or (EMBER .. "affix KEEP" .. R)
          DEFAULT_CHAT_FRAME:AddMessage("  " .. (link or name) .. DIM .. " — " .. R
            .. col .. state .. R .. DIM .. " → " .. R .. verdict)
        end
      end
    end
  end
  if n == 0 then Print("No affixed items in your bags.") return end
  Print(DIM .. "\"affix OK to sell\" still needs Smart mode ON and the stats to not"
    .. " be an upgrade before it actually sells." .. R)
end

-- ------------------------------------------------------------ /sweep tomediag

-- Diagnostic: writes a full structured dump of every tome-ish bag item (name
-- contains "Tome", or IsTome matches) into SellSweepDB.scans.tomediag, which is
-- flushed to the SavedVariables file (WTF\Account\<name>\SavedVariables\
-- SellSweep.lua) on /reload or logout. Each entry records itemType/subType,
-- sell price, quality, every detection result (isTome/isEcho/tipLearned/
-- hubOwned), the RAW scanned tooltip lines, and the final KEEP/SELL verdict —
-- so the exact tooltip text can be read straight off disk instead of scraped
-- from chat. Run /sweep tomediag, then /reload, then inspect the file.
function SS.TomeDiag()
  local db = SS.db
  if not db then Print("Not loaded yet.") return end
  if type(db.scans) ~= "table" then db.scans = {} end
  local items = {}
  for bag = 0, 4 do
    for slot = 1, GetContainerNumSlots(bag) do
      local link = GetContainerItemLink(bag, slot)
      local name = link and GetItemInfo(link)
      if name then
        local lines = BagLines(bag, slot)
        if IsTome(name, lines)
           or string.find(string.lower(name), "tome", 1, true) ~= nil then
          local _, _, quality, ilvl, _, itemType, itemSubType, _, equipLoc, _, sellPrice = GetItemInfo(link)
          local v = SS.Classify(bag, slot, db.smartSell and true or false)
          local owned = TomeEchoOwned(name)   -- true / false / nil (cannot tell)
          items[#items + 1] = {
            bag = bag, slot = slot,
            id = SS.ItemIdFromLink and SS.ItemIdFromLink(link) or nil,
            name = name, itemType = itemType, itemSubType = itemSubType,
            quality = quality, ilvl = ilvl, sellPrice = sellPrice, equipLoc = equipLoc,
            isTome = IsTome(name, lines) and true or false,
            isEcho = IsEchoTome(name, lines) and true or false,
            tipLearned = TomeLearnedFromTip(lines) and true or false,
            hubOwned = (owned == nil) and "nil" or (owned and true or false),
            action = v and v.action, reason = v and v.reason,
            lines = lines,
          }
        end
      end
    end
  end
  db.scans.tomediag = {
    at = (date and date("%Y-%m-%d %H:%M:%S")) or tostring(GetTime and GetTime() or 0),
    sellLearnedTomes = db.sellLearnedTomes and true or false,
    hubDetected = HubAvailable(),
    count = #items,
    items = items,
  }
  Print(GOLD .. "TOME DIAG" .. R .. " — wrote " .. #items
    .. " tome-ish item(s) to SellSweepDB.scans.tomediag. "
    .. DIM .. "/reload to flush it to disk." .. R)
end
