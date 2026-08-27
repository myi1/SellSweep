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

-- Tomes teach echoes; teaching items teach affix ranks / recipes. Never sell.
local function IsTome(name, lines)
  if name and string.sub(name, 1, 4) == "Tome" then return true end
  if FindPlain(lines, "use: learn") then return true end
  if FindPlain(lines, "teaches") then return true end
  return false
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

-- true = provably learned, false = provably not learned, nil = cannot tell.
-- Mirrors the Hub's own semantics: a learned rank >= the item's rank counts.
local function HubAffixLearned(name, rank)
  if not name or not HubAvailable() then return nil end
  local hub = _G.EbonholdHub
  local ok, snap = pcall(hub.AffixOwnership.CollectSnapshot)
  if not ok or type(snap) ~= "table" or type(snap.learned) ~= "table" then return nil end
  if next(snap.learned) == nil then return nil end  -- server data not loaded yet
  local e = snap.learned[name]
  if type(e) ~= "table" then return false end
  local weapon = false
  if hub.AffixData.IsWeaponAffix then
    local okW, w = pcall(hub.AffixData.IsWeaponAffix, name)
    weapon = okW and w == true
  end
  if weapon or not rank then
    if e.rankless or e.any then return true end
    if type(e.ranks) == "table" and next(e.ranks) ~= nil then return true end
    return false
  end
  if type(e.ranks) == "table" then
    if e.ranks[rank] then return true end
    for r in pairs(e.ranks) do
      if type(r) == "number" and r >= rank then return true end
    end
  end
  return false
end

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
  if db.keep[id] then return keep("keep-list") end
  if not sellPrice or sellPrice <= 0 then return keep("no-price") end
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

  local lines = BagLines(bag, slot)
  if IsTome(name, lines) then return keep("tome") end
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
      if aName then learned = HubAffixLearned(aName, aRank) end
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
          affixLearned = v.affixLearned, upgrade = v.upgrade,
          str = v.str, int = v.int, spi = v.spi,
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
