-- lua/vrmod/player/sh_pose.lua
-- VRChat-style poses: play any sequence baked into your playermodel from the
-- quick menu ("Poses"), or bind `vrmod_pose <sequence>` (no arg stops).
--   IK on : the sequence is returned from CalcMainActivity and the VR rig keeps
--           overriding arms/head/fingers on top; procedural crouch eases off
--           through the existing sit-blend so it doesn't fight the anim.
--   IK off: raw playback. The rig, the HMD render shift and the crouch bends are
--           all skipped; the body plays the sequence at the player origin, facing
--           the yaw captured when the pose started.
-- cl_character / sh_character_fbt read vrmod.pose.seq / .raw (keyed by player
-- entity, no SteamID calls on the hot path) -- see patch_pose.py.
-- Cycle is derived from a shared start time, so every client lands on the same
-- frame with no per-frame networking; state only moves on pose changes.
local NET = "vrmod_pose"
-- Server toggle (Server tab). Replicated so clients hide the menu item and
-- skip the local pre-apply instead of flashing a pose the server will reject.
local cvEnabled = CreateConVar("vrmod_sv_poses", "1", {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "Allow VR players to play playermodel animations (poses)", 0, 1)

if SERVER then
	util.AddNetworkString(NET)
	local states = setmetatable({}, {__mode = "k"})

	local function Write(ply, st)
		net.Start(NET)
		net.WriteEntity(ply)
		net.WriteString(st and st.name or "")
		if not st then return end
		net.WriteBool(st.raw)
		net.WriteBool(st.loop)
		net.WriteFloat(st.speed)
		net.WriteFloat(st.cycle)
		net.WriteFloat(st.yaw)
		net.WriteFloat(st.start)
	end

	local function Stop(ply)
		states[ply] = nil
		Write(ply)
		net.Broadcast()
	end

	local function Clear(ply)
		if states[ply] then Stop(ply) end
	end

	-- 1024: fits the payload whether the limiter's third arg is bits or bytes.
	vrmod.NetReceiveLimited(NET, 10, 1024, function(_, ply)
		local name = net.ReadString()
		if name == "" then Clear(ply) return end
		local raw, loop, speed, cycle, yaw = net.ReadBool(), net.ReadBool(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
		-- x*0 ~= 0 rejects NaN and +-inf in one test. A rejected request still
		-- broadcasts a stop so the sender drops the copy it applied locally.
		if not cvEnabled:GetBool() or (speed + cycle + yaw) * 0 ~= 0 or #name > 96 or not g_VR[ply:SteamID()] or not ply:Alive() or ply:InVehicle() or ply:LookupSequence(name) < 0 then
			Stop(ply)
			return
		end

		local st = {name = name, raw = raw, loop = loop, speed = math.Clamp(speed, 0, 4), cycle = math.Clamp(cycle, 0, 1), yaw = math.NormalizeAngle(yaw), start = CurTime()}
		states[ply] = st
		Write(ply, st)
		net.SendOmit(ply)
	end)

	hook.Add("PostPlayerDeath", NET, Clear)
	hook.Add("PlayerEnteredVehicle", NET, Clear)
	hook.Add("VRMod_Exit", NET, Clear)
	-- Disabling ends every running pose (clearing keys mid-pairs is legal).
	cvars.AddChangeCallback("vrmod_sv_poses", function()
		if cvEnabled:GetBool() then return end
		for p in pairs(states) do Stop(p) end
	end, NET)

	-- Late joiners: ride the existing VR-player replay so poses land after the
	-- joins they depend on (same reliable stream, so ordering is guaranteed).
	local replay = net.Receivers.vrutil_net_requestvrplayers
	if replay then
		net.Receivers.vrutil_net_requestvrplayers = function(len, ply)
			replay(len, ply)
			for p, st in pairs(states) do
				if IsValid(p) then
					Write(p, st)
					net.Send(ply)
				end
			end
		end
	end
	return
end

------------------------------------------------------------------------
-- CLIENT
------------------------------------------------------------------------
local WEAK = {__mode = "k"}
local POSE = vrmod.pose or {seq = {}, raw = {}}
vrmod.pose = POSE
local seqs, raws = setmetatable(POSE.seq, WEAK), setmetatable(POSE.raw, WEAK)
local states = setmetatable({}, WEAK)
local ZERO_VEC, ZERO_ANG = Vector(), Angle()
local CurTime, IsValid = CurTime, IsValid
-- Bones the rig drives through ManipulateBoneAngles (crouch bends, alt head).
-- Those persist outside the bone callback, so raw playback has to zero them.
local MANIP = {"ValveBiped.Bip01_Spine", "ValveBiped.Bip01_L_Thigh", "ValveBiped.Bip01_R_Thigh", "ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_R_Calf", "ValveBiped.Bip01_L_Foot", "ValveBiped.Bip01_R_Foot", "ValveBiped.Bip01_Head1"}
local cvIK = CreateClientConVar("vrmod_pose_ik", "1", true, false, "Poses keep VR IK (arms/head tracked). 0 = play the sequence raw", 0, 1)
local cvLoop = CreateClientConVar("vrmod_pose_loop", "1", true, false, "Loop poses (0 = hold the last frame)", 0, 1)
local cvSpeed = CreateClientConVar("vrmod_pose_speed", "1", true, false, "Pose playback speed (0 = freeze on vrmod_pose_cycle)", 0, 4)
local cvCycle = CreateClientConVar("vrmod_pose_cycle", "0", true, false, "Pose start / freeze frame (0-1)", 0, 1)

local function Cycle(st)
	local c, r = st.cycle, st.rate
	if r ~= 0 then
		c = c + (CurTime() - st.start) * r
		if st.loop then c = c % 1 elseif c > 1 then c = 1 end
	end
	return c
end

-- Sequence ids are per-model, so the name is what travels; re-resolved on
-- model swaps (a shared anim set like m_anm survives the swap).
local function Resolve(ply, st)
	st.mdl = ply:GetModel()
	local seq = ply:LookupSequence(st.name)
	if seq < 0 then
		seqs[ply], raws[ply] = nil, nil
		return
	end
	local dur = ply:SequenceDuration(seq)
	st.rate = dur > 0 and st.speed / dur or 0
	seqs[ply] = seq
	if not st.raw then
		raws[ply] = nil
		return
	end
	raws[ply] = st.ang
	for i = 1, #MANIP do
		local b = ply:LookupBone(MANIP[i])
		if b then ply:ManipulateBoneAngles(b, ZERO_ANG) end
	end
end

local function UpdateAnim(ply)
	local st = states[ply]
	if not st then return end
	if ply:GetModel() ~= st.mdl then Resolve(ply, st) end
	if not seqs[ply] then return end
	ply:SetCycle(Cycle(st))
	ply:SetPlaybackRate(0)
	GAMEMODE:MouthMoveAnimation(ply)
	return true
end

local function Apply(ply, name, raw, loop, speed, cycle, yaw, start)
	if not name or name == "" or not (g_VR.net and g_VR.net[ply:SteamID()]) then
		if not states[ply] then return end
		states[ply], seqs[ply], raws[ply] = nil, nil, nil
		if not next(states) then hook.Remove("UpdateAnimation", NET) end
		return
	end

	local st = {name = name, raw = raw, loop = loop, speed = speed, cycle = cycle, start = start, ang = Angle(0, yaw, 0)}
	states[ply] = st
	Resolve(ply, st)
	hook.Add("UpdateAnimation", NET, UpdateAnim)
end

net.Receive(NET, function()
	local ply, name = net.ReadEntity(), net.ReadString()
	if not IsValid(ply) then return end
	if name == "" then return Apply(ply) end
	Apply(ply, name, net.ReadBool(), net.ReadBool(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
end)

hook.Add("VRMod_Exit", NET, function(ply)
	if IsValid(ply) then Apply(ply) end
end)

-- Applied locally at once; the server stamps its own start and relays.
local function Send(name, cycle, yaw)
	if name ~= "" and not (g_VR.active and cvEnabled:GetBool()) then return end
	local raw, loop, speed = not cvIK:GetBool(), cvLoop:GetBool(), cvSpeed:GetFloat()
	cycle, yaw = cycle or cvCycle:GetFloat(), yaw or g_VR.characterYaw or 0
	net.Start(NET)
	net.WriteString(name)
	if name ~= "" then
		net.WriteBool(raw)
		net.WriteBool(loop)
		net.WriteFloat(speed)
		net.WriteFloat(cycle)
		net.WriteFloat(yaw)
	end
	net.SendToServer()
	Apply(LocalPlayer(), name, raw, loop, speed, cycle, yaw, CurTime())
end

-- Setting changes re-send the running pose, keeping its phase and facing.
-- Debounced so a slider drag is one message, not one per tick.
local function Resend(fromCvar)
	if not states[LocalPlayer()] then return end
	timer.Create(NET, 0.15, 1, function()
		local st = states[LocalPlayer()]
		if st then Send(st.name, fromCvar and cvCycle:GetFloat() or Cycle(st), st.ang.y) end
	end)
end

cvars.AddChangeCallback("vrmod_pose_ik", function() Resend() end, NET)
cvars.AddChangeCallback("vrmod_pose_loop", function() Resend() end, NET)
cvars.AddChangeCallback("vrmod_pose_speed", function() Resend() end, NET)
cvars.AddChangeCallback("vrmod_pose_cycle", function() Resend(true) end, NET)
concommand.Add("vrmod_pose", function(_, _, args) Send(args[1] or "") end, nil, "Play a sequence on your VR playermodel (no argument stops)")

------------------------------------------------------------------------
-- Raw-mode bone callback tail (called from the rig callbacks in place of
-- the IK apply): first-person head hide + scaler/hider, same order the rig
-- uses. Local player only.
------------------------------------------------------------------------
function POSE.RawBones(ply, hb)
	if ply ~= LocalPlayer() then return end
	local ep = EyePos()
	if hb and hb >= 0 and (ep == g_VR.eyePosLeft or ep == g_VR.eyePosRight) and ply:GetViewEntity() == ply then
		local m = ply:GetBoneMatrix(hb)
		if m then
			m:Scale(ZERO_VEC)
			ply:SetBoneMatrix(hb, m)
		end
	end
	local bs, bh = vrmod.boneScaler, vrmod.boneHider
	if bs then bs.ApplyToBones(ply) end
	if bh then bh.ApplyToBones(ply) end
end

------------------------------------------------------------------------
-- Quick menu submenu
------------------------------------------------------------------------
local window
local function OpenMenu()
	if IsValid(window) then window:Remove() end
	local lp = LocalPlayer()
	local seqList = lp:GetSequenceList()
	if not seqList or not seqList[0] then return end
	window = vgui.Create("DFrame")
	window:SetSize(512, 512)
	window:SetTitle("Poses - " .. string.GetFileFromFilename(lp:GetModel()))
	window:MakePopup()
	local bar = window:Add("Panel")
	bar:Dock(TOP)
	bar:SetTall(24)
	local function Btn(fn, dock)
		local b = bar:Add("DButton")
		b:Dock(dock)
		b:DockMargin(0, 0, 4, 0)
		b:SetWide(100)
		b.DoClick = fn
		return b
	end
	local function Toggle(cv, label)
		local b
		b = Btn(function()
			cv:SetBool(not cv:GetBool())
			b:SetText(label .. (cv:GetBool() and ": ON" or ": OFF"))
		end, LEFT)
		b:SetText(label .. (cv:GetBool() and ": ON" or ": OFF"))
	end
	Toggle(cvIK, "IK")
	Toggle(cvLoop, "Loop")
	Btn(function() Send("") end, RIGHT):SetText("Stop")
	for _, s in ipairs({{"Speed", "vrmod_pose_speed", 4}, {"Frame", "vrmod_pose_cycle", 1}}) do
		local sl = window:Add("DNumSlider")
		sl:Dock(TOP)
		sl:SetText(s[1])
		sl:SetMinMax(0, s[3])
		sl:SetDecimals(2)
		sl:SetConVar(s[2])
	end
	local search = window:Add("DTextEntry")
	search:Dock(TOP)
	search:SetPlaceholderText("Search sequences...")
	local list = window:Add("DListView")
	list:Dock(FILL)
	list:SetMultiSelect(false)
	list:AddColumn("Sequence")
	list:AddColumn("Length"):SetFixedWidth(64)
	-- GetSequenceList is 0-based, so # is the last id. Lowercase + durations
	-- are built once; filtering only walks cached strings.
	local n, low, lens = #seqList, {}, {}
	for i = 0, n do
		low[i] = seqList[i]:lower()
		lens[i] = string.format("%.2fs", lp:SequenceDuration(i))
	end
	local function Fill(q)
		list:Clear()
		for i = 0, n do
			if q == "" or low[i]:find(q, 1, true) then list:AddLine(seqList[i], lens[i]) end
		end
	end
	Fill("")
	search.OnChange = function(s) Fill(s:GetValue():lower()) end
	list.OnRowSelected = function(_, _, line) Send(line:GetColumnText(1)) end
	hook.Add("VRMod_OpenQuickMenu", "vrmod_pose_close", function()
		hook.Remove("VRMod_OpenQuickMenu", "vrmod_pose_close")
		if IsValid(window) then
			window:Remove()
			return false
		end
	end)
end

-- The quick menu registry persists and upserts by name, so registration
-- order against cl_buttons doesn't matter.
local function AddMenuItem()
	if cvEnabled:GetBool() then vrmod.AddInGameMenuItem("Poses", 0, 3, OpenMenu, true) end
end

hook.Add("VRMod_Start", NET, function(ply)
	if ply == LocalPlayer() then AddMenuItem() end
end)

-- Live server toggle: the server stops running poses itself; here the item
-- (and its backup, so the restore pass can't revive it) and the window go.
cvars.AddChangeCallback("vrmod_sv_poses", function()
	if cvEnabled:GetBool() then
		if g_VR.active then AddMenuItem() end
		return
	end
	vrmod.RemoveInGameMenuItem("Poses", OpenMenu, true)
	if IsValid(window) then window:Remove() end
end, NET)