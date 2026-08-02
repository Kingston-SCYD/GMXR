-- lua/vrmod/player/cl_bonehider.lua
-- Per-playermodel bone hiding via SetBoneMatrix zero-scale.
-- Gated on the same first-person test the character system uses to hide the
-- head, so mirrors, RT cameras, monitors and other players' views of us are
-- untouched. Hiding a bone hides its whole subtree by default: Source orders
-- bones parent-before-child, so a single forward pass propagates.
-- Saves to data/vrmod/bonehider.json keyed by model path.
if SERVER then return end

vrmod = vrmod or {}
vrmod.boneHider = vrmod.boneHider or {}

local BH = vrmod.boneHider
local FILE = "vrmod/bonehider.json"
local ZERO = Vector(0, 0, 0)
local ONE = Vector(1, 1, 1)
local CV_CHILDREN = CreateClientConVar("vrmod_bonehider_children", "1", true, false, "Hiding a bone also hides every bone parented under it", 0, 1)

local saved = {}     -- [modelPath] = { [boneName] = true }
local hiddenIDs = {} -- [boneID] = true, resolved for current model (incl. subtree)
local hasHidden      -- hiddenIDs non-empty
local curModel       -- last model we resolved for
local panelRef       -- weak ref to open DFrame
local fallbackOn     -- ManipulateBoneScale fallback currently written?

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
	local n, v = ply:GetBoneCount(), on and ZERO or ONE
	for id in pairs(hiddenIDs) do
		if id < n then ply:ManipulateBoneScale(id, v) end
	end
end

------------------------------------------------------------------------
-- Resolve bone names -> IDs for current model, propagating to children
------------------------------------------------------------------------
local function Resolve()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	SetFallback(ply, false)
	hiddenIDs = {}
	hasHidden = false
	curModel = ply:GetModel()
	local hidden = saved[curModel]
	if not hidden then return end
	local n = ply:GetBoneCount()
	for i = 0, n - 1 do
		local name = ply:GetBoneName(i)
		if name and hidden[name] then
			hiddenIDs[i] = true
			hasHidden = true
		end
	end
	if hasHidden and CV_CHILDREN:GetBool() then
		for i = 0, n - 1 do
			if not hiddenIDs[i] then
				local p = ply:GetBoneParent(i)
				if p and p >= 0 and hiddenIDs[p] then hiddenIDs[i] = true end
			end
		end
	end
end

cvars.AddChangeCallback("vrmod_bonehider_children", function() Resolve() end, "vrmod_bonehider")

------------------------------------------------------------------------
-- Called by character system AFTER all SetBoneMatrix calls.
-- Zeros the scale component of hidden bone matrices so they collapse
-- regardless of ManipulateBoneScale override by SetBoneMatrix.
------------------------------------------------------------------------
function BH.ApplyToBones(ply)
	if not hasHidden or not LocalEye(ply) then return end
	for id in pairs(hiddenIDs) do
		local mat = ply:GetBoneMatrix(id)
		if mat then
			mat:Scale(ZERO)
			ply:SetBoneMatrix(id, mat)
		end
	end
end

-- Is a bone ID in the hidden set? Used by the bone scaler to avoid fighting us.
function BH.IsHiddenID(id)
	return hiddenIDs[id] == true
end

------------------------------------------------------------------------
-- Public API (for settings UI)
------------------------------------------------------------------------
function BH.IsHidden(boneName)
	return curModel and saved[curModel] and saved[curModel][boneName] == true
end

function BH.Toggle(boneName, hide)
	if not curModel then return end
	if hide then
		if not saved[curModel] then saved[curModel] = {} end
		saved[curModel][boneName] = true
	elseif saved[curModel] then
		saved[curModel][boneName] = nil
		if not next(saved[curModel]) then saved[curModel] = nil end
	end
	Save()
	Resolve()
end

function BH.ShowAll()
	if curModel then saved[curModel] = nil end
	Save()
	Resolve()
end

function BH.HideAll()
	if not curModel then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local t = {}
	for i = 0, ply:GetBoneCount() - 1 do
		local name = ply:GetBoneName(i)
		if name and name ~= "" and name ~= "__INVALIDBONE__" then t[name] = true end
	end
	saved[curModel] = t
	Save()
	Resolve()
