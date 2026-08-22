-- SellSweep: quality-configurable vendor sweeping with a protected keep-list.
-- /sweep at a merchant (or the Sweep button on the merchant frame, or auto).
SellSweep = {}
local SS = SellSweep
local DB

local QUALITY_NAME = { [0]="gray", [1]="white", [2]="green", [3]="blue", [4]="epic" }
local QUALITY_KEY  = { gray=0, white=1, green=2, blue=3, epic=4, purple=4 }
local QUALITY_COLOR = { [0]="|cff9d9d9d", [1]="|cffffffff", [2]="|cff1eff00",
                        [3]="|cff0070dd", [4]="|cffa335ee" }

local DEFAULTS = {
  qualities = { [0]=true, [1]=false, [2]=false, [3]=false, [4]=false },
  autoSell = false,
  protectConsumables = true,
  keep = {},   -- [itemID] = item name
}

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff58c9a8SellSweep|r: " .. tostring(msg))
end

local function Money(c)
  c = c or 0
  local g, s, cp = math.floor(c/10000), math.floor((c%10000)/100), c%100
  local out = {}
  if g > 0 then out[#out+1] = g .. "|cffffd700g|r" end
  if s > 0 or g > 0 then out[#out+1] = s .. "|cffc7c7cfs|r" end
  out[#out+1] = cp .. "|cffeda55fc|r"
  return table.concat(out, " ")
end

local function ItemIdFromLink(link)
  if not link then return nil end
  local id = string.match(link, "item:(%d+)")
  return id and tonumber(id)
end

-- Should this bag item be sold under current settings?
local function ShouldSell(link, count)
  local id = ItemIdFromLink(link)
  if not id then return false end
  if DB.keep[id] then return false end
  local name, _, quality, _, _, itemType, _, _, _, _, sellPrice = GetItemInfo(link)
  if not name then return false end
  if not sellPrice or sellPrice <= 0 then return false end          -- unsellable
  if itemType == "Quest" then return false end
  if DB.protectConsumables and itemType == "Consumable" then return false end
  if not DB.qualities[quality or -1] then return false end
  return true, sellPrice * (count or 1)
end

-- Staggered seller (dumping 100+ UseContainerItem calls in one frame is flaky).
local queue, sweptCount, sweptValue = {}, 0, 0
local seller = CreateFrame("Frame")
seller:Hide()
seller:SetScript("OnUpdate", function(self, e)
  self.t = (self.t or 0) + e
  if self.t < 0.15 then return end
  self.t = 0
  if not (MerchantFrame and MerchantFrame:IsShown()) then
    self:Hide(); queue = {}
    Print("Merchant closed - sweep stopped.")
    return
  end
  local n = 0
  while #queue > 0 and n < 6 do
    local it = table.remove(queue)
    -- Re-verify at sale time (bag may have shifted).
    local link = GetContainerItemLink(it.bag, it.slot)
    if link and ItemIdFromLink(link) == it.id then
      UseContainerItem(it.bag, it.slot)
      n = n + 1
    end
  end
  if #queue == 0 then
    self:Hide()
    Print("Swept " .. sweptCount .. " item" .. (sweptCount == 1 and "" or "s")
      .. " for " .. Money(sweptValue) .. ". (Mistake? The merchant Buyback tab holds the last 12.)")
  end
end)

function SS.Sweep()
  if not (MerchantFrame and MerchantFrame:IsShown()) then
    Print("Open a merchant first.")
    return
  end
  queue, sweptCount, sweptValue = {}, 0, 0
  for bag = 0, 4 do
    for slot = 1, GetContainerNumSlots(bag) do
      local link = GetContainerItemLink(bag, slot)
      if link then
        local _, count = GetContainerItemInfo(bag, slot)
        local sell, value = ShouldSell(link, count)
        if sell then
          queue[#queue+1] = { bag = bag, slot = slot, id = ItemIdFromLink(link) }
          sweptCount = sweptCount + 1
          sweptValue = sweptValue + (value or 0)
        end
      end
    end
  end
  if #queue == 0 then
    Print("Nothing to sweep with the current filters (" .. SS.FilterText() .. ").")
    return
  end
  Print("Sweeping " .. sweptCount .. " items (" .. Money(sweptValue) .. ")…")
  seller.t = 1  -- start immediately
  seller:Show()
end

function SS.FilterText()
  local on = {}
  for q = 0, 4 do
    if DB.qualities[q] then on[#on+1] = QUALITY_COLOR[q] .. QUALITY_NAME[q] .. "|r" end
  end
  return (#on > 0 and table.concat(on, "+") or "none")
    .. (DB.protectConsumables and " |cff58c9a8(consumables protected)|r" or "")
end

function SS.Status()
  Print("Selling: " .. SS.FilterText() .. " · auto-sell: " .. (DB.autoSell and "ON" or "OFF"))
  local n = 0
  for _ in pairs(DB.keep) do n = n + 1 end
  Print("Keep-list: " .. n .. " item" .. (n == 1 and "" or "s")
    .. " (/sweep list to view, /sweep keep [shift-click item] to add)")
end

local function KeepList()
  local any = false
  for id, name in pairs(DB.keep) do
    any = true
    DEFAULT_CHAT_FRAME:AddMessage("  " .. tostring(name) .. " (" .. id .. ")")
  end
  if not any then Print("Keep-list is empty. /sweep keep [shift-click an item into chat] to protect it.") end
end

-- Merchant button + auto-sell.
local btn
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("MERCHANT_SHOW")
ev:SetScript("OnEvent", function(_, event, name)
  if event == "ADDON_LOADED" and name == "SellSweep" then
    if type(SellSweepDB) ~= "table" then SellSweepDB = {} end
    for k, v in pairs(DEFAULTS) do
      if SellSweepDB[k] == nil then
        if type(v) == "table" then
          SellSweepDB[k] = {}
          for k2, v2 in pairs(v) do SellSweepDB[k][k2] = v2 end
        else
          SellSweepDB[k] = v
        end
      end
    end
    DB = SellSweepDB
  elseif event == "MERCHANT_SHOW" then
    if not btn and MerchantFrame then
      btn = CreateFrame("Button", "SellSweepButton", MerchantFrame, "UIPanelButtonTemplate")
      btn:SetWidth(70); btn:SetHeight(21)
      btn:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -42, -14)
      btn:SetText("Sweep")
      btn:SetScript("OnClick", function() SS.Sweep() end)
      btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("SellSweep")
        GameTooltip:AddLine("Sell: " .. SS.FilterText(), 1, 1, 1)
        GameTooltip:AddLine("/sweep help for options", 0.7, 0.7, 0.7)
        GameTooltip:Show()
      end)
      btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    if DB and DB.autoSell then SS.Sweep() end
  end
end)

SLASH_SELLSWEEP1 = "/sweep"
SLASH_SELLSWEEP2 = "/sellsweep"
SlashCmdList["SELLSWEEP"] = function(line)
  local _, _, cmd, arg = string.find(line or "", "^%s*(%S*)%s*(.-)%s*$")
  cmd = string.lower(cmd or "")
  if cmd == "" then
    SS.Sweep()
  elseif QUALITY_KEY[cmd] then
    local q = QUALITY_KEY[cmd]
    DB.qualities[q] = not DB.qualities[q]
    Print((DB.qualities[q] and "Now selling " or "No longer selling ")
      .. QUALITY_COLOR[q] .. QUALITY_NAME[q] .. "|r items. Selling: " .. SS.FilterText())
  elseif cmd == "auto" then
    DB.autoSell = not DB.autoSell
    Print("Auto-sell on merchant open: " .. (DB.autoSell and "ON" or "OFF"))
  elseif cmd == "potions" or cmd == "consumables" then
    DB.protectConsumables = not DB.protectConsumables
    Print("Consumables (potions/food/flasks) are now "
      .. (DB.protectConsumables and "PROTECTED" or "|cffff5050SELLABLE|r") .. ".")
  elseif cmd == "keep" then
    local id = ItemIdFromLink(arg)
    if not id then Print("Shift-click an item into the command: /sweep keep [item]") return end
    local name = GetItemInfo(id) or ("item " .. id)
    DB.keep[id] = name
    Print("Protected: " .. name)
  elseif cmd == "unkeep" then
    local id = ItemIdFromLink(arg)
    if id and DB.keep[id] then
      Print("Unprotected: " .. tostring(DB.keep[id]))
      DB.keep[id] = nil
    else
      Print("Shift-click the item: /sweep unkeep [item] (or see /sweep list)")
    end
  elseif cmd == "list" then
    KeepList()
  elseif cmd == "status" then
    SS.Status()
  else
    Print("Commands:")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep - sell now (at a merchant)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep gray|white|green|blue|epic - toggle each quality")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep keep [shift-click item] - never sell it (/sweep unkeep, /sweep list)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep potions - toggle consumable protection")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep auto - auto-sell whenever a merchant opens")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep status")
  end
end
