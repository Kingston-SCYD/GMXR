-- lua/vrmod/player/cl_bonescaler.lua
-- Per-playermodel bone scaling via SetBoneMatrix.
-- Gated on the same first-person test the character system uses to hide the
-- head, so mirrors, RT cameras, monitors and other players' views of us are
-- untouched. Scaling a bone scales its whole subtree by default: Source orders
-- bones parent-before-child, so a single forward pass propagates -- shrinking
-- the head now takes hair, hats and jigglebones with it.
-- Runs BEFORE boneHider.ApplyToBones so hidden bones get zeroed on top.
-- Saves to data/vrmod/bonescaler.json keyed by model path.
if SERVER then return end

vrmod = vrmod or {}
vrmod.boneScaler = vrmod.boneScaler or {}

local BS = vrmod.boneScaler
local FILE = "vrmod/bonescaler.json"
local VEC_ONE = Vector(1, 1, 1)
local CV_CHILDREN = CreateClientConVar("vrmod_bonescaler_children", "1", true, false, "Scaling a bone also scales every bone parented under it", 0, 1)

local saved = {}    -- [modelPath] = { [boneName] = scale }
local scaleIDs = {} -- [boneID] = Vector(s,s,s), resolved for current model
local hasScales     -- scaleIDs non-empty (skip empty iteration)
local curModel      -- last model we resolved for
local panelRef      -- weak ref to open DFrame
local fallbackOn    -- ManipulateBoneScale fallback currently written?

------------------------------------------------------------------------
-- Disk I/O
------------------------------------------------------------------------
local function Load()
	local raw = file.Read(FILE, "DATA")
	if raw then saved = util.JSONToTable(raw) or {} end
end

local function Save()
	if not file.IsDir("vrmod", "DATA") then file.CreateDir("vrmod") end
	file.Write(FILE, util.TableToJSON(saved, true))
end

------------------------------------------------------------------------
-- View test: true only inside our own VR eye passes.
------------------------------------------------------------------------
local function LocalEye(ply)
	local ep = EyePos()
	return (ep == g_VR.eyePosLeft or ep == g_VR.eyePosRight) and ply:GetViewEntity() == ply
end

-- ManipulateBoneScale is persistent global state, so as a fallback it can only
-- be written per draw -- left latched it leaks into every other view.
local function SetFallback(ply, on)
	if on == fallbackOn then return end
	fallbackOn = on
	local n = ply:GetBoneCount()
	local bh = vrmod.boneHider
	for id, sv in pairs(scaleIDs) do
		-- Skip bones the hider owns; it writes its own zero there.
		if id < n and not (bh and bh.IsHiddenID(id)) then ply:ManipulateBoneScale(id, on and sv or VEC_ONE) end
	end
end

------------------------------------------------------------------------
-- Resolve bone names -> IDs + scale vectors, propagating to children
------------------------------------------------------------------------
local function Resolve()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	SetFallback(ply, false)
	scaleIDs = {}
	hasScales = false
	curModel = ply:GetModel()
	local scales = saved[curModel]
	if not scales then return end
	local n = ply:GetBoneCount()
	for i = 0, n - 1 do
		local name = ply:GetBoneName(i)
		local s = name and scales[name]
		if s and s ~= 1 then
			scaleIDs[i] = Vector(s, s, s)
			hasScales = true
		end
	end
	if hasScales and CV_CHILDREN:GetBool() then
		for i = 0, n - 1 do
			if not scaleIDs[i] then
				local p = ply:GetBoneParent(i)
				-- Sharing the parent's vector is safe: it is only ever read.
				if p and p >= 0 then scaleIDs[i] = scaleIDs[p] end
			end
		end
	end
end

cvars.AddChangeCallback("vrmod_bonescaler_children", function() Resolve() end, "vrmod_bonescaler")

------------------------------------------------------------------------
-- Called by character system AFTER all SetBoneMatrix calls,
-- BEFORE boneHider.ApplyToBones.
------------------------------------------------------------------------
function BS.ApplyToBones(ply)
	if not hasScales or not LocalEye(ply) then return end
	for id, sv in pairs(scaleIDs) do
		local mat = ply:GetBoneMatrix(id)
		if mat then
			mat:Scale(sv)
			ply:SetBoneMatrix(id, mat)
		end
	end
end

------------------------------------------------------------------------
-- Public API (for settings UI)
------------------------------------------------------------------------
function BS.GetScale(boneName)
	return curModel and saved[curModel] and saved[curModel][boneName] or 1
end

function BS.SetScale(boneName, scale)
	if not curModel then return end
	if scale == 1 then
		if saved[curModel] then
			saved[curModel][boneName] = nil
			if not next(saved[curModel]) then saved[curModel] = nil end
		end
	else
		if not saved[curModel] then saved[curModel] = {} end
		saved[curModel][boneName] = scale
	end
	Save()
	Resolve()
end

function BS.ResetAll()
	if curModel then saved[curModel] = nil end
	Save()
	Resolve()
end

function BS.SetAll(scale)
	if not curModel then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	if scale == 1 then
		saved[curModel] = nil
	else
		local t = {}
		for i = 0, ply:GetBoneCount() - 1 do
			local name = ply:GetBoneName(i)
			if name and name ~= "" and name ~= "__INVALIDBONE__" then t[name] = scale end
		end
		saved[curModel] = t
	end
	Save()
	Resolve()
