g_VR = g_VR or {}
g_VR.vehicle = g_VR.vehicle or {}
local convars = vrmod.GetConvars()
if CLIENT then
	local cv_linux_mode = CreateClientConVar("vrmod_linux", "0", true, false, "Use Linux/WiVRn startup path")
	-- Pose prediction scale (%). 100 = runtime default; >100 predicts further
	-- ahead — raise toward 150-200 with multicore rendering to counter the
	-- pipeline's one-frame submission latency. Applies live.
	vrmod.AddCallbackedConvar("vrmod_predictionscale", nil, "100", nil, "Pose prediction scale (%)", 0, 300, tonumber, function(v)
		if VRMOD_SetPredictionScale then VRMOD_SetPredictionScale(v or 100) end
	end)
	g_VR.scale = 0
	g_VR.origin = Vector(0, 0, 0)
	g_VR.rtWidth, g_VR.rtHeight = nil, nil
	g_VR.originAngle = Angle(0, 0, 0)
	g_VR.viewModel = nil
	g_VR.viewModelMuzzle = nil
	g_VR.viewModelPos = Vector(0, 0, 0)
	g_VR.viewModelAng = Angle(0, 0, 0)
	g_VR.active = false
	g_VR.threePoints = false
	g_VR.sixPoints = false
	g_VR.tracking = {}
	g_VR.input = {}
	g_VR.changedInputs = {}
	local cv_debug_input = CreateClientConVar("vrmod_debug_input", "0", false, false, "Print all VR input events")
	local cv_debug_frame = CreateClientConVar("vrmod_debug_frame", "0", false, false, "Print per-eye pose/timing each frame")
	local cv_pausecard = CreateClientConVar("vrmod_pausecard", "1", true, false, "Show a reason card in the headset while the VR render loop is paused", 0, 1)
	local cv_handsmooth = CreateClientConVar("vrmod_hand_smoothing", "0.98", true, false, "Hand pose smoothing, per 90Hz frame. 1 = off, lowest latency", 0.1, 1)
	local cv_handpredict = CreateClientConVar("vrmod_hand_predict", "0", true, false, "Seconds of velocity extrapolation on hand poses. Cancels the eye/hand latch gap", 0, 0.05)
	local cv_debug_latency = CreateClientConVar("vrmod_debug_latency", "0", false, false, "Measure how far the hand poses trail the late-latched eye poses")
	local _latTick = 0
	local COL_PAUSE_TITLE, COL_PAUSE_HINT = Color(255, 190, 60), Color(180, 180, 180)
	local _dbgFrame = 0
	g_VR.errorText = ""
	g_VR.moduleVersion = 0
	local aspectLeft, aspectRight
	local ipd, eyez
	local cropVerticalMargin, cropHorizontalOffset
	local lastPosePos = {}
	local lastPoseAng = {}
	local convarOverrides = {}
	local _xrPoseLeft, _xrPoseRight, _rawHmdPose
	local wasPaused = false
	local cropL_u0, cropL_v0, cropL_u1, cropL_v1 = 0, 0, 1, 1
	local cropR_u0, cropR_v0, cropR_u1, cropR_v1 = 0, 0, 1, 1
	local moduleFile
	if file.Exists("lua/bin/gmcl_vrmod_win64.dll", "GAME") then
		moduleFile = "lua/bin/gmcl_vrmod_win64.dll"
	end

	if moduleFile then
		vrmod = vrmod or {}
		local success, err = pcall(function() require("vrmod") end)
		if success then
			for k, v in pairs(vrmod) do
				_G["VRMOD_" .. k] = v
			end
			g_VR.moduleVersion = VRMOD_GetVersion and VRMOD_GetVersion() or 0
			if VRMOD_CreateActionSet then
				local rawSetActive = VRMOD_SetActiveActionSets
				VRMOD_SetActiveActionSets = function(...)
					return rawSetActive("base")
				end
			end
		else
			vrmod.logger.Err("Failed to load module:", err)
		end
	else
		vrmod.logger.Err("No compatible module file found.")
	end

	-- Engine convars on gmod's blocked-command list can't go through
	-- RunConsoleCommand, and engine-created convars also reject Lua SetString
	-- ("not created by Lua") — guard both so one blocked convar can't error out
	-- VR start/exit. Everything unblocked keeps the deferred RunConsoleCommand
	-- path (OverridePerformanceConvars relies on gmod_mcore_test applying deferred).
	local function setConvar(cv, name, value)
		if not IsConCommandBlocked(name) then
			RunConsoleCommand(name, value)
		elseif not pcall(cv.SetString, cv, value) then
			vrmod.logger.Err("Convar '" .. name .. "' is blocked and not settable from Lua, skipping")
		end
	end

	local function overrideConvar(name, value)
		local cv = GetConVar(name)
		if cv then
			convarOverrides[name] = cv:GetString()
			setConvar(cv, name, value)
		end
	end

	local function restoreConvarOverrides()
		for k, v in pairs(convarOverrides) do setConvar(GetConVar(k), k, v) end
		convarOverrides = {}
	end

	-- Per-eye RT dimensions, cached at SetupRenderTargets (RT size only
	-- changes on session restart; :Width()/:Height() were 4 native calls/frame)
	local rtEyeW, rtEyeH = 0, 0
	-- Y offset of the shared-texture band this frame renders into. The shared RT
	-- is 3 frames tall for triple-buffered async submission; C++ passes the band
	-- offset into VRUtilClientRender each frame.
	local _bandY = 0
	-- DrawEye: renders one eye to rtEye then blits to the current band of g_VR.rt
	local function DrawEye(bLeft, u0, v0, u1, v1)
		render.PushRenderTarget(g_VR.rtEye)
		render.Clear(0, 0, 0, 255, true, true) -- kept: depth reset + void/HOM safety
		render.RenderView(g_VR.view)
		render.PopRenderTarget()
		-- No clear on the blit target: the opaque full-viewport
		-- DrawTexturedRectUV below overwrites every pixel anyway.
		render.PushRenderTarget(g_VR.rt, bLeft and 0 or rtEyeW, _bandY, rtEyeW, rtEyeH)
		cam.Start2D()
		surface.SetDrawColor(255, 255, 255)
		surface.SetMaterial(g_VR.rtEyeMat)
		surface.DrawTexturedRectUV(0, 0, rtEyeW, rtEyeH, u0, v0, u1, v1)
		cam.End2D()
		render.PopRenderTarget()
	end

	-- Full per-eye pass: set the per-eye view fields, fire the eye's pre-render
	-- hook, then render+blit. Hoisted (not a per-frame closure) so swapping draw
	-- order costs nothing; cropL/R and aspectL/R are upvalues updated on setup.
	local function DrawEyeFull(bLeft, di)
		if bLeft then
			g_VR.view.origin = g_VR.eyePosLeft
			g_VR.view.angles = g_VR.eyeAngLeft
			g_VR.view.fov = di.fovLeft
			g_VR.view.viewmodelfov = di.fovLeft
			g_VR.view.aspect = aspectLeft
			g_VR.view.aspectratio = aspectLeft
			hook.Run("VRMod_PreRender")
			-- The muzzle was read back in UpdateCollisionsAndWepPos, three
			-- stages ago. VRMod_PreRender consumers (left-hand mode, foregrip,
			-- any addon) can still move the weapon after that, so re-read it
			-- against the pose this eye is about to render -- otherwise the
			-- laser, aim vector and flashlight trail the gun by a frame, which
			-- reads as lag whenever you are moving.
			-- Must go through UpdateViewModel, not RefreshViewModelMuzzle:
			-- muzzlefix wraps UpdateViewModel to apply its per-weapon muzzle
			-- angle correction, and calling the inner function skips it.
			if vrmod.utils.UpdateViewModel then vrmod.utils.UpdateViewModel() end
			DrawEye(true, cropL_u0, cropL_v0, cropL_u1, cropL_v1)
		else
			g_VR.view.origin = g_VR.eyePosRight
			g_VR.view.angles = g_VR.eyeAngRight
			g_VR.view.fov = di.fovRight
			g_VR.view.viewmodelfov = di.fovRight
			g_VR.view.aspect = aspectRight
			g_VR.view.aspectratio = aspectRight
			hook.Run("VRMod_PreRenderRight")
			if vrmod.utils.UpdateViewModel then vrmod.utils.UpdateViewModel() end
			DrawEye(false, cropR_u0, cropR_v0, cropR_u1, cropR_v1)
		end
	end

	local SmoothVector = vrmod.utils.SmoothVector
	local SmoothAngle = vrmod.utils.SmoothAngle
	local math_sqrt = math.sqrt
	local LocalToWorld, RealFrameTime, hook_Call = LocalToWorld, RealFrameTime, hook.Call
	local math_AngleDifference = math.AngleDifference
	-- UpdateTracking constants/scratch, hoisted so the per-pose loop allocates
	-- nothing on steady paths. LocalToWorld never mutates its args.
	local HAND_OFF_R = Vector(-2, -1.5, 2.5)
	local HAND_OFF_L = Vector(-2, 1.5, 2.5)
	local HAND_OFF_ANG = Angle(67.5, 0, 0)
	local _scaledPos, _velVec, _angVelVec = Vector(), Vector(), Vector()
	local _angVelAng = Angle()

	local function UpdateTracking()
		-- The old fixed 0.98-per-frame filter cost a fraction of a frame of
		-- latency at 90Hz but twice that at 45, so the same setting felt
		-- laggier the worse your framerate. Normalise it to a 90Hz reference
		-- and let it be turned off outright.
		local smoothingFactor = cv_handsmooth:GetFloat()
		if smoothingFactor < 1 then
			local dt = RealFrameTime()
			smoothingFactor = dt > 0 and 1 - (1 - smoothingFactor) ^ (dt * 90) or 1
		end
		local predictT = cv_handpredict:GetFloat()
		local maxPosDeltaSqr = 100
		local maxPosDelta = 10
		local ok, rawPoses = pcall(VRMOD_GetPoses)
		if not ok or not rawPoses then return end
		for k, v in pairs(rawPoses) do
			if v.pose then
				v.pos = v.pose:GetTranslation()
				v.ang = v.pose:GetAngles()
				if k == "hmd" then _rawHmdPose = v.pose end
			end
			local lastPos = lastPosePos[k]
			local currentPos = v.pos
			if lastPos then
				local delta = currentPos - lastPos
				local deltaLenSqr = delta:LengthSqr()
				if deltaLenSqr ~= deltaLenSqr then
					currentPos = lastPos
				elseif deltaLenSqr > maxPosDeltaSqr then
					currentPos = lastPos + delta * (maxPosDelta / math_sqrt(deltaLenSqr))
				end
			end
			lastPosePos[k] = currentPos

