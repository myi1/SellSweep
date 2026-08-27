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

-- Consumable types the keep-list can protect individually. Any GetItemInfo
-- subtype not named here maps to "Other".
local CONSUMABLE_TYPES = { "Potion", "Elixir", "Flask", "Food & Drink",
                          "Bandage", "Scroll", "Other" }
SS.CONSUMABLE_TYPES = CONSUMABLE_TYPES
local CONSUM_MAP = {
  ["Potion"] = "Potion", ["Elixir"] = "Elixir", ["Flask"] = "Flask",
  ["Food & Drink"] = "Food & Drink", ["Bandage"] = "Bandage", ["Scroll"] = "Scroll",
}
function SS.ConsumableBucket(subType) return CONSUM_MAP[subType or ""] or "Other" end

local DEFAULTS = {
  qualities = { [0]=true, [1]=false, [2]=false, [3]=false, [4]=false },
  autoSell = false,
  protectConsumables = true, -- legacy master (kept for migration only)
  -- Per-type consumable protection (true = keep, never sell that type).
  consumableKeep = { Potion=true, Elixir=true, Flask=true, ["Food & Drink"]=true,
                     Bandage=true, Scroll=true, Other=true },
  smartSell = false,  -- smart mode: also sell known-affix non-upgrade greens/blues
  -- When true, an affix learned at ANY rank counts as owned for selling, so a
  -- higher-rank copy is vendor trash. Default false = keep higher-rank copies
  -- (they still advance your affix collection when extracted).
  affixSellAnyRank = false,
  keep = {},        -- WHITELIST: [itemID] = name — never sold
  blacklist = {},   -- BLACKLIST: [itemID] = name — always sold, overrides all else
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

-- How many consumable types are protected (kept).
local function ConsumKeptCount()
  local n = 0
  for _, t in ipairs(CONSUMABLE_TYPES) do
    if not DB.consumableKeep or DB.consumableKeep[t] ~= false then n = n + 1 end
  end
  return n
end
SS.ConsumKeptCount = ConsumKeptCount

function SS.FilterText()
  local on = {}
  for q = 0, 4 do
    if DB.qualities[q] then on[#on+1] = QUALITY_COLOR[q] .. QUALITY_NAME[q] .. "|r" end
  end
  local kept = ConsumKeptCount()
  local cons = (kept == #CONSUMABLE_TYPES) and " |cff58c9a8(consumables protected)|r"
    or (kept == 0) and " |cffd9694a(consumables sellable)|r"
    or (" |cff58c9a8(" .. kept .. "/" .. #CONSUMABLE_TYPES .. " consumable types kept)|r")
  return (#on > 0 and table.concat(on, "+") or "none")
    .. (DB.smartSell and " |cffe0b352+smart|r" or "") .. cons
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
  if panel.consumable then
    for ct, cb in pairs(panel.consumable) do
      cb:SetChecked(DB.consumableKeep and DB.consumableKeep[ct] ~= false)
    end
  end
  panel.auto:SetChecked(DB.autoSell)
  panel.smart:SetChecked(DB.smartSell)
  if panel.anyRank then panel.anyRank:SetChecked(DB.affixSellAnyRank) end

  -- Combined rule list: keep (whitelist) + blacklist, each tagged.
  local items = {}
  for id, name in pairs(DB.keep or {}) do
    items[#items+1] = { id = id, name = name, kind = "keep" }
  end
  for id, name in pairs(DB.blacklist or {}) do
    items[#items+1] = { id = id, name = name, kind = "sell" }
  end
  table.sort(items, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end  -- keep before sell
    return tostring(a.name) < tostring(b.name)
  end)
  local y = 0
  for i, it in ipairs(items) do
    local row = rows[i]
    if not row then
      row = CreateFrame("Frame", nil, panel.listContent)
      row:SetWidth(224); row:SetHeight(19)
      row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.text:SetPoint("LEFT", row, "LEFT", 2, 0)
      row.text:SetWidth(196); row.text:SetJustifyH("LEFT")
      row.del = CreateFrame("Button", nil, row, "UIPanelCloseButton")
      row.del:SetWidth(20); row.del:SetHeight(20)
      row.del:SetPoint("RIGHT", row, "RIGHT", 2, 0)
      rows[i] = row
    end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel.listContent, "TOPLEFT", 0, -y)
    local tag = (it.kind == "sell") and "|cffd9694a[sell]|r " or "|cff58c9a8[keep]|r "
    row.text:SetText(tag .. tostring(it.name))
    local kind, id = it.kind, it.id
    row.del:SetScript("OnClick", function()
      if kind == "sell" then DB.blacklist[id] = nil else DB.keep[id] = nil end
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
  cb:SetWidth(22); cb:SetHeight(22)
  local t = _G[name .. "Text"]
  t:SetFontObject("GameFontHighlightSmall")
  t:SetText(label)
  t:SetTextColor(0.86, 0.88, 0.87)
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
  local WHITE8 = "Interface\\Buttons\\WHITE8X8"
  local TEAL = "|cff58c9a8"
  -- Quality swatch colors (RGB), so state reads by SHAPE+WORD, not color alone.
  local SW = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 0.95, 0.95, 0.95 },
               [2] = { 0.12, 0.90, 0.00 }, [3] = { 0.00, 0.44, 0.87 },
               [4] = { 0.64, 0.21, 0.93 } }

  panel = CreateFrame("Frame", "SellSweepConfig", UIParent)
  panel:SetWidth(280); panel:SetHeight(604)
  panel:SetPoint("CENTER", UIParent, "CENTER", 180, 0)
  panel:SetMovable(true); panel:EnableMouse(true); panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function(s) s:StartMoving() end)
  panel:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
  panel:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 } })
  panel:SetBackdropColor(0.09, 0.10, 0.10, 0.97)
  panel:SetBackdropBorderColor(0.345, 0.788, 0.659, 0.35)
  panel:SetFrameStrata("DIALOG")

  -- Header strip.
  local hdr = panel:CreateTexture(nil, "ARTWORK")
  hdr:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
  hdr:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1); hdr:SetHeight(34)
  hdr:SetTexture(0.13, 0.15, 0.15, 1)
  local hline = panel:CreateTexture(nil, "OVERLAY")
  hline:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, 0)
  hline:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, 0)
  hline:SetHeight(1); hline:SetTexture(1, 1, 1, 0.09)

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("LEFT", panel, "TOPLEFT", 16, -18)
  title:SetText(TEAL .. "SellSweep|r")
  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)

  local function section(text, ypos)
    local f = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, ypos)
    f:SetText(text); f:SetTextColor(0.52, 0.57, 0.55)
  end

  section("SELL QUALITIES", -44)
  panel.quality = {}
  local y = -62
  for q = 0, 4 do
    local word = string.upper(string.sub(QUALITY_NAME[q], 1, 1)) .. string.sub(QUALITY_NAME[q], 2)
    local cb = MakeCheck("SellSweepCBQ" .. q, word, function(v) DB.qualities[q] = v end)
    cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
    local sw = panel:CreateTexture(nil, "OVERLAY")
    sw:SetWidth(11); sw:SetHeight(11); sw:SetPoint("LEFT", cb, "LEFT", 118, 0)
    sw:SetTexture(SW[q][1], SW[q][2], SW[q][3], 1)
    panel.quality[q] = cb
    y = y - 22
  end

  section("CONSUMABLE TYPES TO KEEP", y - 6); y = y - 26
  panel.consumable = {}
  for i, ct in ipairs(CONSUMABLE_TYPES) do
    local safe = string.gsub(ct, "[^%w]", "")
    local cb = MakeCheck("SellSweepCBC" .. safe, ct,
      function(v) DB.consumableKeep[ct] = v end)
    local col = (i - 1) % 2          -- two columns
    local row = math.floor((i - 1) / 2)
    cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 20 + col * 128, y - row * 22)
    panel.consumable[ct] = cb
  end
  y = y - (math.ceil(#CONSUMABLE_TYPES / 2) * 22) - 6

  section("OPTIONS", y); y = y - 20
  panel.auto = MakeCheck("SellSweepCBAuto", "Auto-sell when a merchant opens",
    function(v) DB.autoSell = v end)
  panel.auto:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y); y = y - 24
  panel.smart = MakeCheck("SellSweepCBSmart", "Smart sell known-affix non-upgrades",
    function(v) DB.smartSell = v end)
  panel.smart:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
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
  y = y - 24
  panel.anyRank = MakeCheck("SellSweepCBAnyRank", "Sell affix gear I've learned at any rank",
    function(v) DB.affixSellAnyRank = v end)
  panel.anyRank:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
  panel.anyRank:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Sell any learned rank")
    GameTooltip:AddLine("OFF (default): a higher-rank copy of an affix you've"
      .. " learned at a LOWER rank is kept — extracting it advances your"
      .. " collection.\nON: once you've learned an affix at any rank, higher-rank"
      .. " copies are treated as vendor trash.", 1, 1, 1, true)
    GameTooltip:AddLine("Use /sweep affix to see your learned rank per item.", 0.85, 0.41, 0.29, true)
    GameTooltip:Show()
  end)
  panel.anyRank:SetScript("OnLeave", function() GameTooltip:Hide() end)
  y = y - 32

  section("ITEM RULES", y); y = y - 20

  -- Two mutually-exclusive shift-click modes: KEEP (never sell) and SELL
  -- (always sell — overrides keep-list + consumable-type protection).
  panel.addBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  panel.addBtn:SetWidth(119); panel.addBtn:SetHeight(22)
  panel.addBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y)
  panel.addBtn:SetText(SS.AddMode() == "keep" and "Stop keeping" or "+ Shift = Keep")
  panel.addBtn:SetScript("OnClick", function() SS.SetKeepAdd(SS.AddMode() ~= "keep") end)
  panel.addBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Keep (whitelist)")
    GameTooltip:AddLine("Turn on, then shift-click bag items to never sell them.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  panel.addBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  panel.blackBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  panel.blackBtn:SetWidth(119); panel.blackBtn:SetHeight(22)
  panel.blackBtn:SetPoint("LEFT", panel.addBtn, "RIGHT", 6, 0)
  panel.blackBtn:SetText(SS.AddMode() == "sell" and "Stop selling" or "+ Shift = Sell")
  panel.blackBtn:SetScript("OnClick", function() SS.SetBlackAdd(SS.AddMode() ~= "sell") end)
  panel.blackBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Sell (blacklist)")
    GameTooltip:AddLine("Turn on, then shift-click bag items to ALWAYS sell them —"
      .. " overrides the keep-list and consumable-type protection. Great for"
      .. " dumping low-level potions while keeping the good ones.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  panel.blackBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  y = y - 28

  local scroll = CreateFrame("ScrollFrame", "SellSweepKeepScroll", panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y)
  scroll:SetWidth(226); scroll:SetHeight(90)
  panel.listContent = CreateFrame("Frame", nil, scroll)
  panel.listContent:SetWidth(226); panel.listContent:SetHeight(10)
  scroll:SetScrollChild(panel.listContent)

  panel.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  panel.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", 2, -2)
  panel.empty:SetText("(no rules — shift-click bag items above)")

  -- Secondary: paste a shift-clicked link and Add (for chat-link workflows).
  local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, 46)
  hint:SetWidth(240); hint:SetJustifyH("LEFT")
  hint:SetText("…or shift-click a link into this box:")

  panel.edit = CreateFrame("EditBox", "SellSweepKeepEdit", panel, "InputBoxTemplate")
  panel.edit:SetWidth(180); panel.edit:SetHeight(20)
  panel.edit:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 26, 20)
  panel.edit:SetAutoFocus(false)
  panel.edit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)

  local add = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  add:SetWidth(44); add:SetHeight(21)
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

