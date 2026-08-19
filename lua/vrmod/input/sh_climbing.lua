AddCSLuaFile()

local GRAB_HULL = 2 -- small probe box: a larger hull self-clips the wall at contact (StartSolid deadzone) and inflates reach
local GRAB_BACKOFF = 4 -- start grab traces just behind the palm so a hand touching/penetrating the wall still hits the front face
local LERP_SPEED = 10
local VAULT_SPEED = 6
local LEDGE_SCAN_RATE = 0.1
local VAULT_STICK_THRESHOLD = 0.5
local SYNC_INTERVAL = 0.033 -- send position to server ~30hz during climbing
local HULL_MINS = Vector(-3, -3, 0)
local HULL_MAXS = Vector(3, 3, 36)

-- reusable trace structs
local tr = {
	start = Vector(), endpos = Vector(),
	mins = Vector(-GRAB_HULL, -GRAB_HULL, -GRAB_HULL),
	maxs = Vector(GRAB_HULL, GRAB_HULL, GRAB_HULL),
	mask = MASK_SOLID_BRUSHONLY, filter = nil,
}
local hullTr = {
	start = Vector(), endpos = Vector(),
	mins = HULL_MINS, maxs = HULL_MAXS,
	mask = MASK_PLAYERSOLID, filter = nil,
}
local lineTr = { start = Vector(), endpos = Vector(), mask = MASK_PLAYERSOLID, filter = nil }

local TRACE_DIRS = {
	Vector(-1, 0, 0),
	Vector(0, 0, -1),
	Vector(0, 0, 1),
	Vector(0, 1, 0),
	Vector(0, -1, 0),
}

-- cached metatable calls for ladder suppression (both realms)
local GetMoveType = FindMetaTable("Entity").GetMoveType
local SetMoveType = FindMetaTable("Entity").SetMoveType

