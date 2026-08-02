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
	local ANGLE_THRESHOLD = 0.01
	local POS_THRESHOLD = 0.01
	local zeroVec, zeroAng = ZERO_VEC, ZERO_ANG
	-- Per-player characterIK lookup: LocalPlayer uses local convar,
	-- remote players use the value networked via vrmod_characterik_sync.
	local function GetPlayerCharacterIK(ply)
		if ply == LocalPlayer() then return convarValues.characterIK end
		local n = g_VR.net and g_VR.net[ply:SteamID()]
		return not n or n.characterIK ~= false
	end
	local function GetPlayerEyeHeight(ply)
		if ply ~= LocalPlayer() then
			local n = g_VR.net and g_VR.net[ply:SteamID()]
			if n then
				local lf = n.lerpedFrame
				if lf and lf.eyeHeight then return lf.eyeHeight end
				if n.charEyeHeight then return n.charEyeHeight end
			end
		end
		return convarValues.characterEyeHeight or 66.8
	end
	local function GetPlayerHeadToHmdDist(ply)
		if ply ~= LocalPlayer() then
			local n = g_VR.net and g_VR.net[ply:SteamID()]
			if n then
				local lf = n.lerpedFrame
				if lf and lf.headToHmd then return lf.headToHmd end
				if n.charHeadToHmd then return n.charHeadToHmd end
			end
		end
		return convarValues.characterHeadToHmdDist or 6.3
	end
	------------------------------------------------------------------------
	-- CONVARS
	------------------------------------------------------------------------
	vrmod.AddCallbackedConvar("vrmod_charactereyeheight", "characterEyeHeight", "66.8", FCVAR_ARCHIVE, "Character eye height", 30, 100, tonumber)
	vrmod.AddCallbackedConvar("vrmod_characterheadtohmddist", "characterHeadToHmdDist", "6.3", FCVAR_ARCHIVE, "Head to HMD distance", 0, 20, tonumber)
	vrmod.AddCallbackedConvar("vrmod_characterik", "characterIK", "1", FCVAR_ARCHIVE, "Enable character IK", nil, nil, tobool)
	vrmod.AddCallbackedConvar("vrmod_armstretcher", "armStretcher", "0", FCVAR_ARCHIVE, "Enable arm stretching", nil, nil, tobool)
	vrmod.AddCallbackedConvar("vrmod_characteryawblend", "characterYawBlend", "1.5", FCVAR_ARCHIVE, "Character yaw source", 1, 2, tonumber)
	vrmod.AddCallbackedConvar("vrmod_sitheight", "sitHeight", "40", FCVAR_ARCHIVE, "Head height above feet at/below which the sit anim plays (0 = off)", 0, 60, tonumber)
	vrmod.AddCallbackedConvar("vrmod_proneheight", "proneHeight", "15", FCVAR_ARCHIVE, "Head height above feet at/below which the prone anim plays (0 = off, needs wOS prone mod)", 0, 60, tonumber)
	vrmod.AddCallbackedConvar("vrmod_sitheadtohmddist", "sitHeadToHmdDist", "0", FCVAR_ARCHIVE, "HMD to body distance while sitting", 0, 20, tonumber)
	vrmod.AddCallbackedConvar("vrmod_proneheadtohmddist", "proneHeadToHmdDist", "26", FCVAR_ARCHIVE, "HMD to body distance while prone", 0, 40, tonumber)
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
		panel:NumSlider("Body Yaw Source", "vrmod_characteryawblend", 1, 2, 1)
		panel:Help("1 = head direction only, 2 = arm direction only. Blend in between.")
		panel:ControlHelp("\n--- Model Calibration ---")
		panel:NumSlider("Eye Height", "vrmod_charactereyeheight", 30, 100, 1)
		panel:Help("Character eye height in source units. Default 66.8. Affects crouching and body position.")
		panel:NumSlider("Head to HMD Distance", "vrmod_characterheadtohmddist", 0, 20, 1)
		panel:Help("Distance from HMD to head bone. Default 6.3.")
		panel:ControlHelp("\n")
		local restoreBtn = panel:Button("Restore Defaults")
		restoreBtn.DoClick = function()
			RunConsoleCommand("vrmod_characterik", "1")
			RunConsoleCommand("vrmod_armstretcher", "0")
			RunConsoleCommand("vrmod_characteryawblend", "1.5")
			RunConsoleCommand("vrmod_charactereyeheight", "66.8")
			RunConsoleCommand("vrmod_characterheadtohmddist", "6.3")
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
	local prevFrameNumber = 0
	local cv_minsend
	local lastFrames = {}
	local characterInfo = {}
	local activePlayers = {}
	local updatedPlayers = {}
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
	local cv_altheadauto
	local function UseAltHead(netEntry, charinfo)
		if netEntry and netEntry.characterAltHead then return true end
		cv_altheadauto = cv_altheadauto or GetConVar("vrmod_althead_auto")
		return (not cv_altheadauto or cv_altheadauto:GetBool()) and charinfo ~= nil and (charinfo.headChildren or 0) > 1
	end

	local function UpdateIK(ply)
		local steamid = ply:SteamID()
		local net = g_VR.net[steamid]
		local charinfo = characterInfo[steamid]
		local boneinfo = charinfo.boneinfo
		local bones = charinfo.bones
		local frame = net.lerpedFrame
		-- Skip the IK re-solve if the frame hasn't moved past vrmod_net_minsend.
		-- minsend is now purely this visual threshold -- networking streams at
		-- full precision regardless (see sh_network / sh_frames).
		cv_minsend = cv_minsend or GetConVar("vrmod_net_minsend")
		if lastFrames[steamid] and vrmod.utils.FramesAreEqual(frame, lastFrames[steamid], cv_minsend and cv_minsend:GetFloat() or 0.1) then return end
		local inVehicle = ply:InVehicle()
		local plyAng = inVehicle and ply:GetVehicle():GetAngles() or Angle(0, frame.characterYaw, 0)
		if inVehicle then _, plyAng = LocalToWorld(zeroVec, Angle(0, 90, 0), zeroVec, plyAng) end
		-- Read per-player calibration (reactive to slider changes)
		local eyeHeight = GetPlayerEyeHeight(ply)
		-- Alt head
		if UseAltHead(net, charinfo) then
			local _, tmp2 = WorldToLocal(zeroVec, frame.hmdAng, zeroVec, Angle(0, frame.characterYaw, 0))
			ply:ManipulateBoneAngles(bones.b_head, Angle(-tmp2.roll, -tmp2.pitch, tmp2.yaw))
		end

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
			charinfo.vrSitBlend = math.Approach(charinfo.vrSitBlend or 0, (charinfo.vrSitting or charinfo.vrProne) and 1 or 0, RealFrameTime() * 3)
			cutAmount = cutAmount * (1 - charinfo.vrSitBlend)
			local spineTargetLen = spineLen - cutAmount * 0.5
			local a1 = math.acos(math.Clamp(spineTargetLen / spineLen, -1, 1))
			charinfo.horizontalCrouchOffset = math.sin(a1) * spineLen
			ply:ManipulateBoneAngles(bones.b_spine, Angle(0, math.deg(a1), 0))
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

			ply:ManipulateBoneAngles(bones.b_leftCalf, Angle(0, -(a23 - 180), 0))
			ply:ManipulateBoneAngles(bones.b_leftThigh, Angle(0, -a1, 0))
			ply:ManipulateBoneAngles(bones.b_rightCalf, Angle(0, -(a23 - 180), 0))
			ply:ManipulateBoneAngles(bones.b_rightThigh, Angle(0, -a1, 0))
			ply:ManipulateBoneAngles(bones.b_leftFoot, Angle(0, -a1, 0))
			ply:ManipulateBoneAngles(bones.b_rightFoot, Angle(0, -a1, 0))
		else
			ply:ManipulateBoneAngles(bones.b_spine, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_leftCalf, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_leftThigh, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_rightCalf, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_rightThigh, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_leftFoot, Angle(0, 0, 0))
			ply:ManipulateBoneAngles(bones.b_rightFoot, Angle(0, 0, 0))
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
			if not inVehicle then
				clavicleTargetAng = (tmp2 - claviclePos):Angle()
			else
				_, clavicleTargetAng = LocalToWorld(Vector(), WorldToLocal(tmp2 - claviclePos, zeroAng, zeroVec, plyAng):Angle(), zeroVec, plyAng)
			end

			clavicleTargetAng:RotateAroundAxis(clavicleTargetAng:Forward(), 90)
			local upperarmPos = LocalToWorld(boneinfo[upperarmBone].relativePos, boneinfo[upperarmBone].relativeAng, claviclePos, clavicleTargetAng)
			local targetVec = targetPos - upperarmPos
			local targetVecLen = targetVec:Length()
			local targetVecAng, targetVecAngLocal
			if not inVehicle then
				targetVecAng = targetVec:Angle()
			else
				targetVecAngLocal = WorldToLocal(targetVec, zeroAng, zeroVec, plyAng):Angle()
				_, targetVecAng = LocalToWorld(Vector(), targetVecAngLocal, zeroVec, plyAng)
			end

			local upperarmTargetAng = Angle(targetVecAng.pitch, targetVecAng.yaw, targetVecAng.roll)
			if not isLeft then upperarmTargetAng:RotateAroundAxis(targetVec, 180) end
			local tmp
			if not inVehicle then
				tmp = Angle(targetVecAng.pitch, frame.characterYaw, isLeft and -90 or 90)
			else
				_, tmp = LocalToWorld(Vector(), Angle((targetVecAngLocal or targetVecAng).pitch, 0, isLeft and -90 or 90), zeroVec, plyAng)
			end

			local _, tang = WorldToLocal(zeroVec, tmp, zeroVec, targetVecAng)
			upperarmTargetAng:RotateAroundAxis(upperarmTargetAng:Forward(), tang.roll)
			local totalArmLen = charinfo.upperArmLen + charinfo.lowerArmLen
			local armStretchScale = 1
			local effUpper, effLower = charinfo.upperArmLen, charinfo.lowerArmLen
			if convarValues.armStretcher and targetVecLen > totalArmLen * 0.98 then
				armStretchScale = targetVecLen / (totalArmLen * 0.98)
				effUpper = charinfo.upperArmLen * armStretchScale
				effLower = charinfo.lowerArmLen * armStretchScale
			end

			charinfo[prefix .. "armStretchScale"] = armStretchScale
			local a1 = math.deg(math.acos(math.Clamp((effUpper * effUpper + targetVecLen * targetVecLen - effLower * effLower) / (2 * effUpper * targetVecLen), -1, 1)))
			if a1 == a1 then upperarmTargetAng:RotateAroundAxis(upperarmTargetAng:Up(), a1) end
			local test
			if not inVehicle then
				test = (targetPos.z - upperarmPos.z + 20) * 1.5
			else
				test = ((targetPos - upperarmPos):Dot(plyAng:Up()) + 20) * 1.5
			end

			if test < 0 then test = 0 end
			upperarmTargetAng:RotateAroundAxis(targetVec:GetNormalized(), (isLeft and 1 or -1) * (30 + test))
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

		lastFrames[steamid] = vrmod.utils.CopyFrame(frame)
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
				return false
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
		cm:Remove()
	end

	------------------------------------------------------------------------
	local function BoneCallbackFunc(ply, numbones)
		local steamid = ply:SteamID()
		local netEntry = g_VR.net[steamid]
		local info = characterInfo[steamid]
		if not activePlayers[steamid] or not netEntry or not netEntry.lerpedFrame or not info then return end
		if g_VR.fbtActive[steamid] then return end -- FBT handles all bones
		local frame = netEntry.lerpedFrame
		local bones = info.bones
		local rightHandBone = bones.b_rightHand
		if rightHandBone ~= -1 and ply:GetBoneMatrix(rightHandBone) then
			ply:SetBonePosition(rightHandBone, frame.righthandPos, frame.righthandAng + RIGHT_HAND_OFFSET)
		end
		if not UseAltHead(netEntry, info) then
			local _, targetAng = LocalToWorld(zeroVec, Angle(-80, 0, 90), zeroVec, frame.hmdAng)
			local headBone = bones.b_head
			local mtx = headBone ~= -1 and ply:GetBoneMatrix(headBone) or nil
			if mtx then
				mtx:SetAngles(targetAng)
				ply:SetBoneMatrix(headBone, mtx)
			end
		end

		-- Full-body IK is applied HERE, inside the bone callback, so it
		-- re-applies on EVERY SetupBones. PAC3 forces extra SetupBones passes
		-- (PreDrawOpaqueRenderables -> RenderOverride) whenever the player has
		-- any parts; with the apply loop outside the callback those passes
		-- reset the clavicle/arm chain to the anim pose -- the "PAC3 breaks
		-- shoulders" bug. UpdateIK stays gated to once per frame; only the
		-- cheap SetBoneMatrix writes re-run on the extra passes.
		if prevFrameNumber ~= FrameNumber() then
			prevFrameNumber = FrameNumber()
			updatedPlayers = {}
		end
		-- Only consume the once-per-frame UpdateIK slot inside the PrePlayerDraw
		-- window (info.inDraw, body at renderPos). A held weapon's render
		-- bonemerges against the owner and forces a SetupBones BEFORE
		-- PrePlayerDraw, at the pre-shift position; letting UpdateIK run there
		-- anchored the clavicle/spine chain to the wrong body AND wrote
		-- lastFrames, so the post-shift re-run early-returned on FramesAreEqual
		-- -- the "remote IK breaks while holding a weapon" bug. Early passes
		-- still get the hand/head overrides above (all a bonemerged weapon
		-- needs) plus last frame's world-space matrices below.
		if not updatedPlayers[steamid] and info.inDraw then
			UpdateIK(ply)
			updatedPlayers[steamid] = 1
		end
		local boneorder = info.boneorder
		local boneinfo = info.boneinfo
		if boneorder and boneinfo then
			for i = 1, #boneorder do
				local bone = boneorder[i]
				local bi = boneinfo[bone]
				if bi and bi.targetMatrix and ply:GetBoneMatrix(bone) then
					ply:SetBoneMatrix(bone, bi.targetMatrix)
				end
			end
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
	local up = Vector(0, 0, 1)
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
		if fwd.z < 0.9 and fwd.z > -0.9 then
			headYaw = hmdAng.yaw
		else
			local upv = hmdAng:Up()
			headYaw = fwd.z > 0 and math.deg(math.atan2(-upv.y, -upv.x)) or math.deg(math.atan2(upv.y, upv.x))
		end

		if g_VR.input.boolean_walk or g_VR.input.boolean_turnleft or g_VR.input.boolean_turnright then
			g_VR.characterYaw = headYaw
			return
		end

		local t = (convarValues.characterYawBlend or 1.5) - 1 -- 0 = head, 1 = arms

		-- Compute arm target; falls back to headYaw when pitch is extreme or hands crossed
		local armTarget = headYaw
		if t > 0 and math.abs(hmdAng.pitch) < 80 then
			local hmdPos = g_VR.tracking.hmd.pos
			local lLocal = WorldToLocal(g_VR.tracking.pose_lefthand.pos, zeroAng, hmdPos, hmdAng)
			local rLocal = WorldToLocal(g_VR.tracking.pose_righthand.pos, zeroAng, hmdPos, hmdAng)
			if lLocal.y > rLocal.y then
				local lp, rp = g_VR.tracking.pose_lefthand.pos, g_VR.tracking.pose_righthand.pos
				local handYaw = NA(math.deg(math.atan2(rp.y - lp.y, rp.x - lp.x)) + 90)
				armTarget = headYaw + math.Clamp(NA(handYaw - headYaw), -45, 45)
			end
		end

		local target = NA(headYaw + NA(armTarget - headYaw) * t)
		local factor = (8 + (1 - t) * 52) * RealFrameTime()
		if factor >= 1 then
			g_VR.characterYaw = target
		else
			g_VR.characterYaw = NA(g_VR.characterYaw + NA(target - g_VR.characterYaw) * factor)
		end
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
		if not ply:InVehicle() then
			-- Neck offset direction from characterYaw (stable) instead of
			-- up:Cross(hmdAng:Right()), whose sign flips past vertical pitch
			-- and shoved the body in front of the head.
			-- Distance is per-pose: sitting/prone place the body a fixed,
			-- convar-set distance behind the head (no head-roll shrink -- body
			-- length doesn't change when the head turns); standing keeps the
			-- calibrated dist with the sideways-tilt shrink (Right's horizontal
			-- magnitude, which can't flip sign). Approached at 60u/s so pose
			-- changes slide the body instead of popping it.
			local hd
			if info.vrProne then
				hd = convarValues.proneHeadToHmdDist or 26
			elseif info.vrSitting then
				hd = convarValues.sitHeadToHmdDist or 0
			else
				local r = frame.hmdAng:Right()
				hd = headToHmdDist * math.sqrt(r.x * r.x + r.y * r.y)
			end
			hd = math.Approach(info.hmdDist or hd, hd, RealFrameTime() * 60)
			info.hmdDist = hd
			local renderPos = frame.hmdPos + Angle(0, frame.characterYaw, 0):Forward() * -(hd + info.horizontalCrouchOffset * 0.8)
			renderPos.z = plyPos.z - info.verticalCrouchOffset
			info.renderPos = renderPos
			ply:SetPos(renderPos)
			ply:SetRenderAngles(Angle(0, frame.characterYaw, 0))
		end

		-- SetupBones fires BoneCallbackFunc, which now does all bone writing
		-- (hand/head overrides, full IK apply, scaler/hider, head-hide). Keeping
		-- the apply inside the callback is what makes it survive PAC3's extra
		-- SetupBones passes. FBT self-guards inside the callback too.
		-- Worldmodel mode runs an extra SetupBones in VRMod_PreRender (before
		-- renderPos is applied), consuming the once-per-frame UpdateIK slot and
		-- capturing the arm IK against the pre-shift body. Clear the gate so
		-- UpdateIK re-runs here, after SetPos(renderPos), keeping shoulders aligned
		-- with the shifted body (fixes worldmodel shoulder-forward displacement).
		updatedPlayers[steamid] = nil
		-- inDraw scopes UpdateIK to THIS SetupBones only (post-SetPos(renderPos)).
		-- Scoped here rather than Pre/PostPlayerDraw so a suppressed draw can't
		-- leave the flag stuck on.
		info.inDraw = true
		ply:SetupBones()
		info.inDraw = nil
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
		-- When animations are disabled, force idle standing pose
		if not GetPlayerCharacterIK(ply) then
			ply:SetPlaybackRate(0)
			ply:SetPoseParameter("move_yaw", 0)
			ply:SetPoseParameter("move_x", 0)
			ply:SetPoseParameter("move_y", 0)
			return ACT_HL2MP_IDLE, -1
		end

		local act = ACT_HL2MP_IDLE
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
			if not sm then return act, -1 end
		end
		local ci = characterInfo and characterInfo[sid]
		if ply.m_bJumping then
			act = ACT_HL2MP_JUMP_PASSIVE
			if CurTime() - ply.m_flJumpStartTime > 0.2 and ply:OnGround() then ply.m_bJumping = false end
		else
			-- VR sit: head at/below vrmod_sitheight (live-read from the
			-- convar cache, 0 disables) ->
			-- play sit_zen (cross-legged, feet stay on the floor), moving or
			-- not, so stick-sliding while seated keeps the pose. +5u exit
			-- hysteresis so the boundary doesn't flicker. Sequence cached per
			-- charinfo init; LookupSequence gives -1 if the model lacks it, in
			-- which case we fall through to the normal walk/run/idle pose.
			-- VR prone: same deal below vrmod_proneheight, playing prone_knife
			-- from [wOS] Animation Extension - Prone Mod; without that addon
			-- the lookup caches -1 and we fall through to sitting.
			if ci and ply:OnGround() then
				local h = ci.vrHeadH or 100
				if h <= (convarValues.proneHeight or 15) + (ci.vrProne and 5 or 0) then
					local seq = ci.vrProneSeq
					if not seq then
						seq = ply:LookupSequence("prone_knife") or -1
						ci.vrProneSeq = seq
					end
					if seq > 0 then
						ci.vrProne = true
						return act, seq
					end
				end
				ci.vrProne = nil
				if h <= (convarValues.sitHeight or 40) + (ci.vrSitting and 5 or 0) then
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
			local l = vel:Length2DSqr()
			if l > 22500 then
				act = ACT_HL2MP_RUN
			elseif l > 0.25 then
				act = ACT_HL2MP_WALK
			end
		end
		if ci then
			ci.vrSitting = nil
			ci.vrProne = nil
		end
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
		print("[VRChar] CharacterInit " .. ply:Nick() .. " model=" .. tostring(ply:GetModel()) .. " result=" .. tostring(initResult) .. " retry=" .. tostring(ply.vrmod_charInitRetries))
		if initResult == false then
			-- Deferred (model not ready on respawn race, or bone lookup failed).
			-- Retry next tick so we catch the real model as soon as it's applied.
			local retries = (ply.vrmod_charInitRetries or 0) + 1
			ply.vrmod_charInitRetries = retries
			if retries <= 20 then
				timer.Simple(0, function()
					if IsValid(ply) and g_VR.net and g_VR.net[steamid] and not activePlayers[steamid] then
						g_VR.StartCharacterSystem(ply)
					end
				end)
			else
				ply.vrmod_charInitRetries = nil
				vrmod.logger.Err("StartCharacterSystem gave up after 20 retries for " .. steamid)
			end
			return
		end
		ply.vrmod_charInitRetries = nil
		if not g_VR.net or not g_VR.net[steamid] then print("[VRChar] BAIL: g_VR.net missing for " .. steamid) return end
		if not characterInfo[steamid] then print("[VRChar] BAIL: characterInfo missing for " .. steamid) return end
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
		print("[VRChar] Character system ACTIVE for " .. steamid)
		vrmod.logger.Info("Started character system for " .. steamid)
	end

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
				hook.Remove("VRMod_PreRender", "vrutil_hook_calcplyrenderpos")
				if bones.b_head and bones.b_head ~= -1 then
					ply:ManipulateBoneScale(bones.b_head, VEC_ONE)
				end
			end
		end

		activePlayers[steamid] = nil
		characterInfo[steamid] = nil
		lastFrames[steamid] = nil
		updatedPlayers[steamid] = nil
		if IsValid(ply) then ply.vrmod_charInitRetries = nil end
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