local currentAng = v.ang
			local lastAng = lastPoseAng[k]
			if currentAng.p ~= currentAng.p then
				currentAng = lastAng or Angle()
			end
			lastPoseAng[k] = currentAng

			g_VR.tracking[k] = g_VR.tracking[k] or {}
			local worldPose = g_VR.tracking[k]
			-- Scale into scratch: currentPos is stored unscaled in lastPosePos
			-- and must not be mutated (avoids the currentPos * scale alloc)
			_scaledPos:Set(currentPos)
			_scaledPos:Mul(g_VR.scale)
			local pos, ang = LocalToWorld(_scaledPos, currentAng, g_VR.origin, g_VR.originAngle)
			if smoothingFactor < 1 and (k == "pose_righthand" or k == "pose_lefthand") then
				worldPose.pos = worldPose.pos and SmoothVector(worldPose.pos, pos, smoothingFactor) or pos
				worldPose.ang = worldPose.ang and SmoothAngle(worldPose.ang, ang, smoothingFactor) or ang
			else
				worldPose.pos = pos
				worldPose.ang = ang
			end

			local rawVel = v.vel
			if rawVel.x == 0 and rawVel.y == 0 and rawVel.z == 0 and lastPos then
				local dt = RealFrameTime()
				if dt > 0.0001 then
					_velVec:Set(currentPos)
					_velVec:Sub(lastPos)
					_velVec:Div(dt)
					rawVel = _velVec
				end
			end
			-- LocalToWorld returns a fresh Vector; scale it in place instead
			-- of allocating another via * g_VR.scale
			local wv = LocalToWorld(rawVel, angle_zero, vector_origin, g_VR.originAngle)
			wv:Mul(g_VR.scale)
			worldPose.vel = wv
			local rawAngVel = v.angvel
			if rawAngVel.p == 0 and rawAngVel.y == 0 and rawAngVel.r == 0 and lastAng then
				local dt = RealFrameTime()
				if dt > 0.0001 then
					_angVelAng:SetUnpacked(math_AngleDifference(currentAng.p, lastAng.p) / dt, math_AngleDifference(currentAng.y, lastAng.y) / dt, math_AngleDifference(currentAng.r, lastAng.r) / dt)
					rawAngVel = _angVelAng
				end
			end
			_angVelVec:SetUnpacked(rawAngVel.p, rawAngVel.y, rawAngVel.r)
			worldPose.angvel = LocalToWorld(_angVelVec, angle_zero, vector_origin, g_VR.originAngle)
			if k == "pose_righthand" or k == "pose_lefthand" then
				-- The eyes render from the poses the runtime late-latched for
				-- THIS frame's display time; these hand poses come from the
				-- earlier GetPoses snapshot. The gap is fixed latency, not
				-- filtering, which is why turning smoothing off removes jitter
				-- but not the trailing. Push the hands forward along their own
				-- tracked velocity to land them on the same time base.
				-- Mutated in place: pos/ang are freshly allocated each frame.
				if predictT > 0 then
					local p, vv = worldPose.pos, worldPose.vel
					p.x, p.y, p.z = p.x + vv.x * predictT, p.y + vv.y * predictT, p.z + vv.z * predictT
					local a, av = worldPose.ang, worldPose.angvel
					a.p, a.y, a.r = a.p + av.x * predictT, a.y + av.y * predictT, a.r + av.z * predictT
				end
				local off = k == "pose_righthand" and HAND_OFF_R or HAND_OFF_L
				worldPose.pos, worldPose.ang = LocalToWorld(off, HAND_OFF_ANG, worldPose.pos, worldPose.ang)
			end
		end
		g_VR.sixPoints = g_VR.tracking.pose_waist and g_VR.tracking.pose_leftfoot and g_VR.tracking.pose_rightfoot
		hook_Call("VRMod_Tracking")
		local ox = g_VR.origin.x
		if ox ~= ox then
			g_VR.origin = LocalPlayer():GetPos()
		end
	end

	local function UpdateCollisionsAndWepPos()
		local lh, rh = g_VR.tracking.pose_lefthand, g_VR.tracking.pose_righthand
		local u = vrmod.utils
		if lh and rh and u then
			u.CollisionsPreCheck(lh.pos, rh.pos)
			local leftGrip, rightGrip = u.GetClimbingGripState()
			local leftPos, leftAng, rightPos, rightAng = u.UpdateHandCollisions(lh.pos, lh.ang, rh.pos, rh.ang)
			if not leftGrip then lh.pos = leftPos; lh.ang = leftAng end
			if not rightGrip then rh.pos = rightPos; rh.ang = rightAng end
			-- Single pass. This used to run UpdateViewModelPos once on the raw
			-- pose and again on the collision-corrected one; the first result
			-- was always overwritten, so every frame paid for two weapon
			-- pushout hull traces and two viewmodel bone setups for nothing.
			u.UpdateViewModelPos(rightPos, rightAng)
		end
	end

	local _synthL = {fingerCurls = {0, 0, 0, 0, 0}}
	local _synthR = {fingerCurls = {0, 0, 0, 0, 0}}
	-- Persistent smoothed curls for the real hand-tracking path (raw C++ curls
	-- are per-frame and steppy; math.Approach here matches the synth feel).
	local _smoothL = {0, 0, 0, 0, 0}
	local _smoothR = {0, 0, 0, 0, 0}
	local _lastPrimaryFire = false
	local _lastSecondaryFire = false
	local _lastLeftGrip = false
	local _lastRightGrip = false
	local _gripPending = {false, false}
	local _gripCount = {0, 0}
	local _thumbL, _thumbR = 0, 0
	local _gripL, _gripR = 0, 0
	local _trigL, _trigR = 0, 0
	local THUMB_SPEED = 10 -- curl/sec; full 0<->1 in ~0.1s
	local BTN_NAMES = {
		boolean_primaryfire = "Right Trigger",
		boolean_secondaryfire = "Left Trigger",
		boolean_left_pickup = "Left Grip/Squeeze",
		boolean_right_pickup = "Right Grip/Squeeze",
		boolean_use = "Left A / X Button",
		boolean_spawnmenu = "Left B / Y Button",
		boolean_jump = "Right A Button",
		boolean_crouch = "Right B Button",
		boolean_sprint = "Left Stick Click",
		boolean_changeweapon = "Right Stick Click",
		boolean_left_thumb_touch = "Left Stick Touch",
		boolean_right_thumb_touch = "Right Stick Touch",
		lweaponmenu = "Left B Touch / Y Touch",
	}
	local math_Approach = math.Approach
	-- Per-model open-hand pose. The stock defaultOpenHandAngles are near-zero
	-- offsets that only read as "open" on a model whose finger bind pose is
	-- already straight; on curled bind poses (kleiner included) zero-offset
	-- shows a claw. defaultClosedHandAngles already encodes the fist curl axis,
	-- so extending the opposite way by a small factor straightens the fingers.
	-- Written in place into defaultOpenHandAngles (the table every reset path --
	-- pouch-fix, weapon deploy, char init -- points openHandAngles back at) so
	-- nothing can snap it to the claw mid-interaction. Live-tunable; recomputes
	-- from the fist on change.
	local function ApplyOpenHandPose(k)
		local closed, open = g_VR.defaultClosedHandAngles, g_VR.defaultOpenHandAngles
		if not (closed and open) then return end
		for i = 1, #closed do
			local c, o = closed[i], open[i]
			o.p, o.y, o.r = -c.p * k, -c.y * k, -c.r * k
		end
	end
	vrmod.AddCallbackedConvar("vrmod_finger_openextend", nil, "0.24", nil, "Open-hand extend factor (relative to fist)", 0, 1, tonumber, function(v)
		ApplyOpenHandPose(v or 0.24)
	end)
	hook.Add("VRMod_Start", "vrmod_openhandpose", function()
		local cv = GetConVar("vrmod_finger_openextend")
		ApplyOpenHandPose(cv and cv:GetFloat() or 0.24)
		if g_VR.defaultOpenHandAngles then g_VR.openHandAngles = g_VR.defaultOpenHandAngles end
	end)
	local function HandleInput()
		local ok, inp, changed = pcall(VRMOD_GetActions)
		if not ok or not inp then
			-- Force release if we can't read actions
			if _lastPrimaryFire then
				_lastPrimaryFire = false
				g_VR.changedInputs = g_VR.changedInputs or {}
				g_VR.changedInputs.boolean_primaryfire = false
				hook.Call("VRMod_Input", nil, "boolean_primaryfire", false)
			end
			if _lastSecondaryFire then
				_lastSecondaryFire = false
				g_VR.changedInputs = g_VR.changedInputs or {}
				g_VR.changedInputs.boolean_secondaryfire = false
				hook.Call("VRMod_Input", nil, "boolean_secondaryfire", false)
			end
			return
		end
		g_VR.input, g_VR.changedInputs = inp, changed
		-- Ensure locomotion fields exist
		if not inp.vector2_walkdirection then inp.vector2_walkdirection = {x=0,y=0} end
		if not inp.vector2_smoothturn then inp.vector2_smoothturn = {x=0,y=0} end
		if not inp.vector2_steer then inp.vector2_steer = {x=0,y=0} end

		-- Synthesize boolean fire from analog trigger (always use float, ignore runtime boolean)
		local rTrig = tonumber(inp.vector1_primaryfire) or tonumber(inp.trigger_right_axis) or 0
		local rFire = rTrig >= 0.5
		if rFire ~= _lastPrimaryFire then
			_lastPrimaryFire = rFire
			inp.boolean_primaryfire = rFire
			changed.boolean_primaryfire = rFire
		else
			changed.boolean_primaryfire = nil
		end
		local lTrig = tonumber(inp.vector1_secondaryfire) or tonumber(inp.trigger_left_axis) or 0
		local lFire = lTrig >= 0.5
		if lFire ~= _lastSecondaryFire then
			_lastSecondaryFire = lFire
			inp.boolean_secondaryfire = lFire
			changed.boolean_secondaryfire = lFire
		else
			changed.boolean_secondaryfire = nil
		end

		-- Grip booleans: debounced to reject XR runtime flicker.
		-- Read C++ boolean (set every frame) with analog fallback; require 3
		-- consecutive frames of a new state before accepting the transition.
		local lGrip = tonumber(inp.vector1_left_squeeze) or 0
		local lRaw = inp.boolean_left_pickup
		local lState = (lRaw == true or lRaw == false) and lRaw or (lGrip >= (_lastLeftGrip and 0.3 or 0.5))
		if lState ~= _lastLeftGrip then
			if lState == _gripPending[1] then _gripCount[1] = _gripCount[1] + 1
			else _gripPending[1] = lState; _gripCount[1] = 1 end
			if _gripCount[1] >= 3 then
				_lastLeftGrip = lState
				inp.boolean_left_pickup = lState
				changed.boolean_left_pickup = lState
			else
				changed.boolean_left_pickup = nil
			end
		else
			changed.boolean_left_pickup = nil
		end
		local rGrip = tonumber(inp.vector1_right_squeeze) or 0
		local rRaw = inp.boolean_right_pickup
		local rState = (rRaw == true or rRaw == false) and rRaw or (rGrip >= (_lastRightGrip and 0.3 or 0.5))
		if rState ~= _lastRightGrip then
			if rState == _gripPending[2] then _gripCount[2] = _gripCount[2] + 1
			else _gripPending[2] = rState; _gripCount[2] = 1 end
			if _gripCount[2] >= 3 then
				_lastRightGrip = rState
				inp.boolean_right_pickup = rState
				changed.boolean_right_pickup = rState
			else
				changed.boolean_right_pickup = nil
			end
		else
			changed.boolean_right_pickup = nil
		end

		-- Curls come from one of two sources. The C++ module pushes real
		-- per-finger data (XR_EXT_hand_tracking, e.g. Index knuckles) -> use it
		-- as-is (raw 0..1, no remap). Otherwise synthesize a Touch-style curl
		-- from thumb/trigger/grip analog inputs.
		local dt = RealFrameTime() * THUMB_SPEED
		local htL = inp.skeleton_lefthand
		if htL then
			local c, s = htL.fingerCurls, _smoothL
			for i = 1, 5 do
				s[i] = math_Approach(s[i], c[i], dt)
				c[i] = s[i]
			end
		else
			local cL = _synthL.fingerCurls
			_thumbL = math_Approach(_thumbL, inp.boolean_left_thumb_touch and 1 or 0, dt)
			cL[1] = _thumbL
			_trigL = math_Approach(_trigL, lTrig, dt)
			cL[2] = _trigL
			_gripL = math_Approach(_gripL, lGrip, dt)
			cL[3] = _gripL; cL[4] = _gripL; cL[5] = _gripL
			inp.skeleton_lefthand = _synthL
		end

		local htR = inp.skeleton_righthand
		if htR then
			local c, s = htR.fingerCurls, _smoothR
			for i = 1, 5 do
				s[i] = math_Approach(s[i], c[i], dt)
				c[i] = s[i]
			end
		else
			local cR = _synthR.fingerCurls
			_thumbR = math_Approach(_thumbR, inp.boolean_right_thumb_touch and 1 or 0, dt)
			cR[1] = _thumbR
			_trigR = math_Approach(_trigR, rTrig, dt)
			cR[2] = _trigR
			local rGripTarget = rGrip
			local rMelee = false
			if rGripTarget < 0.3 then
				local wep = LocalPlayer():GetActiveWeapon()
				if IsValid(wep) and wep:GetClass() ~= "weapon_vrmod_empty" then
					local ismelee = wep.NotAGun or wep.MeleeDamageType
					if not ismelee then
						local stored = weapons.GetStored(wep:GetClass())
						ismelee = stored and stored.NotAGun
					end
					if ismelee then rGripTarget = 1; rMelee = true end
				end
			end
			_gripR = math_Approach(_gripR, rGripTarget, dt)
			if rMelee then
				cR[1] = 1; cR[2] = 1; cR[3] = 1; cR[4] = 1; cR[5] = 1
			else
				cR[3] = _gripR; cR[4] = _gripR; cR[5] = _gripR
			end
			inp.skeleton_righthand = _synthR
		end
		local dbg = cv_debug_input:GetBool()
		for k, v in pairs(g_VR.changedInputs) do
			if dbg and (v == true or v == false) then
				print("[VR] " .. (BTN_NAMES[k] or k) .. (v and " PRESSED" or " RELEASED"))
			end
			hook_Call("VRMod_Input", nil, k, v)
		end
	end

	-- A real pause, detected by cause rather than by symptom: game time stops
	-- advancing while real time keeps going. Catches the singleplayer console,
	-- the escape menu and anything else that halts the tick, and stays false in
	-- multiplayer where opening the console pauses nothing -- which is why this
	-- is not keyed off gui.IsConsoleVisible().
	local _pauseCur, _pauseRT = -1, 0
	local function GamePaused()
		local c = CurTime()
		if c ~= _pauseCur then
			_pauseCur = c
			_pauseRT = RealTime()
		end
		return RealTime() - _pauseRT > 0.25
	end

	-- Reason the render loop must be replaced by a card, or nil. A plain pause
	-- is NOT one of these: the world still renders normally, it just gets a
	-- notice drawn over it (see DrawPausedBanner).
	-- SteamVR's startup/status window takes and returns focus over a handful of
	-- frames as it comes up. A single-frame HasFocus() false blanked the desktop
	-- (render.Clear in DrawErrorOverlay) AND swapped the headset to the pause
	-- card, then reverted -- that alternation IS the launch flicker between black
	-- and the last held frame. Believe the loss only once it holds; believe the
	-- recovery immediately, so a real alt-tab still parks well under a second.
	local FOCUS_GRACE = 0.75
	local _unfocusedAt
	local function PauseReason()
		if system.HasFocus() then
			_unfocusedAt = nil
		elseif not _unfocusedAt then
			_unfocusedAt = RealTime()
		elseif RealTime() - _unfocusedAt >= FOCUS_GRACE then
			return "Game window is not focused"
		end
		if #g_VR.errorText > 0 then return g_VR.errorText end
	end

	-- Set once per frame in DrawErrorOverlay, consumed in PerformRenderViews.
	local _gamePaused = false

	local function PauseHint()
		if gui.IsConsoleVisible() then return "The console is open" end
		if gui.IsGameUIVisible() then return "The game menu is open" end
		return "Click the game window to resume"
	end

	-- DermaLarge is ~24px against an eye buffer that is commonly 1600-2000px
	-- tall, so the card read as a smear of pixels from inside the headset.
	-- Sized off the buffer instead, built once per resolution -- the equality
	-- test makes this free on every frame after the first.
	local _stallFontH = 0
	local function EnsureStallFonts(h)
		if _stallFontH == h then return end
		_stallFontH = h
		surface.CreateFont("vrmod_stall_title", {font = "Roboto", size = math.max(34, h * 0.075), weight = 800, antialias = true})
		surface.CreateFont("vrmod_stall_body", {font = "Roboto", size = math.max(24, h * 0.042), weight = 500, antialias = true})
	end

	-- Paint the reason into both eyes. Without this the compositor keeps
	-- reprojecting the last good frame, so from inside the headset a lost focus,
	-- an open console and a hard crash all look exactly the same.
	--
	-- EVERY band, not just the one this frame owns. The shared RT holds 3 frames
	-- for async submission, and a stalled render loop is exactly the state where
	-- it is NOT pumped once per band -- so filling a single band left the
	-- compositor cycling card / stale world frame / stale world frame, which is
	-- the two-frame judder that made the text impossible to read. Writing all
	-- three means whichever band it reaches for is already the card, so the
	-- image is static no matter how erratically the loop runs.
	--
	-- One push per band rather than one per eye: the viewport spans the full
	-- width anyway, so both eyes are drawn inside a single cam.Start2D and the
	-- clear covers them together. Halves the render target churn.
	local function DrawPauseCard(reason)
		local w, h = rtEyeW, rtEyeH
		if w == 0 or h == 0 or not g_VR.rt then return end
		EnsureStallFonts(h)
		local hint = PauseHint()
		local rtW = g_VR.rtWidth
		for band = 0, 2 do
			render.PushRenderTarget(g_VR.rt, 0, band * h, rtW, h)
			render.Clear(0, 0, 0, 255, true, true) -- pure black: nothing behind the text to strobe against
			cam.Start2D()
			for i = 0, 1 do
				local cx = i * w + w * 0.5
				draw.DrawText("VRMod paused", "vrmod_stall_title", cx, h * 0.38, COL_PAUSE_TITLE, TEXT_ALIGN_CENTER)
				draw.DrawText(reason, "vrmod_stall_body", cx, h * 0.49, color_white, TEXT_ALIGN_CENTER)
				draw.DrawText(hint, "vrmod_stall_body", cx, h * 0.55, COL_PAUSE_HINT, TEXT_ALIGN_CENTER)
			end
			cam.End2D()
			render.PopRenderTarget()
		end
	end

	-- Notice drawn over an otherwise normal frame while the tick is halted.
	-- Painted into both eye halves of the shared RT after the world render, the
	-- same way the death tint is, so nothing about the render path changes --
	-- the game keeps drawing, it just says why it is frozen.
	local COL_PAUSE_BG = Color(0, 0, 0, 200)
	local function DrawPausedBanner()
		local w, h = rtEyeW, rtEyeH
		if w == 0 or h == 0 or not g_VR.rt then return end
		local bw, bh, by = w * 0.55, h * 0.1, h * 0.05
		render.PushRenderTarget(g_VR.rt, 0, _bandY, g_VR.rtWidth, g_VR.rtHeight)
		cam.Start2D()
		local hint = PauseHint()
		for i = 0, 1 do
			local cx = i * w + w * 0.5
			surface.SetDrawColor(COL_PAUSE_BG)
			surface.DrawRect(cx - bw * 0.5, by, bw, bh)
			draw.DrawText("Game paused", "DermaLarge", cx, by + bh * 0.1, COL_PAUSE_TITLE, TEXT_ALIGN_CENTER)
			draw.DrawText(hint, "DermaLarge", cx, by + bh * 0.55, COL_PAUSE_HINT, TEXT_ALIGN_CENTER)
		end
		cam.End2D()
		render.PopRenderTarget()
	end

	local function DrawErrorOverlay()
		_gamePaused = GamePaused() -- sampled here so it tracks every frame
		local reason = PauseReason()
		g_VR.pauseReason = reason
		if reason then
			render.Clear(0, 0, 0, 255, true, true)
			cam.Start2D()
			draw.DrawText(reason, "DermaLarge", ScrW() / 2, ScrH() / 2, color_white, TEXT_ALIGN_CENTER)
			draw.DrawText(PauseHint(), "DermaDefaultBold", ScrW() / 2, ScrH() / 2 + 36, COL_PAUSE_HINT, TEXT_ALIGN_CENTER)
			cam.End2D()
			g_VR.active = false
			if not wasPaused then vrmod.logger.Info("VR session paused: " .. reason) end
			wasPaused = true
			return true
		end
		g_VR.active = true
		if wasPaused then vrmod.logger.Info("VR session resumed") end
		wasPaused = false
	end

	local function UpdateViewFromEntity()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end
		local viewEnt = ply:GetViewEntity()
		if not IsValid(viewEnt) then return end
		local hmd = g_VR.tracking.hmd
		if not hmd then return end
		local rawPos, rawAng = WorldToLocal(hmd.pos, hmd.ang, g_VR.origin, g_VR.originAngle)
		local finalPos, finalAng = hmd.pos, hmd.ang
		if viewEnt ~= ply then
			finalPos, finalAng = LocalToWorld(rawPos, rawAng, viewEnt:GetPos(), viewEnt:GetAngles())
		end
		if g_VR.vehicle.glide then
			local forward = g_VR.view.angles:Forward()
			local up = g_VR.view.angles:Up()
			if g_VR.vehicle.type == "motorcycle" then
				g_VR.view.origin = finalPos + forward * 8 + up * 3
			else
				g_VR.view.origin = finalPos + forward * 6 + up * 6
			end
			g_VR.tracking.pose_lefthand.pos = g_VR.tracking.pose_lefthand.pos + forward * 5
			g_VR.tracking.pose_righthand.pos = g_VR.tracking.pose_righthand.pos + forward * 5
		else
			g_VR.view.origin = finalPos
		end
		g_VR.view.angles = finalAng
	end

	local function PerformRenderViews()
		-- RT Override: external addons can set g_VR.rtOverride to a material to bypass all eye rendering
		if g_VR.rtOverride then
			local w, h = rtEyeW, rtEyeH
			local mat = g_VR.rtOverride
			-- Left eye
			render.PushRenderTarget(g_VR.rt, 0, _bandY, w, h)
			render.Clear(0, 0, 0, 255, true, true)
			cam.Start2D()
			surface.SetDrawColor(255, 255, 255, 255)
			surface.SetMaterial(mat)
			surface.DrawTexturedRectUV(0, 0, w, h, cropL_u0, cropL_v0, cropL_u1, cropL_v1)
			cam.End2D()
			render.PopRenderTarget()
			-- Right eye
			render.PushRenderTarget(g_VR.rt, w, _bandY, w, h)
			render.Clear(0, 0, 0, 255, true, true)
			cam.Start2D()
			surface.SetDrawColor(255, 255, 255, 255)
			surface.SetMaterial(mat)
			surface.DrawTexturedRectUV(0, 0, w, h, cropR_u0, cropR_v0, cropR_u1, cropR_v1)
			cam.End2D()
			render.PopRenderTarget()
			return
		end

		-- Deferred first-frame setup: get display info once XR session is fully active
		if g_VR._needsFirstFrameSetup then
			local di
			if cv_linux_mode:GetBool() then
				di = VRMOD_GetDisplayInfo()
				local fovSym = di and di.FovSymmetric
				if not fovSym or fovSym ~= fovSym or fovSym <= 0 then
					return -- retry next frame
				end
				g_VR._needsFirstFrameSetup = false
				if di.TransformRight and di.TransformRight.GetField then
					ipd = di.TransformRight:GetField(1, 4) * 2
					eyez = di.TransformRight:GetField(3, 4)
				end
				aspectLeft = di.AspectSymmetric
				aspectRight = di.AspectSymmetric
				g_VR.displayInfo.fovLeft = fovSym
				g_VR.displayInfo.fovRight = fovSym
				g_VR.displayInfo.ipd = ipd
				g_VR.displayInfo.eyez = eyez
				if di.U0Left and di.U0Left == di.U0Left then
					local function correctUVs(u0, v0, u1, v1)
						local tex = g_VR.rtEyeMat:GetTexture("$basetexture")
						local du = 0.5 / tex:GetMappingWidth()
						local dv = 0.5 / tex:GetMappingHeight()
						return (u0 - du) / (1 - 2 * du), (v0 - dv) / (1 - 2 * dv),
							   (u1 - du) / (1 - 2 * du), (v1 - dv) / (1 - 2 * dv)
					end
					cropL_u0, cropL_v0, cropL_u1, cropL_v1 = correctUVs(di.U0Left, di.V0Left, di.U1Left, di.V1Left)
					cropR_u0, cropR_v0, cropR_u1, cropR_v1 = correctUVs(di.U0Right, di.V0Right, di.U1Right, di.V1Right)
				end
			else
				di = VRMOD_GetDisplayInfo(1, 10000)
				local fovL = di and di.FovLeft
				if not fovL or fovL ~= fovL or fovL <= 0 then
					return -- retry next frame
				end
				g_VR._needsFirstFrameSetup = false
				if di.TransformRight and di.TransformRight.GetField then
					ipd = di.TransformRight:GetField(1, 4) * 2
					eyez = di.TransformRight:GetField(3, 4)
				end
				g_VR.displayInfo.ipd = ipd
				g_VR.displayInfo.eyez = eyez
				local m_tan, m_rad, m_atan, m_deg, m_max = math.tan, math.rad, math.atan, math.deg, math.max
				local function computeEyeParams(fov, aspect, offX, offY)
					local thw = m_tan(m_rad(fov * 0.5))
					local thh = thw / aspect
					local tl, tr = thw * (offX - 1), thw * (offX + 1)
					local tb, tt = thh * (offY - 1), thh * (offY + 1)
					local shw = m_max(-tl, tr)
					local shh = m_max(-tb, tt)
					local symFov = m_deg(m_atan(shw) * 2)
					local symAsp = shw / shh
					local iw = 0.5 / shw
					local ih = 0.5 / shh
					return symFov, symAsp,
						(tl + shw) * iw, (shh - tt) * ih,
						(tr + shw) * iw, (shh - tb) * ih
				end
				local symFovL, symAspL
				symFovL, symAspL, cropL_u0, cropL_v0, cropL_u1, cropL_v1 =
					computeEyeParams(fovL, di.AspectLeft, di.OffsetXLeft, di.OffsetYLeft)
				local symFovR, symAspR
				symFovR, symAspR, cropR_u0, cropR_v0, cropR_u1, cropR_v1 =
					computeEyeParams(di.FovRight, di.AspectRight, di.OffsetXRight, di.OffsetYRight)
				aspectLeft = symAspL
				aspectRight = symAspR
				g_VR.displayInfo.fovLeft = symFovL
				g_VR.displayInfo.fovRight = symFovR
			end
			if g_VR.view then
				g_VR.view.fov = g_VR.displayInfo.fovLeft
				g_VR.view.aspect = aspectLeft
				g_VR.view.aspectratio = aspectLeft
			end
		end

		local deathPos, deathAng = vrmod.utils.GetDeathCamView and vrmod.utils.GetDeathCamView()
		if deathPos then g_VR.view.origin, g_VR.view.angles = deathPos, deathAng end

