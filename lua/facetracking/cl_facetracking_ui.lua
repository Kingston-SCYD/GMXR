-- cl_facetracking_ui.lua
if not FaceTrack then return end

local Clamp  = math.Clamp
local floor  = math.floor
local Format = string.format
local panelRef = nil

local COL_PANEL  = Color(40, 40, 42)
local COL_ACCENT = Color(80, 160, 255)
local COL_GREEN  = Color(80, 200, 80)
local COL_RED    = Color(200, 70, 70)
local COL_ORANGE = Color(220, 160, 50)
local COL_TEXT   = Color(210, 210, 210)
local COL_DIM    = Color(130, 130, 130)
local COL_EDIT   = Color(36, 40, 50)
local COL_BAR_BG = Color(50, 50, 55)
local COL_BAR    = Color(70, 140, 230)

-- ── Settings Tab ────────────────────────────────────────────────────────────

local function BuildSettings(sheet)
	local p = vgui.Create("DPanel", sheet)
	p.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL_PANEL) end

	local sc = vgui.Create("DScrollPanel", p)
	sc:Dock(FILL)
	sc:DockMargin(6, 6, 6, 6)

	local status = vgui.Create("DLabel", sc)
	status:Dock(TOP)
	status:DockMargin(4, 4, 4, 4)
	status:SetText("Status: ---")
	status:SetTextColor(COL_DIM)
	status.Think = function(s)
		local on = FaceTrack.GetListening()
		local act = on and vrmod.FaceTrackingActive()
		if act then
			s:SetText(Format("Status: RECEIVING — %d parameters", FaceTrack.GetParamCount()))
			s:SetTextColor(COL_GREEN)
		elseif on then
			s:SetText("Status: LISTENING — no data")
			s:SetTextColor(COL_ORANGE)
		else
			s:SetText("Status: STOPPED")
			s:SetTextColor(COL_RED)
		end
	end

	local function AddCheck(label, cv)
		local c = vgui.Create("DCheckBoxLabel", sc)
		c:Dock(TOP)
		c:DockMargin(4, 6, 4, 0)
		c:SetText(label)
		c:SetConVar(cv)
		c:SetTextColor(COL_TEXT)
	end
	local function AddSlider(label, cv, lo, hi, dec)
		local s = vgui.Create("DNumSlider", sc)
		s:Dock(TOP)
		s:DockMargin(4, 4, 4, 0)
		s:SetText(label)
		s:SetMin(lo)
		s:SetMax(hi)
		s:SetDecimals(dec or 2)
		s:SetConVar(cv)
		s.Label:SetTextColor(COL_TEXT)
	end
	local function AddSpacer()
		local sp = vgui.Create("DPanel", sc)
		sp:Dock(TOP)
		sp:SetTall(10)
		sp.Paint = nil
	end

	AddCheck("Enable Face Tracking", "ft_enabled")
	AddSlider("OSC Port", "ft_port", 1024, 65535, 0)
	AddSlider("Smoothing", "ft_smooth", 0, 0.95, 2)
	AddSlider("Net Update Rate (Hz)", "ft_rate", 5, 60, 0)
	AddSpacer()
	AddSlider("Global Multiplier", "ft_multiplier", 0, 5, 2)
	AddSpacer()
	AddCheck("Show Debug HUD Overlay", "ft_debug")
	AddSlider("Debug Param Count", "ft_debug_count", 5, 50, 0)

	return p
end

-- ── Mapping Tab ─────────────────────────────────────────────────────────────

