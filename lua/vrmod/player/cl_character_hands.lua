if CLIENT then
	local hands, srcModel, active
	local dirty = false -- finger tables were edited in place; rebuild targets
	CreateClientConVar("vrmod_floatinghands_material", "models/c_arms_citizen_hand", true, FCVAR_ARCHIVE)
	CreateClientConVar("vrmod_floatinghands_model", "models/player/vr_hands.mdl", true, FCVAR_ARCHIVE)
	CreateClientConVar("vrmod_floatinghands_chands", "0", true, FCVAR_ARCHIVE)
	CreateClientConVar("vrmod_floatinghands_stub", "1", true, FCVAR_ARCHIVE)
	local convars = vrmod.GetConvars()
	local FrameNumber, LerpAngle, IsValid = FrameNumber, LerpAngle, IsValid
	local ZERO_VEC, ANG_R180 = Vector(0, 0, 0), Angle(0, 0, 180)
	-- ApplyOpenHandPose (cl_vrmod) rewrites defaultOpenHandAngles IN PLACE, so
	-- the table-identity check in the bone callback can't see it. Flag it.
	-- Open-hand extend is per hands model: c_hands rest poses differ (the HL1
	-- pack is already straight, c_arms is relaxed) so one global factor can't
	-- fit both. The slider stays the single vrmod_finger_openextend convar; its
	-- value is saved under the current hands model on change and pushed back
	-- into the convar whenever a model is built.
	local EXT_FILE = "vrmod/floatinghands_extend.json"
	local extSaved = util.JSONToTable(file.Read(EXT_FILE, "DATA") or "") or {}
	local applyingExt = false
	cvars.AddChangeCallback("vrmod_finger_openextend", function(_, _, new)
		dirty = true
		if applyingExt or not IsValid(hands) then return end
		extSaved[hands:GetModel()] = tonumber(new) or 0.24
		if not file.IsDir("vrmod", "DATA") then file.CreateDir("vrmod") end
		file.Write(EXT_FILE, util.TableToJSON(extSaved, true))
	end, "vrmod_floatinghands")

	-- What the c_hands path would load right now: the local gmod_hands entity
	-- (model/skin/bodygroups already resolved server-side, matchBodySkin
	-- included), or player_manager while that hasn't arrived. Also polled to
	-- catch playermodel changes -- gmod_hands is rebuilt on respawn and there
	-- is no client hook for it.
	local function CHandsSource(ply)
		local h = ply.GetHands and ply:GetHands()
		if IsValid(h) then return h:GetModel(), h end
		local info = player_manager.TranslatePlayerHands(player_manager.TranslateToPlayerModelName(ply:GetModel()))
		return info and info.model or "", nil, info
	end

	-- Any rig missing either ValveBiped hand bone falls through to the convar
	-- model + material. Returns the entity and the c_hands source it tried
	-- (false when c_hands is off) so the poll compares against the attempt,
	-- not the fallback.
	local function ResolveHands(ply)
		local src = false
		if GetConVar("vrmod_floatinghands_chands"):GetBool() then
			local mdl, h, info = CHandsSource(ply)
			src = mdl
			local ent = mdl ~= "" and ClientsideModel(mdl)
			if IsValid(ent) then
				if ent:LookupBone("ValveBiped.Bip01_L_Hand") and ent:LookupBone("ValveBiped.Bip01_R_Hand") then
					local from = h or info.matchBodySkin and ply
					if from then
						ent:SetSkin(from:GetSkin())
						for i = 0, from:GetNumBodyGroups() - 1 do ent:SetBodygroup(i, from:GetBodygroup(i)) end
					else
						ent:SetSkin(info.skin or 0)
						if info.body then ent:SetBodyGroups(info.body) end
					end
					return ent, src
				end
				ent:Remove()
			end
			vrmod.logger.Warn("[Floating hands] c_hands " .. mdl .. " unusable, falling back")
		end
		local ent = ClientsideModel(GetConVar("vrmod_floatinghands_model"):GetString())
		ent:SetMaterial(GetConVar("vrmod_floatinghands_material"):GetString())
		return ent, src
	end

	local Build
	function Build(ply)
		if IsValid(hands) then hands:Remove() end
		local steamid = ply:SteamID()
		hands, srcModel = ResolveHands(ply)
		hands:SetPos(ply:GetPos())
		hands:SetupBones()
		g_VR.hands = hands
		vrmod.logger.Info("[Floating hands] %s", hands:GetModel())
		local k, cv = extSaved[hands:GetModel()], GetConVar("vrmod_finger_openextend")
		if k and cv and cv:GetFloat() ~= k then
			applyingExt = true
			cv:SetFloat(k)
			applyingExt = false
		end
		if srcModel then
			timer.Create("vrmod_floatinghands_rebuild", 1, 0, function()
				if CHandsSource(ply) ~= srcModel then Build(ply) end
			end)
		else
			timer.Remove("vrmod_floatinghands_rebuild")
		end
		local boneCount = hands:GetBoneCount()
		local parent = {}
		for i = 0, boneCount - 1 do parent[i] = hands:GetBoneParent(i) end

		-- Per side: the hand bone and the top drawn bone. Stub on: the forearm,
		-- which must be a hand ancestor or it would take the hand down with it.
		-- Stub off (or no forearm): the hand, so everything above the wrist
		-- collapses.
		local stub = GetConVar("vrmod_floatinghands_stub"):GetBool()
		local function Side(pfx)
			local h = hands:LookupBone("ValveBiped.Bip01_" .. pfx .. "_Hand")
			if not h then return end
			local top = h
			if stub then
				local f = hands:LookupBone("ValveBiped.Bip01_" .. pfx .. "_Forearm") or parent[h]
				local b = parent[h]
				while b >= 0 and b ~= f do b = parent[b] end
				if b >= 0 then top = f end
			end
			return h, top
		end
		local hL, topL = Side("L")
		local hR, topR = Side("R")
		if not (hL and hR) then
			vrmod.logger.Warn("[Floating hands] " .. hands:GetModel() .. " has no ValveBiped hand bones")
			return
		end

		-- side[i]: 1/2 = drawn (inside a top bone's subtree), 0 = collapsed.
		-- Collapsed bones go to the arm they hang off (LeftSide below); shared
		-- spine/root goes right.
		local side, ancL, ancR = {}, {}, {}
		for i = 0, boneCount - 1 do
			local b, s = i, 0
			while b >= 0 do
				if b == topL then s = 1 break end
				if b == topR then s = 2 break end
				b = parent[b]
			end
			side[i] = s
		end
		local b = parent[topL]
		while b >= 0 do ancL[b] = true b = parent[b] end
		b = parent[topR]
		while b >= 0 do ancR[b] = true b = parent[b] end
		-- Which side a collapsed bone belongs to: walk up until an ancestor is
		-- on exactly one arm. Needed for the wrist/ulna twist helpers -- with the
		-- stub off they are siblings of the hand under the forearm, so not in
		-- the hand subtree and not ancestors of anything; the old ancestor-only
		-- test sent the LEFT ones to the right hand, and every vert with a
		-- little wrist weight stretched across to it whenever the hands parted.
		local function LeftSide(i)
			local b = i
			while b >= 0 do
				local l = ancL[b]
				if l ~= ancR[b] then return l end
				b = parent[b]
			end
			return false
		end

		-- Persistent matrices, zero per-frame allocation on any of them:
		-- hand = tracked pose; forearm = hand * (forearm in hand space, reference
		-- pose), i.e. a rigid stub; collapse = top bone with a zeroed 3x3 so every
		-- hidden vert lands on the elbow (or wrist).
		local mHL = hands:GetBoneMatrix(hL) or Matrix()
		local mHR = hands:GetBoneMatrix(hR) or Matrix()
		local mFL, mFR, fPosL, fAngL, fPosR, fAngR
		if topL ~= hL then
			mFL = hands:GetBoneMatrix(topL) or Matrix()
			fPosL, fAngL = WorldToLocal(mFL:GetTranslation(), mFL:GetAngles(), mHL:GetTranslation(), mHL:GetAngles())
		end
		if topR ~= hR then
			mFR = hands:GetBoneMatrix(topR) or Matrix()
			fPosR, fAngR = WorldToLocal(mFR:GetTranslation(), mFR:GetAngles(), mHR:GetTranslation(), mHR:GetAngles())
		end
		local mTL, mTR = mFL or mHL, mFR or mHR
		local mCL, mCR = Matrix(), Matrix()
		mCL:Scale(ZERO_VEC)
		mCR:Scale(ZERO_VEC)

		-- Chain = every drawn bone that isn't a hand or top bone, in ascending
		-- index (Source guarantees parent < child), each driven off its parent's
		-- matrix object. Finger entries carry the open/closed angle sums
		-- (relative + offset) so the per-frame lerp is a single native call.
		local FK = {"0", "01", "02", "1", "11", "12", "2", "21", "22", "3", "31", "32", "4", "41", "42"}
		local fingerK, fingerName = {}, {}
		for k = 1, 30 do
			local name = "ValveBiped.Bip01_" .. (k < 16 and "L" or "R") .. "_Finger" .. FK[k - (k < 16 and 0 or 15)]
			local bi = hands:LookupBone(name)
			fingerName[k] = name
			if bi then fingerK[bi] = k end
		end
		local mats = {[hL] = mHL, [hR] = mHR, [topL] = mTL, [topR] = mTR}
		local aMat = {} -- every bone -> the matrix object it is written from
		local cMat, cPar, cPos, cAng, cKey, cK, cIdx, cOpen, cClosed, nChain = {}, {}, {}, {}, {}, {}, {}, {}, {}, 0
		for i = 0, boneCount - 1 do
			local m = mats[i]
			if not m then
				if side[i] == 0 then
					m = LeftSide(i) and mCL or mCR
				else
					m = hands:GetBoneMatrix(i) or Matrix()
					local pm = hands:GetBoneMatrix(parent[i]) or m
					local rp, ra = WorldToLocal(m:GetTranslation(), m:GetAngles(), pm:GetTranslation(), pm:GetAngles())
					local k = fingerK[i]
					nChain = nChain + 1
					cMat[nChain], cPar[nChain], cPos[nChain], cAng[nChain], cIdx[nChain] = m, mats[parent[i]], rp, ra, i
					cK[nChain] = k or false
					cKey[nChain] = k and "finger" .. math.floor((k - 1) / 3 + 1) or false
					mats[i] = m
				end
			end
			aMat[i] = m
		end

		-- Finger frame correction. cl_api hands out D = pose minus c_arms rest, in
		-- c_arms local Euler, so a finger target is the posed local rotation in the
		-- c_arms rig conjugated into this model's bone frames:
		--   T = Cp^-1 * R(refC + D) * Cb,  Cb = Qc^-1 * Qh,  Q = hand^-1 * bone (rest)
		-- On a Valve rig Cb is identity and this is exactly the old rest + delta.
		-- On a rig whose finger axes are rolled or reversed (HL1 pack) the curl
		-- lands on the right physical axis instead of bending backwards. Init only.
		local cRefC, cCpInv, cCb = {}, {}, {}
		local ref = ClientsideModel("models/weapons/c_arms.mdl")
		local HcInv, HhInv = {}, {mHL:GetInverseTR(), mHR:GetInverseTR()}
		if IsValid(ref) then
			ref:SetupBones()
			local l, r = ref:GetBoneMatrix(ref:LookupBone("ValveBiped.Bip01_L_Hand") or -1), ref:GetBoneMatrix(ref:LookupBone("ValveBiped.Bip01_R_Hand") or -1)
			HcInv[1], HcInv[2] = l and l:GetInverseTR(), r and r:GetInverseTR()
		end
		local corr = {}
		for n = 1, nChain do
			local k = cK[n]
			if k then
				local s = k < 16 and 1 or 2
				local rb = HcInv[s] and ref:LookupBone(fingerName[k])
				local Bc = rb and ref:GetBoneMatrix(rb)
				local Pc = Bc and ref:GetBoneMatrix(ref:GetBoneParent(rb))
				local Bh = Pc and hands:GetBoneMatrix(cIdx[n])
				if Bh then
					local Cb = (HcInv[s] * Bc):GetInverseTR() * (HhInv[s] * Bh)
					local pc = corr[parent[cIdx[n]]]
					corr[cIdx[n]] = Cb
					cRefC[n], cCpInv[n], cCb[n] = (Pc:GetInverseTR() * Bc):GetAngles(), pc and pc:GetInverseTR() or Matrix(), Cb
				else
					cRefC[n], cCpInv[n], cCb[n] = cAng[n], Matrix(), Matrix()
				end
			end
		end
		if IsValid(ref) then ref:Remove() end

		local NormalizeAngle = math.NormalizeAngle
		local scratch = Matrix()
		local function Target(n, tbl, k)
			scratch:SetAngles(cRefC[n] + tbl[k])
			return (cCpInv[n] * scratch * cCb[n]):GetAngles()
		end
		local lastOpen, lastClosed
		local function RebuildFingers(open, closed)
			lastOpen, lastClosed = open, closed
			for n = 1, nChain do
				local k = cK[n]
				if k then
					local o, c = Target(n, open, k), Target(n, closed, k)
					-- GetAngles normalises to +-180; unwrap closed against open so the
					-- per-frame Euler lerp never takes the long way round.
					c.p, c.y, c.r = o.p + NormalizeAngle(c.p - o.p), o.y + NormalizeAngle(c.y - o.y), o.r + NormalizeAngle(c.r - o.r)
					cOpen[n], cClosed[n] = o, c
				end
			end
		end

		hands:SetRenderBounds(ZERO_VEC, ZERO_VEC, Vector(65000, 65000, 65000))
		local wIdx, wMat, nWrite = {}, {}
		local frame = 0
		hands:AddCallback("BuildBonePositions", function(ent)
			local fn = FrameNumber()
			if fn ~= frame then
				frame = fn
				local net = g_VR.net[steamid]
				local f = net and net.lerpedFrame
				if f then
					-- Lighting samples at the entity origin (+ $illumposition). At the
					-- player's feet that sits on the floor plane and reads black on
					-- half the maps; the head is always in open air.
					ent:SetPos(g_VR.tracking.hmd.pos)
					mHL:SetTranslation(f.lefthandPos)
					mHL:SetAngles(f.lefthandAng)
					mHR:SetTranslation(f.righthandPos)
					mHR:SetAngles(f.righthandAng)
					mHR:Rotate(ANG_R180)
					if mFL then
						mFL:Set(mHL)
						mFL:Translate(fPosL)
						mFL:Rotate(fAngL)
					end
					if mFR then
						mFR:Set(mHR)
						mFR:Translate(fPosR)
						mFR:Rotate(fAngR)
					end
					mCL:Set(mTL)
					mCL:Scale(ZERO_VEC)
					mCR:Set(mTR)
					mCR:Scale(ZERO_VEC)
					local open, closed = g_VR.openHandAngles, g_VR.closedHandAngles
					if dirty or open ~= lastOpen or closed ~= lastClosed then
						dirty = false
						RebuildFingers(open, closed)
					end
					for n = 1, nChain do
						local m, key = cMat[n], cKey[n]
						m:Set(cPar[n])
						m:Translate(cPos[n])
						m:Rotate(key and LerpAngle(f[key], cOpen[n], cClosed[n]) or cAng[n])
					end
				end
			end

			if not nWrite then
				-- Bones with no usage flags (HL1 pack has a few) throw "Bone is
				-- unwriteable" from SetBoneMatrix; GetBoneMatrix is nil for exactly
				-- those. Probe once, inside a real pass, and never touch them again.
				nWrite = 0
				for i = 0, boneCount - 1 do
					if ent:GetBoneMatrix(i) then
						nWrite = nWrite + 1
						wIdx[nWrite], wMat[nWrite] = i, aMat[i]
					end
				end
			end
			for n = 1, nWrite do ent:SetBoneMatrix(wIdx[n], wMat[n]) end
		end)
	end

	-- Hands-only draws no body, so nothing runs the character system's
	-- PrePlayerDraw (SetPos(renderPos) + SetupBones + UpdateIK) before a
	-- bonemerged worldmodel weapon draws: the first eye merges against last
	-- frame's hand bone and only the second eye is current. The old 2048x2048
	-- "dummy mirror" existed for this DrawModel side effect, but ran in
	-- PreDrawTranslucentRenderables -- after the opaque weapon draw -- and
	-- rendered the whole model onto a 1x1 quad. Same DrawModel, before anything
	-- opaque in the first eye, colour and depth writes off, then re-merge the
	-- weapon and its muzzle against the fresh bones.
	local drawFrame = 0
	local function DummyDraw(depth, skybox)
		if depth or skybox then return end
		local fn = FrameNumber()
		if fn == drawFrame then return end
		local ep = EyePos()
		if ep ~= g_VR.eyePosLeft and ep ~= g_VR.eyePosRight then return end
		drawFrame = fn
		local ply = LocalPlayer()
		local allow, ro = g_VR.allowPlayerDraw, ply.RenderOverride
		g_VR.allowPlayerDraw, ply.RenderOverride = true, nil
		render.OverrideColorWriteEnable(true, false)
		render.OverrideDepthEnable(true, false)
		render.SuppressEngineLighting(true)
		ply:DrawModel()
		render.SuppressEngineLighting(false)
		render.OverrideDepthEnable(false, false)
		render.OverrideColorWriteEnable(false, false)
		g_VR.allowPlayerDraw, ply.RenderOverride = allow, ro
		local vm = g_VR.viewModel
		if IsValid(vm) and vm:IsWeapon() then vrmod.utils.RefreshViewModelMuzzle(vm) end
	end

	hook.Add("VRMod_Start", "vrmod_starthandsonly", function(ply)
		if not (ply == LocalPlayer() and convars.vrmod_floatinghands:GetBool()) then return end
		active = true
		timer.Simple(0, function() LocalPlayer().RenderOverride = function() end end)
		Build(ply)
		g_VR.characterYaw = 0
		hook.Add("PreDrawOpaqueRenderables", "vrmod_floatinghands_dummydraw", DummyDraw)
	end)

	-- Both are read at build time; rebuild live instead of asking for a restart.
	local function Rebuild() if active then Build(LocalPlayer()) end end
	cvars.AddChangeCallback("vrmod_floatinghands_chands", Rebuild, "vrmod_floatinghands")
	cvars.AddChangeCallback("vrmod_floatinghands_stub", Rebuild, "vrmod_floatinghands")

	hook.Add("VRMod_Exit", "vrmod_stophandsonly", function(ply)
		if not active or ply ~= LocalPlayer() then return end
		active = nil
		timer.Remove("vrmod_floatinghands_rebuild")
		hook.Remove("PreDrawOpaqueRenderables", "vrmod_floatinghands_dummydraw")
		if IsValid(hands) then hands:Remove() end
		hands = nil
		LocalPlayer().RenderOverride = nil
	end)
end