if _xrPoseLeft and _xrPoseRight then
			local scale = g_VR.scale
			local posL, angL = LocalToWorld(_xrPoseLeft:GetTranslation() * scale, _xrPoseLeft:GetAngles(), g_VR.origin, g_VR.originAngle)
			local posR, angR = LocalToWorld(_xrPoseRight:GetTranslation() * scale, _xrPoseRight:GetAngles(), g_VR.origin, g_VR.originAngle)
			local hmdPos = _rawHmdPose and LocalToWorld(_rawHmdPose:GetTranslation() * scale, angle_zero, g_VR.origin, g_VR.originAngle) or g_VR.tracking.hmd.pos
			local dx, dy, dz = g_VR.view.origin.x - hmdPos.x, g_VR.view.origin.y - hmdPos.y, g_VR.view.origin.z - hmdPos.z
			posL.x, posL.y, posL.z = posL.x + dx, posL.y + dy, posL.z + dz
			posR.x, posR.y, posR.z = posR.x + dx, posR.y + dy, posR.z + dz
			g_VR.eyePosLeft = posL
			g_VR.eyePosRight = posR
			-- Per-eye orientation: canted HMDs report distinct L/R pose angles, and
			-- the compositor layer submits each eye's own pose. Each eye must be
			-- RENDERED from its own angle (and its FOV crop is relative to that
			-- forward), or the right eye reprojects against a mismatched reference
			-- and jitters under head motion.
			g_VR.eyeAngLeft = g_VR._ragViewAng or angL
			g_VR.eyeAngRight = g_VR._ragViewAng or angR
			g_VR.view.angles = g_VR.eyeAngLeft
			-- Both angles are world space, so their difference divided by the
			-- head's yaw rate is the latch gap in seconds -- i.e. exactly what
			-- vrmod_hand_predict has to cancel. Only sampled while actually
			-- turning, since the quotient is meaningless near zero rate.
			if cv_debug_latency:GetBool() then
				_latTick = _latTick + 1
				if _latTick >= 30 then
					_latTick = 0
					local hmd = g_VR.tracking.hmd
					local rate = hmd and hmd.angvel and hmd.angvel.y or 0
					if math.abs(rate) > 20 then
						local d = math_AngleDifference(angL.y, hmd.ang.y)
						print(string.format("[VRlat] hands trail eyes by %.1f ms (yaw gap %.2f deg at %.0f deg/s) -> try vrmod_hand_predict %.3f", d / rate * 1000, d, rate, math.max(d / rate, 0)))
					end
				end
			end
			if cv_debug_frame:GetBool() then
				_dbgFrame = _dbgFrame + 1
				if _dbgFrame >= 15 then
					_dbgFrame = 0
					print(string.format("[VRdbg] Lang(%.2f %.2f %.2f) Rang(%.2f %.2f %.2f) dLR(%.3f %.3f %.3f) eyeSep=%.2f",
						angL.p, angL.y, angL.r, angR.p, angR.y, angR.r,
						math_AngleDifference(angR.p, angL.p), math_AngleDifference(angR.y, angL.y), math_AngleDifference(angR.r, angL.r),
						posR:Distance(posL)))
				end
			end
		else
			local right = g_VR.view.angles:Right()
			local eyeOff = ipd * g_VR.scale
			g_VR.eyePosLeft = g_VR.view.origin + right * -eyeOff
			g_VR.eyePosRight = g_VR.view.origin + right * eyeOff
			g_VR.eyeAngLeft = g_VR.view.angles
			g_VR.eyeAngRight = g_VR.view.angles
		end

		if VRUtilRenderMenuRTs then VRUtilRenderMenuRTs() end

		local pl = LocalPlayer()
		local di = g_VR.displayInfo

		g_VR.view.offcenter = nil
		g_VR.view.x = 0
		g_VR.view.y = 0
		g_VR.view.w = g_VR.rtWidth / 2
		g_VR.view.h = g_VR.rtHeight
		DrawEyeFull(true, di)
		DrawEyeFull(false, di)

		if pl and not pl:Alive() then
			render.PushRenderTarget(g_VR.rt, 0, _bandY, g_VR.rtWidth, g_VR.rtHeight)
			cam.Start2D()
			surface.SetDrawColor(255, 0, 0, 128)
			surface.DrawRect(0, 0, g_VR.rtWidth, g_VR.rtHeight)
			cam.End2D()
			render.PopRenderTarget()
		else
			g_VR.deathTime = nil
		end

		if _gamePaused then DrawPausedBanner() end
	end

	local function PerformStartup()
		local err = vrmod.GetStartupError()
		if err and err ~= "VR headset not detected." then vrmod.logger.Err("Failed to start: " .. err) return false end
		VRMOD_Shutdown()
		local ok, ret = pcall(VRMOD_Init)
		if not ok or ret == false then vrmod.logger.Err("Init failed: " .. tostring(ret)) return false end
		return true
	end

	-- Per-item performance overrides. Each engine convar gets its own vrmod_perf_*
	-- toggle (default 1 = apply) so they can be enabled/disabled individually in
	-- Settings > Rendering. Exposed as vrmod.PerfOverrides so the UI builds from the
	-- same source. r_3dsky is handled separately since it tracks vrmod_skybox.
	vrmod.PerfOverrides = {
		{ toggle = "vrmod_perf_threaded_bones",     cvar = "cl_threaded_bone_setup",     val = "1", label = "Threaded bone setup" },
		{ toggle = "vrmod_perf_mcore",              cvar = "gmod_mcore_test",            val = "1", label = "Multicore rendering" },
		{ toggle = "vrmod_perf_mat_queue",          cvar = "mat_queue_mode",             val = "2", label = "Threaded material queue" },
		{ toggle = "vrmod_perf_no_bloom",           cvar = "mat_disable_bloom",          val = "1", label = "Disable bloom" },
		{ toggle = "vrmod_perf_no_fancyblend",      cvar = "mat_disable_fancy_blending", val = "1", label = "Disable fancy blending" },
		{ toggle = "vrmod_perf_no_lightwarp",       cvar = "mat_disable_lightwarp",      val = "1", label = "Disable lightwarp" },
		{ toggle = "vrmod_perf_no_pspatch",         cvar = "mat_disable_ps_patch",       val = "1", label = "Disable pixel-shader patch" },
		{ toggle = "vrmod_perf_no_motionblur",      cvar = "mat_motion_blur_enabled",    val = "0", label = "Disable motion blur" },
		{ toggle = "vrmod_perf_reduce_particles",   cvar = "mat_reduceparticles",        val = "1", label = "Reduce particles" },
		{ toggle = "vrmod_perf_no_rtt_shadows",     cvar = "r_shadowrendertotexture",    val = "0", label = "Disable RTT shadows" },
		{ toggle = "vrmod_perf_threaded_particles", cvar = "r_threaded_particles",       val = "1", label = "Threaded particles" },
		{ toggle = "vrmod_perf_queued_ropes",       cvar = "r_queued_ropes",             val = "1", label = "Queued ropes" },
	}
	for _, o in ipairs(vrmod.PerfOverrides) do
		if not GetConVar(o.toggle) then CreateClientConVar(o.toggle, "1", true, false, "Perf override: " .. o.cvar) end
	end

	-- Returns whether threaded rendering ends up active. overrideConvar defers
	-- via RunConsoleCommand, so gmod_mcore_test can't be read back this frame --
	-- we report what we applied instead. Feeds VRMOD_SetMulticoreMode.
	local function OverridePerformanceConvars()
		-- Skybox tracks its own setting and applies regardless of the master toggle.
		overrideConvar("r_3dsky", convars.vrmod_skybox:GetBool() and "1" or "0")
		local master = GetConVar("vrmod_perfoverrides")
		if master and not master:GetBool() then
			local mq = GetConVar("mat_queue_mode")
			return GetConVar("gmod_mcore_test"):GetBool() or (mq and mq:GetInt() >= 1)
		end
		local mcore = false
		for _, o in ipairs(vrmod.PerfOverrides) do
			if GetConVar(o.toggle):GetBool() then
				overrideConvar(o.cvar, o.val)
				mcore = mcore or o.cvar == "gmod_mcore_test" or o.cvar == "mat_queue_mode"
			end
		end
		return mcore
	end

