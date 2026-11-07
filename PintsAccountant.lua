-- Pint's Accountant
-- Every change in your gold is recorded with a source. The source comes from what you were
-- doing when the gold moved: an action you just took (buying, training, sending mail...),
-- or a window that was open (vendor, mailbox, trade, guild bank...), or a loot message.
-- coins drawn with the money icons (WoW Forever's own coin text came out as bare digits: 6s 64c showed as "664")
local GetCoinTextureString = function(v)
	v = math.floor((tonumber(v) or 0) + 0.5)
	local neg = v < 0; if neg then v = -v end
	local g, s, c = math.floor(v / 10000), math.floor(v / 100) % 100, v % 100
	local out = {}
	if g > 0 then out[#out + 1] = g .. "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t" end
	if s > 0 then out[#out + 1] = s .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t" end
	if c > 0 or #out == 0 then out[#out + 1] = c .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t" end
	return (neg and "-" or "") .. table.concat(out, " ")
end

local ADDON = ...
-- Compatibility: WoW Forever runs on the modern game client, where these older functions moved or were renamed.
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)

local PA = {}
_G.PintsAccountant = PA

local INCOME = {
	"Vendor sales", "Looted", "Quest rewards", "Auction sales", "Auction refunds",
	"Mail from players", "Mail (other)", "Trades received", "Guild bank withdrawals", "Other income",
}
local EXPENSE = {
	"Repairs", "Gear purchases", "Consumables & reagents", "Recipes", "Mounts",
	"Other vendor purchases", "Buyback", "Class training", "Profession training", "Flight paths",
	"Auction deposits", "Auction purchases", "Postage", "Mail sent to players", "COD payments",
	"Trades given (tips)", "Guild bank deposits", "Talent resets", "Bank slots",
	"Guild & tabard fees", "Barber", "Other expenses",
}

-- Currencies (WoW Forever: Merchant's Favor, Honor Points...) get a ledger tab each, with their own short list of sources
local CUR_INC = { "Quest rewards", "Looted", "Honorable kills", "Other gains" }
local CUR_EXP = { "Vendor purchases", "Other spending" }
local CUR = C_CurrencyInfo
local HAS_CUR = CUR and CUR.GetCurrencyInfo and CUR.GetCurrencyListSize and true or false

-- What an open window means for money coming in (inc) or going out (exp).
local CONTEXTS = {
	merchant  = { inc = "Vendor sales", exp = "Other vendor purchases" },
	trainer   = { exp = "Class training" },
	taxi      = { exp = "Flight paths" },
	auction   = { inc = "Auction refunds", exp = "Auction purchases" },
	mail      = { inc = "Mail (other)", exp = "Postage" },
	trade     = { inc = "Trades received", exp = "Trades given (tips)" },
	guildbank = { inc = "Guild bank withdrawals", exp = "Guild bank deposits" },
	bank      = { exp = "Bank slots" },
	loot      = { inc = "Looted" },
	quest     = { inc = "Quest rewards", exp = "Other expenses" },   -- the odd quest that charges gold
	registrar = { exp = "Guild & tabard fees" },
	barber    = { exp = "Barber" },
	talent    = { exp = "Talent resets" },
}

local DEFAULTS = { showDisplay = true, dispChar = true, dispAccount = true, dispSession = false, dispLock = false, dispCur = false }
local CLOSE_GRACE = 3      -- seconds a closed window still counts (money often lands just after closing)
local PENDING_LIFE = 5     -- seconds an action waits for its gold change

local db, char, charKey
local session = { inc = {}, exp = {}, start = time(), cur = {} }
local lastMoney
local active, pending = {}, {}
local trainerIsProfession = false

local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Print(msg) print("|cffd4a017Pint's Accountant:|r " .. msg) end

local function Coin(v)
	v = math.floor(v or 0)
	if v == 0 then return "0" end
	local s = (GetCoinTextureString or GetMoneyString)(math.abs(v))
	return (v < 0 and "-" or "") .. s
end

local function Signed(v)
	if v > 0 then return "|cff40ff40+" .. Coin(v) .. "|r" end
	if v < 0 then return "|cffff5050" .. Coin(v) .. "|r" end
	return "0"
end

local function ClassName(name, class)
	local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
	if c and c.colorStr then return "|c" .. c.colorStr .. name .. "|r" end
	return name
end

local function HourNow() return math.floor(time() / 3600) end
local function DayNow() return math.floor(time() / 86400) end

local function Add(t, dir, cat, amt)
	if cat == "Quest costs" then cat = "Other expenses" end     -- no longer its own line
	t[dir] = t[dir] or {}
	t[dir][cat] = (t[dir][cat] or 0) + amt
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------
-- the record a gold or currency figure lives in: the character itself for gold, char.cur[name] for a currency
local function Book(c, cname)
	if not cname then return c end
	c.cur = c.cur or {}
	local b = c.cur[cname]
	if not b then b = { allTime = { inc = {}, exp = {} }, hours = {}, days = {} }; c.cur[cname] = b end
	return b
end
local function SessionBook(cname)
	if not cname then return session end
	session.cur = session.cur or {}
	session.cur[cname] = session.cur[cname] or { inc = {}, exp = {} }
	return session.cur[cname]
end

local function Record(dir, cat, amt, cname)
	if amt <= 0 then return end
	local b = Book(char, cname)
	local h, d = HourNow(), DayNow()
	b.hours[h] = b.hours[h] or {}
	b.days[d] = b.days[d] or {}
	Add(b.allTime, dir, cat, amt)
	Add(b.hours[h], dir, cat, amt)
	Add(b.days[d], dir, cat, amt)
	Add(SessionBook(cname), dir, cat, amt)
end

local function AddPending(dir, cat, extra)
	local p = extra or {}
	p.dir, p.cat, p.expire = dir, cat, GetTime() + PENDING_LIFE
	pending[#pending + 1] = p
end

local function TakePending(dir)
	local now = GetTime()
	for i = #pending, 1, -1 do
		if pending[i].expire < now then table.remove(pending, i) end
	end
	for i, p in ipairs(pending) do
		if p.dir == dir then
			table.remove(pending, i)
			return p
		end
	end
end

local function ContextCategory(dir)
	local now, best, bestOpened = GetTime(), nil, -1
	for name, st in pairs(active) do
		local map = CONTEXTS[name]
		if st.expire > now and map and map[dir] and st.opened > bestOpened then
			best, bestOpened = map[dir], st.opened
		end
	end
	if best == "Class training" and trainerIsProfession then best = "Profession training" end
	return best
end

local function OnMoneyChanged()
	local money = GetMoney()
	if not lastMoney then lastMoney = money return end
	local delta = money - lastMoney
	lastMoney = money
	char.money = money; char.moneyTime = time()
	if delta == 0 then return end

	local dir, amt = delta > 0 and "inc" or "exp", math.abs(delta)
	local p = TakePending(dir)
	if p and p.split then
		-- Sent mail: postage first, anything beyond it was gold sent to a player.
		local postage = math.min(amt, p.split)
		Record("exp", "Postage", postage)
		Record("exp", "Mail sent to players", amt - postage)
	else
		local cat = (p and p.cat) or ContextCategory(dir) or (dir == "inc" and "Other income" or "Other expenses")
		Record(dir, cat, amt)
	end
	PA:Refresh()
end

---------------------------------------------------------------------------
-- Currencies
---------------------------------------------------------------------------
local function Learn()
	if not HAS_CUR then return end
	db.currencies = db.currencies or {}
	for i = 1, (CUR.GetCurrencyListSize() or 0) do
		local info = CUR.GetCurrencyListInfo(i)
		if info and not info.isHeader and info.name then
			local link = CUR.GetCurrencyListLink and CUR.GetCurrencyListLink(i)
			local id = link and tonumber(link:match("currency:(%d+)"))
			if id then db.currencies[info.name] = { id = id, icon = info.iconFileID } end
		end
	end
end

local CurrencyCategory   -- (defined after the window tracking it reads)

-- a currency changed: record the difference from what we last saw (the first sighting only sets the starting amount)
local function OnCurrencyChanged(id, silent)
	if not HAS_CUR or not char then return end
	db.currencies = db.currencies or {}
	local ids = {}
	if id then ids[1] = id else for _, k in pairs(db.currencies) do ids[#ids + 1] = k.id end end
	for _, cid in ipairs(ids) do
		local info = CUR.GetCurrencyInfo(cid)
		if info and info.name and info.name ~= "" and info.quantity then
			db.currencies[info.name] = db.currencies[info.name] or { id = cid, icon = info.iconFileID }
			local b = Book(char, info.name)
			if b.qty and not silent then
				local delta = info.quantity - b.qty
				if delta ~= 0 then
					local dir = delta > 0 and "inc" or "exp"
					Record(dir, CurrencyCategory(dir, info.name), math.abs(delta), info.name)
				end
			end
			b.qty = info.quantity
		end
	end
	PA:Refresh()
end
PA.OnCurrencyChanged = OnCurrencyChanged

---------------------------------------------------------------------------
-- Context tracking (windows open/closed)
---------------------------------------------------------------------------
local function Open(name) active[name] = { opened = GetTime(), expire = math.huge } end
local function Close(name) if active[name] then active[name].expire = GetTime() + CLOSE_GRACE end end
local function Pulse(name, seconds) active[name] = { opened = GetTime(), expire = GetTime() + seconds } end

local function IsActive(name) local st = active[name]; return st and st.expire > GetTime() end
CurrencyCategory = function(dir, cname)
	if dir == "exp" then return IsActive("merchant") and "Vendor purchases" or "Other spending" end
	if IsActive("quest") then return "Quest rewards" end
	if IsActive("loot") then return "Looted" end
	if cname and cname:find("Honor") then return "Honorable kills" end
	return "Other gains"
end

local OPEN_EVENTS = {
	MERCHANT_SHOW = "merchant", TRAINER_SHOW = "trainer", TAXIMAP_OPENED = "taxi",
	AUCTION_HOUSE_SHOW = "auction", MAIL_SHOW = "mail", TRADE_SHOW = "trade",
	GUILDBANKFRAME_OPENED = "guildbank", BANKFRAME_OPENED = "bank", LOOT_OPENED = "loot",
	QUEST_DETAIL = "quest", QUEST_PROGRESS = "quest", QUEST_COMPLETE = "quest",
	GUILD_REGISTRAR_SHOW = "registrar", TABARD_FRAME_OPEN = "registrar", BARBER_SHOP_OPEN = "barber",
}
local CLOSE_EVENTS = {
	MERCHANT_CLOSED = "merchant", TRAINER_CLOSED = "trainer", TAXIMAP_CLOSED = "taxi",
	AUCTION_HOUSE_CLOSED = "auction", MAIL_CLOSED = "mail", TRADE_CLOSED = "trade",
	GUILDBANKFRAME_CLOSED = "guildbank", BANKFRAME_CLOSED = "bank", LOOT_CLOSED = "loot",
	QUEST_FINISHED = "quest", GUILD_REGISTRAR_CLOSED = "registrar", TABARD_FRAME_CLOSE = "registrar",
	BARBER_SHOP_CLOSE = "barber",
}

-- Newer clients report many windows through one interaction event.
local INTERACTION = {}
do
	local T = Enum and Enum.PlayerInteractionType
	if T then
		local map = {
			Merchant = "merchant", Trainer = "trainer", TaxiNode = "taxi", Auctioneer = "auction",
			MailInfo = "mail", GuildBanker = "guildbank", Banker = "bank", Registrar = "registrar",
			TabardVendor = "registrar", Barber = "barber",
		}
		for key, ctx in pairs(map) do
			if T[key] then INTERACTION[T[key]] = ctx end
		end
	end
end

---------------------------------------------------------------------------
-- Action hooks (exact source when you click something that costs or pays gold)
---------------------------------------------------------------------------
local function PurchaseCategory(index)
	local link = GetMerchantItemLink and GetMerchantItemLink(index)
	if not link then return "Other vendor purchases" end
	local classID, subClassID = select(12, ItemInfo(link))
	if classID == 2 or classID == 4 then return "Gear purchases" end
	if classID == 9 then return "Recipes" end
	if classID == 15 and subClassID == 5 then return "Mounts" end
	if classID == 0 or classID == 5 or classID == 6 or classID == 7 then return "Consumables & reagents" end
	return "Other vendor purchases"
end

local function MailIncomeCategory(index)
	local invoiceType = GetInboxInvoiceInfo and GetInboxInvoiceInfo(index)
	if invoiceType == "seller" then return "Auction sales" end
	if invoiceType then return "Auction refunds" end
	local sender = select(3, GetInboxHeaderInfo(index))
	local canReply = select(12, GetInboxHeaderInfo(index))
	if sender and sender:find("Auction", 1, true) then return "Auction refunds" end
	if canReply then return "Mail from players" end
	return "Mail (other)"
end

local function Hook(name, fn)
	if type(_G[name]) == "function" then hooksecurefunc(name, fn) end
end

local function HookTable(tbl, name, fn)
	if tbl and type(tbl[name]) == "function" then hooksecurefunc(tbl, name, fn) end
end

local function SetupHooks()
	Hook("RepairAllItems", function(guild) if not guild then AddPending("exp", "Repairs") end end)
	Hook("RepairCursorItem", function() AddPending("exp", "Repairs") end)
	Hook("BuyMerchantItem", function(index) AddPending("exp", PurchaseCategory(index)) end)
	Hook("BuybackItem", function() AddPending("exp", "Buyback") end)
	Hook("BuyTrainerService", function()
		local prof = (IsTradeskillTrainer and IsTradeskillTrainer()) or trainerIsProfession
		AddPending("exp", prof and "Profession training" or "Class training")
	end)
	Hook("TakeTaxiNode", function() AddPending("exp", "Flight paths") end)
	Hook("PurchaseSlot", function() AddPending("exp", "Bank slots") end)
	Hook("ConfirmTalentWipe", function() AddPending("exp", "Talent resets") end)
	Hook("DepositGuildBankMoney", function() AddPending("exp", "Guild bank deposits") end)
	Hook("WithdrawGuildBankMoney", function() AddPending("inc", "Guild bank withdrawals") end)

	-- Mailbox
	Hook("TakeInboxMoney", function(i) AddPending("inc", MailIncomeCategory(i)) end)
	Hook("AutoLootMailItem", function(i)
		local money, cod = select(5, GetInboxHeaderInfo(i))
		if cod and cod > 0 then AddPending("exp", "COD payments") end
		if money and money > 0 then AddPending("inc", MailIncomeCategory(i)) end
	end)
	Hook("TakeInboxItem", function(i)
		local cod = select(6, GetInboxHeaderInfo(i))
		if cod and cod > 0 then AddPending("exp", "COD payments") end
	end)
	Hook("SendMail", function()
		local postage = (GetSendMailPrice and GetSendMailPrice()) or 30
		AddPending("exp", "Postage", { split = postage })
	end)

	-- Auction house (older and newer APIs)
	Hook("StartAuction", function() AddPending("exp", "Auction deposits") end)
	Hook("PostAuction", function() AddPending("exp", "Auction deposits") end)
	Hook("PlaceAuctionBid", function() AddPending("exp", "Auction purchases") end)
	HookTable(C_AuctionHouse, "PostItem", function() AddPending("exp", "Auction deposits") end)
	HookTable(C_AuctionHouse, "PostCommodity", function() AddPending("exp", "Auction deposits") end)
	HookTable(C_AuctionHouse, "PlaceBid", function() AddPending("exp", "Auction purchases") end)
	HookTable(C_AuctionHouse, "ConfirmCommoditiesPurchase", function() AddPending("exp", "Auction purchases") end)
end

---------------------------------------------------------------------------
-- Summaries
---------------------------------------------------------------------------
local PERIODS = {
	{ key = "session", label = "Session" },
	{ key = "day",     label = "Today" },
	{ key = "week",    label = "Week" },
	{ key = "month",   label = "Month" },
	{ key = "year",    label = "Year" },
	{ key = "all",     label = "All" },
}
local PERIOD_DAYS = { week = 7, month = 30, year = 365 }

local function Merge(into, from)
	if not from then return end
	for _, dir in ipairs({ "inc", "exp" }) do
		if from[dir] then
			for cat, amt in pairs(from[dir]) do Add(into, dir, cat, amt) end
		end
	end
end

-- "Today" runs from the last daily reset (the server's daily quest reset - 8:00 am server time on most realms)
local function TodayStart()
	local left = (C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset and C_DateAndTime.GetSecondsUntilDailyReset())
		or (GetQuestResetTime and GetQuestResetTime())
	if type(left) == "number" and left > 0 and left <= 86400 then return time() + left - 86400 end
	-- no reset timer from the game: 8:00 by the server clock
	local hr, mn = GetGameTime()
	return time() - (((hr or 0) - 8) % 24) * 3600 - (mn or 0) * 60
end
PA.TodayStart = TodayStart

function PA:Summary(period, scope, cname)
	local res = { inc = {}, exp = {} }
	local key = scope or charKey
	if period == "session" then
		-- the session only exists for the character you're playing
		if key == "account" or key == charKey then Merge(res, cname and session.cur and session.cur[cname] or (not cname and session) or nil) end
		return res
	end
	local chars = (key == "account") and db.chars or { [key] = db.chars[key] }
	local h, d = HourNow(), DayNow()
	for _, ch in pairs(chars) do
		local c = cname and (ch.cur and ch.cur[cname]) or (not cname and ch) or { hours = {}, days = {} }
		if period == "all" then
			Merge(res, c.allTime)
		elseif period == "day" then
			local first = math.floor((TodayStart() + 60) / 3600)      -- the hour the reset happened in
			for hour, t in pairs(c.hours) do if hour >= first then Merge(res, t) end end
		else
			local span = PERIOD_DAYS[period]
			for day, t in pairs(c.days) do if day > d - span then Merge(res, t) end end
		end
	end
	return res
end

local function Total(t) local s = 0 for _, v in pairs(t) do s = s + v end return s end

-- Characters you haven't logged into since installing Pint's Accountant (or whose gold was saved as 0 by the
-- logout bug) pick up their gold from Altoholic's DataStore, when it's installed and its record is newer.
function PA:SeedFromDataStore()
	local ids, info = _G.DataStore_CharacterIDs, _G.DataStore_Characters_Info
	if type(ids) ~= "table" or type(ids.Set) ~= "table" or type(info) ~= "table" then return end
	local realm = GetRealmName()
	for full, id in pairs(ids.Set) do
		local r, name = full:match("^[^.]+%.(.+)%.([^.]+)$")
		local rec = info[id]
		if r == realm and name and type(rec) == "table" and type(rec.money) == "number" then
			local key = name .. "-" .. realm
			if key ~= charKey then
				local c = db.chars[key]
				if not c then
					c = { allTime = { inc = {}, exp = {} }, hours = {}, days = {} }
					db.chars[key] = c
				end
				local stamp = rec.lastUpdate or rec.lastLogoutTimestamp or 0
				if not c.money or c.money == 0 or (c.moneyTime or 0) < stamp then
					c.money = rec.money; c.moneyTime = stamp
				end
			end
		end
	end
end

-- Pint's Ledger already records every character's gold, class and last login; use it to fill in characters
-- this add-on hasn't seen lately (or has at 0).
function PA:SeedFromLedger()
	local L = _G.PintsLedgerDB
	if type(L) ~= "table" or type(L.chars) ~= "table" then return end
	local realm = GetRealmName()
	local list = L.chars[realm]
	if type(list) ~= "table" then return end
	-- WoW Forever (your name has a second name): first-name-only entries in Pint's Alts are left-overs; skip them
	local full = charKey and charKey:sub(1, #charKey - #realm - 1):find(" ")
	for name, rec in pairs(list) do
		if type(rec) == "table" and type(rec.money) == "number" and not (full and not name:find(" ")) then
			local key = name .. "-" .. realm
			if key ~= charKey then
				local c = db.chars[key]
				if not c then
					c = { allTime = { inc = {}, exp = {} }, hours = {}, days = {} }
					db.chars[key] = c
				end
				if not c.class and rec.classFile then c.class = rec.classFile end
				local stamp = rec.lastOnline or 0
				if not c.money or c.money == 0 or (c.moneyTime or 0) < stamp then
					if rec.money > 0 or not c.money then c.money = rec.money; c.moneyTime = stamp end
				end
			end
		end
	end
end

function PA:AccountGold()
	local total = 0
	for _, c in pairs(db.chars) do total = total + (c.money or 0) end
	return total
end

function PA:SessionNet()
	return Total(session.inc) - Total(session.exp)
end

local function GoldPerHour()
	local hours = math.max(1 / 60, (time() - session.start) / 3600)
	return PA:SessionNet() / hours
end

---------------------------------------------------------------------------
-- On-screen gold display
---------------------------------------------------------------------------
local display

local function SavePoint(frame, key)
	local point, _, relPoint, x, y = frame:GetPoint(1)
	db[key] = { point, relPoint, x, y }
end

local function CreateDisplay()
	display = CreateFrame("Frame", "PintsAccountantDisplay", UIParent, "BackdropTemplate")
	display:SetSize(160, 20)
	display:SetFrameStrata("LOW")
	display:SetMovable(true)
	display:SetClampedToScreen(true)
	display:EnableMouse(true)
	display:RegisterForDrag("LeftButton")
	display:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
	display:SetBackdropColor(0, 0, 0, 0.35)
	local p = db.dispPos
	if p then display:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else display:SetPoint("TOP", UIParent, "TOP", 0, -40) end

	-- two columns: names on the left, amounts right-aligned so the gold/silver/copper icons line up
	display.labels, display.values = {}, {}

	display:SetScript("OnDragStart", function(self) if not db.dispLock then self:StartMoving() end end)
	display:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self:SetUserPlaced(false)
		SavePoint(self, "dispPos")
	end)
end

function PA:UpdateDisplay()
	if not display then return end
	local lines = {}
	if db.dispChar then lines[#lines + 1] = { ClassName((GetUnitName and GetUnitName("player", false) or UnitName("player")), char.class) .. ":", Coin(char.money) } end
	if db.dispAccount then lines[#lines + 1] = { "Account:", Coin(PA:AccountGold()) } end
	if db.dispSession then lines[#lines + 1] = { "Session:", Signed(PA:SessionNet()) } end
	if db.dispCur and char and char.cur then
		local names = {}
		for n, b in pairs(char.cur) do if (b.qty or 0) > 0 then names[#names + 1] = n end end
		table.sort(names)
		for _, n in ipairs(names) do
			local k = db.currencies and db.currencies[n]
			lines[#lines + 1] = { n .. ":", char.cur[n].qty .. (k and k.icon and (" |T" .. k.icon .. ":12:12:0:0|t") or "") }
		end
	end
	if not db.showDisplay or #lines == 0 then display:Hide() return end
	local LINE, GAP = 14, 10
	local wl, wv = 0, 0
	for i, l in ipairs(lines) do
		local a, b = display.labels[i], display.values[i]
		if not a then
			a = display:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); a:SetJustifyH("LEFT")
			b = display:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b:SetJustifyH("RIGHT")
			display.labels[i], display.values[i] = a, b
		end
		a:SetText(l[1]); b:SetText(l[2]); a:Show(); b:Show()
		wl = math.max(wl, a:GetStringWidth()); wv = math.max(wv, b:GetStringWidth())
	end
	for i = #lines + 1, #display.labels do display.labels[i]:Hide(); display.values[i]:Hide() end
	for i = 1, #lines do
		local a, b = display.labels[i], display.values[i]
		a:ClearAllPoints(); a:SetPoint("TOPLEFT", 6, -4 - (i - 1) * LINE)
		b:ClearAllPoints(); b:SetPoint("TOPRIGHT", -6, -4 - (i - 1) * LINE)
	end
	display:SetSize(math.ceil(wl + GAP + wv) + 12, #lines * LINE + 6)
	display:Show()
end

---------------------------------------------------------------------------
-- Ledger window: a spreadsheet. Every category is a row (0 when nothing happened), every period a column.
---------------------------------------------------------------------------
local ledger, sheet, rows = nil, nil, {}
local viewScope = nil  -- nil = the character you're on, "account" = everyone, or a "Name-Realm" key
local CAT_W, COL_W, ROW_H = 180, 88, 14
-- slightly smaller lettering so the whole sheet fits on screen
local CELL_FONT = CreateFont("PintsAccountantCellFont"); CELL_FONT:SetFontObject("GameFontHighlightSmall")
do local f, _, fl = GameFontHighlightSmall:GetFont(); CELL_FONT:SetFont(f, 10, fl) end
local HEAD_FONT = CreateFont("PintsAccountantHeadFont"); HEAD_FONT:SetFontObject("GameFontNormalSmall")
do local f, _, fl = GameFontNormal:GetFont(); HEAD_FONT:SetFont(f, 11, fl) end
local NCOL = #PERIODS
local SHEET_W = CAT_W + COL_W * NCOL

-- compact money for cells: 12g 04s 56c, 0 when nothing
local curView = nil   -- nil = gold, or a currency's name
local function Cell(v, color)
	v = math.floor(v or 0)
	if v == 0 then return "|cff6a6a6a0|r" end
	if curView then return (color or "|cffffffff") .. v .. "|r" end
	local neg = v < 0; v = math.abs(v)
	local g, s, c = math.floor(v / 10000), math.floor(v / 100) % 100, v % 100
	local txt
	if g > 0 then txt = ("%s|cffffd700g|r %02d|cffc7c7cfs|r %02d|cffeda55fc|r"):format(g, s, c)
	elseif s > 0 then txt = ("%d|cffc7c7cfs|r %02d|cffeda55fc|r"):format(s, c)
	else txt = ("%d|cffeda55fc|r"):format(c) end
	if neg then txt = "-" .. txt end
	return (color or "|cffffffff") .. txt .. "|r"
end

local function Row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Frame", nil, sheet)
	r:SetSize(SHEET_W, ROW_H)
	r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
	r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
	r.line = r:CreateTexture(nil, "BORDER"); r.line:SetHeight(1); r.line:SetPoint("BOTTOMLEFT"); r.line:SetPoint("BOTTOMRIGHT")
	r.line:SetColorTexture(1, 1, 1, 0.06)
	r.hl = r:CreateTexture(nil, "HIGHLIGHT"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 0.82, 0, 0.07)
	r:EnableMouse(true)
	r.label = r:CreateFontString(nil, "OVERLAY", "PintsAccountantCellFont"); r.label:SetPoint("LEFT", 6, 0)
	r.label:SetWidth(CAT_W - 10); r.label:SetJustifyH("LEFT"); r.label:SetWordWrap(false)
	r.cells = {}
	for c = 1, NCOL do
		local fs = r:CreateFontString(nil, "OVERLAY", "PintsAccountantCellFont")
		fs:SetPoint("RIGHT", r, "LEFT", CAT_W + c * COL_W - 6, 0); fs:SetWidth(COL_W - 8); fs:SetJustifyH("RIGHT"); fs:SetWordWrap(false)
		r.cells[c] = fs
	end
	rows[i] = r
	return r
end

local function Fill(i, kind, label, values, color)
	local r = Row(i)
	r.label:SetText(label or "")
	local bg = { 0, 0, 0, 0 }
	if kind == "section" then
		r.label:SetFontObject("PintsAccountantHeadFont"); bg = { 1, 0.82, 0, 0.12 }
	elseif kind == "total" then
		r.label:SetFontObject("PintsAccountantHeadFont"); r.label:SetTextColor(1, 1, 1); bg = { 1, 1, 1, 0.07 }
	elseif kind == "net" then
		r.label:SetFontObject("PintsAccountantHeadFont"); bg = { 1, 0.82, 0, 0.16 }
	else
		r.label:SetFontObject("PintsAccountantCellFont"); bg = { 1, 1, 1, (kind == "row" and i % 2 == 0) and 0.03 or 0 }
	end
	r.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
	for c = 1, NCOL do
		local v = values and values[c]
		if type(v) == "number" then r.cells[c]:SetText(Cell(v, color))
		else r.cells[c]:SetText(v or "") end
	end
	r:Show()
end

function PA:RefreshLedger()
	if not ledger or not ledger:IsShown() then return end
	if viewScope and viewScope ~= "account" and not db.chars[viewScope] then viewScope = nil end
	local isAll = viewScope == "account"
	local key = isAll and "account" or (viewScope or charKey)
	local viewChar = db.chars[key]
	ledger.scopeBtn:SetText((isAll and "All characters" or ClassName(key, viewChar and viewChar.class)) .. "  |cffaaaaaav|r")
	if curView and not (db.currencies and db.currencies[curView]) then curView = nil end
	PA:UpdateTabs()
	local INC, EXP = curView and CUR_INC or INCOME, curView and CUR_EXP or EXPENSE
	-- one summary per column
	local sums = {}
	for c, p in ipairs(PERIODS) do sums[c] = PA:Summary(p.key, viewScope, curView) end
	local i = 0
	local function line(kind, label, values, color) i = i + 1; Fill(i, kind, label, values, color) end
	local function catValues(dir, cat) local v = {}; for c = 1, NCOL do v[c] = sums[c][dir][cat] or 0 end; return v end
	local function totals(dir) local v = {}; for c = 1, NCOL do v[c] = Total(sums[c][dir]) end; return v end

	line("section", "Income")
	for _, cat in ipairs(INC) do line("row", "   " .. cat, catValues("inc", cat)) end
	local inc = totals("inc")
	line("total", "Total income", inc, "|cff40ff40")
	line("blank", "")
	line("section", "Expenses")
	for _, cat in ipairs(EXP) do line("row", "   " .. cat, catValues("exp", cat)) end
	local exp = totals("exp")
	line("total", "Total expenses", exp, "|cffff5050")
	line("blank", "")
	local net = {}
	for c = 1, NCOL do net[c] = inc[c] - exp[c] end
	local netText = {}
	for c = 1, NCOL do netText[c] = Cell(net[c], net[c] > 0 and "|cff40ff40+" or net[c] < 0 and "|cffff5050" or nil) end
	line("net", "Net", netText)
	-- per-hour for the session column, and gold on hand
	line("blank", "")
	local hours = math.max(1 / 60, (time() - session.start) / 3600)
	local perHour = {}
	perHour[1] = Cell(math.floor(net[1] / hours), net[1] >= 0 and "|cff40ff40" or "|cffff5050")
	line("row", curView and "   Per hour" or "   Gold per hour", perHour)
	local len = {}; len[1] = "|cffffffff" .. (SecondsToTime and SecondsToTime(time() - session.start, true) or "") .. "|r"
	line("row", "   Session length", len)
	local function Held(c)
		if not c then return 0 end
		if curView then return c.cur and c.cur[curView] and c.cur[curView].qty or 0 end
		return c.money or 0
	end
	local onHand = {}
	if isAll then local t = 0; for _, c in pairs(db.chars) do t = t + Held(c) end; onHand[NCOL] = Cell(t)
	elseif key == charKey and not curView then onHand[NCOL] = Cell(GetMoney())
	else onHand[NCOL] = Cell(Held(viewChar)) end
	local what = curView or "Gold"
	line("row", isAll and ("   " .. what .. " on all characters") or ("   " .. what .. " on hand"), onHand)

	-- currencies (WoW Forever: Merchant's Favor, Honor Points...): one line each - how many gained (or spent) in each
	-- period, and how many you have in the last column
	local cnames = {}
	for n in pairs(db.currencies or {}) do cnames[#cnames + 1] = n end
	table.sort(cnames, function(a, b)
		local pa, pb = a == "Merchant's Favor" and 0 or a:find("Honor") and 1 or 2, b == "Merchant's Favor" and 0 or b:find("Honor") and 1 or 2
		if pa ~= pb then return pa < pb end
		return a < b
	end)
	local function Count(v)
		v = math.floor(v or 0)
		if v == 0 then return "|cff6a6a6a0|r" end
		return (v > 0 and "|cff40ff40+" or "|cffff5050") .. v .. "|r"
	end
	local shown = false
	for _, cname in ipairs(cnames) do
		local v, any = {}, false
		for c = 1, NCOL - 1 do
			local sm = PA:Summary(PERIODS[c].key, viewScope, cname)
			local d = Total(sm.inc) - Total(sm.exp)
			if d ~= 0 then any = true end
			v[c] = Count(d)
		end
		local have = 0
		if isAll then for _, c in pairs(db.chars) do have = have + (c.cur and c.cur[cname] and c.cur[cname].qty or 0) end
		else have = viewChar and viewChar.cur and viewChar.cur[cname] and viewChar.cur[cname].qty or 0 end
		if have > 0 or any then
			if not shown then
				line("blank", ""); line("section", "Currencies   |cffaaaaaa(gained in each period - and how many you have)|r"); shown = true
			end
			v[NCOL] = "|cffffffff" .. have .. "|r"
			local k = db.currencies[cname]
			line("row", "   " .. (k and k.icon and ("|T" .. k.icon .. ":12:12:0:0|t ") or "") .. cname, v)
		end
	end

	if isAll then
		line("blank", "")
		line("section", "Characters")
		local list = {}
		for key, c in pairs(db.chars) do list[#list + 1] = { key = key, c = c } end
		table.sort(list, function(a, b) return Held(a.c) > Held(b.c) end)
		for _, e in ipairs(list) do
			local v = {}; v[NCOL] = Cell(Held(e.c))
			line("row", "   " .. ClassName(e.key, e.c.class), v)
		end
	end
	for j = i + 1, #rows do rows[j]:Hide() end
	sheet:SetHeight(math.max(1, i * ROW_H))
	-- tall enough to show every row without scrolling, as long as the screen allows
	local want = i * ROW_H + 96
	local room = UIParent:GetHeight() - 40
	ledger:SetHeight(math.max(300, math.min(want, room)))
	ledger.net:SetText("Session net  " .. (curView and ((net[1] > 0 and "|cff40ff40+" or net[1] < 0 and "|cffff5050" or "") .. net[1] .. "|r") or Signed(net[1])))
end

local function CreateLedger()
	ledger = CreateFrame("Frame", "PintsAccountantLedger", UIParent, "BasicFrameTemplateWithInset")
	ledger:SetSize(SHEET_W + 52, 560)
	ledger:SetPoint("CENTER")
	ledger:SetFrameStrata("DIALOG")
	ledger:SetMovable(true)
	ledger:SetClampedToScreen(true)
	ledger:EnableMouse(true)
	ledger:RegisterForDrag("LeftButton")
	ledger:SetScript("OnDragStart", ledger.StartMoving)
	ledger:SetScript("OnDragStop", ledger.StopMovingOrSizing)
	ledger:Hide()
	tinsert(UISpecialFrames, "PintsAccountantLedger")

	local title = ledger:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOP", 0, -5)
	title:SetText("|cffd4a017Pint's|r Accountant  -  Ledger")
	ledger.titleText = title

	local scope = CreateFrame("Button", nil, ledger, "UIPanelButtonTemplate")
	scope:SetSize(260, 20)
	-- long names (Forever realms) stay inside the button
	do local fs = scope:GetFontString(); if fs then fs:SetPoint("LEFT", 8, 0); fs:SetPoint("RIGHT", -8, 0); fs:SetWordWrap(false) end end
	scope:SetPoint("TOPLEFT", 14, -30)
	-- character picker: plain buttons, no Blizzard dropdown (avoids taint)
	local menu = CreateFrame("Frame", nil, ledger, "BackdropTemplate")
	menu:SetFrameStrata("FULLSCREEN_DIALOG"); menu:SetClampedToScreen(true); menu:EnableMouse(true); menu:Hide()
	menu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
	menu:SetBackdropColor(0, 0, 0, 0.95)
	menu.items = {}
	local function MenuItem(i)
		local b = menu.items[i]
		if b then return b end
		b = CreateFrame("Button", nil, menu)
		b:SetSize(210, 16); b:SetPoint("TOPLEFT", 8, -6 - (i - 1) * 16)
		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.text:SetPoint("LEFT", 4, 0)
		b.hl = b:CreateTexture(nil, "HIGHLIGHT"); b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 0.82, 0, 0.18)
		b:SetScript("OnClick", function(self) viewScope = self.key; menu:Hide(); PA:RefreshLedger() end)
		menu.items[i] = b
		return b
	end
	local function OpenMenu()
		local list = {}
		for key, c in pairs(db.chars) do if key ~= charKey then list[#list + 1] = { key = key, c = c } end end
		table.sort(list, function(a, b) return a.key < b.key end)
		table.insert(list, 1, { key = charKey, c = char, me = true })
		table.insert(list, 1, { key = "account", all = true })
		local cur = viewScope or charKey
		for i, e in ipairs(list) do
			local b = MenuItem(i)
			b.key = e.key
			local label = e.all and "|cffffd100All characters|r" or ClassName(e.key, e.c and e.c.class) .. (e.me and "  |cff888888(you)|r" or "")
			b.text:SetText((e.key == cur and "|cff40ff40>|r " or "   ") .. label)
			b:Show()
		end
		for i = #list + 1, #menu.items do menu.items[i]:Hide() end
		menu:SetSize(226, #list * 16 + 12)
		menu:ClearAllPoints(); menu:SetPoint("TOPLEFT", scope, "BOTTOMLEFT", 0, -2)
		menu:Show()
	end
	scope:SetScript("OnClick", function() if menu:IsShown() then menu:Hide() else OpenMenu() end end)
	ledger:HookScript("OnHide", function() menu:Hide() end)
	scope:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Choose a character, or All characters")
		GameTooltip:AddLine("The Session column only has numbers for the character you're playing.", 1, 1, 1, true); GameTooltip:Show()
	end)
	scope:SetScript("OnLeave", function() GameTooltip:Hide() end)
	ledger.scopeBtn = scope

	-- tabs: Gold, then one per currency (WoW Forever)
	ledger.tabs = {}
	local function Tab(i)
		local t = ledger.tabs[i]
		if t then return t end
		t = CreateFrame("Button", nil, ledger, "UIPanelButtonTemplate")
		t:SetSize(128, 20); t:SetPoint("LEFT", scope, "RIGHT", 10 + (i - 1) * 132, 0)
		t:SetScript("OnClick", function(self) curView = self.cname; PA:RefreshLedger() end)
		ledger.tabs[i] = t
		return t
	end
	function PA:UpdateTabs()
		local names = {}
		for n in pairs(db.currencies or {}) do names[#names + 1] = n end
		table.sort(names, function(a, b)
			local pa, pb = a == "Merchant's Favor" and 0 or a:find("Honor") and 1 or 2, b == "Merchant's Favor" and 0 or b:find("Honor") and 1 or 2
			if pa ~= pb then return pa < pb end
			return a < b
		end)
		curView = nil
		local n = 0
		if false then        -- (currencies now sit at the bottom of the gold ledger instead of a tab each)
			n = 1; local g = Tab(1); g.cname = nil
			g:SetText((curView == nil and "|cff40ff40" or "") .. "Gold|r"); g:Show()
			for _, name in ipairs(names) do
				if n >= 4 then break end     -- (Gold and three currencies fit)
				n = n + 1
				local t = Tab(n); t.cname = name
				local k = db.currencies[name]
				local label = (k and k.icon and ("|T" .. k.icon .. ":14:14:0:0|t ") or "") .. name
				t:SetText((curView == name and "|cff40ff40" or "") .. label .. "|r"); t:Show()
			end
		end
		for i = n + 1, #ledger.tabs do ledger.tabs[i]:Hide() end
		-- with tabs along the top, the session net moves up into the title bar
		ledger.net:ClearAllPoints()
		if n > 0 then ledger.net:SetPoint("TOPLEFT", 12, -6) else ledger.net:SetPoint("TOPRIGHT", -18, -34) end
	end

	ledger.net = ledger:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ledger.net:SetPoint("TOPRIGHT", -18, -34)

	-- column headings (fixed above the scrolling sheet)
	local head = CreateFrame("Frame", nil, ledger)
	head:SetSize(SHEET_W, 20); head:SetPoint("TOPLEFT", 14, -56)
	local hb = head:CreateTexture(nil, "BACKGROUND"); hb:SetAllPoints(); hb:SetColorTexture(1, 0.82, 0, 0.18)
	local hl = head:CreateTexture(nil, "BORDER"); hl:SetHeight(1); hl:SetPoint("BOTTOMLEFT"); hl:SetPoint("BOTTOMRIGHT"); hl:SetColorTexture(1, 0.82, 0, 0.6)
	local ct = head:CreateFontString(nil, "OVERLAY", "PintsAccountantHeadFont"); ct:SetPoint("LEFT", 6, 0); ct:SetText("Category")
	for c, p in ipairs(PERIODS) do
		local fs = head:CreateFontString(nil, "OVERLAY", "PintsAccountantHeadFont")
		fs:SetPoint("RIGHT", head, "LEFT", CAT_W + c * COL_W - 6, 0); fs:SetText(p.label == "All" and "All time" or p.label)
	end

	local sf = CreateFrame("ScrollFrame", "PintsAccountantScroll", ledger, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 14, -78)
	sf:SetPoint("BOTTOMRIGHT", -36, 12)
	sheet = CreateFrame("Frame", nil, sf)
	sheet:SetSize(SHEET_W, 1)
	sf:SetScrollChild(sheet)
	-- column rules down the sheet
	for c = 0, NCOL do
		local x = CAT_W + c * COL_W
		local v = ledger:CreateTexture(nil, "ARTWORK"); v:SetWidth(1)
		v:SetPoint("TOPLEFT", head, "TOPLEFT", x, 0); v:SetPoint("BOTTOMLEFT", ledger, "BOTTOMLEFT", 14 + x, 12)
		v:SetColorTexture(1, 1, 1, c == 0 and 0.18 or 0.08)
	end

	ledger:SetScript("OnShow", function() PA:RefreshLedger() end)
	-- keep the session figures ticking while it's open
	local t = 0
	ledger:SetScript("OnUpdate", function(_, el) t = t + el; if t > 5 then t = 0; PA:RefreshLedger() end end)
end

---------------------------------------------------------------------------
-- Options window
---------------------------------------------------------------------------
local options

local function CreateOptions()
	options = CreateFrame("Frame", "PintsAccountantOptions", UIParent, "BasicFrameTemplateWithInset")
	options:SetSize(240, 244)
	options:SetPoint("CENTER", 0, 120)
	options:SetFrameStrata("DIALOG")
	options:SetMovable(true)
	options:EnableMouse(true)
	options:RegisterForDrag("LeftButton")
	options:SetScript("OnDragStart", options.StartMoving)
	options:SetScript("OnDragStop", options.StopMovingOrSizing)
	options:Hide()
	tinsert(UISpecialFrames, "PintsAccountantOptions")

	local title = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOP", 0, -5)
	title:SetText("Accountant Options")

	local function Check(label, key, x, y)
		local cb = CreateFrame("CheckButton", nil, options, "UICheckButtonTemplate")
		cb:SetSize(24, 24)
		cb:SetPoint("TOPLEFT", x, y)
		local t = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		t:SetPoint("LEFT", cb, "RIGHT", 2, 0)
		t:SetText(label)
		cb:SetScript("OnShow", function(self) self:SetChecked(db[key]) end)
		cb:SetScript("OnClick", function(self)
			db[key] = self:GetChecked() and true or false
			PA:UpdateDisplay()
		end)
	end

	Check("Show gold on screen", "showDisplay", 14, -32)
	Check("Character gold", "dispChar", 34, -58)
	Check("Account gold", "dispAccount", 34, -82)
	Check("Session gain / loss", "dispSession", 34, -106)
	Check("Currencies (Merchant's Favor...)", "dispCur", 34, -130)
	Check("Lock position", "dispLock", 34, -154)

	local reset = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
	reset:SetSize(120, 22)
	reset:SetPoint("BOTTOM", 0, 16)
	reset:SetText("Reset session")
	reset:SetScript("OnClick", function()
		session = { inc = {}, exp = {}, start = time(), cur = {} }
		PA:Refresh()
		Print("session reset.")
	end)
end

---------------------------------------------------------------------------
-- Minimal button
---------------------------------------------------------------------------
local function ButtonTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("|cffd4a017Pint's|r Accountant")
	GameTooltip:AddDoubleLine(ClassName((GetUnitName and GetUnitName("player", false) or UnitName("player")), char.class), Coin(char.money), nil, nil, nil, 1, 1, 1)
	GameTooltip:AddDoubleLine("Account", Coin(PA:AccountGold()), nil, nil, nil, 1, 1, 1)
	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine("Session earned", Coin(Total(session.inc)), nil, nil, nil, 1, 1, 1)
	GameTooltip:AddDoubleLine("Session spent", Coin(Total(session.exp)), nil, nil, nil, 1, 1, 1)
	GameTooltip:AddDoubleLine("Session net", Signed(PA:SessionNet()))
	GameTooltip:AddDoubleLine("Gold per hour", Signed(math.floor(GoldPerHour())))
	local day = PA:Summary("day", "char")
	GameTooltip:AddDoubleLine("Today (since reset)", Signed(Total(day.inc) - Total(day.exp)))
	if char.cur and next(char.cur) then
		GameTooltip:AddLine(" ")
		for n, b in pairs(char.cur) do
			local k = db.currencies and db.currencies[n]
			GameTooltip:AddDoubleLine((k and k.icon and ("|T" .. k.icon .. ":14:14:0:0|t ") or "") .. n, b.qty or 0, nil, nil, nil, 1, 1, 1)
		end
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Left-click: ledger", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Right-click: display options", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

local function CreateButton()
	local b = CreateFrame("Button", "PintsAccountantButton", UIParent)
	b:SetSize(26, 26)
	b:SetFrameStrata("MEDIUM")
	b:SetMovable(true)
	b:SetClampedToScreen(true)
	b:RegisterForDrag("LeftButton")
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture("Interface\\Icons\\INV_Misc_Note_02")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

	local p = db.btnPos
	if p then b:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else b:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -292, 140) end

	b:SetScript("OnDragStart", function(self) self:StartMoving() end)
	b:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self:SetUserPlaced(false)
		SavePoint(self, "btnPos")
	end)
	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			options:SetShown(not options:IsShown())
		else
			ledger:SetShown(not ledger:IsShown())
		end
	end)
	b:SetScript("OnEnter", ButtonTooltip)
	b:SetScript("OnLeave", GameTooltip_Hide)
	-- the minimap button does the same job, so this loose square button stays hidden unless asked for (/pa button)
	b:SetShown(db.floatButton == true)
end

function PA:Refresh()
	PA:UpdateDisplay()
	PA:RefreshLedger()
end

---------------------------------------------------------------------------
-- Setup and events
---------------------------------------------------------------------------
local function InitCharacter()
	charKey = (GetUnitName and GetUnitName("player", false) or UnitName("player")) .. "-" .. GetRealmName()
	-- WoW Forever: characters saved under their first name alone (before second names were known) are cleared once
	local realm = GetRealmName()
	-- (done again as "fullNames2": the first time, Pint's Alts' old list put the first-name entries straight back)
	if charKey:sub(1, #charKey - #realm - 1):find(" ") and not (db.fullNames2 and db.fullNames2[realm]) then
		db.fullNames2 = db.fullNames2 or {}; db.fullNames2[realm] = true
		for k in pairs(db.chars) do
			local n = k:sub(1, #k - #realm - 1)
			if k:sub(-#realm - 1) == "-" .. realm and not n:find(" ") then db.chars[k] = nil end
		end
	end
	db.chars[charKey] = db.chars[charKey] or {}
	char = db.chars[charKey]
	char.allTime = char.allTime or { inc = {}, exp = {} }
	char.hours = char.hours or {}
	char.days = char.days or {}
	char.class = select(2, UnitClass("player"))
	local m = GetMoney()
	if m and m > 0 then char.money = m; char.moneyTime = time() end

	local h, d = HourNow(), DayNow()
	for hour in pairs(char.hours) do if hour <= h - 48 then char.hours[hour] = nil end end
	for day in pairs(char.days) do if day <= d - 400 then char.days[day] = nil end end
	for _, b in pairs(char.cur or {}) do
		for hour in pairs(b.hours or {}) do if hour <= h - 48 then b.hours[hour] = nil end end
		for day in pairs(b.days or {}) do if day <= d - 400 then b.days[day] = nil end end
	end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON then return end
		PintsAccountantDB = PintsAccountantDB or {}
		db = PintsAccountantDB
		db.chars = db.chars or {}
		for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
		-- "Quest costs" was folded into "Other expenses": move anything already recorded
		local function fold(t)
			local e = type(t) == "table" and t.exp
			if e and e["Quest costs"] then e["Other expenses"] = (e["Other expenses"] or 0) + e["Quest costs"]; e["Quest costs"] = nil end
		end
		for _, c in pairs(db.chars) do
			if type(c) == "table" then
				fold(c.allTime)
				for _, k in ipairs({ "hours", "days" }) do if type(c[k]) == "table" then for _, t in pairs(c[k]) do fold(t) end end end
			end
		end
		self:UnregisterEvent("ADDON_LOADED")
		self:RegisterEvent("PLAYER_LOGIN")
	elseif event == "PLAYER_LOGIN" then
		InitCharacter()
		lastMoney = GetMoney()
		pcall(PA.SeedFromLedger, PA)
		pcall(PA.SeedFromDataStore, PA)   -- Altoholic, if it's ever installed again
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		SetupHooks()
		CreateDisplay()
		CreateLedger()
		CreateOptions()
		CreateButton()
		PA:UpdateDisplay()
		for e in pairs(OPEN_EVENTS) do pcall(self.RegisterEvent, self, e) end
		for e in pairs(CLOSE_EVENTS) do pcall(self.RegisterEvent, self, e) end
		if HAS_CUR then
			pcall(Learn)
			pcall(OnCurrencyChanged, nil, true)      -- (takes each currency's amount at login; nothing is recorded)
			pcall(self.RegisterEvent, self, "CURRENCY_DISPLAY_UPDATE")
		end
		for _, e in ipairs({ "PLAYER_MONEY", "CHAT_MSG_MONEY", "QUEST_TURNED_IN", "CONFIRM_TALENT_WIPE",
			"PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "PLAYER_LOGOUT" }) do
			pcall(self.RegisterEvent, self, e)
		end
	elseif event == "PLAYER_MONEY" then
		OnMoneyChanged()
	elseif event == "CHAT_MSG_MONEY" then
		Pulse("loot", 2)
	elseif event == "QUEST_TURNED_IN" then
		AddPending("inc", "Quest rewards")
		Pulse("quest", 3)
	elseif event == "CURRENCY_DISPLAY_UPDATE" then
		local id = ...
		if type(id) == "number" and not (db.currencies and next(db.currencies)) then pcall(Learn) end
		OnCurrencyChanged(type(id) == "number" and id or nil)
	elseif event == "CONFIRM_TALENT_WIPE" then
		Pulse("talent", 60)
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
		local ctx = INTERACTION[...]
		if ctx then Open(ctx) end
		if ctx == "trainer" then trainerIsProfession = IsTradeskillTrainer and IsTradeskillTrainer() or false end
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
		local ctx = INTERACTION[...]
		if ctx then Close(ctx) end
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- gold can read 0 very early at login; take it once the world is loaded (without counting it as income)
		local m = GetMoney()
		if m and m > 0 then
			if not lastMoney or lastMoney == 0 then lastMoney = m end
			char.money = m; char.moneyTime = time()
		end
		PA:UpdateDisplay()
	elseif event == "PLAYER_LOGOUT" then
		-- the game can report 0 gold while logging out; only keep a real value
		local m = GetMoney()
		if m and m > 0 then char.money = m; char.moneyTime = time() end
	elseif OPEN_EVENTS[event] then
		Open(OPEN_EVENTS[event])
		if event == "TRAINER_SHOW" then trainerIsProfession = IsTradeskillTrainer and IsTradeskillTrainer() or false end
	elseif CLOSE_EVENTS[event] then
		Close(CLOSE_EVENTS[event])
	end
end)

SLASH_PINTSACCOUNTANT1 = "/pa"
SLASH_PINTSACCOUNTANT2 = "/accountant"
SlashCmdList.PINTSACCOUNTANT = function(msg)
	msg = (msg or ""):lower()
	if msg == "button" then
		db.floatButton = not db.floatButton
		if _G.PintsAccountantButton then _G.PintsAccountantButton:SetShown(db.floatButton) end
		print("|cffd4a017Pint's|r: loose button " .. (db.floatButton and "shown." or "hidden - use the minimap button."))
	elseif msg == "options" then
		options:SetShown(not options:IsShown())
	elseif msg == "reset" then
		db.btnPos, db.dispPos = nil, nil
		Print("button and display positions reset (after /reload).")
	elseif msg:match("^forget ") then
		local key = msg:match("^forget (.+)$")
		for k in pairs(db.chars) do
			if k:lower() == key and k ~= charKey then
				db.chars[k] = nil
				Print("removed " .. k .. ".")
				PA:Refresh()
				return
			end
		end
		Print("no other character named " .. key .. " (use Name-Realm).")
	else
		ledger:SetShown(not ledger:IsShown())
	end
end

---------------------------------------------------------------------------
-- Minimap button (LibDBIcon when present, otherwise a draggable button)
--   Left-click: gold ledger   Right-click: options
--   /pa minimap  -  show or hide the button
---------------------------------------------------------------------------
do
	local NAME, ICON, ANGLE = "PintsAccountant", "Interface\\AddOns\\PintsAccountant\\Icon", 240
	local btn
	local function Store()
		PintsAccountantDB = PintsAccountantDB or {}
		PintsAccountantDB.minimap = PintsAccountantDB.minimap or {}
		return PintsAccountantDB.minimap
	end
	local function Tip(tt)
		tt:AddLine("Pint's Accountant")
		tt:AddLine("Left-click: ledger (gold and currencies)", 1, 1, 1)
		tt:AddLine("Right-click: options", 1, 1, 1)
		tt:AddLine("Drag to move  -  /pa minimap to hide", 0.5, 0.5, 0.5)
	end
	local function Click(button)
		if button == "RightButton" then SlashCmdList.PINTSACCOUNTANT("options") else SlashCmdList.PINTSACCOUNTANT("") end
	end
	local function Build()
		local store = Store()
		local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
		local Icon = LibStub and LibStub("LibDBIcon-1.0", true)
		if LDB and Icon then
			local obj = LDB:NewDataObject(NAME, { type = "launcher", text = "Pint's Accountant", icon = ICON,
				OnClick = function(_, b) Click(b) end, OnTooltipShow = Tip })
			Icon:Register(NAME, obj, store)
			btn = { lib = Icon }
			return
		end
		local b = CreateFrame("Button", NAME .. "MinimapButton", Minimap)
		b:SetSize(31, 31); b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
		local ic = b:CreateTexture(nil, "BACKGROUND"); ic:SetTexture(ICON); ic:SetSize(20, 20); ic:SetPoint("CENTER", 0, 1)
		ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		local border = b:CreateTexture(nil, "OVERLAY"); border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
		border:SetSize(53, 53); border:SetPoint("TOPLEFT")
		local function Place()
			local a = math.rad(store.angle or ANGLE)
			b:ClearAllPoints(); b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
		end
		Place()
		b:RegisterForDrag("LeftButton")
		b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter(); local px, py = GetCursorPosition(); local s = Minimap:GetEffectiveScale()
			store.angle = math.deg(math.atan2(py / s - my, px / s - mx)); Place() end) end)
		b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
		b:SetScript("OnClick", function(_, which) Click(which) end)
		b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_LEFT"); Tip(GameTooltip); GameTooltip:Show() end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetShown(not store.hide)
		btn = b
	end
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_LOGIN")
	f:SetScript("OnEvent", function() Build() end)
	local orig = SlashCmdList.PINTSACCOUNTANT
	SlashCmdList.PINTSACCOUNTANT = function(msg)
		if (msg or ""):lower():match("^%s*minimap%s*$") then
			local store = Store()
			store.hide = not store.hide
			if btn and btn.lib then
				if store.hide then btn.lib:Hide(NAME) else btn.lib:Show(NAME) end
			elseif btn then btn:SetShown(not store.hide) end
			print("|cffd4a017Pint's|r Accountant: minimap button " .. (store.hide and "hidden" or "shown") .. ".")
			return
		end
		return orig(msg)
	end
end