end

function BH.HiddenCount()
	local t = curModel and saved[curModel]
	if not t then return 0 end
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

function BH.GetCurrentModel() return curModel end

------------------------------------------------------------------------
-- Model change detection + per-draw fallback
------------------------------------------------------------------------
hook.Add("Think", "vrmod_bonehider", function()
	local ply = LocalPlayer()
	if IsValid(ply) and ply:GetModel() ~= curModel then Resolve() end
end)

hook.Add("PrePlayerDraw", "vrmod_bonehider", function(ply)
	if ply == LocalPlayer() then SetFallback(ply, hasHidden and LocalEye(ply)) end
end)

hook.Add("VRMod_Exit", "vrmod_bonehider", function(ply)
	if ply ~= LocalPlayer() then return end
	if IsValid(ply) then SetFallback(ply, false) end
	hiddenIDs = {}
	hasHidden = false
	curModel = nil
end)

------------------------------------------------------------------------
-- UI Panel
------------------------------------------------------------------------
function BH.OpenPanel()
	if IsValid(panelRef) then panelRef:MakePopup() return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	if not curModel then curModel = ply:GetModel() end

	local f = vgui.Create("DFrame")
	panelRef = f
	f:SetTitle("Bone Hider — " .. string.GetFileFromFilename(curModel or "?"))
	f:SetSize(340, 480)
	-- Offset from centre: the settings frame is centred and every popup shares
	-- one world anchor, so centred panels stack exactly on top of each other.
	f:SetPos(ScrW() * 0.5 - 370, ScrH() * 0.5 - 240)
	f:MakePopup()
	f:SetDeleteOnClose(true)
	function f:OnClose() panelRef = nil end

	-- Top bar
	local bar = vgui.Create("DPanel", f)
	bar:Dock(TOP)
	bar:SetTall(24)
	bar.Paint = nil

	local showBtn = vgui.Create("DButton", bar)
	showBtn:SetText("Show All")
	showBtn:Dock(LEFT)
	showBtn:SetWide(76)

	local hideBtn = vgui.Create("DButton", bar)
	hideBtn:SetText("Hide All")
	hideBtn:Dock(LEFT)
	hideBtn:DockMargin(4, 0, 0, 0)
	hideBtn:SetWide(76)

	local countLbl = vgui.Create("DLabel", bar)
	countLbl:Dock(FILL)
	countLbl:DockMargin(8, 0, 0, 0)
	countLbl:SetDark(true)

	local childCb = vgui.Create("DCheckBoxLabel", f)
	childCb:Dock(TOP)
	childCb:DockMargin(4, 4, 4, 0)
	childCb:SetText("Also hide bones parented under hidden bones")
	childCb:SetDark(true)
	childCb:SetConVar("vrmod_bonehider_children")

	-- Scroll body
	local scroll = vgui.Create("DScrollPanel", f)
	scroll:Dock(FILL)
	scroll:DockMargin(0, 4, 0, 0)

	-- Collect bones, sort alphabetically
	local bones = {}
	for i = 0, ply:GetBoneCount() - 1 do
		local name = ply:GetBoneName(i)
		if name and name ~= "" and name ~= "__INVALIDBONE__" then bones[#bones + 1] = name end
	end
	table.sort(bones)

	local checks = {}
	local function UpdateCount()
		countLbl:SetText(BH.HiddenCount() .. " / " .. #bones .. " hidden")
	end

	for _, name in ipairs(bones) do
		local cb = vgui.Create("DCheckBoxLabel", scroll)
		cb:SetText(name)
		cb:SetDark(true)
		cb:SetChecked(BH.IsHidden(name))
		cb:Dock(TOP)
		cb:DockMargin(4, 1, 4, 0)
		function cb:OnChange(val)
			BH.Toggle(name, val)
			UpdateCount()
		end
		checks[#checks + 1] = cb
	end

	function showBtn:DoClick()
		BH.ShowAll()
		for _, cb in ipairs(checks) do cb:SetChecked(false) end
		UpdateCount()
	end

	function hideBtn:DoClick()
		BH.HideAll()
		for _, cb in ipairs(checks) do cb:SetChecked(true) end
		UpdateCount()
	end

	UpdateCount()
end

------------------------------------------------------------------------
Load()