-- server-authoritative whitelist convars (replicated so clients can read them)
local sv_climbing_ledgeonly = CreateConVar("vrmod_sv_climbing_ledgeonly", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Force whitelist ledges for all VR players")
local sv_climbing_ladderonly = CreateConVar("vrmod_sv_climbing_ladderonly", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Force whitelist ladders for all VR players")

-- Throw tuning is gameplay, so it belongs to the server. It used to be a plain
-- FCVAR_ARCHIVE convar, which on a client is just a client convar: the client
-- scaled and capped its own launch velocity and the server applied whatever
-- arrived, so vrmod_brushclimb_throw 10 (or a forged vector) was a free
-- cross-map launch. Replicated now, and enforced in the net handler.
local sv_throw = CreateConVar("vrmod_sv_climbing_throw", "2.5", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Throw force multiplier for climbing momentum", 0, 10)
local sv_throwmin = CreateConVar("vrmod_sv_climbing_throwmin", "40", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Minimum release speed that counts as a throw (below this you just let go)", 0, 400)
local sv_throwmax = CreateConVar("vrmod_sv_climbing_throwmax", "800", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Hard cap on launch speed off a wall", 0, 2000)

if CLIENT then

	g_VR = g_VR or {}

	local convars = vrmod.AddCallbackedConvar("vrmod_brushclimb", nil, "0")
	local cv_ledge = CreateClientConVar("vrmod_brushclimb_ledge", "1", true, false, "Enable ledge vaulting while climbing")
	local cv_marker = CreateClientConVar("vrmod_brushclimb_marker", "1", true, false, "Show landing marker on detected ledges")
	local cv_ledgeonly = CreateClientConVar("vrmod_brushclimb_ledgeonly", "0", true, false, "Whitelist: only grab near ledge tops")
	local cv_ladderonly = CreateClientConVar("vrmod_brushclimb_ladderonly", "0", true, false, "Whitelist: only grab ladder surfaces")
	local cv_ledgereach = CreateClientConVar("vrmod_brushclimb_ledgereach", "48", true, false, "Max height above hand to detect a ledge", 8, 96)
	local cv_vaultreach = CreateClientConVar("vrmod_brushclimb_vaultreach", "48", true, false, "Horizontal scan range for vault targets", 16, 128)
	local cv_vaultmin = CreateClientConVar("vrmod_brushclimb_vaultmin", "24", true, false, "Min horizontal distance for vault target", 8, 64)
	local cv_magnet = CreateClientConVar("vrmod_brushclimb_magnet", "1", true, false, "Snap hand to wall surface when grabbing")
	local cv_magnetoff = CreateClientConVar("vrmod_brushclimb_magnet_offset", "2", true, false, "Palm offset from wall for magnet grab", 0, 8)
	local cv_reach = CreateClientConVar("vrmod_brushclimb_reach", "2", true, false, "Hand grab reach distance", 0, 32)
	local cv_ladderreach = CreateClientConVar("vrmod_brushclimb_ladderreach", "24", true, false, "Hand grab reach inside ladder zones (clip brushes removed leave the wall deeper)", 0, 64)
	local cv_smooth = CreateClientConVar("vrmod_brushclimb_smooth", "0", true, false, "Climb position smoothing (0 = exact 1:1)", 0, 0.9)
	local cv_nofloor = CreateClientConVar("vrmod_brushclimb_nofloor", "1", true, false, "Prevent grabbing walkable floors")
	local cv_requireboth = CreateClientConVar("vrmod_brushclimb_requireboth", "0", true, false, "Require both grip and trigger held to grab walls")
	local cv_anticlipgrace = CreateClientConVar("vrmod_brushclimb_anticlipgrace", "0.7", true, false, "Seconds after letting go of a wall before head anti-clip resumes", 0, 5)

	-- Restore every climbing tuning convar to its built-in default in one shot (master enable is left alone).
	concommand.Add("vrmod_brushclimb_reset", function()
		local cvs = {
			cv_requireboth, cv_nofloor, cv_magnet, cv_magnetoff, cv_reach, cv_smooth,
			cv_ladderreach, cv_ledge, cv_marker, cv_ledgeonly, cv_ladderonly,
			cv_ledgereach, cv_vaultreach, cv_vaultmin, cv_anticlipgrace,
		}
		for i = 1, #cvs do RunConsoleCommand(cvs[i]:GetName(), cvs[i]:GetDefault()) end
		print("[VRMod] Climbing settings reset to defaults")
	end)

	-- combined client+server whitelist checks
	local function LadderWL() return cv_ladderonly:GetBool() or sv_climbing_ladderonly:GetBool() end
	local function LedgeWL() return cv_ledgeonly:GetBool() or sv_climbing_ledgeonly:GetBool() end

	-- Material-typed grab sounds: scan folders once at load
	local grabPools = {}
	for _, folder in ipairs({"concreteandwood", "dirt", "metal_thin"}) do
		local files = file.Find("sound/grab/" .. folder .. "/*.wav", "GAME")
		local pool = {}
		for i = 1, #files do pool[i] = "grab/" .. folder .. "/" .. files[i] end
		grabPools[folder] = pool
	end
	local MAT_GRAB = {
		[MAT_METAL] = "metal_thin", [MAT_GRATE] = "metal_thin", [MAT_VENT] = "metal_thin",
		[MAT_DIRT] = "dirt", [MAT_SAND] = "dirt", [MAT_GRASS] = "dirt",
		[MAT_FOLIAGE] = "dirt", [MAT_SNOW] = "dirt",
	}
	local function PlayGrabSound(pos, matType)
		local pool = grabPools[MAT_GRAB[matType] or "concreteandwood"]
		local n = #pool
		if n > 0 then sound.Play(pool[math.random(n)], pos, 70, math.random(95, 105), 1) end
	end

	-- Vault landing sounds (wood_floor_old + wood_crate merged into "wood" for variety)
	local vaultPools = {}
	for _, folder in ipairs({"concrete", "dirt", "gravel", "metal_thin", "wood_crate", "wood_floor_old"}) do
		local files = file.Find("sound/vault/" .. folder .. "/*.wav", "GAME")
		local pool = {}
		for i = 1, #files do pool[i] = "vault/" .. folder .. "/" .. files[i] end
		vaultPools[folder] = pool
	end
	vaultPools.wood = table.Add(table.Add({}, vaultPools.wood_floor_old), vaultPools.wood_crate)
	local MAT_VAULT = {
		[MAT_METAL] = "metal_thin", [MAT_GRATE] = "metal_thin", [MAT_VENT] = "metal_thin",
		[MAT_DIRT] = "dirt", [MAT_GRASS] = "dirt", [MAT_FOLIAGE] = "dirt", [MAT_SNOW] = "dirt",
		[MAT_SAND] = "gravel",
		[MAT_WOOD] = "wood",
		[MAT_CONCRETE] = "concrete", [MAT_TILE] = "concrete",
	}
	local function PlayVaultSound(pos, matType)
		local pool = vaultPools[MAT_VAULT[matType] or "concrete"]
		local n = #pool
		if n > 0 then sound.Play(pool[math.random(n)], pos, 75, math.random(95, 105), 1) end
	end

	-- Yeet (self-throw) sounds: fire when player launches off the wall with real momentum
	local yeetPool = {}
	do
		local files = file.Find("sound/vault/yeet/*.wav", "GAME")
		for i = 1, #files do yeetPool[i] = "vault/yeet/" .. files[i] end
	end
	local function PlayYeetSound(pos)
		local n = #yeetPool
		if n > 0 then sound.Play(yeetPool[math.random(n)], pos, 75, math.random(95, 105), 1) end
	end

	-- warm sound caches so the first play of each variant doesn't hitch mid-climb
	for _, pool in pairs(grabPools) do for i = 1, #pool do util.PrecacheSound(pool[i]) end end
	for _, pool in pairs(vaultPools) do for i = 1, #pool do util.PrecacheSound(pool[i]) end end
	for i = 1, #yeetPool do util.PrecacheSound(yeetPool[i]) end

	vrmod.climbing = vrmod.climbing or {}
	vrmod.climbing.gripLeft = false
	vrmod.climbing.gripRight = false
	vrmod.climbing.wallLeft = false
	vrmod.climbing.wallRight = false

	local hands = {
		[1] = { poseName = "pose_lefthand",  grabPos = nil, wallNormal = nil, worldAnchor = nil },
		[2] = { poseName = "pose_righthand", grabPos = nil, wallNormal = nil, worldAnchor = nil },
	}

	-- Input dispatch: action -> {hand, isGrip}. Trigger actions are only consulted when
	-- cv_requireboth is on, but state is always tracked so toggling the convar mid-session
	-- stays coherent. Single table lookup replaces string compares in the hot path.
	local INPUT_MAP = {
		boolean_left_pickup   = {1, true},
		boolean_right_pickup  = {2, true},
		boolean_secondaryfire = {1, false}, -- left trigger
		boolean_primaryfire   = {2, false}, -- right trigger
	}
	local gripHeld    = {false, false}
	local triggerHeld = {false, false}
	local handActive  = {false, false} -- last effective (grab-eligible) state per hand

	local refHand = nil
	local lerpOrigin = nil
	local lerpTarget = nil
	local lerpEndOrigin = nil
	local lerpTime = 0
	local lerpSpeed = LERP_SPEED
	-- When the last hand let go, for the head anti-clip grace window below.
	local releaseTime = -1

	-- momentum tracking
	local prevOriginX, prevOriginY, prevOriginZ = 0, 0, 0
	local velocityX, velocityY, velocityZ = 0, 0, 0
	local lastFrameTime = 0
	local nextSyncTime = 0

	-- ledge detection state
	local ledgeMarker = nil
	local ledgePos = nil
	local ledgeMat = 0
	local nextLedgeScan = 0
	local markerMtx = Matrix()
	local zeroMtx = Matrix()
	zeroMtx:Scale(Vector(0, 0, 0))

	-- reusable vectors to avoid per-frame allocations
	local _tmpVec = Vector()
	local _tmpAng = Angle()
	local COLOR_LEDGE = Color(7, 255, 0, 200)
	local COLOR_HIDDEN = Color(0, 0, 0, 0)

	-- Ladder surface detection: texture match + cached AABB zones (survives entity removal)
	local string_find, string_upper = string.find, string.upper
	local ladderZones = {} -- {minx,miny,minz,maxx,maxy,maxz} per ladder entity
	local function CacheLadderZones()
		for _, class in ipairs({"func_ladder", "func_useableladder"}) do
			for _, ent in ipairs(ents.FindByClass(class)) do
				local pos = ent:GetPos()
				local mn, mx = ent:GetCollisionBounds()
				local n = #ladderZones + 1
				ladderZones[n] = {pos.x+mn.x-8, pos.y+mn.y-8, pos.z+mn.z-8, pos.x+mx.x+8, pos.y+mx.y+8, pos.z+mx.z+8}
			end
		end
	end
	hook.Add("InitPostEntity", "brushclimb_cache", CacheLadderZones)

	local function IsLadderSurface(hx, hy, hz, hitTexture)
		if hitTexture and string_find(string_upper(hitTexture), "LADDER", 1, true) then return true end
		for i = 1, #ladderZones do
			local z = ladderZones[i]
			if hx >= z[1] and hx <= z[4] and hy >= z[2] and hy <= z[5] and hz >= z[3] and hz <= z[6] then return true end
		end
		return false
	end

	-- Check if a ledge top exists near a wall hit point (probes INTO wall and upward)
	local function HasLedgeNearby(hx, hy, hz, nx, ny)
		local reach = cv_ledgereach:GetInt()
		lineTr.filter = LocalPlayer()
		for zOff = 0, reach, 8 do
			local probeZ = hz + zOff
			for dist = 4, reach, 4 do
				local px, py = hx - nx * dist, hy - ny * dist
				lineTr.start.x, lineTr.start.y, lineTr.start.z = px, py, probeZ
				lineTr.endpos.x, lineTr.endpos.y, lineTr.endpos.z = px, py, probeZ + reach
				local upRes = util.TraceLine(lineTr)
				local topZ = upRes.Hit and (upRes.HitPos.z - 1) or (probeZ + reach)
				lineTr.start.z = topZ
				lineTr.endpos.z = topZ - reach
				local downRes = util.TraceLine(lineTr)
				if downRes.Hit and downRes.HitNormal.z >= 0.7 then return true end
			end
		end
		return false
	end

	-- Whitelist gate: if any whitelist is on, surface must match at least one
	local function PassesWhitelist(hx, hy, hz, nx, ny, hitTexture)
		local wlLedge = LedgeWL()
		local wlLadder = LadderWL()
		if not wlLedge and not wlLadder then return true end
		if wlLadder then
			if not hitTexture then
				-- collision fallback: quick trace to get texture
				lineTr.filter = LocalPlayer()
				lineTr.start.x, lineTr.start.y, lineTr.start.z = hx, hy, hz
				lineTr.endpos.x = hx - nx * 8
				lineTr.endpos.y = hy - ny * 8
				lineTr.endpos.z = hz
				hitTexture = util.TraceLine(lineTr).HitTexture or ""
			end
			if IsLadderSurface(hx, hy, hz, hitTexture) then return true end
		end
		if wlLedge and HasLedgeNearby(hx, hy, hz, nx, ny) then return true end
		return false
	end

	local function TraceForBrush(handPos, handAng)
		tr.filter = LocalPlayer()
		local fwd = handAng:Forward()
		local rt = handAng:Right()
		local up = handAng:Up()
		local noFloor = cv_nofloor:GetBool()
		-- extend reach when hand is inside a ladder zone (removed clip brushes leave wall deeper)
		local range = cv_reach:GetInt()
		if LadderWL() then
			local hx, hy, hz = handPos.x, handPos.y, handPos.z
			for j = 1, #ladderZones do
				local z = ladderZones[j]
				if hx >= z[1] and hx <= z[4] and hy >= z[2] and hy <= z[5] and hz >= z[3] and hz <= z[6] then
					range = cv_ladderreach:GetInt()
					break
				end
			end
		end
		for i = 1, 5 do
			local d = TRACE_DIRS[i]
			local dx = fwd.x * d.x + rt.x * d.y + up.x * d.z
			local dy = fwd.y * d.x + rt.y * d.y + up.y * d.z
			local dz = fwd.z * d.x + rt.z * d.y + up.z * d.z
			tr.start.x = handPos.x - dx * GRAB_BACKOFF
			tr.start.y = handPos.y - dy * GRAB_BACKOFF
			tr.start.z = handPos.z - dz * GRAB_BACKOFF
			tr.endpos.x = handPos.x + dx * range
			tr.endpos.y = handPos.y + dy * range
			tr.endpos.z = handPos.z + dz * range
			local res = util.TraceHull(tr)
			if res.Hit and not res.StartSolid and not res.HitSky and res.HitWorld then
				if not (noFloor and res.HitNormal.z >= 0.7) and PassesWhitelist(res.HitPos.x, res.HitPos.y, res.HitPos.z, res.HitNormal.x, res.HitNormal.y, res.HitTexture) then
					return res.HitPos, res.HitNormal, res.MatType
				end
			end
		end
		-- Hand inside a ladder brush: StartSolid killed all 5 traces.
		-- Probe from outside each horizontal AABB face toward the hand to find the front surface.
		if LadderWL() then
			local hx, hy, hz = handPos.x, handPos.y, handPos.z
			for j = 1, #ladderZones do
				local z = ladderZones[j]
				if hx >= z[1] and hx <= z[4] and hy >= z[2] and hy <= z[5] and hz >= z[3] and hz <= z[6] then
					tr.endpos.x, tr.endpos.y, tr.endpos.z = hx, hy, hz
					for p = 1, 4 do
						tr.start.x, tr.start.y, tr.start.z = hx, hy, hz
						if p == 1 then tr.start.x = z[1] - 5
						elseif p == 2 then tr.start.x = z[4] + 5
						elseif p == 3 then tr.start.y = z[2] - 5
						else tr.start.y = z[5] + 5 end
						local res = util.TraceHull(tr)
						if res.Hit and not res.StartSolid and not res.HitSky and PassesWhitelist(res.HitPos.x, res.HitPos.y, res.HitPos.z, res.HitNormal.x, res.HitNormal.y, res.HitTexture) then
							return res.HitPos, res.HitNormal, res.MatType
						end
					end
					break
				end
			end
		end
		return nil
	end

	local function ScanForLedge()
		if not cv_ledge:GetBool() then return nil end

		local ply = LocalPlayer()
		lineTr.filter = ply
		hullTr.filter = ply

		-- use highest grab point as base Z; fall back to origin if grabs are below it
		local bestZ = g_VR.origin.z
		local bestNormal = nil
		for i = 1, 2 do
			local h = hands[i]
			if h.grabPos then
				if h.grabPos.z > bestZ then
					bestZ = h.grabPos.z
				end
				bestNormal = bestNormal or h.wallNormal
			end
		end
		if not bestNormal then return nil end

		local hmdPos = g_VR.tracking.hmd.pos
		local hmdX, hmdY = hmdPos.x, hmdPos.y
		_tmpAng.p, _tmpAng.y, _tmpAng.r = 0, g_VR.tracking.hmd.ang.yaw, 0
		local hmdFwd = _tmpAng:Forward()
		local dirs = { hmdFwd, bestNormal }
		local vaultReach = cv_vaultreach:GetInt()
		local vaultMinSq = cv_vaultmin:GetFloat() ^ 2
		for d = 1, 2 do
			local dir = dirs[d]
			for dist = 16, vaultReach, 16 do
				local probeX = hmdX + dir.x * dist
				local probeY = hmdY + dir.y * dist

				lineTr.start.x, lineTr.start.y, lineTr.start.z = probeX, probeY, bestZ
				lineTr.endpos.x, lineTr.endpos.y, lineTr.endpos.z = probeX, probeY, bestZ + 72
				local upRes = util.TraceLine(lineTr)
				local topZ = upRes.Hit and (upRes.HitPos.z - 1) or (bestZ + 72)

				lineTr.start.z = topZ
				lineTr.endpos.z = topZ - 72
				local downRes = util.TraceLine(lineTr)
				if downRes.Hit and downRes.HitNormal.z >= 0.7 then
					local pos = downRes.HitPos
					local dx, dy = pos.x - hmdX, pos.y - hmdY
					if dx * dx + dy * dy >= vaultMinSq then
						hullTr.start.x, hullTr.start.y, hullTr.start.z = pos.x, pos.y, pos.z + 1
						hullTr.endpos.x, hullTr.endpos.y, hullTr.endpos.z = pos.x, pos.y, pos.z + 2
						if not util.TraceHull(hullTr).Hit then
							return pos, downRes.HitNormal, downRes.MatType
						end
					end
				end
			end
		end
		return nil
	end

	local function CreateMarker()
		if IsValid(ledgeMarker) then return end
		ledgeMarker = ClientsideModel("models/vrmod/tpbeam.mdl")
		ledgeMarker:SetRenderMode(RENDERMODE_TRANSCOLOR)
		ledgeMarker:SetColor(COLOR_LEDGE)
		ledgeMarker.RenderOverride = function(self)
			render.SuppressEngineLighting(true)
			self:SetupBones()
			self:SetBoneMatrix(0, markerMtx)
			for i = 1, self:GetBoneCount() - 1 do
				self:SetBoneMatrix(i, zeroMtx)
			end
			self:DrawModel()
			render.SetColorModulation(1, 1, 1)
			render.SuppressEngineLighting(false)
		end
	end

	local function RemoveMarker()
		if IsValid(ledgeMarker) then ledgeMarker:Remove() end
		ledgeMarker = nil
		ledgePos = nil
	end

	-- send current position to server for entity sync
	local function SyncPosToServer()
		net.Start("vrmod_brushclimb_sync")
		net.WriteVector(g_VR.origin)
		net.SendToServer()
	end

	-- release all hands and begin drop/vault lerp
	local function BeginRelease(vaultPos, launchVel, matType)
		RemoveMarker()

		local dropPos
		if vaultPos then
			dropPos = vaultPos
			lerpTarget = vaultPos
			lerpSpeed = VAULT_SPEED
			-- Snapshot the end origin: offset so HMD lands at vaultPos
			local hmdPos = g_VR.tracking.hmd.pos
			local origin = g_VR.origin
			lerpEndOrigin = Vector(
				origin.x + (vaultPos.x - hmdPos.x),
				origin.y + (vaultPos.y - hmdPos.y),
				vaultPos.z
			)
			PlayVaultSound(vaultPos, matType or 0)
			launchVel = nil -- no momentum on vault
		else
			dropPos = g_VR.tracking.hmd.pos + Angle(0, g_VR.tracking.hmd.ang.yaw, 0):Forward() * -10
			dropPos.z = g_VR.origin.z
			-- Predict the server's decision so the sound fires exactly when a
			-- throw actually registers, using the same replicated numbers.
			if launchVel then
				local scaled = launchVel:Length() * sv_throw:GetFloat()
				local cap = sv_throwmax:GetFloat()
				if scaled > cap then scaled = cap end
				if scaled >= sv_throwmin:GetFloat() and scaled > 0 then PlayYeetSound(dropPos) end
			end
		end

		net.Start("vrmod_brushclimb_state")
		net.WriteBool(false)
		net.WriteVector(dropPos)
		net.WriteVector(launchVel or Vector(0, 0, 0))
		net.SendToServer()

		refHand = nil
		releaseTime = SysTime()
		for i = 1, 2 do
			hands[i].grabPos = nil
			hands[i].wallNormal = nil
			hands[i].worldAnchor = nil
		end
		vrmod.climbing.gripLeft = false
		vrmod.climbing.gripRight = false
		vrmod.climbing.wallLeft = false
		vrmod.climbing.wallRight = false

		if vaultPos then
			-- vault: animate the play space up onto the ledge (lerp handled in OnPreRender)
			lerpOrigin = Vector(g_VR.origin.x, g_VR.origin.y, g_VR.origin.z)
			lerpTime = SysTime()
		else
			-- Plain release: hand straight to normal locomotion from the current origin. Lerping toward
			-- the live player entity made the origin chase the engine unsticking the capsule from the
			-- wall, which read as a backward-then-forward jolt. Gravity/momentum carry the player now.
			lerpOrigin = nil
			lerpTarget = nil
			lerpEndOrigin = nil
			lerpSpeed = LERP_SPEED
			hook.Remove("PreRender", "brushclimb")
			vrmod.StartLocomotion()
		end
	end

	local function OnPreRender()
		local now = SysTime()
		local origin = g_VR.origin

		if refHand then
			local h1, h2 = hands[1], hands[2]
			local bothGrabbed = h1.worldAnchor and h2.worldAnchor
			local desiredX, desiredY, desiredZ

			if bothGrabbed then
				local lp1 = g_VR.tracking[h1.poseName].pos
				local lp2 = g_VR.tracking[h2.poseName].pos
				local ox = origin.x
				local oy = origin.y
				local oz = origin.z
				local o1x = h1.worldAnchor.x - (lp1.x - ox)
				local o1y = h1.worldAnchor.y - (lp1.y - oy)
				local o1z = h1.worldAnchor.z - (lp1.z - oz)
				local o2x = h2.worldAnchor.x - (lp2.x - ox)
				local o2y = h2.worldAnchor.y - (lp2.y - oy)
				local o2z = h2.worldAnchor.z - (lp2.z - oz)
				desiredX = (o1x + o2x) * 0.5
				desiredY = (o1y + o2y) * 0.5
				desiredZ = (o1z + o2z) * 0.5
			else
				local h = hands[refHand]
				local hp = g_VR.tracking[h.poseName].pos
				desiredX = h.worldAnchor.x - (hp.x - origin.x)
				desiredY = h.worldAnchor.y - (hp.y - origin.y)
				desiredZ = h.worldAnchor.z - (hp.z - origin.z)
			end

			-- hull collision: slide along surfaces
			local ply = LocalPlayer()
			hullTr.filter = ply
			hullTr.start.x, hullTr.start.y, hullTr.start.z = origin.x, origin.y, origin.z
			hullTr.endpos.x, hullTr.endpos.y, hullTr.endpos.z = desiredX, desiredY, desiredZ
			local res = util.TraceHull(hullTr)
			if res.Fraction < 1 and res.HitWorld then
				local n = res.HitNormal
				local hpx, hpy, hpz = res.HitPos.x, res.HitPos.y, res.HitPos.z
				local into = (desiredX - hpx) * n.x + (desiredY - hpy) * n.y + (desiredZ - hpz) * n.z
				if into < 0 then
					local slidX = desiredX - n.x * into
					local slidY = desiredY - n.y * into
					local slidZ = desiredZ - n.z * into
					-- verify the slid position is actually clear
					hullTr.start.x, hullTr.start.y, hullTr.start.z = origin.x, origin.y, origin.z
					hullTr.endpos.x, hullTr.endpos.y, hullTr.endpos.z = slidX, slidY, slidZ
					local verify = util.TraceHull(hullTr)
					if verify.Fraction >= 0.99 then
						desiredX, desiredY, desiredZ = slidX, slidY, slidZ
					else
						-- slide still blocked, use the safe fraction position
						desiredX = origin.x + (slidX - origin.x) * verify.Fraction
						desiredY = origin.y + (slidY - origin.y) * verify.Fraction
						desiredZ = origin.z + (slidZ - origin.z) * verify.Fraction
					end
				else
					-- moving away from wall, use fraction-safe position
					desiredX = origin.x + (desiredX - origin.x) * res.Fraction
					desiredY = origin.y + (desiredY - origin.y) * res.Fraction
					desiredZ = origin.z + (desiredZ - origin.z) * res.Fraction
				end
			end

			-- apply position — write to current g_VR.origin, surviving reassignment
			origin = g_VR.origin
			local s = cv_smooth:GetFloat()
			if s > 0 then
				local k = 1 - s
				origin.x = origin.x + (desiredX - origin.x) * k
				origin.y = origin.y + (desiredY - origin.y) * k
				origin.z = origin.z + (desiredZ - origin.z) * k
			else
				origin.x, origin.y, origin.z = desiredX, desiredY, desiredZ
			end

			-- track velocity for momentum throw (use actual origin, post-collision)
			local dt = now - lastFrameTime
			if dt > 0 and dt < 0.1 then
				local blend = 0.3
				local nvx = (origin.x - prevOriginX) / dt
				local nvy = (origin.y - prevOriginY) / dt
				local nvz = (origin.z - prevOriginZ) / dt
				velocityX = velocityX + (nvx - velocityX) * blend
				velocityY = velocityY + (nvy - velocityY) * blend
				velocityZ = velocityZ + (nvz - velocityZ) * blend
			end
			prevOriginX, prevOriginY, prevOriginZ = origin.x, origin.y, origin.z
			lastFrameTime = now

			-- keep player entity in sync for body/shadow rendering
			_tmpAng.p, _tmpAng.y, _tmpAng.r = 0, g_VR.tracking.hmd.ang.yaw, 0
			local fwd = _tmpAng:Forward()
			local hmdPos = g_VR.tracking.hmd.pos
			_tmpVec.x = hmdPos.x - fwd.x * 10
			_tmpVec.y = hmdPos.y - fwd.y * 10
			_tmpVec.z = desiredZ
			ply:SetPos(_tmpVec)

			-- periodic server sync so other clients see us move
			if now >= nextSyncTime then
				nextSyncTime = now + SYNC_INTERVAL
				SyncPosToServer()
			end

			-- stick forward = vault to ledge
			if ledgePos and g_VR.input and g_VR.input.vector2_walkdirection then
				if g_VR.input.vector2_walkdirection.y > VAULT_STICK_THRESHOLD then
					BeginRelease(ledgePos, nil, ledgeMat)
					return
				end
			end

			-- throttled ledge scan
			if now >= nextLedgeScan then
				nextLedgeScan = now + LEDGE_SCAN_RATE
				local pos, normal, mat = ScanForLedge()
				if pos then
					ledgePos = pos
					ledgeMat = mat or 0
					if cv_marker:GetBool() then
						CreateMarker()
						ledgeMarker:SetColor(COLOR_LEDGE)
						markerMtx:Identity()
						markerMtx:Translate(pos + normal)
						markerMtx:Rotate(normal:Angle() + Angle(90, 0, 90))
						ledgeMarker:SetPos(pos)
					else
						RemoveMarker()
						ledgePos = pos
					end
				else
					ledgePos = nil
					if IsValid(ledgeMarker) then
						ledgeMarker:SetColor(COLOR_HIDDEN)
					end
				end
			end
		elseif lerpOrigin then
			-- Vault animation: ease the play space onto the ledge (fixed snapshot target)
			origin = g_VR.origin
			local dt = math.min((now - lerpTime) * lerpSpeed, 1)
			origin.x = lerpOrigin.x + (lerpEndOrigin.x - lerpOrigin.x) * dt
			origin.y = lerpOrigin.y + (lerpEndOrigin.y - lerpOrigin.y) * dt
			origin.z = lerpOrigin.z + (lerpEndOrigin.z - lerpOrigin.z) * dt
			if dt >= 1 then
				origin.z = LocalPlayer():GetPos().z
				lerpOrigin = nil
				lerpTarget = nil
				lerpEndOrigin = nil
				lerpSpeed = LERP_SPEED
				hook.Remove("PreRender", "brushclimb")
				vrmod.StartLocomotion()
			end
		end
	end

	local function OnInput(action, pressed)
		local info = INPUT_MAP[action]
		if not info then return end
		local hand, isGrip = info[1], info[2]

		if isGrip then gripHeld[hand] = pressed else triggerHeld[hand] = pressed end

		local effective = gripHeld[hand]
		if cv_requireboth:GetBool() then effective = effective and triggerHeld[hand] end

		if effective == handActive[hand] then return end
		handActive[hand] = effective

		local h = hands[hand]
		if effective then
			local pose = g_VR.tracking[h.poseName]
			local hitPos, hitNorm, matType = TraceForBrush(pose.pos, pose.ang)

			-- Collision fallback: hand was pushed away from wall, reuse the wall data collisions already found
			if not hitPos and vrmod._collisionShapeByHand then
				local shape = vrmod._collisionShapeByHand[hand == 1 and "left" or "right"]
				if shape and shape.isClipped and shape.hitNormal then
					local hp, hn = shape.pushOutPos, shape.hitNormal
					if not (cv_nofloor:GetBool() and hn.z >= 0.7) and PassesWhitelist(hp.x, hp.y, hp.z, hn.x, hn.y, nil) then
						hitPos = hp
						hitNorm = hn
					end
				end
			end

			if not hitPos then
				if hand == 1 then vrmod.climbing.wallLeft = false else vrmod.climbing.wallRight = false end
				return
			end
			if hand == 1 then vrmod.climbing.wallLeft = true else vrmod.climbing.wallRight = true end
			PlayGrabSound(hitPos, matType or 0)

			h.grabPos = Vector(hitPos.x, hitPos.y, hitPos.z)
			h.wallNormal = Vector(hitNorm.x, hitNorm.y, hitNorm.z)

			-- Anchor at the hand's current world pos so grabbing never teleports the player.
			-- (worldAnchor drives movement only; the wall point lives in grabPos for ledge scans.)
			h.worldAnchor = Vector(pose.pos.x, pose.pos.y, pose.pos.z)
			-- Re-anchor an already-gripped hand to its current pos so adding a second hand is seamless.
			local oh = hands[3 - hand]
			if oh.worldAnchor then
				local op = g_VR.tracking[oh.poseName].pos
				oh.worldAnchor.x, oh.worldAnchor.y, oh.worldAnchor.z = op.x, op.y, op.z
			end
			if hand == 1 then vrmod.climbing.gripLeft = true else vrmod.climbing.gripRight = true end

			refHand = hand

			if not hands[3 - hand].grabPos then
				-- starting a fresh climb (other hand not already holding): do the one-time setup here,
				-- so a hand-over-hand grab while still climbing stays cheap and stutter-free.
				vrmod.StopLocomotion()
				prevOriginX, prevOriginY, prevOriginZ = g_VR.origin.x, g_VR.origin.y, g_VR.origin.z
				velocityX, velocityY, velocityZ = 0, 0, 0
				lastFrameTime = SysTime()
				nextSyncTime = 0

				net.Start("vrmod_brushclimb_state")
				net.WriteBool(true)
				net.SendToServer()

				hook.Add("PreRender", "brushclimb", OnPreRender)
			end
		elseif h.grabPos then
			h.grabPos = nil
			h.wallNormal = nil
			h.worldAnchor = nil
			if hand == 1 then vrmod.climbing.gripLeft = false; vrmod.climbing.wallLeft = false
			else vrmod.climbing.gripRight = false; vrmod.climbing.wallRight = false end
			local other = 3 - hand
			if hands[other].grabPos then
				refHand = other
				-- re-anchor the remaining hand to its current pos so the handoff doesn't pop the origin
				local op = g_VR.tracking[hands[other].poseName].pos
				hands[other].worldAnchor.x, hands[other].worldAnchor.y, hands[other].worldAnchor.z = op.x, op.y, op.z
			else
				-- Raw measured velocity. Scaling, the minimum-throw threshold
				-- and the speed cap are all applied server-side.
				BeginRelease(nil, Vector(velocityX, velocityY, velocityZ))
			end
		end
	end

	-- Sync engine ladder suppression state to server
	local function SyncLadderSuppress()
		net.Start("vrmod_brushclimb_noladder")
		net.WriteBool(convars.vrmod_brushclimb:GetBool() and LadderWL())
		net.SendToServer()
	end

	local function EnableClimbing()
		hook.Add("VRMod_Input", "brushclimb", OnInput)
		-- The head anti-clip pushes g_VR.origin out of walls, which is the
		-- opposite of what a climb wants: a gripped hand deliberately holds you
		-- against a wall with your head inside the no-go zone, so the two argue
		-- over the origin every frame. Suppressed through VRMod_AllowHeadAntiClip
		-- rather than by touching vrmod_anticlip, so sh_hull zeroes its
		-- accumulated correction on the way out instead of snapping the view
		-- sideways when it resumes -- and the user's own toggle is left alone.
		--
		-- refHand is non-nil exactly while a hand is holding. The grace window
		-- after that covers the vault/drop lerp in OnPreRender, which is still
		-- driving the origin for a moment after the last hand lets go.
		hook.Add("VRMod_AllowHeadAntiClip", "brushclimb", function()
			if refHand then return false end
			if releaseTime >= 0 and SysTime() - releaseTime < cv_anticlipgrace:GetFloat() then return false end
		end)
		hook.Add("VRMod_Tracking", "brushclimb_walldetect", function()
			if not g_VR.tracking then return end
			local lp = g_VR.tracking.pose_lefthand
			local rp = g_VR.tracking.pose_righthand
			if lp then
				vrmod.climbing.wallLeft = TraceForBrush(lp.pos, lp.ang) ~= nil
			end
			if rp then
				vrmod.climbing.wallRight = TraceForBrush(rp.pos, rp.ang) ~= nil
			end
		end)
		-- suppress engine ladder climbing for client prediction
		hook.Add("SetupMove", "vrmod_brushclimb_ladder", function(ply)
			if ply == LocalPlayer() and LadderWL() and GetMoveType(ply) == MOVETYPE_LADDER then
				SetMoveType(ply, MOVETYPE_WALK)
			end
		end)
		SyncLadderSuppress()
	end

	local function DisableClimbing()
		vrmod.StartLocomotion()
		hook.Remove("VRMod_Input", "brushclimb")
		hook.Remove("VRMod_AllowHeadAntiClip", "brushclimb")
		hook.Remove("VRMod_Tracking", "brushclimb_walldetect")
		hook.Remove("PreRender", "brushclimb")
		hook.Remove("SetupMove", "vrmod_brushclimb_ladder")
		RemoveMarker()
		-- always clear ladder suppress on disable (VRMod_Exit leaves convar on)
		net.Start("vrmod_brushclimb_noladder")
		net.WriteBool(false)
		net.SendToServer()
		if refHand then
			net.Start("vrmod_brushclimb_state")
			net.WriteBool(false)
			net.WriteVector(LocalPlayer():GetPos())
			net.WriteVector(Vector(0, 0, 0))
			net.SendToServer()
		end
		refHand = nil
		releaseTime = -1
		lerpOrigin = nil
		lerpTarget = nil
		lerpEndOrigin = nil
		for i = 1, 2 do
			hands[i].grabPos = nil
			hands[i].wallNormal = nil
			hands[i].worldAnchor = nil
			gripHeld[i] = false
			triggerHeld[i] = false
			handActive[i] = false
		end
		vrmod.climbing.gripLeft = false
		vrmod.climbing.gripRight = false
		vrmod.climbing.wallLeft = false
		vrmod.climbing.wallRight = false
	end

	cvars.RemoveChangeCallback("vrmod_brushclimb", "vrmod_brushclimb")
	cvars.AddChangeCallback("vrmod_brushclimb", function(_, _, new)
		if not g_VR.active then return end
		if new == "1" then EnableClimbing() else DisableClimbing() end
	end, "vrmod_brushclimb")

	cvars.RemoveChangeCallback("vrmod_brushclimb_ladderonly", "vrmod_brushclimb_ladderonly")
	cvars.AddChangeCallback("vrmod_brushclimb_ladderonly", function()
		if g_VR.active and convars.vrmod_brushclimb:GetBool() then SyncLadderSuppress() end
	end, "vrmod_brushclimb_ladderonly")

	hook.Add("VRMod_Start", "brushclimb", function()
		if convars.vrmod_brushclimb:GetBool() then EnableClimbing() end
	end)
	hook.Add("VRMod_Exit", "brushclimb", function()
		if convars.vrmod_brushclimb:GetBool() then DisableClimbing() end
	end)

elseif SERVER then

	util.AddNetworkString("vrmod_brushclimb_state")
	util.AddNetworkString("vrmod_brushclimb_sync")
	util.AddNetworkString("vrmod_brushclimb_noladder")

	-- engine ladder suppression per player
	local suppressLadder = {}
	local laddersRemoved = false

	local function RemoveLadderEntities()
		if laddersRemoved then return end
		laddersRemoved = true
		for _, class in ipairs({"func_ladder", "func_useableladder"}) do
			for _, ent in ipairs(ents.FindByClass(class)) do ent:Remove() end
		end
		-- catch late-spawned ladder ents
		hook.Add("OnEntityCreated", "vrmod_brushclimb_ladder", function(ent)
			if not IsValid(ent) then return end
			local c = ent:GetClass()
			if c == "func_ladder" or c == "func_useableladder" then ent:Remove() end
		end)
	end

	-- Removing the brushes is map-wide and irreversible, so at least stop
	-- paying for (and stop applying) the per-entity removal hook once nobody
	-- is asking for suppression -- previously one VR player enabling ladder
	-- whitelist killed late-spawned ladders for everyone until map change.
	local function UpdateLadderSuppression()
		if next(suppressLadder) or sv_climbing_ladderonly:GetBool() then
			RemoveLadderEntities()
		elseif laddersRemoved then
			hook.Remove("OnEntityCreated", "vrmod_brushclimb_ladder")
			laddersRemoved = false
		end
	end

	vrmod.NetReceiveLimited("vrmod_brushclimb_noladder", 5, 32, function(_, ply)
		suppressLadder[ply] = net.ReadBool() or nil
		UpdateLadderSuppression()
	end)

	-- server convar forces ladder suppression for all players
	cvars.AddChangeCallback("vrmod_sv_climbing_ladderonly", function()
		UpdateLadderSuppression()
	end, "vrmod_sv_climbing_ladderonly")

	local function ShouldSuppressLadder(ply)
		return suppressLadder[ply] or sv_climbing_ladderonly:GetBool()
	end

	hook.Add("SetupMove", "vrmod_brushclimb_ladder", function(ply)
		if ShouldSuppressLadder(ply) and GetMoveType(ply) == MOVETYPE_LADDER then
			SetMoveType(ply, MOVETYPE_WALK)
		end
	end)

	hook.Add("PlayerUse", "vrmod_brushclimb_ladder", function(ply, ent)
		if ShouldSuppressLadder(ply) then
			local c = ent:GetClass()
			if c == "func_useableladder" or c == "func_ladder" then return false end
		end
	end)

	hook.Add("PlayerDisconnected", "vrmod_brushclimb_ladder", function(ply)
		suppressLadder[ply] = nil
		UpdateLadderSuppression()
	end)

	-- Both of these messages move the player, so neither can be taken on
	-- trust: the sync handler was an unconditional SetPos to any vector a
	-- client cared to send, and the release handler took an arbitrary position
	-- AND velocity. Bound both to a plausible step from where the server
	-- already thinks the player is, and reject NaN / out-of-world.
	local MAX_SYNC_STEP = 128    -- ~4x the fastest plausible climb step at 30Hz
	local MAX_RELEASE_STEP = 192 -- release point is head-relative, allow slack

	local function ValidPos(ply, pos, maxStep)
		if pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z then return false end
		if not util.IsInWorld(pos) then return false end
		return ply:GetPos():DistToSqr(pos) <= maxStep * maxStep
	end

	vrmod.NetReceiveLimited("vrmod_brushclimb_state", 10, 256, function(_, ply)
		if net.ReadBool() then
			SetMoveType(ply, MOVETYPE_NONE)
			ply:SetVelocity(-ply:GetVelocity())
			return
		end

		local pos = net.ReadVector()
		local vel = net.ReadVector()
		-- Let gravity settle the player from the release point. Previously a 64u down-trace
		-- snapped the player onto the nearest floor below, which teleported them on release.
		if ValidPos(ply, pos, MAX_RELEASE_STEP) then ply:SetPos(pos) end
		SetMoveType(ply, MOVETYPE_WALK)

		-- Authoritative throw: the client reports the raw velocity it measured,
		-- the server decides what that is worth.
		local speed = vel:Length()
		if speed ~= speed or speed <= 0 then return end
		speed = speed * sv_throw:GetFloat()
		local cap = sv_throwmax:GetFloat()
		if speed > cap then speed = cap end
		if speed < sv_throwmin:GetFloat() then return end
		vel:Normalize()
		vel:Mul(speed)
		ply:SetVelocity(vel)
	end)

	vrmod.NetReceiveLimited("vrmod_brushclimb_sync", 45, 128, function(_, ply)
		if GetMoveType(ply) ~= MOVETYPE_NONE then return end
		local pos = net.ReadVector()
		if ValidPos(ply, pos, MAX_SYNC_STEP) then ply:SetPos(pos) end
	end)
end