-- ---------------------------------------------------------- shift-click add modes
-- Two mutually-exclusive modes: "keep" (whitelist, never sell) and "sell"
-- (blacklist, always sell). While one is ON, shift+left-click a bag item toggles
-- its membership in that list. Runtime-only so it can't be left on by accident.
local addMode = nil  -- nil | "keep" | "sell"

local function refreshModeButtons()
  if panel and panel.addBtn then
    panel.addBtn:SetText(addMode == "keep" and "Stop keeping" or "+ Shift = Keep")
  end
  if panel and panel.blackBtn then
    panel.blackBtn:SetText(addMode == "sell" and "Stop selling" or "+ Shift = Sell")
  end
end

function SS.SetKeepAdd(on)
  addMode = on and "keep" or nil
  Print(addMode == "keep"
    and "|cff58c9a8Keep-add ON|r - shift-click bag items to KEEP them (shift-click a"
      .. " kept one to remove). |cffe0b352/sweep add|r to stop."
    or "Keep-add off.")
  refreshModeButtons()
end

function SS.SetBlackAdd(on)
  addMode = on and "sell" or nil
  Print(addMode == "sell"
    and "|cffd9694aSell-add ON|r - shift-click bag items to ALWAYS SELL them (overrides"
      .. " keep-list + type protection; shift-click a listed one to remove)."
      .. " |cffe0b352/sweep addsell|r to stop."
    or "Sell-add off.")
  refreshModeButtons()
