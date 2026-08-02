if CLIENT then
	local convars, convarValues = vrmod.AddCallbackedConvar("vrmod_flashlight_attachment", nil, "0", nil, nil, 0, 2, function(val) return math.floor(tonumber(val) or 0) end)
	local attachments = {"pose_righthand", "pose_lefthand", "hmd",}
	local flashlight = nil
	local fwd, lastPos, lastAng = Vector(), Vector(1e9, 0, 0), Angle() -- scratch; lastPos far so first frame always updates
	vrmod.AddCallbackedConvar("vrmod_flashlight_projtex", nil, "1", nil, nil, 0, 1, function(val) return math.floor(tonumber(val) or 0) end)
	-- Engine flashlight shadow depth: the depth pass re-renders whenever an
	-- animated caster (hands/body/props) is in the beam and flushes the
	-- material queue under mat_queue_mode 2 -- the close-prop / pointed-down
	-- eye stutter. MUST be committed while no VR session exists: changing it
	-- in VR reallocates the depth texture and corrupts the shared eye RT
	-- (RunConsoleCommand also defers a frame, so a "VR start" apply lands
	-- mid-init). Applied at game load and on toggle change outside VR only.
	CreateClientConVar("vrmod_flashlight_nodepth", "1", true, false, "Disable engine flashlight shadow depth (VR stutter fix; applies at load / outside VR only)", 0, 1)
	local function ApplyFlashlightDepth()
		if g_VR.active then return end -- never reallocate the depth RT mid-session
		local off = GetConVar("vrmod_flashlight_nodepth"):GetBool()
		if IsConCommandBlocked("r_flashlightdepthtexture") then
			if off then vrmod.logger.Err("r_flashlightdepthtexture is blocked from Lua; add +r_flashlightdepthtexture 0 to launch options") end
			return
		end
		RunConsoleCommand("r_flashlightdepthtexture", off and "0" or "1")
	end
	hook.Add("InitPostEntity", "vrmod_flashlight_depth", ApplyFlashlightDepth)
	cvars.AddChangeCallback("vrmod_flashlight_nodepth", function() ApplyFlashlightDepth() end, "vrmod_flashlight_depth")
	if IsValid(LocalPlayer()) then ApplyFlashlightDepth() end -- lua autorefresh: InitPostEntity already fired
	local usingDL, farZ, tanHalf = false, 750, 0.5
	local endPos, lightPos = Vector(), Vector() -- scratch
	local trOut = {}
	local trace = {output = trOut, mask = MASK_SOLID}
	net.Receive("vrmod_flashlight", function()
		local enabled = net.ReadBool()
		if not flashlight and enabled then
			surface.PlaySound("items/flashlight1.wav")
			local fov = GetConVar("r_flashlightfov"):GetFloat()
			farZ = GetConVar("r_flashlightfar"):GetFloat()
			-- Projected-texture cone by default; vrmod_flashlight_projtex 0
			-- selects a traced dynamic light instead (one trace + one dlight at
			-- the beam's impact -- no per-model lighting passes, cheaper on weak
			-- GPUs). Applies on next flashlight toggle. The eye stutter blamed
			-- on this projtex was actually the pickup halos (see cl_halos.lua).
			usingDL = convarValues.vrmod_flashlight_projtex ~= 1
			if usingDL then
				flashlight = true
				tanHalf = math.tan(math.rad(fov * 0.5))
				trace.filter = LocalPlayer()
			else
				flashlight = ProjectedTexture()
				-- Never own a shadow depth map: the depth pass re-renders whenever
				-- an animated caster (hands/body/props) sits in the beam, and under
				-- mat_queue_mode 2 that pass flushes the queue every frame -- the
				-- close-prop / pointed-down eye stutter (confirmed via
				-- r_flashlightdepthtexture 0; see also the perf override).
				flashlight:SetEnableShadows(false)
				flashlight:SetTexture("effects/flashlight001")
				flashlight:SetFOV(fov)
				flashlight:SetFarZ(farZ)
			end
			-- gmod PreRender, NOT VRMod_PreRender: the VR hook fires inside
			-- RenderScene, and mutating projtex state mid-pipeline under
			-- mat_queue_mode 2 desyncs what each queued eye render samples ->
			-- per-eye flicker at fine fps. PreRender runs before the render
			-- path (df_flashlight's pattern, flicker-free on mcore); the light
			-- trails tracking by one frame, invisible for a cone. Also skip the
			-- mutation entirely while the hand is still -- no Update() means no
			-- queue interaction at all, exactly when flicker is most visible.
			hook.Add("PreRender", "vrmod_flashlight", function()
				if not g_VR.threePoints then return end
				local t = g_VR.tracking[attachments[convarValues.vrmod_flashlight_attachment + 1]]
				local pos, ang = t.pos, t.ang
				if convarValues.vrmod_flashlight_attachment == 0 and g_VR.viewModelMuzzle then
					pos = g_VR.viewModelMuzzle.Pos
					if not (g_VR.currentvmi and g_VR.currentvmi.wrongMuzzleAng) then ang = g_VR.viewModelMuzzle.Ang end
				end
				if usingDL then
					fwd:Set(ang:Forward())
					endPos:Set(fwd)
					endPos:Mul(farZ)
					endPos:Add(pos)
					trace.start = pos
					trace.endpos = endPos
					util.TraceLine(trace)
					local dl = DynamicLight(LocalPlayer():EntIndex())
					if dl then
						-- sit on the surface, pulled out along the normal so the
						-- light doesn't bleed through it
						lightPos:Set(trOut.HitNormal)
						lightPos:Mul(8)
						lightPos:Add(trOut.HitPos)
						dl.pos = lightPos
						dl.r, dl.g, dl.b = 255, 250, 235
						dl.brightness = 3
						dl.decay = 1000
						-- spot radius at hit distance from the flashlight FOV
						dl.size = math.Clamp(trOut.Fraction * farZ * tanHalf * 2.2, 96, 600)
						dl.dietime = CurTime() + 0.1
					end
					return
				end
				local dp, dy, dr = ang.p - lastAng.p, ang.y - lastAng.y, ang.r - lastAng.r
				if lastPos:DistToSqr(pos) < 0.25 and dp < 0.5 and dp > -0.5 and dy < 0.5 and dy > -0.5 and dr < 0.5 and dr > -0.5 then return end
				lastPos:Set(pos)
				lastAng:Set(ang)
				fwd:Set(ang:Forward())
				fwd:Mul(10)
				fwd:Add(pos)
				flashlight:SetPos(fwd)
				flashlight:SetAngles(ang)
				flashlight:Update()
			end)
		elseif flashlight then
			surface.PlaySound("items/flashlight1.wav")
			hook.Remove("PreRender", "vrmod_flashlight")
			if not usingDL then flashlight:Remove() end -- dlight expires via dietime
			flashlight = nil
		end
	end)

	hook.Add("VRMod_Exit", "flashlight", function(ply, steamid)
		if ply == LocalPlayer() and flashlight then
			hook.Remove("PreRender", "vrmod_flashlight")
			if not usingDL then flashlight:Remove() end
			flashlight = nil
		end
	end)

	-- ── Dynamic Flashlight (df_flashlight) VR bridge ────────────
	-- The addon owns toggle + texture props (shadows/FOV/distance/texture); we
	-- only override the transform to the VR attachment pose. PreRender runs
	-- after Think, so we win whether df renders on Think (render_type 1) or
	-- PreRender (0). For the default we register after df's PreRender hook.
	local function setupDFBridge()
		if not ConVarExists("df_flashlight") then return end
		local player_Iterator = player.Iterator
		local fwd = Vector() -- scratch, reused
		local function poseFor(ply, lp)
			if ply == lp then
				if not (g_VR.active and g_VR.threePoints) then return end
				local att = convarValues.vrmod_flashlight_attachment
				if att == 0 and g_VR.viewModelMuzzle then -- match native VR feel: emit from muzzle
					local m = g_VR.viewModelMuzzle
					if g_VR.currentvmi and g_VR.currentvmi.wrongMuzzleAng then
						local t = g_VR.tracking.pose_righthand
						return m.Pos, t and t.ang
					end
					return m.Pos, m.Ang
				end
				local t = g_VR.tracking[attachments[att + 1]]
				if t then return t.pos, t.ang end
			else -- remote VR player: networked hand pose (right hand; pref isn't networked)
				local n = g_VR.net and g_VR.net[ply:SteamID()]
				local lf = n and n.lerpedFrame
				if lf then return lf.righthandPos, lf.righthandAng end
			end
		end
		local function vrReposition()
			local lp = LocalPlayer()
			for _, ply in player_Iterator() do
				local tex = ply.DynamicFlashlight -- only set by df when flashlight is on
				if tex then
					local pos, ang = poseFor(ply, lp)
					if pos and ang then
						fwd:Set(ang:Forward())
						fwd:Mul(10)
						fwd:Add(pos)
						tex:SetPos(fwd)
						tex:SetAngles(ang)
						tex:Update()
					end
				end
			end
		end
		local function arm()
			hook.Remove("PreRender", "vrmod_df_vr")
			hook.Add("PreRender", "vrmod_df_vr", vrReposition)
		end
		arm()
		-- df can move its render hook to PreRender at runtime; re-arm after it.
		cvars.AddChangeCallback("df_flashlight_render_type", function() timer.Simple(0, arm) end, "vrmod_df_vr")
	end
	-- df may load before or after VRMod; defer if its convar isn't up yet.
	if ConVarExists("df_flashlight") then setupDFBridge()
	else hook.Add("InitPostEntity", "vrmod_df_vr_init", setupDFBridge) end
elseif SERVER then
	util.AddNetworkString("vrmod_flashlight")
	local skip = false
	hook.Add("PlayerSwitchFlashlight", "vrmod_flashlight", function(ply, enabled)
		if skip then return end
		-- Dynamic Flashlight addon present: let it own the on/off toggle and its proj text.
		local df = GetConVar("df_flashlight")
		if df and df:GetBool() then return end
		if g_VR[ply:SteamID()] then
			skip = true
			local res = hook.Run("PlayerSwitchFlashlight", ply, enabled)
			skip = false
			if res == false then return end
			net.Start("vrmod_flashlight")
			net.WriteBool(ply.m_bFlashlight ~= false and enabled)
			net.Send(ply)
			if enabled then
				return false --don't turn on the default flashlight cus we're using a custom one for vr
			end
		end
	end)
end