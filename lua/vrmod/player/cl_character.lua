if CLIENT then
	g_VR = g_VR or {}
	g_VR.characterYaw = 0
	local convars, convarValues = vrmod.GetConvars()
	-- Discard slot for the second return of LocalToWorld/WorldToLocal. Without
	-- this declaration every `_, x = ...` below writes _G._, which breaks the
	-- many addons that treat a non-nil `_` as meaningful.
	local _
	-- Constants
	local NUM_FINGER_BONES = 30
	local ZERO_VEC = Vector()
	local ZERO_ANG = Angle()
	local VEC_ONE = Vector(1, 1, 1)
	local RIGHT_HAND_OFFSET = Angle(0, 0, 180)
	local POSE = vrmod.pose or {seq = {}, raw = {}}
	vrmod.pose = POSE
	local ANGLE_THRESHOLD = 0.01
	local POS_THRESHOLD = 0.01
	local zeroVec, zeroAng = ZERO_VEC, ZERO_ANG
	-- Body settings are per player (sh_network): a player's own convars pose
	-- their body on every client. Anything below that animates a given ply
	-- reads CharCfg(ply), never convarValues.
	local CharCfg = vrmod.CharCfg
	local function GetPlayerCharacterIK(ply) return CharCfg(ply).characterIK end
	-- Calibration also rides every frame; that copy is the freshest remote one
	local function GetPlayerEyeHeight(ply)
		if ply ~= LocalPlayer() then
			local n = g_VR.net[ply:SteamID()]
			local lf = n and n.lerpedFrame
			if lf and lf.eyeHeight then return lf.eyeHeight end
		end
		return CharCfg(ply).characterEyeHeight or 67.8
	end
	local function GetPlayerHeadToHmdDist(ply)
		if ply ~= LocalPlayer() then
			local n = g_VR.net[ply:SteamID()]
			local lf = n and n.lerpedFrame
			if lf and lf.headToHmd then return lf.headToHmd end
		end
		return CharCfg(ply).characterHeadToHmdDist or 6.3
	end
	------------------------------------------------------------------------
	-- CONVARS
	------------------------------------------------------------------------
	vrmod.AddCallbackedConvar("vrmod_charactereyeheight", "characterEyeHeight", "67.8", FCVAR_ARCHIVE, "Character eye height", 30, 100, tonumber)
	vrmod.AddCallbackedConvar("vrmod_characterheadtohmddist", "characterHeadToHmdDist", "6.3", FCVAR_ARCHIVE, "Head to HMD distance", 0, 20, tonumber)
	vrmod.AddCallbackedConvar("vrmod_characterik", "characterIK", "1", FCVAR_ARCHIVE, "Enable character IK", nil, nil, tobool)
	vrmod.AddCallbackedConvar("vrmod_armstretcher", "armStretcher", "1", FCVAR_ARCHIVE, "Enable arm stretching", nil, nil, tobool)
	vrmod.AddCallbackedConvar("vrmod_characterik_solver", "characterIKSolver", "1", FCVAR_ARCHIVE, "Character IK solver (0 = classic, 1 = Hai IK full body)", 0, 1, tonumber)
	vrmod.AddCallbackedConvar("vrmod_hik_animblend", "hikAnimBlend", "0.33", FCVAR_ARCHIVE, "Hai IK: how much the walk/idle animation moves the head (shoulders/elbows get a third)", 0, 1, tonumber)
	vrmod.AddCallbackedConvar("vrmod_hik_handblend", "hikHandBlend", "0.1", FCVAR_ARCHIVE, "Hai IK: how much the animation swings the hands (others and spectator view only)", 0, 1, tonumber)
	-- Split body yaw tuning: how much head / arms steer hips and torso.
	vrmod.AddCallbackedConvar("vrmod_yaw_hip_head", "yawHipHead", "1", FCVAR_ARCHIVE, "Hip yaw: head influence", 0, 1, tonumber)
	vrmod.AddCallbackedConvar("vrmod_yaw_hip_arms", "yawHipArms", "0.7", FCVAR_ARCHIVE, "Hip yaw: arm influence", 0, 1, tonumber)
	vrmod.AddCallbackedConvar("vrmod_yaw_torso_head", "yawTorsoHead", "0.25", FCVAR_ARCHIVE, "Torso yaw: head influence", 0, 1, tonumber)
	vrmod.AddCallbackedConvar("vrmod_yaw_torso_arms", "yawTorsoArms", "1", FCVAR_ARCHIVE, "Torso yaw: arm influence", 0, 1, tonumber)
	vrmod.AddCallbackedConvar("vrmod_lean_sens", "leanSens", "3.13", FCVAR_ARCHIVE, "Body lean from sideways head tilt: sensitivity", 0, 4, tonumber)
	vrmod.AddCallbackedConvar("vrmod_lean_sens_fwd", "leanSensFwd", "1.28", FCVAR_ARCHIVE, "Body lean from head pitch (forward/back): sensitivity", 0, 4, tonumber)
	vrmod.AddCallbackedConvar("vrmod_sitheight", "sitHeight", "31", FCVAR_ARCHIVE, "Head height above feet at/below which the sit anim plays (0 = off)", 0, 60, tonumber)
	vrmod.AddCallbackedConvar("vrmod_lieheight", "lieHeight", "20", FCVAR_ARCHIVE, "HMD height above the floor at/below which the body lies down, prone or supine (0 = off)", 0, 40, tonumber)
	vrmod.AddCallbackedConvar("vrmod_sitheadtohmddist", "sitHeadToHmdDist", "13.1", FCVAR_ARCHIVE, "HMD to body distance while sitting", 0, 20, tonumber)
	------------------------------------------------------------------------
	-- SPAWN MENU
	------------------------------------------------------------------------
	function CreateCharacterPanel(panel)
		panel:ClearControls()
		panel:SetName("VR Character Animations")
		panel:Help("Controls for VR character animations, arm stretching, and model calibration.")
		panel:ControlHelp("\n--- Animation System ---")
		local animCheckbox = panel:CheckBox("Disable Animations")
		animCheckbox:SetChecked(not GetConVar("vrmod_characterik"):GetBool())
		function animCheckbox:OnChange(val)
			RunConsoleCommand("vrmod_characterik", val and "0" or "1")
		end

		panel:Help("When checked, the player model stays in place without animations.")
		panel:CheckBox("Enable Arm Stretcher", "vrmod_armstretcher")
		panel:Help("Stretches arm bones to reach targets beyond the model's natural arm length.")
		local adv = vgui.Create("DForm", panel)
		adv:SetName("Advanced")
		adv:SetExpanded(false)
		panel:AddItem(adv)
		adv:CheckBox("Use Hai IK (full body)", "vrmod_characterik_solver")
		adv:Help("On by default. Haï~'s solver: spine, head and legs follow your head, knees bend when you crouch, learned elbow placement. Off = the classic solver. Falls back to classic on models without a full ValveBiped spine.")
		adv:NumSlider("Hai IK: Animation Blend", "vrmod_hik_animblend", 0, 1, 2)
		adv:Help("Lets the walk/idle animation move the head, and the shoulders and elbows a little. Default 0.33.")
		adv:NumSlider("Hai IK: Hand Swing", "vrmod_hik_handblend", 0, 1, 2)
		adv:Help("How much the animation swings the hands. Only other players and your spectator view see it; in your headset the hands stay on the controllers. Default 0.1.")
		adv:NumSlider("Hip Yaw: Head", "vrmod_yaw_hip_head", 0, 1, 2)
		adv:NumSlider("Hip Yaw: Arms", "vrmod_yaw_hip_arms", 0, 1, 2)
		adv:NumSlider("Torso Yaw: Head", "vrmod_yaw_torso_head", 0, 1, 2)
		adv:NumSlider("Torso Yaw: Arms", "vrmod_yaw_torso_arms", 0, 1, 2)
		adv:Help("How much head and arm direction steer the hips (legs, feet) and the torso (chest, arms). Defaults 1 / 0.7 and 0.25 / 1.")
		adv:NumSlider("Lean Sensitivity: Side", "vrmod_lean_sens", 0, 4, 2)
		adv:NumSlider("Lean Sensitivity: Forward/Back", "vrmod_lean_sens_fwd", 0, 4, 2)
		adv:Help("How little head tilt (side) or nod (forward/back) it takes to lean the body on the way down. Higher kicks in sooner. 0 turns that lean off. Defaults 3.13 / 1.28.")
		panel:ControlHelp("\n--- Model Calibration ---")
		panel:NumSlider("Eye Height", "vrmod_charactereyeheight", 30, 100, 1)
		panel:Help("Character eye height in source units. Default 67.8. Affects crouching and body position.")
		panel:NumSlider("Head to HMD Distance", "vrmod_characterheadtohmddist", 0, 20, 1)
		panel:Help("Distance from HMD to head bone. Default 6.3.")
		panel:ControlHelp("\n")
		local restoreBtn = panel:Button("Restore Defaults")
		restoreBtn.DoClick = function()
			for _, n in ipairs({"vrmod_characterik", "vrmod_armstretcher", "vrmod_characterik_solver", "vrmod_hik_animblend", "vrmod_hik_handblend", "vrmod_yaw_hip_head", "vrmod_yaw_hip_arms", "vrmod_yaw_torso_head", "vrmod_yaw_torso_arms", "vrmod_lean_sens", "vrmod_lean_sens_fwd", "vrmod_charactereyeheight", "vrmod_characterheadtohmddist"}) do
				local cv = GetConVar(n)
				if cv then RunConsoleCommand(n, cv:GetDefault()) end
			end
			chat.AddText(Color(100, 255, 100), "[VR Character] ", Color(255, 255, 255), "Settings reset to defaults!")
		end
	end

	------------------------------------------------------------------------
	-- VR MIRROR: Separate panel that appears when heightmenu is open
	------------------------------------------------------------------------
	local charIKMenuOpen = false
	local function OpenCharIKPanel()
		if charIKMenuOpen then return end
		if not VRUtilIsMenuOpen("heightmenu") then return end
		charIKMenuOpen = true
		VRUtilMenuOpen("charik", 200, 200, nil, nil, Vector(), Angle(), 0.1, true, function()
			hook.Remove("PreRender", "VRModCharIK_RenderPanel")
			hook.Remove("VRMod_Input", "VRModCharIK_PanelInput")
			charIKMenuOpen = false
		end)

		local buttons = {}
		local function rebuildButtons()
			buttons = {
				{
					x = 0,
					y = 5,
					w = 55,
					h = 35,
					text = "Eye +",
					font = "Trebuchet18",
					text_x = 27,
					text_y = 8,
					fn = function() RunConsoleCommand("vrmod_charactereyeheight", tostring(math.Clamp((convarValues.characterEyeHeight or 66.8) + 1, 30, 100))) end
				},
				{
					x = 0,
					y = 45,
					w = 55,
					h = 35,
					text = "Eye -",
					font = "Trebuchet18",
					text_x = 27,
					text_y = 8,
					fn = function() RunConsoleCommand("vrmod_charactereyeheight", tostring(math.Clamp((convarValues.characterEyeHeight or 66.8) - 1, 30, 100))) end
				},
				{
					x = 60,
					y = 5,
					w = 55,
					h = 35,
					text = "HMD +",
					font = "Trebuchet18",
					text_x = 27,
					text_y = 8,
					fn = function() RunConsoleCommand("vrmod_characterheadtohmddist", tostring(math.Clamp((convarValues.characterHeadToHmdDist or 6.3) + 0.5, 0, 20))) end
				},
				{
					x = 60,
					y = 45,
					w = 55,
					h = 35,
					text = "HMD -",
					font = "Trebuchet18",
					text_x = 27,
					text_y = 8,
					fn = function() RunConsoleCommand("vrmod_characterheadtohmddist", tostring(math.Clamp((convarValues.characterHeadToHmdDist or 6.3) - 0.5, 0, 20))) end
				},
				{
					x = 120,
					y = 5,
					w = 75,
					h = 35,
					text = "Auto\nEye",
					font = "Trebuchet18",
					text_x = 37,
					text_y = 1,
					fn = function()
						if g_VR and g_VR.tracking and g_VR.tracking.hmd and g_VR.origin then
							local h = g_VR.tracking.hmd.pos.z - g_VR.origin.z
							if g_VR.scale then h = h / g_VR.scale end
							h = math.Clamp(math.Round(h, 1), 30, 100)
							RunConsoleCommand("vrmod_charactereyeheight", tostring(h))
						end
					end
				},
				{
					x = 120,
					y = 45,
					w = 75,
					h = 35,
					text = convarValues.characterIK and "Anim: ON" or "Anim: OFF",
					font = "Trebuchet18",
					text_x = 37,
					text_y = 8,
					fn = function() RunConsoleCommand("vrmod_characterik", convarValues.characterIK and "0" or "1") end
				},
				{
					x = 0,
					y = 90,
					w = 95,
					h = 35,
					text = convarValues.armStretcher and "Stretch: ON" or "Stretch: OFF",
					font = "Trebuchet18",
					text_x = 47,
					text_y = 8,
					fn = function() RunConsoleCommand("vrmod_armstretcher", convarValues.armStretcher and "0" or "1") end
				},
				{
					x = 100,
					y = 90,
					w = 95,
					h = 35,
					text = "Defaults",
					font = "Trebuchet18",
					text_x = 47,
					text_y = 8,
					fn = function()
						RunConsoleCommand("vrmod_charactereyeheight", "66.8")
						RunConsoleCommand("vrmod_characterheadtohmddist", "6.3")
						RunConsoleCommand("vrmod_characterik", "1")
						RunConsoleCommand("vrmod_armstretcher", "0")
					end
				},
			}
		end

		rebuildButtons()
		local lastEyeH, lastHmdD, lastIK, lastStretch = -1, -1, nil, nil
		hook.Add("PreRender", "VRModCharIK_RenderPanel", function()
			if not VRUtilIsMenuOpen("charik") then return end
			-- Only redraw if values changed
			local eyeH = convarValues.characterEyeHeight or 66.8
			local hmdD = convarValues.characterHeadToHmdDist or 6.3
			local ik = convarValues.characterIK
			local stretch = convarValues.armStretcher
			if eyeH == lastEyeH and hmdD == lastHmdD and ik == lastIK and stretch == lastStretch then return end
			lastEyeH, lastHmdD, lastIK, lastStretch = eyeH, hmdD, ik, stretch
			rebuildButtons()
			VRUtilMenuRenderStart("charik")
			-- Labels
			draw.DrawText(string.format("Eye: %.1f  HMD: %.1f", eyeH, hmdD), "Trebuchet18", 3, 135, color_white, TEXT_ALIGN_LEFT)
			draw.DrawText("Character Animations", "Trebuchet18", 3, 155, Color(150, 200, 255), TEXT_ALIGN_LEFT)
			-- Buttons
			for _, btn in ipairs(buttons) do
				surface.SetDrawColor(0, 0, 0, 220)
				surface.DrawRect(btn.x, btn.y, btn.w, btn.h)
				draw.DrawText(btn.text, btn.font, btn.x + btn.text_x, btn.y + btn.text_y, color_white, TEXT_ALIGN_CENTER)
			end

			VRUtilMenuRenderEnd()
		end)

		hook.Add("VRMod_Input", "VRModCharIK_PanelInput", function(action, pressed)
			if g_VR.menuFocus ~= "charik" then return end
			if action ~= "boolean_primaryfire" or not pressed then return end
			for _, btn in ipairs(buttons) do
				if g_VR.menuCursorX > btn.x and g_VR.menuCursorX < btn.x + btn.w and g_VR.menuCursorY > btn.y and g_VR.menuCursorY < btn.y + btn.h then
					btn.fn()
					-- Force redraw
					lastEyeH = -1
				end
			end
		end)

		-- Position panel near the height menu (slightly to the right and below)
		-- The height menu positions itself dynamically; we piggyback off its transform
		hook.Add("PreDrawTranslucentRenderables", "VRModCharIK_PositionPanel", function()
			if not VRUtilIsMenuOpen("heightmenu") or not VRUtilIsMenuOpen("charik") then
				if charIKMenuOpen then VRUtilMenuClose("charik") end
				hook.Remove("PreDrawTranslucentRenderables", "VRModCharIK_PositionPanel")
				return
			end

			if g_VR.menus and g_VR.menus.heightmenu and g_VR.menus.charik then
				local hm = g_VR.menus.heightmenu
				-- Place below the height menu
				g_VR.menus.charik.pos = hm.pos + hm.ang:Up() * -20
				g_VR.menus.charik.ang = hm.ang
			end
		end)
	end

	-- Auto-open our panel when the height menu opens, auto-close when it closes
	hook.Add("Think", "VRModCharIK_WatchHeightMenu", function()
		if not g_VR or not g_VR.active then
			if charIKMenuOpen then VRUtilMenuClose("charik") end
			return
		end

		if VRUtilIsMenuOpen and VRUtilIsMenuOpen("heightmenu") then
			if not charIKMenuOpen then OpenCharIKPanel() end
		elseif charIKMenuOpen then
			VRUtilMenuClose("charik")
		end
	end)

	------------------------------------------------------------------------
	-- HAND ANGLES
	------------------------------------------------------------------------
	g_VR.zeroHandAngles = {}
	for i = 1, NUM_FINGER_BONES do
		g_VR.zeroHandAngles[i] = Angle(0, 0, 0)
	end

	g_VR.defaultOpenHandAngles = {Angle(5, 10, 0), Angle(0, -20, 5), Angle(0, -10, 0), Angle(0, -3, 1), Angle(0, -2, 0), Angle(0, -1, 0), Angle(0, 0, 0), Angle(0, -2, 0), Angle(0, -1, 0), Angle(0, 2, -1), Angle(0, -1, 0), Angle(0, 0, 0), Angle(0, 4, -1), Angle(0, 0, 0), Angle(0, 0, 0), Angle(5, -10, 0), Angle(0, -20, -5), Angle(0, -10, 0), Angle(0, 3, -1), Angle(0, -2, 0), Angle(0, -1, 0), Angle(0, 0, 0), Angle(0, -2, 0), Angle(0, -1, 0), Angle(0, -2, 1), Angle(0, -1, 0), Angle(0, 0, 0), Angle(0, -4, 1), Angle(0, 0, 0), Angle(0, 0, 0),}
	g_VR.defaultClosedHandAngles = {Angle(30, 0, 0), Angle(0, 0, 0), Angle(0, 30, 0), Angle(0, -50, -10), Angle(0, -90, 0), Angle(0, -70, 0), Angle(0, -35.8, 0), Angle(0, -80, 0), Angle(0, -70, 0), Angle(0, -26.5, 4.8), Angle(0, -70, 0), Angle(0, -70, 0), Angle(0, -30, 12.7), Angle(0, -70, 0), Angle(0, -70, 0), Angle(-30, 0, 0), Angle(0, 0, 0), Angle(0, 30, 0), Angle(0, -50, 10), Angle(0, -90, 0), Angle(0, -70, 0), Angle(0, -35.8, 0), Angle(0, -80, 0), Angle(0, -70, 0), Angle(0, -26.5, -4.8), Angle(0, -70, 0), Angle(0, -70, 0), Angle(0, -30, -12.7), Angle(0, -70, 0), Angle(0, -70, 0),}
	g_VR.openHandAngles = g_VR.defaultOpenHandAngles
	g_VR.closedHandAngles = g_VR.defaultClosedHandAngles
	----------------------------------------------------------------------------------------------------------------------------------------------------
	-- CHARACTER SYSTEM
	----------------------------------------------------------------------------------------------------------------------------------------------------
	-- {bone, twist share, lean share}. Twist sits mostly in the chest, so the
	-- lower torso and chest separate. The lean starts low (each bone's share
	-- adds to the ones below), so the torso tips from the hips and the chest
	-- ends up leaning the full amount, the lower torso less. Spine (the lumbar
	-- bone) also carries the crouch bend.
	local SPINE_CHAIN = {
		{"ValveBiped.Bip01_Spine", 0.05, 0.40},
		{"ValveBiped.Bip01_Spine1", 0.15, 0.25},
		{"ValveBiped.Bip01_Spine2", 0.35, 0.20},
		{"ValveBiped.Bip01_Spine4", 0.45, 0.15},
	}
	local cv_minsend
	local lastFrames = {}
	local characterInfo = {}
	local activePlayers = {}
	g_VR.fbtActive = g_VR.fbtActive or {} -- Per-player FBT active flag, set by sh_character_fbt.lua
	local function RecursiveBoneTable2(ent, parentbone, infotab, ordertab, notfirst)
		local bones = notfirst and ent:GetChildBones(parentbone) or {parentbone}
		for k, v in pairs(bones) do
			local n = ent:GetBoneName(v)
			local boneparent = ent:GetBoneParent(v)
			local parentmat = ent:GetBoneMatrix(boneparent)
			local childmat = ent:GetBoneMatrix(v)
			local parentpos, parentang = parentmat:GetTranslation(), parentmat:GetAngles()
			local childpos, childang = childmat:GetTranslation(), childmat:GetAngles()
			local relpos, relang = WorldToLocal(childpos, childang, parentpos, parentang)
			infotab[v] = {
				name = n,
				pos = Vector(0, 0, 0),
				ang = Angle(0, 0, 0),
				parent = boneparent,
				relativePos = relpos,
				relativeAng = relang,
				offsetAng = Angle(0, 0, 0),
				targetMatrix = Matrix(),
				overrideAng = nil
			}

			ordertab[#ordertab + 1] = v
		end

		for k, v in pairs(bones) do
			RecursiveBoneTable2(ent, v, infotab, ordertab, true)
		end
	end

	-- Jigglebone compat. Driving the head with SetBoneMatrix freezes every bone
	-- parented under it, so hair, ears, hats and jiggle chains lock rigid -- the
	-- "horrors". The althead path uses ManipulateBoneAngles instead, which leaves
	-- the procedural chain running. Auto-enable it on any model with more than
	-- one bone hanging off the head rather than making people find the toggle.
	local function UseAltHead(netEntry, charinfo, cfg)
		if netEntry and netEntry.characterAltHead then return true end
		return cfg.altHeadAuto and charinfo ~= nil and (charinfo.headChildren or 0) > 1
	end

	------------------------------------------------------------------------
	-- BODY: spine twist / leans and planted, stepping feet (classic solver).
	------------------------------------------------------------------------
	-- Head-tilt lean: sideways head tilt (capped LEAN_TILT) x LEAN_K x
	-- "down" -- how far you've gone down with the head tilted (BodyRoot
	-- latches it) or how deep you're crouched, whichever is more. Standing
	-- tall and tilting your head leans nothing.
	local LEAN_TILT, LEAN_K = 35, 0.6
	local STEP_DIST, STEP_YAW, STEP_Z, STEP_TIME, STEP_LIFT, STEP_LEAD = 9, 40, 6, 0.22, 3.5, 0.6
	local spineAng, rAxis, UPV = Angle(), Vector(), Vector(0, 0, 1)
	local sqrt, sin, cos, rad, deg, atan2, NAng = math.sqrt, math.sin, math.cos, math.rad, math.deg, math.atan2, math.NormalizeAngle

	-- Turn each chain bone about body axes by its shares: twist about up,
	-- lean about forward, bend about left; the lumbar bone starts from the
	-- crouch bend. Right-hand rule: +twist turns left, +lean leans right,
	-- +bend leans forward.
	local function SpineApply(ply, ci, twist, lean, bend, crouch)
		local chain = ci.spineChain
		if not chain then return end
		if twist == 0 and lean == 0 and bend == 0 and crouch == 0 then
			if ci.spineZero then return end
			ci.spineZero = true
		else
			ci.spineZero = nil
		end
		local lumbar = ci.bones.b_spine
		for i = 1, #chain do
			local c = chain[i]
			spineAng:SetUnpacked(0, c.bone == lumbar and crouch or 0, 0)
			spineAng:RotateAroundAxis(c.up, twist * c.wT)
			spineAng:RotateAroundAxis(c.fwd, lean * c.wF)
			spineAng:RotateAroundAxis(c.left, bend * c.wF)
			ply:ManipulateBoneAngles(c.bone, spineAng)
		end
	end

	-- Forward/back the same way off head pitch, past PITCH_DEAD (looking down
	-- a bit is normal) and capped at PITCH_MAX. The sensitivity sliders scale
	-- the head angle going in, so higher reaches full lean with less of it.
	-- CROUCH_DEAD: crouch depth (units) that doesn't count as "down" -- a nod
	-- dips the head that much on its own.
	local PITCH_DEAD, PITCH_MAX, CROUCH_DEAD = 12, 40, 4
	local function TiltLean(frame, ci, crouch, cv)
		local d = ci.downHold or 0
		d = crouch > d and crouch or d
		if d <= 0 then return 0, 0 end
		d = (d < 1 and d or 1) * LEAN_K
		local ha = frame.hmdAng
		local tilt = deg(math.asin(math.Clamp(-ha:Right().z, -1, 1))) * (cv.leanSens or 3.13)
		tilt = tilt > LEAN_TILT and LEAN_TILT or tilt < -LEAN_TILT and -LEAN_TILT or tilt
		local p = deg(math.asin(math.Clamp(-ha:Forward().z, -1, 1)))
		p = (p > PITCH_DEAD and p - PITCH_DEAD or p < -PITCH_DEAD and p + PITCH_DEAD or 0) * (cv.leanSensFwd or 1.28)
		p = p > PITCH_MAX and PITCH_MAX or p < -PITCH_MAX and -PITCH_MAX or p
		return tilt * d, p * d
	end

	-- Hip shift for a lean (world x, y), with L x the lean's sine as the unit:
	--   side   : against the lean x LEAN_SIDE (more than the head swing
	--            alone, so hips and feet clear it) -- sideways for the tilt,
	--            back/forward for the nod.
	--   back   : x LEAN_BACK back from where the head faces, always -- the
	--            behind-the-lean feel an aimed gun gave, now without one.
	--   assist : on top, once the hand that's further out (the gun hand,
	--            usually) is past HAND_OUT, x up to LEAN_ASSIST back from that
	--            hand (full at HAND_OUT * 2), so an aimed gun still pushes the
	--            body further behind it.
	-- Feet take FEET_FOLLOW of the whole shift.
	local LEAN_SIDE, LEAN_BACK, LEAN_ASSIST, FEET_FOLLOW, HAND_OUT = 1.3, 0.35, 0.35, 0.7, 12
	local function LeanShift(frame, side, fwd, L, hipYaw)
		if side == 0 and fwd == 0 then return 0, 0 end
		local ss, sf = sin(rad(side)) * L, sin(rad(fwd)) * L
		local yr = rad(hipYaw)
		local c, s = cos(yr), sin(yr)
		-- left of the hips is (-s, c), forward (c, s)
		local x, y = (-s * ss - c * sf) * LEAN_SIDE, (c * ss - s * sf) * LEAN_SIDE
		-- facing: the head's forward, flattened (the hips' if it's near vertical)
		local hf = frame.hmdAng:Forward()
		local fx, fy = hf.x, hf.y
		local fl = fx * fx + fy * fy
		if fl < 0.04 then
			fx, fy, fl = c, s, 1
		else
			fl = sqrt(fl)
		end
		local mag = sqrt(ss * ss + sf * sf)
		local b = mag * LEAN_BACK / fl
		x, y = x - fx * b, y - fy * b
		local hp, l, r = frame.hmdPos, frame.lefthandPos, frame.righthandPos
		local hx, hy = l.x - hp.x, l.y - hp.y
		local rx, ry = r.x - hp.x, r.y - hp.y
		local hl, rl = hx * hx + hy * hy, rx * rx + ry * ry
		if rl > hl then hx, hy, hl = rx, ry, rl end
		hl = sqrt(hl)
		local a = (hl - HAND_OUT) / HAND_OUT
		if a <= 0 then return x, y end
		b = mag * LEAN_ASSIST * (a < 1 and a or 1) / hl
		return x - hx * b, y - hy * b
	end

	-- Look-down view clearance (local player). Looking down at yourself put
	-- the camera inside the chest: the body sits right under the head, and
	-- the model's chest reaches further forward than yours. Past VIEW_P0 of
	-- pitch the whole body (and the head it hangs from) slides back along
	-- the HIPS' facing, VIEW_BACK units by VIEW_P1, eased at VIEW_RATE u/s.
	-- (Along the look direction it flipped forward once you looked past
	-- vertical at yourself -- the body jumped in front of the camera.)
	-- Rigid, so nothing stretches or floats; only you get it -- others see
	-- you where you are. Stepped once per frame.
	local VIEW_BACK, VIEW_P0, VIEW_P1, VIEW_RATE = 7, 25, 70, 30
	local function ViewBack(frame, info)
		local fn = FrameNumber()
		if info.viewF ~= fn then
			info.viewF = fn
			local p = deg(math.asin(math.Clamp(-frame.hmdAng:Forward().z, -1, 1)))
			p = p > VIEW_P0 and (p - VIEW_P0) / (VIEW_P1 - VIEW_P0) or 0
			info.viewK = math.Approach(info.viewK or 0, (p < 1 and p or 1) * VIEW_BACK, RealFrameTime() * VIEW_RATE)
		end
		local k = info.viewK or 0
		if k == 0 then return 0, 0 end
		local yr = rad(frame.characterYaw - (frame.yawTwist or 0) * 0.5)
		return -cos(yr) * k, -sin(yr) * k
	end

	------------------------------------------------------------------------
	-- FEET. Both solvers plant the feet and step them (StepFeet) toward a
	-- "home" built from the animated feet (StanceHomes):
	--   stance blend : the weapon stance's feet when the gun points ahead,
	--                  the unarmed idle's feet (measured at init) as it points
	--                  at the floor -- by the gun hand's pitch, smoothly
	--                  (BodyRoot's stanceW). No weapon, both are the same.
	--   legs back    : the stance's feet line pulled back to sit under the
	--                  hips the way the plain stand's does (both measured off
	--                  their own pelvis) x LEGS_BACK, so the torso isn't left
	--                  behind the legs.
	-- A foot holds its world spot and yaw until its home is STEP_DIST /
	-- STEP_YAW / STEP_Z away (summed), then steps there over STEP_TIME with a
	-- STEP_LIFT arc, one at a time -- instead of snapping with every change of
	-- home. w blends planted (1) and home (0): stick walking, airborne,
	-- sitting and lying fade to home, and the plants keep syncing to it.
	------------------------------------------------------------------------
	local LEGS_BACK = 1
	-- Both corrections are for standing: walking (ci.moveW) keeps the walk
	-- cycle's own feet.
	local function StanceHomes(ci, H, ws, P, F1, A1, F2, A2, rpos, rang)
		local nf = ci.neutralFeet
		local h1, h2 = H[1], H[2]
		h1.x, h1.y, h1.z, h1.a = F1.x, F1.y, F1.z, A1
		h2.x, h2.y, h2.z, h2.a = F2.x, F2.y, F2.z, A2
		if not nf or not P then return end
		local f = rang:Forward()
		local fx, fy = f.x, f.y
		local fl = sqrt(fx * fx + fy * fy)
		if fl < 1e-3 then return end
		fx, fy = fx / fl, fy / fl
		local n1, na1 = LocalToWorld(nf.p[1], nf.a[1], rpos, rang)
		local n2, na2 = LocalToWorld(nf.p[2], nf.a[2], rpos, rang)
		local np = LocalToWorld(nf.pelvis, zeroAng, rpos, rang)
		-- fore/aft of each pose's feet line off its own pelvis
		local nm = ((n1.x + n2.x) * 0.5 - np.x) * fx + ((n1.y + n2.y) * 0.5 - np.y) * fy
		local sm = ((F1.x + F2.x) * 0.5 - P.x) * fx + ((F1.y + F2.y) * 0.5 - P.y) * fy
		local still = 1 - (ci.moveW or 0)
		local back = (sm - nm) * LEGS_BACK * still
		back = back > 0 and back or 0
		-- the plain stand's feet under the actual hips
		local ox, oy = P.x - np.x, P.y - np.y
		local k = (1 - ws) * still
		h1.x = F1.x - fx * back + (n1.x + ox - F1.x + fx * back) * k
		h1.y = F1.y - fy * back + (n1.y + oy - F1.y + fy * back) * k
		h1.z = F1.z + (n1.z - F1.z) * k
		h2.x = F2.x - fx * back + (n2.x + ox - F2.x + fx * back) * k
		h2.y = F2.y - fy * back + (n2.y + oy - F2.y + fy * back) * k
		h2.z = F2.z + (n2.z - F2.z) * k
		if k > 0 then
			h1.a, h2.a = LerpAngle(ws, na1, A1), LerpAngle(ws, na2, A2)
		end
	end

	-- Physical feet (sv_physhands' foot props), local player only: record
	-- where the solve WANTS foot i (1 left, 2 right), as the hand pose does
	-- for the hands -- a pose whose forward is foot -> toe and whose position
	-- sits DEFAULT_OFFSET behind the ball of the foot (60% foot -> toe), since
	-- the hand step puts its sphere that far forward of the pose. Sent once a
	-- frame (SendFootPose). F / X: animated foot / toe position (X may be nil).
	local function FootPhys(i, x, y, z, F, X, hipYaw)
		local fp = g_VR.footPose
		if not fp then
			fp = {Vector(), Angle(), Vector(), Angle()}
			g_VR.footPose = fp
		end
		local dx, dy, dz
		if X then
			dx, dy, dz = X.x - F.x, X.y - F.y, X.z - F.z
		else
			local r = rad(hipYaw or 0)
			dx, dy, dz = cos(r) * 5, sin(r) * 5, 0
		end
		local l = sqrt(dx * dx + dy * dy + dz * dz)
		local off = vrmod.DEFAULT_OFFSET or 0
		local k = l > 0.01 and off / l or 0
		local p, a = fp[2 * i - 1], fp[2 * i]
		p:SetUnpacked(x + dx * (0.6 - k), y + dy * (0.6 - k), z + dz * (0.6 - k))
		a:Set(Vector(dx, dy, dz):Angle())
		fp.f = FrameNumber()
		return x, y, z
	end

	-- To sv_physhands, laid out like vrmod_hand_pose (pose pair, sequence,
	-- send clock in ms) so the server plays it back the same way. Up to 150/s.
	local footSeq, nextFoot, cvFootPhys = 0, 0, nil
	local function SendFootPose(fp)
		-- the server's switch, replicated; unknown yet: send (the server drops it)
		if not cvFootPhys then cvFootPhys = GetConVar("vrmod_foot_physics") end
		if cvFootPhys and not cvFootPhys:GetBool() then return end
		local now = SysTime()
		if now < nextFoot then return end
		nextFoot = now + 1 / 150
		net.Start("vrmod_foot_pose", true)
		net.WriteVector(fp[1])
		net.WriteAngle(fp[2])
		net.WriteVector(fp[3])
		net.WriteAngle(fp[4])
		footSeq = footSeq % 65535 + 1
		net.WriteUInt(footSeq, 16)
		net.WriteUInt(now * 1000 % 65536, 16)
		net.SendToServer()
	end

	-- Plant / step both feet toward homes H (x, y, z). Writes each L.tx/ty/tz
	-- (target) and L.dyaw (planted yaw off the hips). Returns busy.
	local function StepFeet(F, H, hipYaw, w, dt, sync)
		for i = 1, 2 do
			local L, m = F[i], H[i]
			if not L.px or sync or w < 0.02 then L.px, L.py, L.pz, L.pyaw, L.s = m.x, m.y, m.z, hipYaw, nil end
		end
		if dt > 0 then
			local busy
			for i = 1, 2 do
				local L, m = F[i], H[i]
				if L.s then
					L.s = L.s + dt / STEP_TIME
					if L.s >= 1 then
						L.px, L.py, L.pz, L.pyaw, L.s = m.x, m.y, m.z, hipYaw, nil
					else
						busy = true
					end
				end
			end
			if not busy and w >= 0.02 then
				local best, bi = 1, nil
				for i = 1, 2 do
					local L, m = F[i], H[i]
					local dx, dy, dz, dy2 = m.x - L.px, m.y - L.py, m.z - L.pz, NAng(hipYaw - L.pyaw)
					local e = sqrt(dx * dx + dy * dy) / STEP_DIST + (dy2 < 0 and -dy2 or dy2) / STEP_YAW + (dz < 0 and -dz or dz) / STEP_Z
					if e >= best then best, bi = e, i end
				end
				if bi then
					local L = F[bi]
					L.fx, L.fy, L.fz, L.fyaw, L.s = L.px, L.py, L.pz, L.pyaw, 0
				end
			end
		end
		for i = 1, 2 do
			local L, m = F[i], H[i]
			local px, py, pz, yaw = L.px, L.py, L.pz, L.pyaw
			local st = L.s
			if st then
				local e = st * st * (3 - 2 * st)
				px, py = L.fx + (m.x - L.fx) * e, L.fy + (m.y - L.fy) * e
				pz = L.fz + (m.z - L.fz) * e + STEP_LIFT * sin(st * 3.14159265)
				yaw = L.fyaw + NAng(hipYaw - L.fyaw) * e
			end
			L.tx, L.ty, L.tz = m.x + (px - m.x) * w, m.y + (py - m.y) * w, m.z + (pz - m.z) * w
			L.dyaw = NAng(yaw - hipYaw) * w
		end
		return F[1].s or F[2].s or w < 1
	end

	-- Rotate ang by the shortest arc taking direction a onto b (any lengths).
	local function Swing(ang, ax, ay, az, bx, by, bz)
		local cx, cy, cz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
		local cl = sqrt(cx * cx + cy * cy + cz * cz)
		if cl < 1e-6 then return end
		rAxis:SetUnpacked(cx / cl, cy / cl, cz / cl)
		ang:RotateAroundAxis(rAxis, deg(atan2(cl, ax * bx + ay * by + az * bz)))
	end

	-- Planted feet. Each foot holds its world spot and yaw until its "home"
	-- (the animated foot, back on the floor, led a little by the body's
	-- motion) is STEP_DIST / STEP_YAW / STEP_Z away -- summed, so a bit of
	-- each counts -- then steps there over STEP_TIME with a STEP_LIFT arc.
	-- One foot at a time, the worse one first. w blends planted (1) and the
	-- plain animation (0): stick walking, airborne, sitting and lying fade
	-- to the anim, and the plants keep syncing to home while they do so
	-- feet start where they stand. The legs are solved two-bone from the
	-- measured hip with the knee toward the toes; thigh and calf keep their
	-- animated twist (shortest-arc swing), the foot its animated pitch.
	local legTmp, legH = {{}, {}}, {{}, {}}
	local function SolveLegs(ply, ci, hipYaw, drop, w, dt)
		local legs = ci.legs
		if not legs or w <= 0.001 then
			ci.legOn = nil
			return
		end
		local lead = ci.legSync and 0 or STEP_TIME * STEP_LEAD * (1 - (ci.moveW or 0))
		local lx, ly = (ci.rootVX or 0) * lead, (ci.rootVY or 0) * lead
		local ll = lx * lx + ly * ly
		if ll > 100 then
			ll = 10 / sqrt(ll)
			lx, ly = lx * ll, ly * ll
		end
		for i = 1, 2 do
			local L, m = legs[i], legTmp[i]
			local mT, mC, mF = ply:GetBoneMatrix(L.thigh), ply:GetBoneMatrix(L.calf), ply:GetBoneMatrix(L.foot)
			if not (mT and mC and mF) then
				ci.legOn = nil
				return
			end
			m.mT, m.mC, m.mF, m.mX = mT, mC, mF, L.toe and ply:GetBoneMatrix(L.toe) or nil
			m.T, m.K, m.F = mT:GetTranslation(), mC:GetTranslation(), mF:GetTranslation()
			m.AF = mF:GetAngles()
		end
		local nf = ci.neutralFeet
		local mp = nf and ply:GetBoneMatrix(nf.pelvisB)
		StanceHomes(ci, legH, ci.stanceW or 1, mp and mp:GetTranslation(), legTmp[1].F, legTmp[1].AF, legTmp[2].F, legTmp[2].AF, ply:GetPos(), ply:GetRenderAngles())
		local ox, oy = lx - (ci.cbSX or 0) * (1 - FEET_FOLLOW) - (ci.viewBX or 0), ly - (ci.cbSY or 0) * (1 - FEET_FOLLOW) - (ci.viewBY or 0)
		for i = 1, 2 do
			local m = legH[i]
			m.x, m.y, m.z = m.x + ox, m.y + oy, m.z + drop
		end
		ci.legBusy = StepFeet(legs, legH, hipYaw, w, dt, ci.legSync)
		if ply == LocalPlayer() then
			for i = 1, 2 do
				local L, m = legs[i], legTmp[i]
				L.tx, L.ty, L.tz = FootPhys(i, L.tx, L.ty, L.tz, m.F, m.mX and m.mX:GetTranslation(), hipYaw)
			end
		end
		ci.plantIdle = w > 0.5
		local u, l = ci.upperLegLen, ci.lowerLegLen
		local maxD = (u + l) * 0.999
		for i = 1, 2 do
			local L, m = legs[i], legTmp[i]
			local T, K, F = m.T, m.K, m.F
			local dx, dy, dz = L.tx - T.x, L.ty - T.y, L.tz - T.z
			local D = sqrt(dx * dx + dy * dy + dz * dz)
			if D < 0.01 then dx, dy, dz, D = 0, 0, -0.01, 0.01 end
			if D > maxD then
				local k = maxD / D
				dx, dy, dz, D = dx * k, dy * k, dz * k, maxD
			end
			local nx, ny, nz = dx / D, dy / D, dz / D
			local a = (u * u - l * l + D * D) / (2 * D)
			local h = u * u - a * a
			h = h > 0 and sqrt(h) or 0
			-- Knee toward the (planted) toes, off the hip-foot line.
			local dyaw = L.dyaw
			local yr = rad(hipYaw + dyaw)
			local qx, qy = cos(yr), sin(yr)
			local dq = qx * nx + qy * ny
			qx, qy = qx - nx * dq, qy - ny * dq
			local qz = -nz * dq
			local ql = sqrt(qx * qx + qy * qy + qz * qz)
			if ql < 1e-3 then qx, qy, qz, ql = 0, 0, 1, 1 end
			h = h / ql
			local kx, ky, kz = T.x + nx * a + qx * h, T.y + ny * a + qy * h, T.z + nz * a + qz * h
			local fx, fy, fz = T.x + dx, T.y + dy, T.z + dz
			-- Thigh: swing the animated thigh onto the new knee.
			local AT, AC, AF = m.mT:GetAngles(), m.mC:GetAngles(), m.mF:GetAngles()
			local AT2 = Angle(AT)
			Swing(AT2, K.x - T.x, K.y - T.y, K.z - T.z, kx - T.x, ky - T.y, kz - T.z)
			-- Calf: carried by the thigh's swing, then swung onto the foot.
			local lc = WorldToLocal(F - K, zeroAng, zeroVec, AT)
			local wc = LocalToWorld(lc, zeroAng, zeroVec, AT2)
			local _, la = WorldToLocal(zeroVec, AC, zeroVec, AT)
			local _, AC2 = LocalToWorld(zeroVec, la, zeroVec, AT2)
			Swing(AC2, wc.x, wc.y, wc.z, fx - kx, fy - ky, fz - kz)
			-- Foot: home angle (stance / stand blend), planted yaw.
			local AF2 = Angle(legH[i].a)
			if dyaw ~= 0 then AF2:RotateAroundAxis(UPV, dyaw) end
			local mt, mc, mf = L.mT, L.mC, L.mF
			mt:Set(m.mT)
			mt:SetAngles(AT2)
			mc:Set(m.mC)
			mc:SetTranslation(Vector(kx, ky, kz))
			mc:SetAngles(AC2)
			local fp = Vector(fx, fy, fz)
			mf:Set(m.mF)
			mf:SetTranslation(fp)
			mf:SetAngles(AF2)
			local mX = m.mX
			if mX then
				local tp, ta = WorldToLocal(mX:GetTranslation(), mX:GetAngles(), F, AF)
				tp, ta = LocalToWorld(tp, ta, fp, AF2)
				local mx = L.mX
				mx:Set(mX)
				mx:SetTranslation(tp)
				mx:SetAngles(ta)
			end
			L.hasToe = mX ~= nil
		end
		ci.legOn = true
	end

	-- FBT tracker targets for a player this frame (sh_character_fbt), or nil.
	local function FbtTargets(ply, steamid)
		if not (g_VR.fbtActive and g_VR.fbtActive[steamid]) or ply:InVehicle() then return end
		return vrmod.fbt and vrmod.fbt.GetTargets(ply)
	end

	local BuildArmTargets
	local function UpdateIK(ply)
		local steamid = ply:SteamID()
		local net = g_VR.net[steamid]
		local charinfo = characterInfo[steamid]
		local boneinfo = charinfo.boneinfo
		local bones = charinfo.bones
		local frame = net.lerpedFrame
		local cfg = CharCfg(ply)
		-- Skip the IK re-solve if the frame hasn't moved past vrmod_net_minsend.
		-- minsend is now purely this visual threshold -- networking streams at
		-- full precision regardless (see sh_network / sh_frames).
		cv_minsend = cv_minsend or GetConVar("vrmod_net_minsend")
		if lastFrames[steamid] and vrmod.utils.FramesAreEqual(frame, lastFrames[steamid], cv_minsend and cv_minsend:GetFloat() or 0.1) then return end
		charinfo.hikClean, charinfo.hikBody = nil, nil
		local inVehicle = ply:InVehicle()
		-- Lying (PrePlayerDraw's lieAng) is a tilted body frame, same as a seat:
		-- the arm math goes through plyAng instead of assuming upright.
		local lieAng = not inVehicle and charinfo.lieAng or nil
		local tilted = inVehicle or lieAng ~= nil
		-- Split yaw: hips are the render frame, the torso carries the arm solve.
		local twist = frame.yawTwist or 0
		local hipYaw, torsoYaw = frame.characterYaw - twist * 0.5, frame.characterYaw + twist * 0.5
		local plyAng = inVehicle and ply:GetVehicle():GetAngles() or lieAng or Angle(0, torsoYaw, 0)
		if inVehicle then _, plyAng = LocalToWorld(zeroVec, Angle(0, 90, 0), zeroVec, plyAng) end
		-- Read per-player calibration (reactive to slider changes)
		local eyeHeight = GetPlayerEyeHeight(ply)
		-- Alt head
		if UseAltHead(net, charinfo, cfg) then
			local _, tmp2 = WorldToLocal(zeroVec, frame.hmdAng, zeroVec, lieAng or Angle(0, torsoYaw, 0))
			ply:ManipulateBoneAngles(bones.b_head, Angle(-tmp2.roll, -tmp2.pitch, tmp2.yaw))
		end

		-- Planted-feet weight (SolveLegs), stepped once per frame on real time
		-- since the last solve. The crouch below hands its leg bends over to
		-- the leg IK by the same weight.
		local drop = charinfo.verticalCrouchOffset -- what PrePlayerDraw applied
		local fnow, rnow = FrameNumber(), RealTime()
		local dt = 0
		if charinfo.legF ~= fnow then
			dt = rnow - (charinfo.legRT or rnow)
			if dt > 0.1 then dt = 0.1 end
			charinfo.legF, charinfo.legRT = fnow, rnow
			local legT = (not inVehicle and not frame.stickMoving and ply:OnGround() and not POSE.seq[ply]) and (1 - (charinfo.lieT or 0)) * (1 - (charinfo.vrSitBlend or 0)) or 0
			local lw = math.Approach(charinfo.legW or 0, legT, dt * 8)
			local lk = 1 - (charinfo.lieT or 0)
			charinfo.legW = lw < lk and lw or lk
			-- Handing back to the anim: plants ride home, so a foot left behind
			-- (or led ahead) doesn't stretch the leg mid-fade.
			charinfo.legSync = legT == 0
		end
		local legW = charinfo.legW or 0
		local crouch01, crouchBend = 0, 0

		-- Crouching
		if not inVehicle then
			-- Update spineLen if eyeHeight changed
			local spineLen = eyeHeight - charinfo.spineZ
			charinfo.spineLen = spineLen
			local headHeight = frame.hmdPos.z + (frame.hmdAng:Forward() * -3).z
			local cutAmount = math.Clamp(charinfo.preRenderPos.z + eyeHeight - headHeight, 0, 40)
			-- VR sit (paired with CalcMainActivityFunc): vrHeadH feeds the sit
			-- check; while the engine sit anim owns the pose, ease the procedural
			-- crouch to 0 so the existing spine/leg bends and render offsets relax
			-- through the same math instead of fighting the anim (~0.33s, on par
			-- with the activity crossfade).
			charinfo.vrHeadH = headHeight - charinfo.preRenderPos.z
			charinfo.vrSitBlend = math.Approach(charinfo.vrSitBlend or 0, (charinfo.vrSitting or POSE.seq[ply]) and 1 or 0, RealFrameTime() * 5)
			-- Lying unbends the squat by its height blend instead (LieUpdate).
			cutAmount = cutAmount * (1 - charinfo.vrSitBlend) * (1 - (charinfo.lieT or 0))
			crouch01 = cutAmount > CROUCH_DEAD and (cutAmount - CROUCH_DEAD) / (40 - CROUCH_DEAD) or 0
			local spineTargetLen = spineLen - cutAmount * 0.5
			local a1 = math.acos(math.Clamp(spineTargetLen / spineLen, -1, 1))
			charinfo.horizontalCrouchOffset = math.sin(a1) * spineLen
			crouchBend = math.deg(a1) -- applied on Spine by SpineApply
			charinfo.verticalCrouchOffset = cutAmount * 0.5
			local legTargetLen = charinfo.upperLegLen + charinfo.lowerLegLen - charinfo.verticalCrouchOffset * 0.8
			local cosA1 = (charinfo.upperLegLen * charinfo.upperLegLen + legTargetLen * legTargetLen - charinfo.lowerLegLen * charinfo.lowerLegLen) / (2 * charinfo.upperLegLen * legTargetLen)
			local cosA23 = (charinfo.lowerLegLen * charinfo.lowerLegLen + legTargetLen * legTargetLen - charinfo.upperLegLen * charinfo.upperLegLen) / (2 * charinfo.lowerLegLen * legTargetLen)
			local a1 = math.deg(math.acos(math.Clamp(cosA1, -1, 1)))
			local a23 = 180 - a1 - math.deg(math.acos(math.Clamp(cosA23, -1, 1)))
			if a1 ~= a1 or a23 ~= a23 then
				a1 = 0
				a23 = 180
			end

			-- Planted feet bend the knees themselves (pelvis dropped, feet on
			-- the floor); these bends fade out as they take over.
			local lk = 1 - legW
			a1, a23 = a1 * lk, 180 + (a23 - 180) * lk
			ply:ManipulateBoneAngles(bones.b_leftCalf, Angle(0, -(a23 - 180), 0))
			ply:ManipulateBoneAngles(bones.b_leftThigh, Angle(0, -a1, 0))
			ply:ManipulateBoneAngles(bones.b_rightCalf, Angle(0, -(a23 - 180), 0))
			ply:ManipulateBoneAngles(bones.b_rightThigh, Angle(0, -a1, 0))
			ply:ManipulateBoneAngles(bones.b_leftFoot, Angle(0, -a1, 0))
			ply:ManipulateBoneAngles(bones.b_rightFoot, Angle(0, -a1, 0))
		else
			ply:ManipulateBoneAngles(bones.b_leftCalf, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_leftThigh, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_rightCalf, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_rightThigh, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_leftFoot, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_rightFoot, Angle(0, 0, 0))
		end

		-- Spine. Fades with sitting and lying, so the sit pose and the lying
		-- tip get a straight, untwisted spine.
		-- Twist: hips -> torso, mostly in the chest.
		-- Lean: head tilt and nod (TiltLean) decide where the hips go
		-- (LeanShift: against the lean, back from the hands); the spine bends over
		-- the shift the hips actually have (BodyRoot eases it), using the
		-- MEASURED hip-to-head length, so the head stays on the HMD.
		if charinfo.spineChain then
			local keep = 1 - (charinfo.lieT or 0)
			local live = (1 - (charinfo.vrSitBlend or 0)) * keep
			local lean, cbx, cby, side, bend = 0, 0, 0, 0, 0
			local mh, ms = ply:GetBoneMatrix(bones.b_head), ply:GetBoneMatrix(bones.b_spine)
			if not inVehicle and mh and ms then
				local L = mh:GetTranslation():Distance(ms:GetTranslation())
				if live > 0 then
					local lf
					lean, lf = TiltLean(frame, charinfo, crouch01, cfg)
					lean, lf = lean * live, lf * live
					charinfo.leanFwd = lf
					cbx, cby = LeanShift(frame, lean, lf, L, hipYaw)
				end
				-- reach for the lean-over: horizontal room a spine this long has
				-- from the hips up to the head
				local dzr = frame.hmdPos.z - ms:GetTranslation().z
				charinfo.leanReach = dzr < L and (dzr > 0 and math.sqrt(L * L - dzr * dzr) or L) or 0
				local ox, oy = (charinfo.cbSX or 0) + (charinfo.overX or 0), (charinfo.cbSY or 0) + (charinfo.overY or 0)
				if L > 1 and (ox ~= 0 or oy ~= 0) then
					local yr = rad(hipYaw)
					local c, s = cos(yr), sin(yr)
					-- hips right of / behind the head -> lean left / bend forward
					side = deg(math.asin(math.Clamp(-(ox * s - oy * c) / L, -1, 1))) * keep
					bend = deg(math.asin(math.Clamp(-(ox * c + oy * s) / L, -1, 1))) * keep
				end
			end
			local d = lean - (charinfo.leanT or 0)
			charinfo.leanBusy = d * d > 0.04
			charinfo.leanT, charinfo.cbX, charinfo.cbY = lean, cbx, cby
			SpineApply(ply, charinfo, inVehicle and 0 or twist * keep, side, bend, crouchBend)
		end

		--****************** ARM PROCESSING ******************
		local function ProcessArm(side)
			local isLeft = side == "left"
			local prefix = isLeft and "L_" or "R_"
			local targetPos = isLeft and frame.lefthandPos or frame.righthandPos
			local targetAng = isLeft and frame.lefthandAng or frame.righthandAng
			local clavicleBone = isLeft and bones.b_leftClavicle or bones.b_rightClavicle
			local upperarmBone = isLeft and bones.b_leftUpperarm or bones.b_rightUpperarm
			local mtx = ply:GetBoneMatrix(clavicleBone)
			local claviclePos = mtx and mtx:GetTranslation() or Vector()
			charinfo[prefix .. "ClaviclePos"] = claviclePos
			local tmp1 = claviclePos + plyAng:Right() * (isLeft and -charinfo.clavicleLen or charinfo.clavicleLen)
			local tmp2 = tmp1 + (targetPos - tmp1) * 0.15
			local clavicleTargetAng
			if not tilted then
				clavicleTargetAng = (tmp2 - claviclePos):Angle()
			else
				_, clavicleTargetAng = LocalToWorld(Vector(), WorldToLocal(tmp2 - claviclePos, zeroAng, zeroVec, plyAng):Angle(), zeroVec, plyAng)
			end

			clavicleTargetAng:RotateAroundAxis(clavicleTargetAng:Forward(), 90)
			local upperarmPos = LocalToWorld(boneinfo[upperarmBone].relativePos, boneinfo[upperarmBone].relativeAng, claviclePos, clavicleTargetAng)
			local targetVec = targetPos - upperarmPos
			local targetVecLen = targetVec:Length()
			local targetVecAng, targetVecAngLocal
			if not tilted then
				targetVecAng = targetVec:Angle()
			else
				targetVecAngLocal = WorldToLocal(targetVec, zeroAng, zeroVec, plyAng):Angle()
				_, targetVecAng = LocalToWorld(Vector(), targetVecAngLocal, zeroVec, plyAng)
			end

			local upperarmTargetAng = Angle(targetVecAng.pitch, targetVecAng.yaw, targetVecAng.roll)
			if not isLeft then upperarmTargetAng:RotateAroundAxis(targetVec, 180) end
			local tmp
			if not tilted then
				tmp = Angle(targetVecAng.pitch, torsoYaw, isLeft and -90 or 90)
			else
				_, tmp = LocalToWorld(Vector(), Angle((targetVecAngLocal or targetVecAng).pitch, 0, isLeft and -90 or 90), zeroVec, plyAng)
			end

			local _, tang = WorldToLocal(zeroVec, tmp, zeroVec, targetVecAng)
			upperarmTargetAng:RotateAroundAxis(upperarmTargetAng:Forward(), tang.roll)
			local totalArmLen = charinfo.upperArmLen + charinfo.lowerArmLen
			local armStretchScale = 1
			local effUpper, effLower = charinfo.upperArmLen, charinfo.lowerArmLen
			if cfg.armStretcher and targetVecLen > totalArmLen * 0.98 then
				armStretchScale = targetVecLen / (totalArmLen * 0.98)
				effUpper = charinfo.upperArmLen * armStretchScale
				effLower = charinfo.lowerArmLen * armStretchScale
			end

			charinfo[prefix .. "armStretchScale"] = armStretchScale
			local a1 = math.deg(math.acos(math.Clamp((effUpper * effUpper + targetVecLen * targetVecLen - effLower * effLower) / (2 * effUpper * targetVecLen), -1, 1)))
			if a1 == a1 then upperarmTargetAng:RotateAroundAxis(upperarmTargetAng:Up(), a1) end
			local test
			if not tilted then
				test = (targetPos.z - upperarmPos.z + 20) * 1.5
			else
				test = ((targetPos - upperarmPos):Dot(plyAng:Up()) + 20) * 1.5
			end

			if test < 0 then test = 0 end
			-- Reaching forward (aiming) that swing throws the elbow out to the
			-- side -- chicken wing. Past 0.3 of forward reach it eases off, down
			-- to 15% at full reach, so the elbow hangs down under the arm.
			local tn = targetVec:GetNormalized()
			local fr = (tn:Dot(plyAng:Forward()) - 0.3) / 0.7
			local swing = (30 + test) * (fr > 0 and 1 - (fr < 1 and fr or 1) * 0.85 or 1)
			upperarmTargetAng:RotateAroundAxis(tn, (isLeft and 1 or -1) * swing)
			local forearmTargetAng = Angle(upperarmTargetAng.pitch, upperarmTargetAng.yaw, upperarmTargetAng.roll)
			local a23 = 180 - a1 - math.deg(math.acos(math.Clamp((effLower * effLower + targetVecLen * targetVecLen - effUpper * effUpper) / (2 * effLower * targetVecLen), -1, 1)))
			if a23 == a23 then forearmTargetAng:RotateAroundAxis(forearmTargetAng:Up(), 180 + a23) end
			local tmp = Angle(targetAng.pitch, targetAng.yaw, targetAng.roll - 90)
			local _, tang = WorldToLocal(zeroVec, tmp, zeroVec, forearmTargetAng)
			local wristTargetAng = Angle(forearmTargetAng.pitch, forearmTargetAng.yaw, forearmTargetAng.roll)
			wristTargetAng:RotateAroundAxis(wristTargetAng:Forward(), tang.roll)
			local ulnaTargetAng = LerpAngle(0.5, forearmTargetAng, wristTargetAng)
			return {
				clavicle = clavicleTargetAng,
				upperarm = upperarmTargetAng,
				forearm = forearmTargetAng,
				wrist = wristTargetAng,
				ulna = ulnaTargetAng,
				hand = isLeft and targetAng or targetAng + RIGHT_HAND_OFFSET,
				targetPos = targetPos,
			}
		end

		local leftArm = ProcessArm("left")
		local rightArm = ProcessArm("right")
		-- Override angles
		boneinfo[bones.b_leftClavicle].overrideAng = leftArm.clavicle
		boneinfo[bones.b_leftUpperarm].overrideAng = leftArm.upperarm
		boneinfo[bones.b_leftHand].overrideAng = leftArm.hand
		boneinfo[bones.b_rightClavicle].overrideAng = rightArm.clavicle
		boneinfo[bones.b_rightUpperarm].overrideAng = rightArm.upperarm
		boneinfo[bones.b_rightHand].overrideAng = rightArm.hand
		-- Hand position override for stretching
		charinfo.L_HandTargetPos = charinfo.L_armStretchScale ~= 1 and leftArm.targetPos or nil
		charinfo.R_HandTargetPos = charinfo.R_armStretchScale ~= 1 and rightArm.targetPos or nil
		if bones.b_leftWrist and boneinfo[bones.b_leftWrist] and bones.b_leftUlna and boneinfo[bones.b_leftUlna] then
			boneinfo[bones.b_leftForearm].overrideAng = leftArm.forearm
			boneinfo[bones.b_leftWrist].overrideAng = leftArm.wrist
			boneinfo[bones.b_leftUlna].overrideAng = leftArm.ulna
			boneinfo[bones.b_rightForearm].overrideAng = rightArm.forearm
			boneinfo[bones.b_rightWrist].overrideAng = rightArm.wrist
			boneinfo[bones.b_rightUlna].overrideAng = rightArm.ulna
		else
			boneinfo[bones.b_leftForearm].overrideAng = leftArm.ulna
			boneinfo[bones.b_rightForearm].overrideAng = rightArm.ulna
		end

		BuildArmTargets(charinfo, boneinfo, bones, frame)
		if inVehicle then charinfo.legOn = nil else SolveLegs(ply, charinfo, hipYaw, drop, legW, dt) end
		if not charinfo.legOn then charinfo.plantIdle = nil end
		-- Mid-step, mid-blend or still leaning in: solve again next frame
		-- even if the tracking frame itself doesn't move.
		lastFrames[steamid] = not (charinfo.legOn and charinfo.legBusy or charinfo.leanBusy) and vrmod.utils.CopyFrame(frame) or nil
	end

	------------------------------------------------------------------------
	-- Hai IK (cl_character_hik.lua). Same contract as UpdateIK: the arm
	-- overrides feed BuildArmTargets; in body mode the solver writes the
	-- spine, head, legs and their descendants inside this bone callback.
	-- Body mode crouches by dropping the render origin (PrePlayerDraw) and
	-- planting the animated feet back against that shift, so the knees bend
	-- instead of the classic spine/leg ManipulateBoneAngles.
	local CROUCH_BONES = {"b_spine", "b_leftThigh", "b_leftCalf", "b_leftFoot", "b_rightThigh", "b_rightCalf", "b_rightFoot"}
	local hikComp = Vector()
	local hikHoff = Vector()
	local hikH, hikFeet = {{}, {}}, {Vector(), Angle(), Vector(), Angle()}
	-- clavicle, upperarm, forearm, hand, wrist, ulna, then charinfo fields
	local HIK_KEYS = {
		{"b_leftClavicle", "b_leftUpperarm", "b_leftForearm", "b_leftHand", "b_leftWrist", "b_leftUlna", "L_ClaviclePos", "L_armStretchScale", "L_HandTargetPos"},
		{"b_rightClavicle", "b_rightUpperarm", "b_rightForearm", "b_rightHand", "b_rightWrist", "b_rightUlna", "R_ClaviclePos", "R_armStretchScale", "R_HandTargetPos"},
	}
	local function UpdateHIK(ply, h)
		local steamid = ply:SteamID()
		local net = g_VR.net[steamid]
		local charinfo = characterInfo[steamid]
		local bones = charinfo.bones
		local frame = net.lerpedFrame
		local cfg = CharCfg(ply)
		lastFrames[steamid] = nil
		if not charinfo.hikClean then
			for i = 1, #CROUCH_BONES do ply:ManipulateBoneAngles(bones[CROUCH_BONES[i]], ZERO_ANG) end
			charinfo.hikClean = true
		end
		-- Shift PrePlayerDraw applied this frame (renderPos), read before the
		-- next frame's values replace it.
		local v, hz = charinfo.verticalCrouchOffset, charinfo.horizontalCrouchOffset * 0.8
		local body, cut = false, 0
		local eyeH = GetPlayerEyeHeight(ply)
		-- FBT: always the body solve, hips and feet from the trackers; none of
		-- the crouch / lean / squat / planting that stand in for them.
		local fbtT = FbtTargets(ply, steamid)
		if fbtT then
			body = true
			charinfo.vrSitBlend, charinfo.vrSitting = 0, nil
		elseif not ply:InVehicle() then
			local headHeight = frame.hmdPos.z - frame.hmdAng:Forward().z * 3
			charinfo.vrHeadH = headHeight - charinfo.preRenderPos.z
			charinfo.vrSitBlend = math.Approach(charinfo.vrSitBlend or 0, (charinfo.vrSitting or POSE.seq[ply]) and 1 or 0, RealFrameTime() * 5)
			-- Sit anim owns the legs once it's fully in; while it crossfades in
			-- (or out) the body solve keeps the squat, easing it off by the same
			-- blend. Dropping straight to arms-only stood the body up for the
			-- crossfade before the sit pose showed. Lying keeps the body solve
			-- and the full drop: the lie blend weights this squat out of the
			-- placement and the feet plant (keep) instead of lifting the hips
			-- back up into a head that's still going down.
			body = charinfo.vrSitBlend < 1
			if body then cut = math.Clamp(charinfo.preRenderPos.z + eyeH - headHeight, 0, 40) * (1 - charinfo.vrSitBlend) end
		end
		local drop = math.min(cut, h.maxDrop)
		charinfo.verticalCrouchOffset = drop
		-- Hips back, MEASURED: with the hips down as far as the legs fold
		-- (maxDrop), the height the head still has to lose comes off by
		-- leaning the spine forward over the knees -- the hips go back by
		-- however far a near-straight hip-to-head line needs (animated hip
		-- height read off the pelvis, head where the solver will put it). A
		-- fixed share of the crouch left the spine to squash upright under a
		-- low head: the puffer fish on the way into prone.
		-- The head height here is the nod-steady one the crouch uses (HMD less
		-- 3 x forward.z): looking down drops the HMD on its own, and reading
		-- that as a lower head pushed the hips back.
		local back, hipLow, headZ = 0, nil, nil
		if body and not fbtT then
			local mp = ply:GetBoneMatrix(h.pelvis)
			local hipZ = mp and mp:GetTranslation().z - ply:GetPos().z or h.maxDrop / 0.6
			local lift = h.eyeZ - eyeH
			hipLow = charinfo.preRenderPos.z + hipZ -- the hips' height before any drop
			headZ = frame.hmdPos.z - h.eyeUp + lift -- where the solver puts the head
			local dz = frame.hmdPos.z - frame.hmdAng:Forward().z * 3 - h.eyeUp + lift - (hipLow - drop)
			local L = h.hipToHead * 0.95
			if dz < L then back = dz > 0 and math.sqrt(L * L - dz * dz) or L end
		end
		back = math.Approach(charinfo.hikBack or back, back, RealFrameTime() * 80)
		charinfo.hikBack = back
		charinfo.horizontalCrouchOffset = back / 0.8
		-- PrePlayerDraw weights the crouch shift by (1 - lie blend); plant the
		-- feet against what it actually applied.
		local keep = 1 - (charinfo.lieT or 0)
		local twist = frame.yawTwist or 0
		-- Classic's planted feet don't run here: no stale weight forcing idle.
		charinfo.legOn, charinfo.legW = nil, 0
		-- Body mode turns the solved spine itself (HIK.Solve twist / lean);
		-- arms-only (sitting) twists the animated spine for the arm solve.
		-- Lean: the hips move per LeanShift (PrePlayerDraw applies it); the
		-- solver's spine then leans to the head by itself, and the chest gets a
		-- little extra roll. The feet take FEET_FOLLOW of the shift.
		local tw, lean, lf, cbx, cby = ply:InVehicle() and 0 or twist * keep, 0, 0, 0, 0
		local y = math.rad(frame.characterYaw - twist * 0.5)
		-- FBT: the chest turns from the waist tracker to the torso yaw
		if fbtT then
			tw = NAng(frame.characterYaw + twist * 0.5 - fbtT.pelvisAng.yaw)
			tw = tw > 70 and 70 or tw < -70 and -70 or tw
		end
		if body and not fbtT then
			local live = keep * (1 - charinfo.vrSitBlend)
			lean, lf = TiltLean(frame, charinfo, cut > CROUCH_DEAD and (cut - CROUCH_DEAD) / (40 - CROUCH_DEAD) or 0, cfg)
			lean, lf = lean * live, lf * live
			cbx, cby = LeanShift(frame, lean, lf, h.hipToHead, frame.characterYaw - twist * 0.5)
			-- The hips sit off the head by the squat's back shift, the lean-over
			-- (BodyRoot) and this, and
			-- the head is pinned: a full-length spine at that angle reaches less
			-- far down, so the hips drop LESS than the crouch would have them
			-- (below) -- going down with a lean, the spine's tilt takes up part of
			-- the descent. They can't come up past standing (that's the float:
			-- the solver hauling them toward the head off planted feet), so the
			-- shift is held to what the spine reaches from standing hip height.
			-- Standing tall that's nothing; it opens up as you go down.
			local L = h.hipToHead * 0.98
			local dz = headZ - hipLow
			local avail = dz < L and (dz > 0 and math.sqrt(L * L - dz * dz) or L) or 0
			-- what the lean-over may take (BodyRoot, next frame)
			charinfo.leanReach = avail
			local ovx, ovy = charinfo.overX or 0, charinfo.overY or 0
			local cc = cbx * cbx + cby * cby
			if cc > 0 then
				local vx, vy = -math.cos(y) * back + ovx, -math.sin(y) * back + ovy
				local vc, vv = vx * cbx + vy * cby, vx * vx + vy * vy - avail * avail
				local sc = 0
				if vv < 0 then
					sc = (-vc + math.sqrt(vc * vc - cc * vv)) / cc
					sc = sc < 1 and sc or 1
				end
				cbx, cby = cbx * sc, cby * sc
			end
			-- Drop for the shift the hips actually have (BodyRoot's eased one):
			-- no lower than a full-length spine at that angle reaches.
			local ax, ay = -math.cos(y) * back + (charinfo.cbSX or 0) + ovx, -math.sin(y) * back + (charinfo.cbSY or 0) + ovy
			local off = ax * ax + ay * ay
			if off > 0 then
				local reach = off < L * L and math.sqrt(L * L - off) or 0
				local over = headZ - (hipLow - drop) - reach
				if over > 0 then
					drop = drop > over and drop - over or 0
					charinfo.verticalCrouchOffset = drop
				end
			end
		end
		charinfo.leanFwd = lf
		local d = lean - (charinfo.leanT or 0)
		charinfo.leanBusy = d * d > 0.04
		charinfo.leanT, charinfo.cbX, charinfo.cbY = lean, cbx, cby
		SpineApply(ply, charinfo, body and 0 or tw, 0, 0, 0)
		if body then
			hz, v = hz * keep, v * keep
			local fk = 1 - FEET_FOLLOW
			-- feet stay put under the look-down clearance (only the body slides)
			hikComp:SetUnpacked(math.cos(y) * hz - (charinfo.cbSX or 0) * fk - (charinfo.viewBX or 0) * keep, math.sin(y) * hz - (charinfo.cbSY or 0) * fk - (charinfo.viewBY or 0) * keep, v)
		elseif UseAltHead(net, charinfo, cfg) then
			local _, tmp2 = WorldToLocal(zeroVec, frame.hmdAng, zeroVec, charinfo.lieAng or Angle(0, frame.characterYaw + twist * 0.5, 0))
			ply:ManipulateBoneAngles(bones.b_head, Angle(-tmp2.roll, -tmp2.pitch, tmp2.yaw))
		end
		-- Eye Height is the calibrated standing height: standing there puts
		-- the model at its own eye height instead of pinning its head to the
		-- HMD (which squashed or floated every model that isn't your size).
		-- Hands follow the anim swing everywhere except the local player's own
		-- HMD eyes (spec view and other players see it). Runs per render pass.
		local blend = cfg.hikAnimBlend or 0
		local hand = cfg.hikHandBlend or 0
		if hand > 0 and ply == LocalPlayer() then
			local ep = EyePos()
			if ep == g_VR.eyePosLeft or ep == g_VR.eyePosRight then hand = 0 end
		end
		-- Feet: homes from the animated feet (stance / plain-stand blend, legs
		-- back), pushed the way comp pushes them, then planted and stepped
		-- (StepFeet) so they hold their spot instead of jolting with every
		-- change of the body under them. Stepped once per frame.
		local feet
		if fbtT then
			-- the foot trackers; the walk anim's feet while stick walking upright
			local b = fbtT.legBlend or 0
			local m1, m2 = b > 0 and ply:GetBoneMatrix(h.leg[1].foot), b > 0 and ply:GetBoneMatrix(h.leg[2].foot)
			if m1 and m2 then
				hikFeet[1]:Set(LerpVector(b, fbtT.lfPos, m1:GetTranslation()))
				hikFeet[2]:Set(LerpAngle(b, fbtT.lfAng, m1:GetAngles()))
				hikFeet[3]:Set(LerpVector(b, fbtT.rfPos, m2:GetTranslation()))
				hikFeet[4]:Set(LerpAngle(b, fbtT.rfAng, m2:GetAngles()))
			else
				hikFeet[1]:Set(fbtT.lfPos)
				hikFeet[2]:Set(fbtT.lfAng)
				hikFeet[3]:Set(fbtT.rfPos)
				hikFeet[4]:Set(fbtT.rfAng)
			end
			feet = hikFeet
			charinfo.plantIdle = nil
		elseif body then
			local m1, m2 = ply:GetBoneMatrix(h.leg[1].foot), ply:GetBoneMatrix(h.leg[2].foot)
			if m1 and m2 then
				local fs = charinfo.hFeet
				if not fs then
					fs = {{}, {}}
					charinfo.hFeet = fs
				end
				local fn, rt, dt = FrameNumber(), RealTime(), 0
				local legT = (not frame.stickMoving and ply:OnGround() and not POSE.seq[ply]) and keep * (1 - charinfo.vrSitBlend) or 0
				if charinfo.hFeetF ~= fn then
					dt = rt - (charinfo.hFeetRT or rt)
					dt = dt < 0.1 and dt or 0.1
					charinfo.hFeetF, charinfo.hFeetRT = fn, rt
					charinfo.hFeetW = math.Approach(charinfo.hFeetW or 0, legT, dt * 8)
				end
				local w = charinfo.hFeetW or 0
				local mp = ply:GetBoneMatrix(h.pelvis)
				StanceHomes(charinfo, hikH, charinfo.stanceW or 1, mp and mp:GetTranslation(), m1:GetTranslation(), m1:GetAngles(), m2:GetTranslation(), m2:GetAngles(), ply:GetPos(), ply:GetRenderAngles())
				local lead = legT == 0 and 0 or STEP_TIME * STEP_LEAD * (1 - (charinfo.moveW or 0))
				local lx, ly = (charinfo.rootVX or 0) * lead, (charinfo.rootVY or 0) * lead
				local ll = lx * lx + ly * ly
				if ll > 100 then
					ll = 10 / math.sqrt(ll)
					lx, ly = lx * ll, ly * ll
				end
				local cx, cy, cz = hikComp:Unpack()
				for i = 1, 2 do
					local m = hikH[i]
					m.x, m.y, m.z = m.x + cx + lx, m.y + cy + ly, m.z + cz
				end
				StepFeet(fs, hikH, frame.characterYaw - twist * 0.5, w, dt, legT == 0)
				charinfo.plantIdle = w > 0.5
				local me = ply == LocalPlayer()
				for i = 1, 2 do
					local L = fs[i]
					if me then
						local toe = charinfo.legs and charinfo.legs[i].toe
						local mt = toe and ply:GetBoneMatrix(toe)
						L.tx, L.ty, L.tz = FootPhys(i, L.tx, L.ty, L.tz, (i == 1 and m1 or m2):GetTranslation(), mt and mt:GetTranslation(), frame.characterYaw - twist * 0.5)
					end
					hikFeet[2 * i - 1]:SetUnpacked(L.tx, L.ty, L.tz)
					local a = hikFeet[2 * i]
					a:Set(hikH[i].a)
					if L.dyaw ~= 0 then a:RotateAroundAxis(UPV, L.dyaw) end
				end
				feet = hikFeet
			end
		end
		if not feet then charinfo.plantIdle = nil end
		-- the look-down clearance moved the body back (PrePlayerDraw); the
		-- head target goes with it so the spine doesn't stretch to the HMD
		local hoff
		local vbx, vby = charinfo.viewBX or 0, charinfo.viewBY or 0
		if body and not fbtT and (vbx ~= 0 or vby ~= 0) then
			hikHoff:SetUnpacked(vbx * keep, vby * keep, 0)
			hoff = hikHoff
		end
		if not vrmod.hik.Solve(ply, h, frame, body, hikComp, GetPlayerHeadToHmdDist(ply), cfg.armStretcher, frame.lefthandAng, frame.righthandAng + RIGHT_HAND_OFFSET, fbtT and 0 or (h.eyeZ - eyeH) * keep, blend, hand, body and tw or 0, lean * 0.5, hoff, feet, fbtT and fbtT.pelvisPos, fbtT and fbtT.pelvisBoneAng) then
			charinfo.hikBody = false
			return
		end
		charinfo.hikBody = body
		local boneinfo = charinfo.boneinfo
		for i = 1, 2 do
			local R, k = h.arm[i], HIK_KEYS[i]
			charinfo[k[7]] = R.clavPos
			charinfo[k[8]] = R.stretch
			charinfo[k[9]] = R.stretch ~= 1 and R.handPos or nil
			boneinfo[bones[k[1]]].overrideAng = R.clav
			boneinfo[bones[k[2]]].overrideAng = R.upper
			boneinfo[bones[k[3]]].overrideAng = R.fore
			boneinfo[bones[k[4]]].overrideAng = R.hand
			local w, u = boneinfo[bones[k[5]]], boneinfo[bones[k[6]]]
			if R.wrist and w and u then
				w.overrideAng = R.wristA
				u.overrideAng = R.ulnaA
			end
		end
		BuildArmTargets(charinfo, boneinfo, bones, frame)
	end

	-- Fingers + per-bone target matrices for the clavicle subtrees. Shared by
	-- UpdateIK and UpdateHIK.
	function BuildArmTargets(charinfo, boneinfo, bones, frame)
		-- Fingers
		for k, v in pairs(bones.fingers) do
			if not boneinfo[v] then continue end
			boneinfo[v].offsetAng = LerpAngle(frame["finger" .. math.floor((k - 1) / 3 + 1)], g_VR.openHandAngles[k], g_VR.closedHandAngles[k])
		end

		-- Target matrices (reuse existing Matrix, only update if changed)
		for i = 1, #charinfo.boneorder do
			local bone = charinfo.boneorder[i]
			local bd = boneinfo[bone]
			local wpos, wang
			if bd.name == "ValveBiped.Bip01_L_Clavicle" then
				wpos = charinfo.L_ClaviclePos
			elseif bd.name == "ValveBiped.Bip01_R_Clavicle" then
				wpos = charinfo.R_ClaviclePos
			else
				wpos, wang = LocalToWorld(bd.relativePos, bd.relativeAng + bd.offsetAng, boneinfo[bd.parent].pos, boneinfo[bd.parent].ang)
			end

			if bd.overrideAng ~= nil then wang = bd.overrideAng end
			if charinfo.L_HandTargetPos and bd.name == "ValveBiped.Bip01_L_Hand" then
				wpos = charinfo.L_HandTargetPos
			elseif charinfo.R_HandTargetPos and bd.name == "ValveBiped.Bip01_R_Hand" then
				wpos = charinfo.R_HandTargetPos
			end

			local mat = bd.targetMatrix
			if not bd.pos or not bd.ang or wpos:DistToSqr(bd.pos) > POS_THRESHOLD or math.abs(wang.pitch - bd.ang.pitch) > ANGLE_THRESHOLD or math.abs(wang.yaw - bd.ang.yaw) > ANGLE_THRESHOLD or math.abs(wang.roll - bd.ang.roll) > ANGLE_THRESHOLD then
				mat:Identity()
				mat:SetTranslation(wpos)
				mat:SetAngles(wang)
				if charinfo.L_armStretchScale ~= 1 and (bd.name == "ValveBiped.Bip01_L_UpperArm" or bd.name == "ValveBiped.Bip01_L_Forearm") then mat:Scale(Vector(charinfo.L_armStretchScale, 1, 1)) end
				if charinfo.R_armStretchScale ~= 1 and (bd.name == "ValveBiped.Bip01_R_UpperArm" or bd.name == "ValveBiped.Bip01_R_Forearm") then mat:Scale(Vector(charinfo.R_armStretchScale, 1, 1)) end
				-- Copy, never reference: wpos/wang can be pooled lerpedFrame
				-- objects (hand overrideAng / stretcher targetPos) mutated in
				-- place every PreRender. Storing the reference made the change
				-- check above compare an object against itself, so the target
				-- matrix never rebuilt -- remote hand bones froze in place.
				if bd.pos then bd.pos:Set(wpos) else bd.pos = Vector(wpos) end
				if bd.ang then bd.ang:Set(wang) else bd.ang = Angle(wang) end
			end
		end
	end

	------------------------------------------------------------------------
	local function CharacterInit(ply)
		local steamid = ply:SteamID()
		local pmname = ply:GetModel()
		-- Reject invalid/placeholder models (race on PlayerSpawn before model is applied).
		-- Caller should retry next frame; returning false here avoids stale info with wrong bones.
		if pmname == "" or pmname == "models/player.mdl" then
			vrmod.logger.Warn("CharacterInit deferred for " .. steamid .. " (model not ready: " .. pmname .. ")")
			return false
		end
		-- Always wipe prior state. The previous "early return on matching modelName" left
		-- a stale characterInfo entry after death/respawn whose boneCallback had been
		-- removed in StopCharacterSystem, leaving the player stuck in desktop anims.
		characterInfo[steamid] = nil
		lastFrames[steamid] = nil
		if ply == LocalPlayer() then
			timer.Create("vrutil_timer_validatefingertracking", 0.1, 0, function()
				if g_VR.tracking.pose_lefthand and g_VR.tracking.pose_righthand and g_VR.tracking.pose_lefthand.simulatedPos == nil and g_VR.tracking.pose_righthand.simulatedPos == nil then
					timer.Remove("vrutil_timer_validatefingertracking")
					for i = 1, 2 do
						for k, v in pairs(i == 1 and g_VR.input.skeleton_lefthand.fingerCurls or g_VR.input.skeleton_righthand.fingerCurls) do
							if v < 0 or v > 1 or k == 3 and v == 0.75 then
								g_VR.defaultOpenHandAngles = g_VR.zeroHandAngles
								g_VR.defaultClosedHandAngles = g_VR.zeroHandAngles
								g_VR.openHandAngles = g_VR.zeroHandAngles
								g_VR.closedHandAngles = g_VR.zeroHandAngles
								break
							end
						end
					end
				end
			end)
		end

		characterInfo[steamid] = {
			preRenderPos = Vector(0, 0, 0),
			renderPos = Vector(0, 0, 0),
			bones = {},
			boneinfo = {},
			boneorder = {},
			player = ply,
			boneCallback = 0,
			verticalCrouchOffset = 0,
			horizontalCrouchOffset = 0,
		wasAlive = true,
		}

		ply:SetLOD(0)
		local cm = ClientsideModel(pmname)
		cm:SetPos(LocalPlayer():GetPos())
		cm:SetAngles(Angle(0, 0, 0))
		cm:SetupBones()
		RecursiveBoneTable2(cm, cm:LookupBone("ValveBiped.Bip01_L_Clavicle"), characterInfo[steamid].boneinfo, characterInfo[steamid].boneorder)
		RecursiveBoneTable2(cm, cm:LookupBone("ValveBiped.Bip01_R_Clavicle"), characterInfo[steamid].boneinfo, characterInfo[steamid].boneorder)
		local boneNames = {
			b_leftClavicle = "ValveBiped.Bip01_L_Clavicle",
			b_leftUpperarm = "ValveBiped.Bip01_L_UpperArm",
			b_leftForearm = "ValveBiped.Bip01_L_Forearm",
			b_leftHand = "ValveBiped.Bip01_L_Hand",
			b_leftWrist = "ValveBiped.Bip01_L_Wrist",
			b_leftUlna = "ValveBiped.Bip01_L_Ulna",
			b_leftCalf = "ValveBiped.Bip01_L_Calf",
			b_leftThigh = "ValveBiped.Bip01_L_Thigh",
			b_leftFoot = "ValveBiped.Bip01_L_Foot",
			b_rightClavicle = "ValveBiped.Bip01_R_Clavicle",
			b_rightUpperarm = "ValveBiped.Bip01_R_UpperArm",
			b_rightForearm = "ValveBiped.Bip01_R_Forearm",
			b_rightHand = "ValveBiped.Bip01_R_Hand",
			b_rightWrist = "ValveBiped.Bip01_R_Wrist",
			b_rightUlna = "ValveBiped.Bip01_R_Ulna",
			b_rightCalf = "ValveBiped.Bip01_R_Calf",
			b_rightThigh = "ValveBiped.Bip01_R_Thigh",
			b_rightFoot = "ValveBiped.Bip01_R_Foot",
			b_head = "ValveBiped.Bip01_Head1",
			b_spine = "ValveBiped.Bip01_Spine",
		}

		characterInfo[steamid].bones = {
			fingers = {cm:LookupBone("ValveBiped.Bip01_L_Finger0") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger01") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger02") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger1") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger11") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger12") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger2") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger21") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger22") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger3") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger31") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger32") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger4") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger41") or -1, cm:LookupBone("ValveBiped.Bip01_L_Finger42") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger0") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger01") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger02") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger1") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger11") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger12") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger2") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger21") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger22") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger3") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger31") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger32") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger4") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger41") or -1, cm:LookupBone("ValveBiped.Bip01_R_Finger42") or -1,}
		}

		for k, v in pairs(boneNames) do
			local bone = cm:LookupBone(v) or -1
			characterInfo[steamid].bones[k] = bone
			if bone == -1 and not string.find(k, "Wrist") and not string.find(k, "Ulna") then
				cm:Remove()
				g_VR.StopCharacterSystem(steamid)
				vrmod.logger.Err("CharacterInit failed for " .. steamid .. " - missing bone " .. v)
				if ply == LocalPlayer() then
					local msg = "Incompatible player model. Missing bone: " .. v
					chat.AddText(Color(255, 80, 80), "[VRMod] ", Color(255, 255, 255), msg)
					-- Defer exit: calling VRUtilClientExit synchronously from CharacterInit
					-- would tear down hooks we're currently inside, and CharacterInit runs
					-- from StartCharacterSystem which fires from the VRMod_Start hook.
					timer.Simple(0, function()
						if g_VR and (g_VR.active or g_VR.errorText) and isfunction(VRUtilClientExit) then
							g_VR.errorText = "" -- prevent DrawErrorOverlay from freezing the exit path
							VRUtilClientExit()
						end
					end)
				end
				-- nil, not false: false means "deferred, retry" to the caller, and an
				-- incompatible model would re-run this whole init on every retry.
				return nil
			end
		end

		local headBone = characterInfo[steamid].bones.b_head
		local headChildren = 0
		if headBone ~= -1 then
			for i = 0, cm:GetBoneCount() - 1 do
				if cm:GetBoneParent(i) == headBone then headChildren = headChildren + 1 end
			end
		end
		characterInfo[steamid].headChildren = headChildren
		if headChildren > 1 then vrmod.logger.Info("%s: head has %d children, using jigglebone-safe head angles", pmname, headChildren) end
		characterInfo[steamid].modelName = pmname
		local claviclePos = cm:GetBonePosition(characterInfo[steamid].bones.b_leftClavicle)
		local upperPos = cm:GetBonePosition(characterInfo[steamid].bones.b_leftUpperarm)
		local lowerPos = cm:GetBonePosition(characterInfo[steamid].bones.b_leftForearm)
		local handPos = cm:GetBonePosition(characterInfo[steamid].bones.b_leftHand)
		local thighPos = cm:GetBonePosition(characterInfo[steamid].bones.b_leftThigh)
		local calfPos = cm:GetBonePosition(characterInfo[steamid].bones.b_leftCalf)
		local footPos = cm:GetBonePosition(characterInfo[steamid].bones.b_leftFoot)
		local spinePos = cm:GetBonePosition(characterInfo[steamid].bones.b_spine)
		characterInfo[steamid].clavicleLen = claviclePos:Distance(upperPos)
		characterInfo[steamid].upperArmLen = upperPos:Distance(lowerPos)
		characterInfo[steamid].lowerArmLen = lowerPos:Distance(handPos)
		characterInfo[steamid].upperLegLen = thighPos:Distance(calfPos)
		characterInfo[steamid].lowerLegLen = calfPos:Distance(footPos)
		characterInfo[steamid].spineZ = spinePos.z - cm:GetPos().z
		characterInfo[steamid].spineLen = GetPlayerEyeHeight(ply) - characterInfo[steamid].spineZ
		-- (Spine's crouch bend goes through SpineApply; a model without the
		-- Spine bone already failed init above.)
		-- Spine chain for the split yaw and the leans. Each bone gets the model's
		-- up / forward / left axes MEASURED in its own frame off this rest pose
		-- (model at angle 0), so ManipulateBoneAngles can turn it about body
		-- axes on any rig instead of guessing which Euler slot is which.
		-- Columns: twist, lean; renormalised over the bones the model has.
		do
			local ci, chain, sums = characterInfo[steamid], {}, {0, 0}
			for _, d in ipairs(SPINE_CHAIN) do
				local b = cm:LookupBone(d[1])
				local m = b and cm:GetBoneMatrix(b)
				if m then
					local a = m:GetAngles()
					chain[#chain + 1] = {
						bone = b, w = {d[2], d[3], d[4]},
						up = WorldToLocal(Vector(0, 0, 1), zeroAng, zeroVec, a),
						fwd = WorldToLocal(Vector(1, 0, 0), zeroAng, zeroVec, a),
						left = WorldToLocal(Vector(0, 1, 0), zeroAng, zeroVec, a),
					}
					for j = 1, 2 do sums[j] = sums[j] + d[j + 1] end
					ci.bones[d[1]] = b -- reset by StopCharacterSystem's manip sweep
				end
			end
			for _, c in ipairs(chain) do
				local w = c.w
				c.wT = sums[1] > 0 and w[1] / sums[1] or 0
				c.wF = sums[2] > 0 and w[2] / sums[2] or 0
				c.w = nil
			end
			ci.spineChain = #chain > 0 and chain or nil
			local b = ci.bones
			ci.legs = {
				{thigh = b.b_leftThigh, calf = b.b_leftCalf, foot = b.b_leftFoot, toe = cm:LookupBone("ValveBiped.Bip01_L_Toe0"), mT = Matrix(), mC = Matrix(), mF = Matrix(), mX = Matrix()},
				{thigh = b.b_rightThigh, calf = b.b_rightCalf, foot = b.b_rightFoot, toe = cm:LookupBone("ValveBiped.Bip01_R_Toe0"), mT = Matrix(), mC = Matrix(), mF = Matrix(), mX = Matrix()},
			}
		end
		-- Plain stand for the weapon-stance blend (StanceHomes): the unarmed
		-- idle's feet and pelvis in model space. Measured last, since it moves
		-- the rest pose everything above was read off.
		do
			local ci = characterInfo[steamid]
			local pb = cm:LookupBone("ValveBiped.Bip01_Pelvis")
			local seq = cm:SelectWeightedSequence(ACT_HL2MP_IDLE)
			if pb and seq and seq >= 0 then
				ci.neutralSeq, ci.neutralPB = seq, pb
			end
		end
		if vrmod.hik then
			local h, missing = vrmod.hik.Build(cm)
			characterInfo[steamid].hik = h
			if not h then vrmod.logger.Info("%s: Hai IK unavailable (no %s), classic IK used", pmname, missing) end
		end
		do
			local ci = characterInfo[steamid]
			if ci.neutralSeq then
				cm:ResetSequence(ci.neutralSeq)
				cm:SetCycle(0)
				cm:InvalidateBoneCache()
				cm:SetupBones()
				local o = cm:GetPos()
				local m1, m2, mp = cm:GetBoneMatrix(ci.bones.b_leftFoot), cm:GetBoneMatrix(ci.bones.b_rightFoot), cm:GetBoneMatrix(ci.neutralPB)
				if m1 and m2 and mp then
					local p1, a1 = WorldToLocal(m1:GetTranslation(), m1:GetAngles(), o, zeroAng)
					local p2, a2 = WorldToLocal(m2:GetTranslation(), m2:GetAngles(), o, zeroAng)
					ci.neutralFeet = {p = {p1, p2}, a = {a1, a2}, pelvis = WorldToLocal(mp:GetTranslation(), zeroAng, o, zeroAng), pelvisB = ci.neutralPB}
				end
			end
		end
		cm:Remove()
	end

	------------------------------------------------------------------------
	------------------------------------------------------------------------
	-- FBT. The trackers place the body for both solvers (PrePlayerDraw:
	-- render frame and the local hull off the waist tracker). With Hai IK as
	-- the solver, FBT runs through it too -- the waist tracker is the hips,
	-- the foot trackers the feet, the HMD and controllers as usual -- so the
	-- arms, hands and spine are the same as without trackers. Otherwise the
	-- FBT module solves the whole body itself.
	------------------------------------------------------------------------
	function vrmod.FbtUsesHai(ply)
		local sid = ply:SteamID()
		local ci = characterInfo[sid]
		return CharCfg(ply).characterIKSolver == 1 and ci and ci.hik and activePlayers[sid] and FbtTargets(ply, sid) ~= nil or false
	end

	local function BoneCallbackFunc(ply, numbones)
		local steamid = ply:SteamID()
		local netEntry = g_VR.net[steamid]
		local info = characterInfo[steamid]
		if not activePlayers[steamid] or not netEntry or not netEntry.lerpedFrame or not info then return end
		if g_VR.fbtActive[steamid] and not vrmod.FbtUsesHai(ply) then return end -- the FBT module has all bones
		if POSE.raw[ply] then POSE.RawBones(ply, info.bones.b_head) return end
		local frame = netEntry.lerpedFrame
		local bones = info.bones
		-- IK output is only trusted when solved this frame or last. targetMatrix
		-- starts as identity (world origin) and goes stale whenever PrePlayerDraw
		-- stops running: floating hands (no body draw), a culled remote player.
		-- Any SetupBones then -- including the client death ragdoll's init
		-- arrays -- dragged the arm chain to the map origin or an old position
		-- and the ragdoll solver launched it. Not live = plain anim pose.
		local fn, ik = FrameNumber(), info.ikFrame
		local live = info.inDraw or ik and fn - ik < 2
		local cfg = CharCfg(ply)
		local hik = cfg.characterIKSolver == 1 and info.hik or nil
		-- Lying measures the pose it tips over (squat, sit, standing) here, before
		-- any IK write: head and mid-feet in the model's own frame. Only near
		-- or inside the lie band (LieUpdate sets lieNear).
		if info.inDraw and info.lieNear and info.renderAng then
			local mh, ml, mr = ply:GetBoneMatrix(bones.b_head), ply:GetBoneMatrix(bones.b_leftFoot), ply:GetBoneMatrix(bones.b_rightFoot)
			if mh and ml and mr then
				local o, a, fp = info.renderPos, info.renderAng, ml:GetTranslation()
				fp:Add(mr:GetTranslation())
				fp:Mul(0.5)
				info.lieFootL = WorldToLocal(fp, zeroAng, o, a)
				info.lieHeadL = WorldToLocal(mh:GetTranslation(), zeroAng, o, a)
			end
		end

		-- Full-body IK is applied HERE, inside the bone callback, so it
		-- re-applies on EVERY SetupBones. PAC3 forces extra SetupBones passes
		-- (PreDrawOpaqueRenderables -> RenderOverride) whenever the player has
		-- any parts; with the apply loop outside the callback those passes
		-- reset the clavicle/arm chain to the anim pose -- the "PAC3 breaks
		-- shoulders" bug. UpdateIK only runs inside the PrePlayerDraw window
		-- (info.inDraw, body at renderPos); the extra passes just re-apply.
		-- A held weapon's render bonemerges against the owner and forces a
		-- SetupBones BEFORE PrePlayerDraw, at the pre-shift position; solving
		-- there anchored the clavicle/spine chain to the wrong body AND wrote
		-- lastFrames, so the post-shift re-run early-returned on FramesAreEqual
		-- -- the "remote IK breaks while holding a weapon" bug. Early passes
		-- still get the hand/head overrides (all a bonemerged weapon needs)
		-- plus last frame's world-space matrices below.
		if info.inDraw then
			if hik then UpdateHIK(ply, hik) else UpdateIK(ply) end
			info.ikFrame = fn
		elseif hik and live and info.hikBody then
			vrmod.hik.Reapply(ply, hik)
		end
		-- Head: after the solve, which reads the animated head; Hai IK body
		-- mode places the head itself.
		if not (hik and live and info.hikBody) and not UseAltHead(netEntry, info, cfg) then
			local _, targetAng = LocalToWorld(zeroVec, Angle(-80, 0, 90), zeroVec, frame.hmdAng)
			local headBone = bones.b_head
			local mtx = headBone ~= -1 and ply:GetBoneMatrix(headBone) or nil
			if mtx then
				mtx:SetAngles(targetAng)
				ply:SetBoneMatrix(headBone, mtx)
			end
		end
		local boneorder = info.boneorder
		local boneinfo = info.boneinfo
		if live and boneorder and boneinfo then
			for i = 1, #boneorder do
				local bone = boneorder[i]
				local bi = boneinfo[bone]
				if bi and bi.targetMatrix and ply:GetBoneMatrix(bone) then
					ply:SetBoneMatrix(bone, bi.targetMatrix)
				end
			end
		end
		local legs = live and info.legOn and info.legs
		if legs then
			-- The draw pass sets up every bone; extra passes (a worldmodel's
			-- bonemerge) only some, and the rest are unwriteable.
			local full = info.inDraw
			for i = 1, 2 do
				local L = legs[i]
				if full or ply:GetBoneMatrix(L.thigh) then ply:SetBoneMatrix(L.thigh, L.mT) end
				if full or ply:GetBoneMatrix(L.calf) then ply:SetBoneMatrix(L.calf, L.mC) end
				if full or ply:GetBoneMatrix(L.foot) then ply:SetBoneMatrix(L.foot, L.mF) end
				if L.hasToe and (full or ply:GetBoneMatrix(L.toe)) then ply:SetBoneMatrix(L.toe, L.mX) end
			end
		end
		-- Early pass: the loop above laid LAST frame's matrices on the hands
		-- too, so a weapon bonemerged off this pass drew a frame behind the
		-- hand. Hands take this frame's pose after it. The in-draw pass
		-- keeps the solved chain (hand on the forearm).
		if live and not (info.inDraw and boneorder) then
			-- Remote Hai IK hands keep the anim swing so a bonemerged weapon
			-- stays in the drawn hand.
			local ha = hik and ply ~= LocalPlayer() and hik.arm
			local b = bones.b_rightHand
			if b ~= -1 and ply:GetBoneMatrix(b) then ply:SetBonePosition(b, ha and frame.righthandPos + ha[2].hd or frame.righthandPos, frame.righthandAng + RIGHT_HAND_OFFSET) end
			b = bones.b_leftHand
			if b ~= -1 and ply:GetBoneMatrix(b) then ply:SetBonePosition(b, ha and frame.lefthandPos + ha[1].hd or frame.lefthandPos, frame.lefthandAng) end
		end
		if ply == LocalPlayer() then
			-- First-person head hide via matrix scale-zero (authoritative).
			-- ManipulateBoneScale here would be reset every frame by PAC3's
			-- per-bone scale-reset loop, popping the head model back into view.
			local hb = bones.b_head
			if hb ~= -1 then
				local ep = EyePos()
				local hide = (ep == g_VR.eyePosLeft or ep == g_VR.eyePosRight) and ply:GetViewEntity() == ply
				if hide then
					local hmtx = ply:GetBoneMatrix(hb)
					if hmtx then hmtx:Scale(zeroVec) ply:SetBoneMatrix(hb, hmtx) end
				end
			end
			if vrmod.boneScaler then vrmod.boneScaler.ApplyToBones(ply) end
			if vrmod.boneHider then vrmod.boneHider.ApplyToBones(ply) end
		end
	end

	------------------------------------------------------------------------
	------------------------------------------------------------------------
	-- SPLIT BODY YAW (local player; the frame carries the average as
	-- characterYaw plus torso - hip as yawTwist).
	--   hips  : the legs' frame. Follow their head/arm mix only once it's
	--           HIP_DEADZONE past them, so small head turns twist the torso
	--           and the planted feet stay put; when they do turn, the feet
	--           step after them (UpdateIK).
	--   torso : chest, shoulders, arm solve. The old VRMod arm-line yaw
	--           (line between the hands, +-45 off the head) mixed with head.
	--   Each part takes a weighted circular mean of head and arm yaw (the
	--   vrmod_yaw_* sliders); the more head in the mix, the faster it follows
	--   (8/s arms-only to 60/s head-only, as the old blend slider did).
	--   Stick walking ramps both onto the head and drops the hip deadzone.
	--   Snap/smooth turns rotate the world under you, so the origin's yaw
	--   change is carried straight into both.
	--   The torso stays within TWIST_MAX of the hips; past that it drags them.
	------------------------------------------------------------------------
	local HIP_DEADZONE, TWIST_MAX = 30, 60
	local yawHip, yawTorso, yawOrigin, yawMove = nil, nil, 0, 0
	local function YawTarget(cur, head, arm, wh, wa)
		local sw = wh + wa
		if sw <= 0 then return cur, 0 end
		local h, a = math.rad(head), math.rad(arm)
		local x, y = wh * math.cos(h) + wa * math.cos(a), wh * math.sin(h) + wa * math.sin(a)
		if x * x + y * y < 1e-6 then return cur, 0 end
		return math.deg(math.atan2(y, x)), wh / sw
	end
	local function PreRenderFunc()
		local hmdAng = g_VR.tracking.hmd.ang
		local NA = math.NormalizeAngle
		-- Euler yaw is degenerate at steep pitch and flips 180 when the head
		-- tips past vertical, spinning the body. Past ~64 deg (|fwd.z| >= 0.9)
		-- derive yaw from the head's up axis instead: its horizontal
		-- projection points along the facing when looking down (opposite when
		-- up) and stays continuous through and beyond +-90 pitch.
		local headYaw
		local fwd = hmdAng:Forward()
		local level = fwd.z < 0.9 and fwd.z > -0.9
		if level then
			headYaw = hmdAng.yaw
		else
			local upv = hmdAng:Up()
			headYaw = fwd.z > 0 and math.deg(math.atan2(-upv.y, -upv.x)) or math.deg(math.atan2(upv.y, upv.x))
		end
		local oy = g_VR.originAngle and g_VR.originAngle.yaw or 0
		if not g_VR.characterHipYaw or not yawHip then
			yawHip, yawTorso, yawOrigin, yawMove = headYaw, headYaw, oy, 0
		end
		local d = NA(oy - yawOrigin)
		yawOrigin = oy
		yawHip, yawTorso = yawHip + d, yawTorso + d
		local inp = g_VR.input
		local wd = inp.vector2_walkdirection
		local dt = RealFrameTime()
		yawMove = math.Approach(yawMove, (inp.boolean_walk or wd and wd.x * wd.x + wd.y * wd.y > 0.04) and 1 or 0, dt * 4)

		-- Arm yaw (the old VRMod system): perpendicular to the hand line,
		-- clamped +-45 off the head. Not with crossed hands or a steep head.
		local armYaw, armOk = headYaw, false
		if level then
			local hmdPos = g_VR.tracking.hmd.pos
			local lp, rp = g_VR.tracking.pose_lefthand.pos, g_VR.tracking.pose_righthand.pos
			if WorldToLocal(lp, zeroAng, hmdPos, hmdAng).y > WorldToLocal(rp, zeroAng, hmdPos, hmdAng).y then
				armYaw = headYaw + math.Clamp(NA(math.deg(math.atan2(rp.y - lp.y, rp.x - lp.x)) + 90 - headYaw), -45, 45)
				armOk = true
			end
		end

		local cv, m = convarValues, yawMove
		local t, share = YawTarget(yawTorso, headYaw, armYaw, cv.yawTorsoHead or 0.25, armOk and (cv.yawTorsoArms or 1) or 0)
		t = t + NA(headYaw - t) * m
		local k = (8 + 52 * (share + (1 - share) * m)) * dt
		yawTorso = yawTorso + NA(t - yawTorso) * (k < 1 and k or 1)

		t, share = YawTarget(yawHip, headYaw, armYaw, cv.yawHipHead or 1, armOk and (cv.yawHipArms or 0.7) or 0)
		t = t + NA(headYaw - t) * m
		d = NA(t - yawHip)
		local dz = HIP_DEADZONE * (1 - m)
		if d > dz or d < -dz then
			k = (8 + 52 * (share + (1 - share) * m)) * dt
			yawHip = yawHip + (d > 0 and d - dz or d + dz) * (k < 1 and k or 1)
		end

		yawTorso = NA(yawTorso)
		local tw = NA(yawTorso - yawHip)
		if tw > TWIST_MAX then tw = TWIST_MAX elseif tw < -TWIST_MAX then tw = -TWIST_MAX end
		yawHip = NA(yawTorso - tw)
		g_VR.characterHipYaw, g_VR.characterTorsoYaw = yawHip, yawTorso
		g_VR.characterYaw = NA(yawHip + tw * 0.5)
	end

	------------------------------------------------------------------------
	-- LYING DOWN (prone / supine), done by the rig, no sequence. The body
	-- frame goes into SetRenderAngles, and both solvers already work in the
	-- model's own frame (classic through plyAng like a seat, Hai IK on the
	-- drawn torso), so arms, head and fingers keep tracking.
	--   blend   : driven by HMD height, not time. 0 where the squat bottoms
	--             out (crouch maxed), 1 at vrmod_lieheight. The crouch stays on
	--             and unbends as it rises.
	--   tipping : the pose being tipped is MEASURED, not assumed: head and
	--             mid-feet from the bone callback, in model space, so a squat,
	--             the sit pose or a straight body all pivot right. The body
	--             rotates over its feet until the head reaches the HMD's head
	--             point with the feet on the floor. At the band top the head
	--             over the feet is squeezed down to that height, so the solve
	--             starts at no tilt -- no stand-up, no sinking -- and opens up
	--             to the real pose as the blend grows.
	--   base    : entered from the sit pose (Sit on), lying keeps sit_zen until
	--             fully down and takes it back on the way up, instead of
	--             swapping to a standing anim mid-tip.
	--   heading : the head's up axis runs feet -> head. When it's vertical
	--             (prone looking ahead, supine chin down) the face direction
	--             takes over, signed by which way up you are.
	--   up side : a roll about the body axis, 0 prone / 180 supine. Lying, a
	--             change rolls the body over; still near upright, it swaps
	--             yaw and roll together so the facing doesn't spin.
	-- Everything comes from the lerped frame: remote players need no extra
	-- networking. Stepped once per frame; stereo/spec passes reuse it.
	------------------------------------------------------------------------
	local LIE_LIFT = 3 -- foot bones over the floor
	local LIE_BAND = 4 -- shortest height range the blend runs over
	local LIE_NEAR = 10 -- start measuring the pose this far above the band
	local CROUCH_MAX = 40 -- the crouch clamp both solvers use
	local deg, rad, acos, atan2, sqrt, cos, sin = math.deg, math.rad, math.acos, math.atan2, math.sqrt, math.cos, math.sin
	local Approach, Clamp, NormA = math.Approach, math.Clamp, math.NormalizeAngle
	local function LieUpdate(ply, info, frame, plyPos, hd, steamid)
		local fn = FrameNumber()
		if info.lieF == fn then return info.lieT end
		info.lieF = fn
		local lh, s0, eyeH = CharCfg(ply).lieHeight or 0, info.lieT or 0, GetPlayerEyeHeight(ply)
		local hh = frame.hmdPos.z - plyPos.z
		local top = eyeH - CROUCH_MAX
		if top < lh + LIE_BAND then top = lh + LIE_BAND end
		info.lieNear = lh > 0 and hh < top + LIE_NEAR or nil
		local t = 0
		if lh > 0 and not POSE.seq[ply] and (s0 > 0 or ply:OnGround()) then
			t = Clamp((top - hh) / (top - lh), 0, 1)
			t = t * t * (3 - 2 * t)
		end
		info.lieT, info.vrLie = t, t > 0 or nil
		if t == 0 then
			info.lieAng, info.lieSit, info.lieP = nil, nil, nil
			return 0
		end
		if s0 == 0 then info.lieSit = info.vrSitting end
		local ha = frame.hmdAng
		local fwd, up = ha:Forward(), ha:Up()
		local fz, was = fwd.z, info.lieSup
		local sup = was
		if s0 == 0 then
			sup = fz > 0
		elseif fz > 0.35 then
			sup = true
		elseif fz < -0.1 then
			sup = false
		end
		info.lieSup = sup
		local w = (1 - sqrt(up.x * up.x + up.y * up.y)) * (sup and -1 or 1)
		local yaw, roll = deg(atan2(up.y + fwd.y * w, up.x + fwd.x * w)), sup and 180 or 0
		local settled = false
		if s0 == 0 then
			-- Start from the standing facing: yaw + roll == characterYaw.
			info.lieRoll, info.lieYaw = roll, frame.characterYaw - roll
		else
			if sup ~= was and t < 0.5 then
				info.lieYaw, info.lieRoll = info.lieYaw + info.lieRoll - roll, roll
			end
			local r, d = Approach(info.lieRoll, roll, RealFrameTime() * 360), NormA(yaw - info.lieYaw)
			local k = RealFrameTime() * 6
			info.lieRoll, info.lieYaw = r, info.lieYaw + d * (k < 1 and k or 1)
			settled = r == roll and d < 0.5 and d > -0.5
		end
		roll = info.lieRoll
		-- Head point (where the head bone belongs) and the pose's head over
		-- feet, its height squeezed to the head point's at the band top.
		local ht = info.lieHT or Vector()
		ht:Set(fwd)
		ht:Mul(-hd)
		ht:Add(frame.hmdPos)
		info.lieHT = ht
		local k = ht.z - plyPos.z - LIE_LIFT
		local hl, fl, off = info.lieHeadL, info.lieFootL, info.lieOff or Vector()
		local fx, fy, fz2, ex, ey, ez = 0, 0, 0, 0, 0, eyeH
		if hl and fl then
			fx, fy, fz2 = fl:Unpack()
			ex, ey, ez = hl.x - fx, hl.y - fy, hl.z - fz2
		end
		-- Classic's measured pose is the real squat (its bends are bone
		-- manipulations), so it tips as soon as the head goes below it. Hai
		-- IK squats in the solver, after the measurement, so its standing pose
		-- is squeezed down to the head at the band top and opens up with the
		-- blend (its own spine covers the squat until then).
		if info.hikBody and ez > k then ez = k + (ez - k) * t end
		-- The head's offset over the feet opens up with the blend as well, so
		-- the tip starts at exactly 0 whichever way it goes.
		ex, ey = ex * t, ey * t
		off:SetUnpacked(fx + ex, fy + ey, fz2 + ez)
		info.lieOff = off -- origin -> (squeezed) head, model space
		-- Tip over the feet: z of the rotated head-over-feet == k.
		--   ez*cos(p) - x*sin(p) = k, x = forward part after the roll
		local r = rad(roll)
		local x = ex * cos(r) - ey * sin(r)
		-- The tip that goes down past the feet. (Picking "the branch nearest
		-- last frame" let a clamped backwards solution sit at 0 from the start
		-- and win every frame after: the body never tipped -- upright prone.)
		local R, p = sqrt(x * x + ez * ez), 0
		if R > 1e-3 then p = Clamp(deg(acos(Clamp(k / R, -1, 1)) - atan2(x, ez)), 0, 90) end
		info.lieP = p
		local ang = info.lieAng or Angle()
		ang:SetUnpacked(p, info.lieYaw, 0)
		ang:RotateAroundAxis(ang:Up(), roll)
		info.lieAng = ang
		-- Still turning: re-solve the arms even if the frame itself didn't move.
		if not settled then lastFrames[steamid] = nil end
		return t
	end

	------------------------------------------------------------------------
	-- ROOT. The hips sit right under the head (the old placement) and only
	-- move off it for the head-tilt lean: leaning swings the head toward the
	-- tilt, so the hips shift the other way by that swing (measured off the
	-- bones for classic, hipToHead for Hai IK), easing at SHIFT_RATE. Head
	-- position alone never offsets them.
	-- The lean's "down" latch lives here too: it builds while the head goes
	-- down tilted or nodded (DOWN_DIST of descent = full), holds while that
	-- holds, and lets go (RELEASE/s) when the tilt drops under TILT_HOLD
	-- degrees and the nod under PITCH_DEAD, or the head rises faster than
	-- UP_SPEED. Stepped once per frame.
	------------------------------------------------------------------------
	local SHIFT_RATE, DOWN_DIST, TILT_HOLD, UP_SPEED, RELEASE = 6, 12, 6, 20, 2
	local TILT_HOLD_SIN = math.sin(math.rad(TILT_HOLD))
	local PITCH_HOLD_SIN = math.sin(math.rad(PITCH_DEAD))
	-- LEAN-OVER. The hull follows the hips (locomotion). When something
	-- holds it back -- a table, a railing, a crate -- while the head goes on
	-- over it, the hips stay with the hull and the spine leans out to the
	-- head: the body is drawn up to info.leanReach (what the model can reach
	-- from there, measured by the solver) off its usual spot, toward the
	-- hull, past OVER_DEAD (the hull's ordinary follow lag). Locomotion only
	-- pushes the view back for what's beyond that reach.
	local OVER_DEAD, OVER_RATE = 3, 12
	local GetMoveType = FindMetaTable("Entity").GetMoveType
	local function BodyRoot(ply, info, frame, ix, iy, plyPos, steamid)
		local plyZ = plyPos.z
		local r, fn = info.root, FrameNumber()
		if r and info.rootF == fn then return r.x, r.y end
		info.rootF = fn
		local dt = RealFrameTime()
		info.moveW = math.Approach(info.moveW or 0, (frame.stickMoving or not ply:OnGround()) and 1 or 0, dt * 4)
		-- Weapon stance weight for the feet (StanceHomes): 1 with the gun hand
		-- pointing ahead, easing to the plain stand as it points at the floor.
		-- Only with a weapon that has a stance (the unarmed anim already is
		-- the plain stand -- and empty hands hang pointing down).
		local wep, sw = ply:GetActiveWeapon(), 1
		if IsValid(wep) and wep.GetHoldType and wep:GetHoldType() ~= "normal" and wep:GetClass() ~= "weapon_vrmod_empty" then
			local ga = (ply == LocalPlayer() and g_VR.gunInLeftHand) and frame.lefthandAng or frame.righthandAng
			local gd = -ga:Forward().z
			gd = gd > 0 and math.asin(gd < 1 and gd or 1) / 1.5707963 or 0
			sw = 1 - gd * gd * (3 - 2 * gd)
		end
		info.stanceW = math.Approach(info.stanceW or 1, sw, dt * 4)
		-- Neck height (HMD less ~3 forward, ~5 up in head space): nodding
		-- swings the HMD down around it, which shouldn't count as going down.
		local ha0 = frame.hmdAng
		local z = frame.hmdPos.z - ha0:Forward().z * 3 - ha0:Up().z * 5 - plyZ
		local dz = z - (info.hmdZ or z)
		info.hmdZ = z
		-- Held while either lean's input is past its threshold (scaled the way
		-- the sensitivity scales the lean, so a higher setting holds sooner).
		local ha = frame.hmdAng
		local tz, fz = ha:Right().z, ha:Forward().z
		local cv = CharCfg(ply)
		local ts, fs = cv.leanSens or 3.13, cv.leanSensFwd or 1.28
		tz = (tz < 0 and -tz or tz) * ts
		fz = fz < 0 and -fz or fz
		local held = tz > TILT_HOLD_SIN or (fs > 0 and fz > PITCH_HOLD_SIN)
		local d = info.downHold or 0
		if not held or (dt > 0 and dz > UP_SPEED * dt) then
			d = math.Approach(d, 0, dt * RELEASE)
		else
			-- net travel, so tracking jitter cancels instead of creeping up
			d = d - dz / DOWN_DIST
			d = d > 1 and 1 or d < 0 and 0 or d
		end
		info.downHold = d
		local k = dt * SHIFT_RATE
		k = k < 1 and k or 1
		local sx, sy = info.cbSX or 0, info.cbSY or 0
		local nx, ny = sx + ((info.cbX or 0) - sx) * k, sy + ((info.cbY or 0) - sy) * k
		info.cbSX, info.cbSY = nx, ny
		-- shift still easing: re-solve even if the frame didn't move
		if (nx - sx) * (nx - sx) + (ny - sy) * (ny - sy) > 1e-4 then lastFrames[steamid] = nil end
		local x, y = ix + nx, iy + ny
		-- Where the hips want to be (less the look-down clearance -- a camera
		-- nicety the hull shouldn't rock with). The local hull follows it.
		local hx, hy = x - (info.viewBX or 0), y - (info.viewBY or 0)
		if ply == LocalPlayer() then
			local hr = g_VR.hipRoot
			if not hr then
				hr = Vector()
				g_VR.hipRoot = hr
			end
			hr:SetUnpacked(hx, hy, 0)
			g_VR.hipRootF, g_VR.leanReach = fn, info.leanReach or 0
		end
		-- Lean-over: toward a held-back hull, up to the reach. Not in noclip:
		-- the hull doesn't follow the hips there at all (locomotion glues the
		-- playspace to it), so walking off it read as being held back and pinned
		-- the hips toward where the hull was left.
		local gx, gy = plyPos.x - hx, plyPos.y - hy
		local gl = sqrt(gx * gx + gy * gy)
		local m = gl - OVER_DEAD
		local reach = GetMoveType(ply) ~= MOVETYPE_NOCLIP and info.leanReach or 0
		m = m < reach and m or reach
		local tx, ty = 0, 0
		if m > 0 then tx, ty = gx / gl * m, gy / gl * m end
		k = dt * OVER_RATE
		k = k < 1 and k or 1
		local ox, oy = info.overX or 0, info.overY or 0
		ox, oy = ox + (tx - ox) * k, oy + (ty - oy) * k
		info.overX, info.overY = ox, oy
		x, y = x + ox, y + oy
		if not r then
			info.root, info.rootVX, info.rootVY = Vector(x, y, 0), 0, 0
			return x, y
		end
		local inv = dt > 0 and 1 / dt or 0
		info.rootVX, info.rootVY = (x - r.x) * inv, (y - r.y) * inv
		r.x, r.y = x, y
		return x, y
	end

	------------------------------------------------------------------------
	local function PrePlayerDrawFunc(ply)
		if not IsValid(ply) then return end
		local steamid = ply:SteamID()
		if not activePlayers[steamid] or not g_VR.net[steamid] or not g_VR.net[steamid].lerpedFrame then return end
		local info = characterInfo[steamid]
		if not info or not info.bones then return end
		-- Handle model changes (e.g. playermodel swap) - full re-init.
		if info.modelName ~= ply:GetModel() then
			g_VR.StopCharacterSystem(steamid)
			g_VR.StartCharacterSystem(ply)
			return
		end
		local headToHmdDist = GetPlayerHeadToHmdDist(ply)
		local netEntry = g_VR.net[steamid]
		local frame = netEntry.lerpedFrame

		local plyPos = ply:GetPos()
		info.preRenderPos = plyPos
		local poseAng = POSE.raw[ply]
		if poseAng then
			info.renderPos = plyPos
			ply:SetRenderAngles(poseAng)
			return
		end
		-- The player anim aims spine and head at the eye angles, which in VR
		-- follow the gun -- and the weapon stances twist the upper body hard by
		-- them. The split torso yaw does that job here, so neutralise them for
		-- this draw, both solvers (UpdateAnimation rewrites them next frame;
		-- the SetPos below invalidates the bone cache).
		ply:SetPoseParameter("aim_yaw", 0)
		ply:SetPoseParameter("aim_pitch", 0)
		ply:SetPoseParameter("head_yaw", 0)
		ply:SetPoseParameter("head_pitch", 0)
		local fbtT = FbtTargets(ply, steamid)
		if fbtT then
			-- FBT: the waist tracker is where the body stands -- over its xy on
			-- the floor, facing its yaw -- and the local hull follows it (no
			-- lean-over: the hips are real here). No lying tip or root logic.
			local p = fbtT.pelvisPos
			local renderPos, ang = Vector(p.x, p.y, plyPos.z), Angle(0, fbtT.pelvisAng.yaw, 0)
			info.lieAng, info.lieT, info.vrLie, info.lieNear, info.root = nil, nil, nil, nil, nil
			info.verticalCrouchOffset, info.horizontalCrouchOffset = 0, 0
			info.viewBX, info.viewBY, info.overX, info.overY, info.leanReach = 0, 0, 0, 0, 0
			if ply == LocalPlayer() then
				local hr = g_VR.hipRoot
				if not hr then
					hr = Vector()
					g_VR.hipRoot = hr
				end
				hr:SetUnpacked(p.x, p.y, 0)
				g_VR.hipRootF, g_VR.leanReach = FrameNumber(), 0
			end
			info.renderPos, info.renderAng = renderPos, ang
			ply:SetPos(renderPos)
			ply:SetRenderAngles(ang)
		elseif not ply:InVehicle() then
			-- Neck offset direction from characterYaw (stable) instead of
			-- up:Cross(hmdAng:Right()), whose sign flips past vertical pitch
			-- and shoved the body in front of the head.
			-- Distance is per-pose: sitting places the body a fixed,
			-- convar-set distance behind the head (no head-roll shrink -- body
			-- length doesn't change when the head turns); standing keeps the
			-- calibrated dist with the sideways-tilt shrink (Right's horizontal
			-- magnitude, which can't flip sign). Approached at 60u/s so pose
			-- changes slide the body instead of popping it.
			local lieT = LieUpdate(ply, info, frame, plyPos, headToHmdDist, steamid)
			local hd
			if info.vrSitting then
				hd = CharCfg(ply).sitHeadToHmdDist or 0
			else
				local r = frame.hmdAng:Right()
				hd = headToHmdDist * math.sqrt(r.x * r.x + r.y * r.y)
			end
			hd = math.Approach(info.hmdDist or hd, hd, RealFrameTime() * 60)
			info.hmdDist = hd
			-- Hips are the render frame (split yaw); the planted root holds the
			-- body's spot rather than riding the head.
			local hipYaw = frame.characterYaw - (frame.yawTwist or 0) * 0.5
			local yr, back = rad(hipYaw), hd + info.horizontalCrouchOffset * 0.8
			local vx, vy = 0, 0
			if ply == LocalPlayer() then vx, vy = ViewBack(frame, info) end
			info.viewBX, info.viewBY = vx, vy
			local rx, ry = BodyRoot(ply, info, frame, frame.hmdPos.x - cos(yr) * back + vx, frame.hmdPos.y - sin(yr) * back + vy, plyPos, steamid)
			local renderPos = Vector(rx, ry, plyPos.z - info.verticalCrouchOffset)
			local ang = info.lieAng
			if ang then
				-- Head on the head point, feet on the floor (LieUpdate's tilt),
				-- weighted from the base pose by the same height blend.
				local lp = info.lieHT - LocalToWorld(info.lieOff, zeroAng, zeroVec, ang)
				renderPos = lieT < 1 and LerpVector(lieT, renderPos, lp) or lp
			else
				ang = Angle(0, hipYaw, 0)
			end
			info.renderPos, info.renderAng = renderPos, ang
			ply:SetPos(renderPos)
			ply:SetRenderAngles(ang)
		else
			-- In a seat: drop the lying frame and the planted root; both start
			-- over on exit.
			info.root, info.viewBX, info.viewBY, info.overX, info.overY, info.leanReach = nil, 0, 0, 0, 0, 0
			if info.lieT then info.lieT, info.lieAng, info.vrLie, info.lieSit, info.lieP, info.lieNear = nil, nil, nil, nil, nil, nil end
		end

		-- SetupBones fires BoneCallbackFunc, which now does all bone writing
		-- (hand/head overrides, full IK apply, scaler/hider, head-hide). Keeping
		-- the apply inside the callback is what makes it survive PAC3's extra
		-- SetupBones passes. FBT self-guards inside the callback too.
		-- inDraw scopes UpdateIK to THIS SetupBones only (post-SetPos(renderPos)).
		-- Scoped here rather than Pre/PostPlayerDraw so a suppressed draw can't
		-- leave the flag stuck on.
		info.inDraw = true
		ply:SetupBones()
		info.inDraw = nil
		-- Physical feet: anything the solvers didn't record this frame (FBT)
		-- comes off the drawn foot / toe bones; then the pose goes out, once.
		if ply == LocalPlayer() and not ply:InVehicle() then
			local fp, fn, legs = g_VR.footPose, FrameNumber(), info.legs
			if legs and not (fp and fp.f == fn) then
				for i = 1, 2 do
					local L = legs[i]
					local mf, mt = ply:GetBoneMatrix(L.foot), L.toe and ply:GetBoneMatrix(L.toe)
					if mf then
						local F = mf:GetTranslation()
						FootPhys(i, F.x, F.y, F.z, F, mt and mt:GetTranslation(), info.renderAng and info.renderAng.y or 0)
					end
				end
				fp = g_VR.footPose
			end
			if fp and fp.f == fn and fp.sent ~= fn then
				fp.sent = fn
				SendFootPose(fp)
			end
		end
	end

	local function PostPlayerDrawFunc(ply)
		if not IsValid(ply) then return end
		local steamid = ply:SteamID()
		if not activePlayers[steamid] or not g_VR.net or not g_VR.net[steamid] or not g_VR.net[steamid].lerpedFrame then return end
		if not characterInfo or not characterInfo[steamid] then return end
		if ply:InVehicle() then return end
		ply:SetPos(characterInfo[steamid].preRenderPos)
	end

	------------------------------------------------------------------------
	local function CalcMainActivityFunc(ply, vel)
		if not activePlayers[ply:SteamID()] or ply:InVehicle() then return end
		local pseq = POSE.seq[ply]
		if pseq then return ACT_HL2MP_IDLE, pseq end
		-- When animations are disabled, force idle standing pose
		if not GetPlayerCharacterIK(ply) then
			ply:SetPlaybackRate(0)
			ply:SetPoseParameter("move_yaw", 0)
			ply:SetPoseParameter("move_x", 0)
			ply:SetPoseParameter("move_y", 0)
			return ACT_HL2MP_IDLE, -1
		end

		-- The ACT_MP_* activities, like the base gamemode's own: TranslateActivity
		-- maps them through the held weapon's hold type (rifle stance, pistol
		-- stance...), then to plain idle/walk/run when there's none. ACT_HL2MP_*
		-- skipped that, so every weapon stood with the unarmed legs.
		local act = ACT_MP_STAND_IDLE
		-- FBT players: only play walk/run during stick locomotion, not roomscale
		local sid = ply:SteamID()
		if g_VR.fbtActive and g_VR.fbtActive[sid] then
			local sm
			if ply == LocalPlayer() then
				local wd = g_VR.input and g_VR.input.vector2_walkdirection
				sm = wd and (wd.x * wd.x + wd.y * wd.y) > 0.04
			else
				local n = g_VR.net and g_VR.net[sid]
				sm = n and n.lerpedFrame and n.lerpedFrame.stickMoving
			end
			-- The trackers own the body: the plain unarmed cycle only (a weapon
			-- stance swung the shoulders out in front), and none of the sit /
			-- lie / planted-feet states, whose flags go stale under FBT.
			if not sm then return ACT_HL2MP_IDLE, -1 end
			if ply.m_bJumping then
				if CurTime() - ply.m_flJumpStartTime > 0.2 and ply:OnGround() then ply.m_bJumping = false end
				return ACT_HL2MP_JUMP_PASSIVE, -1
			end
			local l = vel:Length2DSqr()
			return l > 22500 and ACT_HL2MP_RUN or l > 0.25 and ACT_HL2MP_WALK or ACT_HL2MP_IDLE, -1
		end
		local ci = characterInfo and characterInfo[sid]
		if ply.m_bJumping then
			act = ACT_MP_JUMP
			if CurTime() - ply.m_flJumpStartTime > 0.2 and ply:OnGround() then ply.m_bJumping = false end
		else
			-- VR sit: head at/below vrmod_sitheight (live-read from the
			-- convar cache, 0 disables) ->
			-- play sit_zen (cross-legged, feet stay on the floor), moving or
			-- not, so stick-sliding while seated keeps the pose. +5u exit
			-- hysteresis so the boundary doesn't flicker. Sequence cached per
			-- charinfo init; LookupSequence gives -1 if the model lacks it, in
			-- which case we fall through to the normal walk/run/idle pose.
			-- Lying (vrLie, set in PrePlayerDraw) is the rig's: no walk cycle.
			-- Entered from sitting it tips the sit pose and only straightens to
			-- idle once fully down (and back on the way up); otherwise idle.
			if ci and ci.vrLie then
				local sq = ci.lieSit and ci.lieT < 1 and ci.vrSitSeq
				if sq and sq > 0 then
					ci.vrSitting = true
					return act, sq
				end
				ci.vrSitting = nil
				return act, -1
			end
			if ci and ply:OnGround() then
				local h = ci.vrHeadH or 100
				if h <= (CharCfg(ply).sitHeight or 40) + (ci.vrSitting and 5 or 0) then
					local seq = ci.vrSitSeq
					if not seq then
						seq = ply:LookupSequence("sit_zen") or -1
						ci.vrSitSeq = seq
					end
					if seq > 0 then
						ci.vrSitting = true
						return act, seq
					end
				end
			end
			-- Planted feet step on their own (SolveLegs): no walk cycle under
			-- them for roomscale moves. Stick walking fades them to the anim.
			if ci and ci.plantIdle then
				ci.vrSitting = nil
				return act, -1
			end
			local l = vel:Length2DSqr()
			if l > 22500 then
				act = ACT_MP_RUN
			elseif l > 0.25 then
				act = ACT_MP_WALK
			end
		end
		if ci then ci.vrSitting = nil end
		return act, -1
	end

	local function DoAnimationEventFunc(ply, evt, data)
		if not activePlayers[ply:SteamID()] or ply:InVehicle() then return end
		-- Block all animation events when animations are disabled
		if not GetPlayerCharacterIK(ply) then return ACT_INVALID end
		if evt ~= PLAYERANIMEVENT_JUMP then return ACT_INVALID end
	end

	------------------------------------------------------------------------
	function g_VR.StartCharacterSystem(ply)
		if not IsValid(ply) then return end
		local steamid = ply:SteamID()
		local initResult = CharacterInit(ply)
		local tname = "vrmod_charinit_" .. steamid
		if initResult == false then
			-- Deferred: the playermodel isn't networked yet. 20 frames (~0.3s) only
			-- covered the respawn race; a client joining mid-session waits on a
			-- remote model for far longer and used to give up permanently, leaving
			-- that player in desktop anims until they died. One self-terminating
			-- timer covers 10s at 4 calls/sec, instead of a closure per frame.
			if not timer.Exists(tname) then
				timer.Create(tname, 0.25, 40, function()
					if IsValid(ply) and g_VR.net and g_VR.net[steamid] and not activePlayers[steamid] then
						g_VR.StartCharacterSystem(ply)
					else
						timer.Remove(tname)
					end
				end)
			end
			return
		end
		timer.Remove(tname)
		if not g_VR.net or not g_VR.net[steamid] then vrmod.logger.Warn("StartCharacterSystem: no net entry for " .. steamid) return end
		if not characterInfo[steamid] then vrmod.logger.Warn("StartCharacterSystem: no characterInfo for " .. steamid) return end
		local info = characterInfo[steamid]
		if info.boneCallback and info.boneCallback ~= 0 then
			ply:RemoveCallback("BuildBonePositions", info.boneCallback)
		end
		info.boneCallback = ply:AddCallback("BuildBonePositions", BoneCallbackFunc)
		if ply == LocalPlayer() then
			hook.Add("VRMod_PreRender", "vrutil_hook_calcplyrenderpos", PreRenderFunc)
		end
		-- hook.Add replaces same-name hooks natively, no need to Remove first.
		hook.Add("PrePlayerDraw", "vrutil_hook_preplayerdraw", PrePlayerDrawFunc)
		hook.Add("PostPlayerDraw", "vrutil_hook_postplayerdraw", PostPlayerDrawFunc)
		hook.Add("CalcMainActivity", "vrutil_hook_calcmainactivity", CalcMainActivityFunc)
		hook.Add("DoAnimationEvent", "vrutil_hook_doanimationevent", DoAnimationEventFunc)
		activePlayers[steamid] = true
		vrmod.logger.Info("Started character system for " .. steamid)
	end

	------------------------------------------------------------------------
	-- IK DEBUG (vrmod_ik_debug 1): per VR player, at chest height --
	--   green = hip yaw, blue = torso yaw, yellow = head yaw (from the frame),
	--   red = the chest bone's actual facing (MEASURED off Spine4: if blue
	--   and red disagree, the twist isn't reaching the bones),
	--   white circle = planted root, spheres = planted feet (cyan, magenta
	--   while stepping), plus a text readout above the head.
	-- The hook only exists while the convar is on.
	------------------------------------------------------------------------
	local cvIKDebug = CreateClientConVar("vrmod_ik_debug", "0", false, false, "Draw the VR body IK debug readout", 0, 1)
	local DBG_HIP, DBG_TORSO, DBG_HEAD, DBG_CHEST = Color(80, 255, 80), Color(80, 160, 255), Color(255, 230, 60), Color(255, 70, 70)
	local DBG_FOOT, DBG_STEP, DBG_ROOT = Color(0, 255, 255), Color(255, 0, 255), Color(255, 255, 255)
	local function DbgArrow(o, yaw, len, col)
		local r = math.rad(yaw)
		render.DrawLine(o, o + Vector(math.cos(r) * len, math.sin(r) * len, 0), col, false)
	end
	local function IKDebugDraw(depth, sky)
		if depth or sky then return end
		local eyeYaw = EyeAngles().yaw
		for steamid, info in pairs(characterInfo) do
			local ply, nt = info.player, g_VR.net and g_VR.net[steamid]
			local f = nt and nt.lerpedFrame
			if activePlayers[steamid] and IsValid(ply) and f and info.renderPos then
				local tw = f.yawTwist or 0
				local hip, torso = f.characterYaw - tw * 0.5, f.characterYaw + tw * 0.5
				local o = info.renderPos + Vector(0, 0, 45)
				DbgArrow(o, hip, 24, DBG_HIP)
				DbgArrow(o + Vector(0, 0, 2), torso, 24, DBG_TORSO)
				DbgArrow(o + Vector(0, 0, 4), f.hmdAng.yaw, 24, DBG_HEAD)
				local chain = info.spineChain
				local c = chain and chain[#chain]
				local m = c and ply:GetBoneMatrix(c.bone)
				local chestYaw
				if m then
					local d = LocalToWorld(c.fwd, zeroAng, zeroVec, m:GetAngles())
					chestYaw = math.deg(math.atan2(d.y, d.x))
					DbgArrow(o + Vector(0, 0, 6), chestYaw, 24, DBG_CHEST)
				end
				if info.root then
					local rp = Vector(info.root.x, info.root.y, info.preRenderPos.z + 1)
					render.DrawWireframeSphere(rp, 3, 8, 2, DBG_ROOT, false)
				end
				local legs = info.legOn and info.legs
				if legs then
					for i = 1, 2 do
						local L = legs[i]
						if L.px then render.DrawWireframeSphere(Vector(L.px, L.py, L.pz), 2, 6, 6, L.s and DBG_STEP or DBG_FOOT, false) end
					end
				end
				local hik = CharCfg(ply).characterIKSolver == 1 and info.hik
				local ox2, oy2 = 0, 0
				if info.root then
					local yr, back = math.rad(hip), (info.hmdDist or 0) + info.horizontalCrouchOffset * 0.8
					ox2, oy2 = info.root.x - (f.hmdPos.x - math.cos(yr) * back), info.root.y - (f.hmdPos.y - math.sin(yr) * back)
				end
				local txt = string.format("%s%s\nhip %.0f  torso %.0f  head %.0f\ntwist %.1f  chest-hip %s\ntilt lean %.1f%s\nhips off %.1f%s  move %.2f  down %.2f  lie %.2f",
					hik and (info.hikBody and "Hai IK (body)" or "Hai IK (arms)") or "classic", f.stickMoving and "  [stick]" or "",
					NAng(hip), NAng(torso), f.hmdAng.yaw, tw, chestYaw and string.format("%.1f", NAng(chestYaw - hip)) or "?",
					info.leanT or 0, string.format("  fwd %.1f", info.leanFwd or 0) .. (hik and "" or string.format("  feet %.2f", info.legW or 0)),
					math.sqrt(ox2 * ox2 + oy2 * oy2), "", info.moveW or 0, info.downHold or 0, info.lieT or 0)
				if (info.lieT or 0) > 0 then
					txt = txt .. string.format("\nlie tip %.0f  roll %.0f  %s  render pitch %.0f", info.lieP or 0, info.lieRoll or 0, info.lieSup and "supine" or "prone", info.renderAng and info.renderAng.p or 0)
				end
				cam.Start3D2D(info.renderPos + Vector(0, 0, 88), Angle(0, eyeYaw - 90, 90), 0.08)
				local y = 0
				for line in string.gmatch(txt, "[^\n]+") do
					draw.SimpleTextOutlined(line, "DermaLarge", 0, y, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2, color_black)
					y = y + 34
				end
				cam.End3D2D()
			end
		end
	end
	local function IKDebugSet(on)
		if on then hook.Add("PostDrawTranslucentRenderables", "vrmod_ik_debug", IKDebugDraw) else hook.Remove("PostDrawTranslucentRenderables", "vrmod_ik_debug") end
	end
	cvars.AddChangeCallback("vrmod_ik_debug", function(_, _, v) IKDebugSet(v == "1") end, "vrmod_ik_debug")
	IKDebugSet(cvIKDebug:GetBool())

	function g_VR.StopCharacterSystem(steamid)
		-- Note: Do NOT early-exit on activePlayers[steamid] here. Failed CharacterInit
		-- paths call StopCharacterSystem before activePlayers is set, and we still need
		-- to clean up any partial characterInfo / lastFrames entries.
		local wasActive = activePlayers[steamid] ~= nil
		local ply = player.GetBySteamID(steamid)
		if characterInfo[steamid] and IsValid(ply) then
			local bones = characterInfo[steamid].bones
			for k, v in pairs(bones) do
				if not isnumber(v) then continue end
				ply:ManipulateBoneAngles(v, ZERO_ANG)
			end

			if characterInfo[steamid].boneCallback and characterInfo[steamid].boneCallback ~= 0 then
				ply:RemoveCallback("BuildBonePositions", characterInfo[steamid].boneCallback)
			end
			if ply == LocalPlayer() then
				g_VR.characterHipYaw, g_VR.characterTorsoYaw = nil, nil
				hook.Remove("VRMod_PreRender", "vrutil_hook_calcplyrenderpos")
				if bones.b_head and bones.b_head ~= -1 then
					ply:ManipulateBoneScale(bones.b_head, VEC_ONE)
				end
			end
		end

		activePlayers[steamid] = nil
		characterInfo[steamid] = nil
		lastFrames[steamid] = nil
		timer.Remove("vrmod_charinit_" .. steamid)
		if not next(activePlayers) then
			hook.Remove("PrePlayerDraw", "vrutil_hook_preplayerdraw")
			hook.Remove("PostPlayerDraw", "vrutil_hook_postplayerdraw")
			hook.Remove("UpdateAnimation", "vrutil_hook_updateanimation")
			hook.Remove("CalcMainActivity", "vrutil_hook_calcmainactivity")
			hook.Remove("DoAnimationEvent", "vrutil_hook_doanimationevent")
		end

		if wasActive then vrmod.logger.Info("Stopped character system for " .. steamid) end
	end

	hook.Add("VRMod_Start", "vrmod_characterstart", function(ply) g_VR.StartCharacterSystem(ply) end)
	hook.Add("VRMod_Exit", "vrmod_characterstop", function(ply, steamid) g_VR.StopCharacterSystem(steamid) end)

	------------------------------------------------------------------------
	-- ArcVR MP: weapon worldmodel rendering for other VR players
	-- Handles left-hand weapons (hide engine worldmodel, draw CSModel at
	-- left hand) and dual-wield ghost weapons (draw second CSModel).
	------------------------------------------------------------------------
	local avrMP = {} -- [steamid] = { wepModel, wepClass, dwModel, dwClass }

	local function AvrComputeVMI(class)
		if g_VR.viewModelInfo and g_VR.viewModelInfo[class] and g_VR.viewModelInfo[class].offsetPos then
			local e = g_VR.viewModelInfo[class]
			return Vector(e.offsetPos), Angle(e.offsetAng or angle_zero)
		end
		local def = weapons.GetStored(class)
		if not def then return end
		local vmPath = def.ViewModel or ""
		if vmPath == "" then return end
		local cm = ClientsideModel(vmPath)
		if not IsValid(cm) then return end
		cm:SetupBones()
		local bone = cm:LookupBone("ValveBiped.Bip01_R_Hand")
		local oP, oA = vector_origin, angle_zero
		if bone then
			local mat = cm:GetBoneMatrix(bone)
			if mat then
				local bAng = mat:GetAngles()
				bAng:RotateAroundAxis(bAng:Forward(), 180)
				oP, oA = WorldToLocal(vector_origin, angle_zero, mat:GetTranslation(), bAng)
			end
		end
		cm:Remove()
		return oP, oA
	end

	-- VMI offset cache to avoid recomputing
	local avrVMICache = {}
	local function AvrGetVMI(class)
		if avrVMICache[class] then return avrVMICache[class].p, avrVMICache[class].a end
		local p, a = AvrComputeVMI(class)
		if p then avrVMICache[class] = { p = p, a = a } end
		return p, a
	end

	local function AvrMakeModel(vmPath)
		local mdl = ClientsideModel(vmPath, RENDERGROUP_OPAQUE)
		if not IsValid(mdl) then return nil end
		mdl:SetNoDraw(true)
		mdl:SetRenderBoundsWS(Vector(-32000, -32000, -32000), Vector(32000, 32000, 32000))
		return mdl
	end

	local function AvrCleanup(steamid)
		local mp = avrMP[steamid]
		if not mp then return end
		if IsValid(mp.wepModel) then mp.wepModel:Remove() end
		if IsValid(mp.dwModel) then mp.dwModel:Remove() end
		avrMP[steamid] = nil
	end

	local function AvrPositionModel(mdl, class, handPos, handAng, isLeftHand)
		local pos, ang = Vector(handPos), Angle(handAng)
		local oP, oA = AvrGetVMI(class)
		if oP then pos, ang = LocalToWorld(oP, oA, pos, ang) end
		if isLeftHand and ArcticVR and ArcticVR.DualWieldGhostOffset then
			pos, ang = LocalToWorld(ArcticVR.DualWieldGhostOffset, angle_zero, pos, ang)
		end
		mdl:SetPos(pos)
		mdl:SetAngles(ang)
		mdl:SetupBones()
	end

	-- Think: manage SetNoDraw flags and CSModel lifecycle only (no positioning)
	hook.Add("Think", "avr_mp_weapons", function()
		if not g_VR.net then return end
		local lp = LocalPlayer()
		for steamid, netdata in pairs(g_VR.net) do
			local ply = player.GetBySteamID(steamid)
			if not IsValid(ply) or ply == lp then continue end

			local gunInLeft = ply:GetNWBool("avr_GunInLeft", false)
			local isDW = ply:GetNWBool("avr_DW", false)
			local mp = avrMP[steamid]

			-- ── Active weapon in left hand ──
			if gunInLeft then
				local wep = ply:GetActiveWeapon()
				if IsValid(wep) then
					wep:SetNoDraw(true)
					if not mp then mp = {} avrMP[steamid] = mp end
					local wepClass = wep:GetClass()
					local def = weapons.GetStored(wepClass)
					local vmPath = def and def.ViewModel or ""
					if mp.wepClass ~= wepClass and vmPath ~= "" then
						if IsValid(mp.wepModel) then mp.wepModel:Remove() end
						mp.wepModel = AvrMakeModel(vmPath)
						mp.wepClass = wepClass
					end
				end
			else
				if mp and IsValid(mp.wepModel) then mp.wepModel:Remove() mp.wepModel = nil mp.wepClass = nil end
				local wep = ply:GetActiveWeapon()
				if IsValid(wep) then wep:SetNoDraw(false) end
			end

			-- ── Dual wield ghost ──
			if isDW then
				local dwClass = ply:GetNWString("avr_DWClass", "")
				if dwClass ~= "" then
					if not mp then mp = {} avrMP[steamid] = mp end
					local def = weapons.GetStored(dwClass)
					local vmPath = def and def.ViewModel or ""
					if mp.dwClass ~= dwClass and vmPath ~= "" then
						if IsValid(mp.dwModel) then mp.dwModel:Remove() end
						mp.dwModel = AvrMakeModel(vmPath)
						mp.dwClass = dwClass
					end
				end
			else
				if mp and IsValid(mp.dwModel) then mp.dwModel:Remove() mp.dwModel = nil mp.dwClass = nil end
			end
		end
	end)

	-- Draw: position from freshest lerpedFrame then render (after PreRender lerp)
	hook.Add("PostDrawTranslucentRenderables", "avr_mp_draw", function(depth, sky)
		if depth or sky then return end
		if not g_VR.net then return end
		local lp = LocalPlayer()
		for steamid, mp in pairs(avrMP) do
			local netdata = g_VR.net[steamid]
			if not netdata then continue end
			local frame = netdata.lerpedFrame
			if not frame then continue end
			local ply = player.GetBySteamID(steamid)
			if not IsValid(ply) or ply == lp then continue end
			render.SetColorModulation(1, 1, 1)
			if IsValid(mp.wepModel) and mp.wepClass then
				AvrPositionModel(mp.wepModel, mp.wepClass, frame.lefthandPos, frame.lefthandAng, true)
				mp.wepModel:DrawModel()
			end
			if IsValid(mp.dwModel) and mp.dwClass then
				local dwLeft = ply:GetNWBool("avr_DWLeft", false)
				local hPos = dwLeft and frame.lefthandPos or frame.righthandPos
				local hAng = dwLeft and frame.lefthandAng or frame.righthandAng
				AvrPositionModel(mp.dwModel, mp.dwClass, hPos, hAng, dwLeft)
				mp.dwModel:DrawModel()
			end
		end
	end)

	hook.Add("VRMod_Exit", "avr_mp_cleanup", function(ply, steamid)
		-- Restore weapon visibility before cleanup
		if IsValid(ply) then
			local wep = ply:GetActiveWeapon()
			if IsValid(wep) then wep:SetNoDraw(false) end
		end
		AvrCleanup(steamid)
	end)
end