local function SetupRenderTargets()
    g_VR.desktopView = convars.vrmod_desktopview:GetInt()

    -- GetDisplayInfo returns recommended per-eye dimensions and sets
    -- g_TextureWidth/g_TextureHeight in the C module for ShareTextureFinish.
    local rtWidth, rtHeight
    if cv_linux_mode:GetBool() then
        -- Proton/Linux with 0.2.0a: ShareTextureBegin hooks texture but doesn't return dims
        pcall(VRMOD_ShareTextureBegin, 100)
        -- Quest 2: 1832x1920 per eye
        rtWidth, rtHeight = 3664, 1920
    else
        local info = VRMOD_GetDisplayInfo(1, 10000)
        if not info or not info.RecommendedWidth or info.RecommendedWidth == 0 then
            rtWidth, rtHeight = VRMOD_ShareTextureBegin(100)
            rtWidth = rtWidth * 2
        else
            rtWidth, rtHeight = info.RecommendedWidth * 2, info.RecommendedHeight
            VRMOD_ShareTextureBegin()
        end
    end

    g_VR.rtWidth = rtWidth
    g_VR.rtHeight = rtHeight

    cropVerticalMargin = (1 - (ScrH() / ScrW() * (rtWidth / 2) / rtHeight)) / 2
    cropHorizontalOffset = (g_VR.desktopView == 3) and 0.5 or 0

    local frameH = rtHeight -- single-frame height; the shared RT holds 3 frames
    g_VR.rt = GetRenderTargetEx("vrmod_rt" .. tostring(SysTime()), rtWidth, frameH * 3, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, bit.bor(256, 32768), 0, IMAGE_FORMAT_BGRA8888)
    rtWidth = g_VR.rt:Width() -- width is unchanged; height is intentionally 3x frameH
    g_VR.rtWidth = rtWidth
    g_VR.rtHeight = frameH
    VRMOD_ShareTextureFinish(rtWidth / 2, frameH)

    if not g_VR.rtMat then
        g_VR.rtMat = CreateMaterial("vrmod_rtMat", "UnlitGeneric", { ["$basetexture"] = g_VR.rt:GetName() })
    else
        g_VR.rtMat:SetTexture("$basetexture", g_VR.rt:GetName())
    end

    local eyeW, eyeH = rtWidth / 2, frameH
    rtEyeW, rtEyeH = eyeW, eyeH -- cache for DrawEye / rtOverride hot paths
    g_VR.rtEye = GetRenderTargetEx("vrmod_rtEye_" .. eyeW .. "x" .. eyeH, eyeW, eyeH, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_SEPARATE, bit.bor(256, 32768), 0, IMAGE_FORMAT_BGRA8888)
    if not g_VR.rtEyeMat then
        g_VR.rtEyeMat = CreateMaterial("vrmod_rtEyeMat", "UnlitGeneric", { ["$basetexture"] = g_VR.rtEye:GetName() })
    else
        g_VR.rtEyeMat:SetTexture("$basetexture", g_VR.rtEye:GetName())
    end

    -- Defer display info to first render frame
    g_VR._needsFirstFrameSetup = true
    aspectLeft = 1
    aspectRight = 1
    ipd = 0.064; eyez = 0
    cropL_u0, cropL_v0, cropL_u1, cropL_v1 = 0, 0, 1, 1
    cropR_u0, cropR_v0, cropR_u1, cropR_v1 = 0, 0, 1, 1
    g_VR.displayInfo = {
        ipd = ipd, eyez = eyez,
        fovLeft = 90,
        fovRight = 90,
    }
