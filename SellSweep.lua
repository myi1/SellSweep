-- SellSweep: quality-configurable vendor sweeping with a protected keep-list.
-- /sweep at a merchant (or the Sweep button on the merchant frame, or auto).
-- Smart mode (SmartSweep.lua) additionally sells green/blue gear that is
-- provably useless: affix already learned (or absent) and not an upgrade.
-- /sweep preview dry-runs the smart rules without selling anything.
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
  smartSell = false,  -- smart mode: also sell known-affix non-upgrade greens/blues
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

-- Shared with SmartSweep.lua (which owns all sell/keep classification).
SS.ItemIdFromLink = ItemIdFromLink
SS.Money = Money

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

-- forceSmart: run this sweep with the smart rules even if the checkbox is off
-- (/sweep smart). Otherwise DB.smartSell decides.
function SS.Sweep(forceSmart)
  if not (MerchantFrame and MerchantFrame:IsShown()) then
    Print("Open a merchant first.")
    return
  end
  if not SS.Classify then
    Print("SmartSweep.lua failed to load — sweep aborted.")
    return
  end
  local smart = (forceSmart or DB.smartSell) and true or false
  queue, sweptCount, sweptValue = {}, 0, 0
  for bag = 0, 4 do
    for slot = 1, GetContainerNumSlots(bag) do
      local v = SS.Classify(bag, slot, smart)
      if v and v.action == "SELL" then
        queue[#queue+1] = { bag = bag, slot = slot, id = v.id }
        sweptCount = sweptCount + 1
        sweptValue = sweptValue + (v.value or 0)
      end
    end
  end
  if #queue == 0 then
    Print("Nothing to sweep with the current filters (" .. SS.FilterText() .. ").")
    return
  end
  Print("Sweeping " .. sweptCount .. " items (" .. Money(sweptValue) .. ")"
    .. (smart and " |cffe0b352[smart]|r" or "") .. "…")
  seller.t = 1  -- start immediately
  seller:Show()
end

function SS.FilterText()
  local on = {}
  for q = 0, 4 do
    if DB.qualities[q] then on[#on+1] = QUALITY_COLOR[q] .. QUALITY_NAME[q] .. "|r" end
  end
  return (#on > 0 and table.concat(on, "+") or "none")
    .. (DB.smartSell and " |cffe0b352+smart|r" or "")
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

-- ---------------------------------------------------------- config panel

local panel, rows = nil, {}

local function RefreshPanel()
  if not panel or not DB then return end
  for q = 0, 4 do panel.quality[q]:SetChecked(DB.qualities[q]) end
  panel.auto:SetChecked(DB.autoSell)
  panel.cons:SetChecked(DB.protectConsumables)
  panel.smart:SetChecked(DB.smartSell)

  local items = {}
  for id, name in pairs(DB.keep) do items[#items+1] = { id = id, name = name } end
  table.sort(items, function(a, b) return tostring(a.name) < tostring(b.name) end)
  local y = 0
  for i, it in ipairs(items) do
    local row = rows[i]
    if not row then
      row = CreateFrame("Frame", nil, panel.listContent)
      row:SetWidth(206); row:SetHeight(19)
      row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.text:SetPoint("LEFT", row, "LEFT", 2, 0)
      row.text:SetWidth(176); row.text:SetJustifyH("LEFT")
      row.del = CreateFrame("Button", nil, row, "UIPanelCloseButton")
      row.del:SetWidth(20); row.del:SetHeight(20)
      row.del:SetPoint("RIGHT", row, "RIGHT", 2, 0)
      rows[i] = row
    end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel.listContent, "TOPLEFT", 0, -y)
    row.text:SetText(tostring(it.name))
    row.del:SetScript("OnClick", function()
      DB.keep[it.id] = nil
      RefreshPanel()
    end)
    row:Show()
    y = y + 19
  end
  for i = #items + 1, #rows do rows[i]:Hide() end
  panel.listContent:SetHeight(math.max(y, 10))
  if #items == 0 then panel.empty:Show() else panel.empty:Hide() end
end

local function MakeCheck(name, label, onclick)
  local cb = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
  cb:SetWidth(24); cb:SetHeight(24)
  _G[name .. "Text"]:SetText(label)
  cb:SetScript("OnClick", function(self)
    onclick(self:GetChecked() and true or false)
    RefreshPanel()
  end)
  return cb
end

function SS.OpenConfig()
  if panel then
    if panel:IsShown() then panel:Hide() else RefreshPanel(); panel:Show() end
    return
  end
  panel = CreateFrame("Frame", "SellSweepConfig", UIParent)
  panel:SetWidth(260); panel:SetHeight(494)
  panel:SetPoint("CENTER", UIParent, "CENTER", 180, 0)
  panel:SetMovable(true); panel:EnableMouse(true); panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function(s) s:StartMoving() end)
  panel:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
  panel:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 28,
    insets = { left = 8, right = 8, top = 8, bottom = 8 } })
  panel:SetFrameStrata("DIALOG")

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", panel, "TOP", 0, -14)
  title:SetText("|cff58c9a8SellSweep|r")

  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)

  local qLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  qLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -42)
  qLabel:SetText("Sell these qualities:")

  panel.quality = {}
  local y = -62
  for q = 0, 4 do
    local cb = MakeCheck("SellSweepCBQ" .. q,
      QUALITY_COLOR[q] .. string.upper(string.sub(QUALITY_NAME[q],1,1)) ..
      string.sub(QUALITY_NAME[q],2) .. "|r",
      function(v) DB.qualities[q] = v end)
    cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, y)
    panel.quality[q] = cb
    y = y - 24
  end

  panel.cons = MakeCheck("SellSweepCBCons", "Protect consumables (potions etc.)",
    function(v) DB.protectConsumables = v end)
  panel.cons:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, y - 6)
  panel.auto = MakeCheck("SellSweepCBAuto", "Auto-sell when a merchant opens",
    function(v) DB.autoSell = v end)
  panel.auto:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, y - 30)
  panel.smart = MakeCheck("SellSweepCBSmart", "Smart sell known-affix non-upgrades",
    function(v) DB.smartSell = v end)
  panel.smart:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, y - 54)
  panel.smart:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Smart sell")
    GameTooltip:AddLine("Also sells green/blue armor+weapons whose affix is"
      .. " already learned (or absent) AND that beat nothing you wear."
      .. " Tomes, unlearned affixes, uniques, sets, quest items and the"
      .. " keep-list are never touched.", 1, 1, 1, true)
    GameTooltip:AddLine("Run /sweep preview first — it sells nothing.", 0.85, 0.41, 0.29, true)
    GameTooltip:Show()
  end)
  panel.smart:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local kLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  kLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y - 88)
  kLabel:SetText("Keep-list (never sold):")

  local scroll = CreateFrame("ScrollFrame", "SellSweepKeepScroll", panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, y - 106)
  scroll:SetWidth(200); scroll:SetHeight(120)
  panel.listContent = CreateFrame("Frame", nil, scroll)
  panel.listContent:SetWidth(200); panel.listContent:SetHeight(10)
  scroll:SetScrollChild(panel.listContent)

  panel.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  panel.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", 4, -4)
  panel.empty:SetText("(empty)")

  local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 22, 52)
  hint:SetWidth(216); hint:SetJustifyH("LEFT")
  hint:SetText("Shift-click an item into the box, then Add:")

  panel.edit = CreateFrame("EditBox", "SellSweepKeepEdit", panel, "InputBoxTemplate")
  panel.edit:SetWidth(150); panel.edit:SetHeight(20)
  panel.edit:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 28, 24)
  panel.edit:SetAutoFocus(false)
  panel.edit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)

  local add = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  add:SetWidth(50); add:SetHeight(21)
  add:SetPoint("LEFT", panel.edit, "RIGHT", 8, 0)
  add:SetText("Add")
  add:SetScript("OnClick", function()
    local id = ItemIdFromLink(panel.edit:GetText())
    if id then
      DB.keep[id] = GetItemInfo(id) or ("item " .. id)
      panel.edit:SetText("")
      RefreshPanel()
    else
      Print("Shift-click an item into the box first.")
    end
  end)

  -- Route shift-clicked item links into our box while it has focus.
  local origInsert = ChatEdit_InsertLink
  ChatEdit_InsertLink = function(link)
    if panel and panel.edit and panel.edit:HasFocus() then
      panel.edit:SetText(link or "")
      return true
    end
    return origInsert(link)
  end

  RefreshPanel()
  panel:Show()
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
    if type(SellSweepDB.scans) ~= "table" then SellSweepDB.scans = {} end
    DB = SellSweepDB
    SS.db = DB
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

      local cfg = CreateFrame("Button", "SellSweepCfgButton", MerchantFrame, "UIPanelButtonTemplate")
      cfg:SetWidth(36); cfg:SetHeight(21)
      cfg:SetPoint("RIGHT", btn, "LEFT", -4, 0)
      cfg:SetText("Cfg")
      cfg:SetScript("OnClick", function() SS.OpenConfig() end)
      cfg:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("SellSweep options")
        GameTooltip:AddLine("Qualities, keep-list, auto-sell", 1, 1, 1)
        GameTooltip:Show()
      end)
      cfg:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
  elseif cmd == "smart" then
    SS.Sweep(true)
  elseif cmd == "preview" then
    if SS.Preview then SS.Preview() else Print("SmartSweep.lua failed to load.") end
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
  elseif cmd == "config" or cmd == "options" then
    SS.OpenConfig()
  else
    Print("Commands:")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep - sell now (at a merchant)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep preview - dry run: SELL/KEEP verdict for every bag item (sells nothing)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep smart - one-off smart sweep (also sells known-affix non-upgrade greens/blues)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep gray|white|green|blue|epic - toggle each quality")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep keep [shift-click item] - never sell it (/sweep unkeep, /sweep list)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep potions - toggle consumable protection")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep auto - auto-sell whenever a merchant opens")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep status")
  end
end