end

function BS.ScaledCount()
	local t = curModel and saved[curModel]
	if not t then return 0 end
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

function BS.GetCurrentModel() return curModel end

------------------------------------------------------------------------
-- Model change detection + per-draw fallback
------------------------------------------------------------------------
hook.Add("Think", "vrmod_bonescaler", function()
	local ply = LocalPlayer()
	if IsValid(ply) and ply:GetModel() ~= curModel then Resolve() end
end)

hook.Add("PrePlayerDraw", "vrmod_bonescaler", function(ply)
	if ply == LocalPlayer() then SetFallback(ply, hasScales and LocalEye(ply)) end
end)

hook.Add("VRMod_Exit", "vrmod_bonescaler", function(ply)
	if ply ~= LocalPlayer() then return end
	if IsValid(ply) then SetFallback(ply, false) end
	scaleIDs = {}
	hasScales = false
	curModel = nil
end)

------------------------------------------------------------------------
-- UI Panel
------------------------------------------------------------------------
function BS.OpenPanel()
	if IsValid(panelRef) then panelRef:MakePopup() return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	if not curModel then curModel = ply:GetModel() end

	local f = vgui.Create("DFrame")
	panelRef = f
	f:SetTitle("Bone Scaler — " .. string.GetFileFromFilename(curModel or "?"))
	f:SetSize(380, 520)
	-- Offset from centre: the settings frame is centred and every popup shares
	-- one world anchor, so centred panels stack exactly on top of each other.
	f:SetPos(ScrW() * 0.5 + 30, ScrH() * 0.5 - 260)
	f:MakePopup()
	f:SetDeleteOnClose(true)
	function f:OnClose() panelRef = nil end

	-- Top bar
	local bar = vgui.Create("DPanel", f)
	bar:Dock(TOP)
	bar:SetTall(24)
	bar.Paint = nil

	local resetBtn = vgui.Create("DButton", bar)
	resetBtn:SetText("Reset All")
	resetBtn:Dock(LEFT)
	resetBtn:SetWide(76)

	local countLbl = vgui.Create("DLabel", bar)
	countLbl:Dock(FILL)
	countLbl:DockMargin(8, 0, 0, 0)
	countLbl:SetDark(true)

	local childCb = vgui.Create("DCheckBoxLabel", f)
	childCb:Dock(TOP)
	childCb:DockMargin(4, 4, 4, 0)
	childCb:SetText("Also scale bones parented under scaled bones")
	childCb:SetDark(true)
	childCb:SetConVar("vrmod_bonescaler_children")

	-- Collect bones, sort alphabetically
	local bones = {}
	for i = 0, ply:GetBoneCount() - 1 do
		local name = ply:GetBoneName(i)
		if name and name ~= "" and name ~= "__INVALIDBONE__" then bones[#bones + 1] = name end
	end
	table.sort(bones)

	-- Scroll body
	local scroll = vgui.Create("DScrollPanel", f)
	scroll:Dock(FILL)
	scroll:DockMargin(0, 4, 0, 0)

	-- Uniform scale slider at top
	local uniformPanel = vgui.Create("DPanel", scroll)
	uniformPanel:Dock(TOP)
	uniformPanel:SetTall(36)
	uniformPanel:DockMargin(4, 0, 4, 4)
	uniformPanel.Paint = function(_, w, h)
		surface.SetDrawColor(60, 60, 60, 80)
		surface.DrawRect(0, 0, w, h)
	end

	local uniformSlider = vgui.Create("DNumSlider", uniformPanel)
	uniformSlider:Dock(FILL)
	uniformSlider:DockMargin(4, 0, 4, 0)
	uniformSlider:SetText("Uniform Scale")
	uniformSlider:SetMin(0)
	uniformSlider:SetMax(3)
	uniformSlider:SetDecimals(2)
	uniformSlider:SetValue(1)
	uniformSlider:SetDark(true)

	local sliders = {} -- [boneName] = DNumSlider
	local suppressUniform = false

	local function UpdateCount()
		countLbl:SetText(BS.ScaledCount() .. " / " .. #bones .. " scaled")
	end

	for _, name in ipairs(bones) do
		local sl = vgui.Create("DNumSlider", scroll)
		sl:Dock(TOP)
		sl:DockMargin(4, 0, 4, 0)
		sl:SetText(name)
		sl:SetMin(0)
		sl:SetMax(3)
		sl:SetDecimals(2)
		sl:SetValue(BS.GetScale(name))
		sl:SetDark(true)
		function sl:OnValueChanged(val)
			if suppressUniform then return end
			BS.SetScale(name, math.Round(val, 2))
			UpdateCount()
		end
		sliders[name] = sl
	end

	function uniformSlider:OnValueChanged(val)
		val = math.Round(val, 2)
		suppressUniform = true
		for _, name in ipairs(bones) do
			if sliders[name] then sliders[name]:SetValue(val) end
		end
		suppressUniform = false
		BS.SetAll(val)
		UpdateCount()
	end

	function resetBtn:DoClick()
		BS.ResetAll()
		suppressUniform = true
		uniformSlider:SetValue(1)
		for _, sl in pairs(sliders) do sl:SetValue(1) end
		suppressUniform = false
		UpdateCount()
	end

	UpdateCount()
end

------------------------------------------------------------------------
Load()