end

function SS.AddMode() return addMode end

-- Post-hook (safe): the default modified-click only inserts a link when a chat
-- editbox is focused, so adding here doesn't conflict.
if ContainerFrameItemButton_OnModifiedClick then
  hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function(self, button)
    if not (addMode and DB and IsShiftKeyDown() and button == "LeftButton") then return end
    local parent = self.GetParent and self:GetParent()
    local bag = parent and parent.GetID and parent:GetID()
    local slot = self.GetID and self:GetID()
    if not (bag and slot and bag >= 0 and bag <= 4) then return end
    local link = GetContainerItemLink(bag, slot)
    local id = link and ItemIdFromLink(link)
    if not id then return end
    local list = (addMode == "sell") and DB.blacklist or DB.keep
    local other = (addMode == "sell") and DB.keep or DB.blacklist
    if list[id] then
      Print("Removed: " .. tostring(list[id]))
      list[id] = nil
    else
      local name = GetItemInfo(id) or ("item " .. id)
      list[id] = name
      other[id] = nil  -- an item can't be in both lists
      Print(((addMode == "sell") and "Will always sell: " or "Keeping: ") .. name)
    end
    RefreshPanel()
  end)
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
    -- Migrate the old all-or-nothing protectConsumables=false into per-type off.
    if SellSweepDB.protectConsumables == false and not SellSweepDB.consumMigrated then
      for _, t in ipairs(CONSUMABLE_TYPES) do SellSweepDB.consumableKeep[t] = false end
    end
    SellSweepDB.consumMigrated = true
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
      cfg:SetWidth(54); cfg:SetHeight(21)
      cfg:SetPoint("RIGHT", btn, "LEFT", -4, 0)
      cfg:SetText("Config")
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
  elseif cmd == "affix" then
    if SS.AffixDiag then SS.AffixDiag() else Print("SmartSweep.lua failed to load.") end
  elseif cmd == "anyrank" then
    DB.affixSellAnyRank = not DB.affixSellAnyRank
    Print("Sell affix gear learned at ANY rank: " .. (DB.affixSellAnyRank and "ON" or "OFF")
      .. (DB.affixSellAnyRank and "" or " (higher-rank copies are kept as affix progression)"))
    if panel then RefreshPanel() end
  elseif cmd == "auto" then
    DB.autoSell = not DB.autoSell
    Print("Auto-sell on merchant open: " .. (DB.autoSell and "ON" or "OFF"))
  elseif cmd == "potions" or cmd == "consumables" then
    -- Master toggle: if any type is kept, make all sellable; else keep all.
    local anyKept = SS.ConsumKeptCount() > 0
    for _, t in ipairs(CONSUMABLE_TYPES) do DB.consumableKeep[t] = not anyKept end
    Print("All consumables are now "
      .. (anyKept and "|cffff5050SELLABLE|r" or "PROTECTED")
      .. ". (Pick individual types in /sweep config.)")
    if panel then RefreshPanel() end
  elseif cmd == "add" then
    SS.SetKeepAdd(SS.AddMode() ~= "keep")
  elseif cmd == "addsell" then
    SS.SetBlackAdd(SS.AddMode() ~= "sell")
  elseif cmd == "blacklist" then
    local id = ItemIdFromLink(arg)
    if not id then Print("Shift-click an item: /sweep blacklist [item]") return end
    local name = GetItemInfo(id) or ("item " .. id)
    DB.blacklist[id] = name; DB.keep[id] = nil
    Print("Will always sell: " .. name)
    if panel then RefreshPanel() end
  elseif cmd == "unblacklist" then
    local id = ItemIdFromLink(arg)
    if id and DB.blacklist[id] then
      Print("Removed from sell-list: " .. tostring(DB.blacklist[id]))
      DB.blacklist[id] = nil
      if panel then RefreshPanel() end
    else
      Print("Shift-click the item: /sweep unblacklist [item]")
    end
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
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep affix - why each affixed item is kept/sold (your learned rank vs the item's)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep anyrank - toggle: sell affix gear you've learned at ANY rank")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep smart - one-off smart sweep (also sells known-affix non-upgrade greens/blues)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep gray|white|green|blue|epic - toggle each quality")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep keep [shift-click item] - never sell it (/sweep unkeep, /sweep list)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep add - shift-click-to-KEEP mode (never sell those items)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep addsell - shift-click-to-SELL mode (blacklist: always sell, e.g. low-level potions)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep blacklist [shift-click item] - always sell it (/sweep unblacklist)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep potions - keep/sell ALL consumables (pick per-type in /sweep config)")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep auto - auto-sell whenever a merchant opens")
    DEFAULT_CHAT_FRAME:AddMessage("  /sweep status")
  end
end