end

	local function SetupActions()
		vrmod.SetupXRActions()
	end

	local function SetupNetworkAndOrigin()
		VRUtilNetworkInit()
		g_VR.origin = LocalPlayer():GetPos()
	end

	local function SetupScale()
		g_VR.scale = convars.vrmod_scale:GetFloat()
	end

	local function SetupViewParams()
		g_VR.view = {
			x = 0, y = 0,
			w = g_VR.rtWidth / 2, h = g_VR.rtHeight,
			aspect = aspectLeft or 1, aspectratio = aspectLeft or 1,
			fov = g_VR.displayInfo.fovLeft or 90,
			drawmonitors = true, drawviewmodel = false,
			znear = convars.vrmod_znear:GetFloat(),
			dopostprocess = convars.vrmod_postprocess:GetBool()
		}
	end

	local function InitializeTracking()
		lastPosePos = {}
		lastPoseAng = {}
		g_VR.tracking = {
			hmd = { pos = LocalPlayer():GetPos() + Vector(0, 0, 66.8), ang = Angle(), vel = Vector(), angvel = Angle() },
			pose_lefthand = { pos = LocalPlayer():GetPos(), ang = Angle(), vel = Vector(), angvel = Angle() },
			pose_righthand = { pos = LocalPlayer():GetPos(), ang = Angle(), vel = Vector(), angvel = Angle() },
		}
		g_VR.threePoints = true
	end

	local function SetupHandSimulation()
		local simulate = {
			{ pose = g_VR.tracking.pose_lefthand, offset = Vector(0, 10, -30) },
			{ pose = g_VR.tracking.pose_righthand, offset = Vector(0, -10, -30) },
		}
		for _, v in ipairs(simulate) do v.pose.simulatedPos = v.pose.pos end
		hook.Add("VRMod_Tracking", "simulatehands", function()
			for i = #simulate, 1, -1 do
				local v = simulate[i]
				if v.pose.pos == v.pose.simulatedPos then
					v.pose.pos, v.pose.ang = LocalToWorld(v.offset, Angle(90, 0, 0), g_VR.tracking.hmd.pos, Angle(0, g_VR.tracking.hmd.ang.yaw, 0))
					v.pose.simulatedPos = v.pose.pos
				else
					table.remove(simulate, i)
				end
			end
			if #simulate == 0 then hook.Remove("VRMod_Tracking", "simulatehands") end
		end)
	end

	local function BindRenderSceneHook()
		function VRUtilClientRender(poseLeft, poseRight, bandY)
			_bandY = bandY or 0
			_xrPoseLeft, _xrPoseRight = poseLeft, poseRight
			if g_VR.pauseReason then DrawPauseCard(g_VR.pauseReason) return end
			VRMOD_UpdatePosesAndActions()
			UpdateTracking()
			UpdateCollisionsAndWepPos()
			HandleInput()
			VRUtilNetUpdateLocalPly()
			UpdateViewFromEntity()
			PerformRenderViews()
		end
		hook.Add("RenderScene", "vrutil_hook_renderscene", function()
			if DrawErrorOverlay() then
				-- Still submit: VRUtilClientRender short-circuits to the pause
				-- card. pcall'd because we are deliberately running the module
				-- loop in a state it never used to see.
				if cv_pausecard:GetBool() then pcall(VRMOD_DoRenderLoop) end
				return true
			end
			local success = VRMOD_DoRenderLoop()
			if success == false then
				vrmod.logger.Err("DoRenderLoop returned false, shutting down VR")
				VRUtilClientExit()
				return true
			end
			if convars.vrmod_desktopview:GetInt() > 1 then
				-- Shared RT is 3 frames tall; sample only the band rendered this
				-- frame (_bandY / frameHeight) and squeeze the vertical crop into it.
				local band = g_VR.rtHeight > 0 and (_bandY / g_VR.rtHeight) or 0
				local v0 = (band + cropVerticalMargin) / 3
				local v1 = (band + 1 - cropVerticalMargin) / 3
				cam.Start2D()
				surface.SetDrawColor(255, 255, 255, 255)
				surface.SetMaterial(g_VR.rtMat)
				surface.DrawTexturedRectUV(0, 0, ScrW(), ScrH(), cropHorizontalOffset, v0, 0.5 + cropHorizontalOffset, v1)
				cam.End2D()
			end
			hook.Run("VRMod_PostRender")
			return true
		end)
	end

	if not GetConVar("vrmod_useworldmodels") then CreateConVar("vrmod_useworldmodels", "0", FCVAR_ARCHIVE) end
	g_VR.wmActive = false
	g_VR.wmWeapons = g_VR.wmWeapons or {}

	local function SetupModelAndPlayerHooks()
		g_VR.usingWorldModels = GetConVar("vrmod_useworldmodels"):GetBool()
		if not g_VR.usingWorldModels then
			-- viewmodel_fov is fully blocked from Lua on x64 (RunConsoleCommand
			-- AND SetString) so the old override silently failed — leaving the
			-- viewmodel rendering at fov 62 against a ~100° world projection,
			-- which visually displaces guns out of the hand. g_VR.view.viewmodelfov
			-- (set per-eye in DrawEye to match the eye projection exactly) now
			-- does the job engine-side with no convar at all.
			hook.Add("CalcViewModelView", "vrutil_hook_calcviewmodelview", function(_, vm, _, _, _, _) return g_VR.viewModelPos, g_VR.viewModelAng end)
			local blockViewModelDraw = true
			g_VR.allowPlayerDraw = false
			local hideplayer = convars.vrmod_floatinghands:GetBool()
			hook.Add("PostDrawTranslucentRenderables", "vrutil_hook_drawplayerandviewmodel", function(bSky, _)
				if bSky or not LocalPlayer():Alive() then return end
				if not g_VR.wmActive then
					if IsValid(g_VR.viewModel) then
						blockViewModelDraw = false
						g_VR.viewModel:DrawModel()
						blockViewModelDraw = true
					end
					render.SetColorModulation(1, 1, 1)
					if not hideplayer then
						g_VR.allowPlayerDraw = true
						cam.Start3D() cam.End3D()
						local prev = render.GetBlend()
						render.SetBlend(1)
						LocalPlayer():DrawModel()
						render.SetBlend(prev)
						cam.Start3D() cam.End3D()
						g_VR.allowPlayerDraw = false
					end
				end
				if VRUtilRenderMenuSystem then VRUtilRenderMenuSystem() end
			end)
			hook.Add("PreDrawPlayerHands", "vrutil_hook_predrawplayerhands", function() return true end)
			hook.Add("PreDrawViewModel", "vrutil_hook_predrawviewmodel", function()
				if g_VR.wmActive then return true end
				return blockViewModelDraw
			end)
		else
			g_VR.allowPlayerDraw = true
			hook.Add("PostDrawTranslucentRenderables", "vrutil_hook_drawplayerandviewmodel", function(bSky, _)
				if bSky then return end
				if VRUtilRenderMenuSystem then VRUtilRenderMenuSystem() end
			end)
		end
		hook.Add("ShouldDrawLocalPlayer", "vrutil_hook_shoulddrawlocalplayer", function()
			if g_VR.wmActive then return true end
			return g_VR.allowPlayerDraw
		end)
	end

	local function SetupShutdownHooks()
		function VRUtilClientExit()
			if not g_VR.active then return end
			restoreConvarOverrides()
			VRUtilMenuClose()
			VRUtilNetworkCleanup()
			vrmod.StopLocomotion()
			if IsValid(g_VR.viewModel) and g_VR.viewModel:GetClass() == "class C_BaseFlex" then g_VR.viewModel:Remove() end
			g_VR.viewModel = nil
			g_VR.viewModelMuzzle = nil
			VRUtilClientRender = nil
			_xrPoseLeft, _xrPoseRight, _rawHmdPose = nil, nil, nil
			g_VR.wmActive = false
			if IsValid(LocalPlayer()) and IsValid(LocalPlayer():GetViewModel()) then
				LocalPlayer():GetViewModel().RenderOverride = nil
				LocalPlayer():GetViewModel():RemoveEffects(EF_NODRAW)
			end
			hook.Remove("RenderScene", "vrutil_hook_renderscene")
			hook.Remove("CalcViewModelView", "vrutil_hook_calcviewmodelview")
			hook.Remove("PostDrawTranslucentRenderables", "vrutil_hook_drawplayerandviewmodel")
			hook.Remove("PreDrawPlayerHands", "vrutil_hook_predrawplayerhands")
			hook.Remove("PreDrawViewModel", "vrutil_hook_predrawviewmodel")
			hook.Remove("ShouldDrawLocalPlayer", "vrutil_hook_shoulddrawlocalplayer")
			hook.Remove("CalcView", "vrutil_hook_calcview")
			g_VR.tracking = {}
			g_VR.threePoints = false
			g_VR.sixPoints = false
			g_VR.displayInfo = nil
			if g_VR.rt then
				render.PushRenderTarget(g_VR.rt)
				render.Clear(0, 0, 0, 255, true, true)
				render.PopRenderTarget()
				g_VR.rt = nil
			end
			g_VR.rtEye = nil
			g_VR.rtEyeMat = nil
			g_VR.active = false
			VRMOD_Shutdown()
			vrmod.logger.Info("Ended VR session")
		end
		hook.Add("ShutDown", "vrutil_hook_shutdown", function()
			if IsValid(LocalPlayer()) and g_VR.net and g_VR.net[LocalPlayer():SteamID()] then VRUtilClientExit() end
		end)
	end

	function VRUtilClientStart()
		if not PerformStartup() then return end
		local mcoreOn = OverridePerformanceConvars()
		if SetupRenderTargets() == false then return end
		SetupActions()
		SetupNetworkAndOrigin()
		SetupScale()
		SetupViewParams()
		InitializeTracking()
		SetupHandSimulation()
		BindRenderSceneHook()
		SetupModelAndPlayerHooks()
		SetupShutdownHooks()
		vrmod.StartLocomotion()
		if VRMOD_SetMulticoreMode then VRMOD_SetMulticoreMode(mcoreOn) end
		if VRMOD_SetPredictionScale then VRMOD_SetPredictionScale(convars.vrmod_predictionscale:GetInt()) end
		g_VR.active = true
		vrmod.logger.Info("Started VR session")
	end
end