local function BuildMapping(sheet)
	local p = vgui.Create("DPanel", sheet)
	p.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL_PANEL) end

	local topBar = vgui.Create("DPanel", p)
	topBar:Dock(TOP)
	topBar:SetTall(28)
	topBar.Paint = nil

	local ms = vgui.Create("DNumSlider", topBar)
	ms:Dock(FILL)
	ms:DockMargin(4, 2, 4, 0)
	ms:SetText("Global Multiplier")
	ms:SetMin(0)
	ms:SetMax(5)
	ms:SetDecimals(2)
	ms:SetConVar("ft_multiplier")
	ms.Label:SetTextColor(COL_TEXT)

	local botBar = vgui.Create("DPanel", p)
	botBar:Dock(BOTTOM)
	botBar:SetTall(30)
	botBar.Paint = nil

	local function MkBtn(txt, w, fn)
		local b = vgui.Create("DButton", botBar)
		b:Dock(LEFT)
		b:SetWide(w)
		b:DockMargin(4, 3, 0, 3)
		b:SetText(txt)
		b.DoClick = fn
		return b
	end

	local split = vgui.Create("DPanel", p)
	split:Dock(FILL)
	split:DockMargin(4, 4, 4, 2)
	split.Paint = nil

	-- Left: flex list
	local listPanel = vgui.Create("DPanel", split)
	listPanel:Dock(LEFT)
	listPanel:SetWide(310)
	listPanel.Paint = nil

	local list = vgui.Create("DListView", listPanel)
	list:Dock(FILL)
	list:SetMultiSelect(false)
	list:AddColumn("ID"):SetFixedWidth(30)
	list:AddColumn("Flex Name"):SetFixedWidth(150)
	list:AddColumn("Status"):SetFixedWidth(60)
	list:AddColumn("Value"):SetFixedWidth(50)

	-- Right: editor
	local editPanel = vgui.Create("DPanel", split)
	editPanel:Dock(FILL)
	editPanel:DockMargin(4, 0, 0, 0)
	editPanel.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL_EDIT) end

	local editTitle = vgui.Create("DLabel", editPanel)
	editTitle:Dock(TOP)
	editTitle:DockMargin(8, 6, 8, 2)
	editTitle:SetText("Select a flex to edit")
	editTitle:SetTextColor(COL_ACCENT)
	editTitle:SetFont("DermaDefaultBold")

	local editValue = vgui.Create("DLabel", editPanel)
	editValue:Dock(TOP)
	editValue:DockMargin(8, 0, 8, 4)
	editValue:SetText("")
	editValue:SetTextColor(COL_DIM)

	local biasLabel = vgui.Create("DLabel", editPanel)
	biasLabel:Dock(TOP)
	biasLabel:DockMargin(8, 4, 8, 0)
	biasLabel:SetText("Bias (offset)")
	biasLabel:SetTextColor(COL_TEXT)

	local biasWang = vgui.Create("DNumberWang", editPanel)
	biasWang:Dock(TOP)
	biasWang:DockMargin(8, 2, 8, 4)
	biasWang:SetTall(24)
	biasWang:SetMin(-5)
	biasWang:SetMax(5)
	biasWang:SetDecimals(2)
	biasWang:SetValue(0)

	local srcHeader = vgui.Create("DLabel", editPanel)
	srcHeader:Dock(TOP)
	srcHeader:DockMargin(8, 4, 8, 0)
	srcHeader:SetText("Sources")
	srcHeader:SetTextColor(COL_TEXT)

	local srcScroll = vgui.Create("DScrollPanel", editPanel)
	srcScroll:Dock(FILL)
	srcScroll:DockMargin(4, 2, 4, 2)

	local addSrcBtn = vgui.Create("DButton", editPanel)
	addSrcBtn:Dock(BOTTOM)
	addSrcBtn:DockMargin(8, 2, 8, 6)
	addSrcBtn:SetTall(24)
	addSrcBtn:SetText("+ Add Source")

	local editFlexID = -1
	local editSources = {}
	local editBias = 0

	local function ApplyEdit()
		if editFlexID < 0 then return end
		FaceTrack.LiveUpdateFlex(editFlexID, editSources, editBias)
	end

	local function RebuildSourceRows()
		srcScroll:Clear()
		for idx, src in ipairs(editSources) do
			local row = vgui.Create("DPanel", srcScroll)
			row:Dock(TOP)
			row:SetTall(28)
			row:DockMargin(2, 2, 2, 0)
			row.Paint = nil

			local combo = vgui.Create("DComboBox", row)
			combo:Dock(LEFT)
			combo:SetWide(180)
			combo:DockMargin(0, 0, 4, 0)
			combo:SetSortItems(true)
			combo:SetValue(src.param ~= "" and src.param or "Select param...")
			for _, name in ipairs(FaceTrack.knownParams) do
				combo:AddChoice(name)
			end
			combo.OnSelect = function(_, _, val)
				src.param = val
				ApplyEdit()
			end

			local sl = vgui.Create("DLabel", row)
			sl:Dock(LEFT)
			sl:SetWide(8)

			local wang = vgui.Create("DNumberWang", row)
			wang:Dock(FILL)
			wang:DockMargin(0, 2, 4, 2)
			wang:SetMin(-10)
			wang:SetMax(10)
			wang:SetDecimals(2)
			wang:SetValue(src.scale)
			wang.OnValueChanged = function(_, val)
				src.scale = tonumber(val) or 1
				ApplyEdit()
			end

			local rm = vgui.Create("DButton", row)
			rm:Dock(RIGHT)
			rm:SetWide(24)
			rm:SetText("X")
			rm:SetTextColor(COL_RED)
			rm.DoClick = function()
				table.remove(editSources, idx)
				ApplyEdit()
				RebuildSourceRows()
			end
		end
	end

	biasWang.OnValueChanged = function(_, val)
		editBias = tonumber(val) or 0
		ApplyEdit()
	end

	addSrcBtn.DoClick = function()
		if editFlexID < 0 then return end
		editSources[#editSources + 1] = { param = "", scale = 1 }
		RebuildSourceRows()
	end

	editValue.Think = function(s)
		if editFlexID < 0 then return end
		local sm = FaceTrack.GetSmoothed()
		s:SetText(Format("Current value: %.3f", sm[editFlexID] or 0))
	end

	local lastBuildModel = ""

	local function PopulateList()
		list:Clear()
		editFlexID = -1
		editTitle:SetText("Select a flex to edit")
		editValue:SetText("")
		srcScroll:Clear()

		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		lastBuildModel = ply:GetModel()

		local map = FaceTrack.GetActiveMap() or {}
		local mapByID = {}
		for _, e in ipairs(map) do mapByID[e.id] = e end

		for i = 0, ply:GetFlexNum() - 1 do
			local name = ply:GetFlexName(i)
			local entry = mapByID[i]
			local line = list:AddLine(i, name, entry and "mapped" or "-", "0.00")
			line.flexID = i
			line.entry = entry
		end
	end

	list.Think = function(s)
		local sm = FaceTrack.GetSmoothed()
		for _, line in ipairs(s:GetLines()) do
			line:SetColumnText(4, Format("%.2f", sm[line.flexID] or 0))
		end
	end

	list.OnRowSelected = function(_, _, row)
		editFlexID = row.flexID
		local ply = LocalPlayer()
		local flexName = IsValid(ply) and ply:GetFlexName(editFlexID) or "?"
		editTitle:SetText(Format("[%d] %s", editFlexID, flexName))

		editSources = {}
		editBias = 0
		local entry = row.entry
		if entry then
			for _, src in ipairs(entry.sources) do
				editSources[#editSources + 1] = { param = src.param, scale = src.scale }
			end
			editBias = entry.bias or 0
		end
		biasWang:SetValue(editBias)
		RebuildSourceRows()
	end

	p.Think = function()
		local ply = LocalPlayer()
		if IsValid(ply) and ply:GetModel() ~= lastBuildModel then PopulateList() end
	end

	timer.Simple(0, PopulateList)

	MkBtn("Refresh", 70, PopulateList)
	MkBtn("Save Override", 100, function()
		if FaceTrack.SaveMapping() then
			Derma_Message("Mapping saved!", "FaceTrack", "OK")
		end
	end)
	MkBtn("Reset to Defaults", 110, function()
		local mdl = FaceTrack.GetLastModel()
		if mdl ~= "" then
			local name = string.match(mdl, "([^/\\]+)%.mdl$")
			if name then
				local path = "facetracking/" .. name .. ".json"
				if file.Exists(path, "DATA") then file.Delete(path) end
			end
		end
		FaceTrack.ForceResolve()
		timer.Simple(0.1, PopulateList)
	end)

	return p
end

-- ── Raw Params Tab ──────────────────────────────────────────────────────────

local function BuildParams(sheet)
	local p = vgui.Create("DPanel", sheet)
	p.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL_PANEL) end

	local search = vgui.Create("DTextEntry", p)
	search:Dock(TOP)
	search:DockMargin(4, 4, 4, 2)
	search:SetTall(24)
	search:SetPlaceholderText("Filter parameters...")

	local paramList = vgui.Create("DListView", p)
	paramList:Dock(FILL)
	paramList:DockMargin(4, 2, 4, 4)
	paramList:SetMultiSelect(false)
	paramList:AddColumn("Parameter"):SetFixedWidth(280)
	paramList:AddColumn("Value"):SetFixedWidth(80)

	local allLines = {}

	local function Rebuild()
		paramList:Clear()
		allLines = {}
		local data = FaceTrack.GetLastData()
		local sorted = {}
		for k in pairs(data) do sorted[#sorted + 1] = k end
		table.sort(sorted)
		for _, name in ipairs(sorted) do
			local line = paramList:AddLine(name, Format("%.4f", data[name] or 0))
			line.pName = name
			allLines[#allLines + 1] = line
		end
	end

	paramList.Think = function()
		local data = FaceTrack.GetLastData()
		for _, line in ipairs(allLines) do
			line:SetColumnText(2, Format("%.4f", data[line.pName] or 0))
		end
	end

	search.OnValueChange = function(_, val)
		local filt = string.lower(val)
		for _, line in ipairs(allLines) do
			line:SetVisible(filt == "" or string.find(string.lower(line.pName), filt, 1, true) ~= nil)
		end
	end

	local lastCnt = 0
	p.Think = function()
		local c = FaceTrack.GetParamCount()
		if c ~= lastCnt then lastCnt = c; Rebuild() end
	end

	local bot = vgui.Create("DPanel", p)
	bot:Dock(BOTTOM)
	bot:SetTall(30)
	bot.Paint = nil

	local rb = vgui.Create("DButton", bot)
	rb:Dock(LEFT)
	rb:SetWide(80)
	rb:DockMargin(4, 3, 0, 3)
	rb:SetText("Refresh")
	rb.DoClick = Rebuild

	local db = vgui.Create("DButton", bot)
	db:Dock(LEFT)
	db:SetWide(120)
	db:DockMargin(4, 3, 0, 3)
	db:SetText("Dump to Console")
	db.DoClick = function()
		local data = FaceTrack.GetLastData()
		local s = {}
		for k in pairs(data) do s[#s + 1] = k end
		table.sort(s)
		print("--- VRCFT Params (" .. #s .. ") ---")
		for _, k in ipairs(s) do print(Format("  %-40s %.4f", k, data[k])) end
	end

	return p
end

-- ── Standalone Frame ────────────────────────────────────────────────────────

local function OpenMenu()
	if IsValid(panelRef) then panelRef:Remove() end

	local f = vgui.Create("DFrame")
	f:SetSize(720, 550)
	f:Center()
	f:SetTitle("Face Tracking")
	f:MakePopup()
	f:SetDeleteOnClose(true)

	local sh = vgui.Create("DPropertySheet", f)
	sh:Dock(FILL)
	sh:DockMargin(4, 4, 4, 4)
	sh:AddSheet("Settings", BuildSettings(sh), "icon16/cog.png")
	sh:AddSheet("Mapping", BuildMapping(sh), "icon16/table_edit.png")
	sh:AddSheet("Raw Params", BuildParams(sh), "icon16/chart_bar.png")

	panelRef = f
end

concommand.Add("ft_menu", OpenMenu)
