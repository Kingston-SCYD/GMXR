--[[
	sh_trackers.lua
	Unified tracker registry for VRMod x64-exper2.

	One list of tracker slots, whatever the source. XR trackers arrive through
	the HTCX role paths declared in cl_input.lua; external trackers (SlimeVR via
	VRChat OSC, or any VMC device) arrive through the module's UDP receiver.
	The module links both into the table VRMOD_GetPoses returns, so
	UpdateTracking converts them to world space identically and nothing
	downstream needs to know which is which.

	Every slot carries a user-assigned role, set in Client > Trackers:
	  auto       eligible for FBT proximity matching at calibration (default)
	  pelvis     pinned to that FBT slot, skips matching
	  leftfoot
	  rightfoot
	  object     excluded from FBT, addressable by label (cameras, props)
	  off        ignored entirely

	Defaulting to "auto" is what makes a fresh tracker work for 6-point without
	anyone opening the menu -- calibration decides which of the auto trackers is
	the waist and which are the feet by measuring, not by trusting whatever role
	SteamVR or SlimeVR happened to assign.

	The resolved FBT slots live in g_VR.fbtPose as { pelvis, leftfoot,
	rightfoot }, refreshed on rescan. sh_character_fbt.lua reads that instead of
	g_VR.tracking.pose_waist and friends, so a rig made of OSC trackers drives
	the body exactly like a rig made of Vive pucks. When nothing is configured
	the three HTCX role poses are used as-is, so an existing 3-puck setup keeps
	working with no menu interaction at all.

	Roles, labels and the calibration assignment are persisted to
	data/vrmod/trackers.json, so they survive a session restart and a tracker
	being power-cycled.
]]
if SERVER then return end

g_VR = g_VR or {}
vrmod = vrmod or {}

local TrackerStart    = vrmod.TrackerStart    or VRMOD_TrackerStart
local TrackerStop     = vrmod.TrackerStop     or VRMOD_TrackerStop
local TrackerPoll     = vrmod.TrackerPoll     or VRMOD_TrackerPoll
local TrackerGetPoses = vrmod.TrackerGetPoses or VRMOD_TrackerGetPoses
local TrackerActive   = vrmod.TrackerActive   or VRMOD_TrackerActive

local SAVE_DIR  = "vrmod"
local SAVE_FILE = "vrmod/trackers.json"
local RESCAN_INTERVAL = 0.5

local VALID_ROLES = {
	auto = true, pelvis = true, leftfoot = true, rightfoot = true,
	object = true, off = true,
}

-- FBT slots, the boneids key each is measured against, and the g_VR.tracking
-- key used as a fallback when nothing has been assigned.
local FBT_SLOTS   = { "pelvis", "leftfoot", "rightfoot" }
local FBT_BONEKEY = { pelvis = "pelvis", leftfoot = "leftFoot", rightfoot = "rightFoot" }
local FBT_LEGACY  = { pelvis = "pose_waist", leftfoot = "pose_leftfoot", rightfoot = "pose_rightfoot" }

-- ─────────────────────────────────────────────────────────────────────────────
-- Convars
-- ─────────────────────────────────────────────────────────────────────────────

-- 9001, not 9000: the face-tracking receiver already binds 9000 by default, and
-- two UDP binds on one port means whichever starts second silently gets
-- nothing. Set SlimeVR's OSC output port to match this.
vrmod.AddCallbackedConvar("vrmod_trackers_osc", "trackersOsc", "0", FCVAR_ARCHIVE,
	"Receive external trackers (SlimeVR / VMC) over OSC", nil, nil, tobool)
vrmod.AddCallbackedConvar("vrmod_trackers_oscport", "trackersOscPort", "9001", FCVAR_ARCHIVE,
	"UDP port for the external tracker receiver", 1024, 65535, tonumber)
vrmod.AddCallbackedConvar("vrmod_trackers_calradius", "trackersCalRadius", "12", FCVAR_ARCHIVE,
	"Max distance in units from a bone to accept a tracker during FBT calibration", 1, 48, tonumber)
vrmod.AddCallbackedConvar("vrmod_trackers_debug", "trackersDebug", "0", FCVAR_ARCHIVE,
	"Draw a cube at every tracker position", nil, nil, tobool)
vrmod.AddCallbackedConvar("vrmod_trackers_debuglabels", "trackersDebugLabels", "1", FCVAR_ARCHIVE,
	"Also draw each tracker's label and role next to its cube", nil, nil, tobool)
-- Outside VR the playspace has no defined orientation relative to the world, so
-- there is no right answer here. Off (default) leaves the playspace world-
-- aligned: point a tracked camera left and it stays pointing left no matter
-- where you look. On rotates the playspace with your eye yaw, which is what you
-- want if the tracker is meant to sit "in front of you" as you turn.
vrmod.AddCallbackedConvar("vrmod_trackers_deskfollowyaw", "trackersDeskFollowYaw", "0", FCVAR_ARCHIVE,
	"Outside VR, rotate the tracker playspace with the player's eye yaw", nil, nil, tobool)

local cv = select(2, vrmod.GetConvars())

-- ─────────────────────────────────────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────────────────────────────────────

-- slots[id] = { id, key, source, role, label, trackingKey, pose, raw }
--   pose  live reference into g_VR.tracking -- world space pos/ang/vel/angvel
--   raw   live reference into the module's own table -- carries .active
-- Both are references, never copies, so reading a tracker is one table index
-- and the per-frame cost here is the poll alone.
local slots = {}
local order = {}          -- array view, rebuilt only on rescan
local labelIndex = {}     -- lowercase label -> slot
local savedTrackers = {}  -- id -> { role, label }
local fbtAssign = {}      -- fbt slot -> tracker id, written by calibration
local nextRescan = 0
local lastOscCount = -1
local oscRunning = false

-- Resolved FBT poses, read every frame by sh_character_fbt.lua. Allocated once
-- and mutated in place so the hot path is three table indexes.
g_VR.fbtPose = g_VR.fbtPose or {}
local fbtPose = g_VR.fbtPose

local function Save()
	if not file.Exists(SAVE_DIR, "DATA") then file.CreateDir(SAVE_DIR) end
	file.Write(SAVE_FILE, util.TableToJSON({ trackers = savedTrackers, fbt = fbtAssign }, true))
end

local function Load()
	local raw = file.Read(SAVE_FILE, "DATA")
	local t = raw and util.JSONToTable(raw)
	if type(t) ~= "table" then return end
	savedTrackers = type(t.trackers) == "table" and t.trackers or {}
	fbtAssign     = type(t.fbt) == "table" and t.fbt or {}
end

Load()

-- ─────────────────────────────────────────────────────────────────────────────
-- Discovery
-- ─────────────────────────────────────────────────────────────────────────────

local function AddSlot(id, key, source, trackingKey)
	local s = slots[id]
	if s then
		s.trackingKey = trackingKey
		return s
	end
	local rec = savedTrackers[id]
	s = {
		id          = id,
		key         = key,
		source      = source,
		trackingKey = trackingKey,
		role        = rec and VALID_ROLES[rec.role] and rec.role or "auto",
		label       = rec and rec.label or key,
	}
	slots[id] = s
	return s
end

--- True when a slot is currently reporting a usable pose. OSC trackers carry an
--- explicit staleness flag from the module; XR trackers are only linked into
--- the pose table once the runtime reports them active.
local function IsLive(s)
	local p = s.pose
	if not p or not p.pos then return false end
	local r = s.raw
	return r == nil or r.active ~= false
end

-- Rebuilds the slot list and re-resolves the FBT slots. Runs at most twice a
-- second; the per-frame path below never iterates a hash table.
local function Rescan()
	local tracking = g_VR.tracking or {}

	for i = #order, 1, -1 do order[i] = nil end
	for k in pairs(labelIndex) do labelIndex[k] = nil end

	-- XR trackers: the HTCX pose actions declared in cl_input.lua. Only roles
	-- the runtime has actually reported ever appear in the tracking table, so
	-- presence of the key is the availability test.
	local roleActions = vrmod.GetTrackerRoleActions and vrmod.GetTrackerRoleActions()
	if roleActions then
		for i = 1, #roleActions do
			local actionName, roleName = roleActions[i][1], roleActions[i][2]
			local pose = tracking[actionName]
			if pose then
				local s = AddSlot("xr:" .. roleName, roleName, "xr", actionName)
				s.pose, s.raw = pose, nil
				order[#order + 1] = s
			end
		end
	end

	-- External trackers. The module's own table is the source of truth for
	-- which ones exist and whether they are stale; g_VR.tracking holds the
	-- world-space conversion, and only after UpdateTracking has run once.
	local osc = TrackerGetPoses and TrackerGetPoses()
	if osc then
		for key, raw in pairs(osc) do
			local s = AddSlot("osc:" .. key, key, "osc", "pose_osc_" .. key)
			s.raw  = raw
			-- In VR the tracking loop owns the world-space conversion; outside
			-- it, ConvertDesktopPoses does, into s.deskPose.
			s.pose = tracking[s.trackingKey] or s.deskPose
			order[#order + 1] = s
		end
	end

	for i = 1, #order do
		local s = order[i]
		if s.label and s.label ~= "" then labelIndex[string.lower(s.label)] = s end
	end

	-- Resolve FBT slots, most specific source first:
	--   1. a role the user pinned by hand
	--   2. the assignment calibration measured
	--   3. the HTCX role poses, so an unconfigured 3-puck rig is unchanged
	fbtPose.pelvis, fbtPose.leftfoot, fbtPose.rightfoot = nil, nil, nil
	for i = 1, #order do
		local s = order[i]
		if FBT_BONEKEY[s.role] and not fbtPose[s.role] and IsLive(s) then
			fbtPose[s.role] = s.pose
		end
	end
	local n = 0
	for si = 1, #FBT_SLOTS do
		local slot = FBT_SLOTS[si]
		if not fbtPose[slot] then
			local s = slots[fbtAssign[slot]]
			if s and IsLive(s) then fbtPose[slot] = s.pose end
		end
		if not fbtPose[slot] then fbtPose[slot] = tracking[FBT_LEGACY[slot]] end
		if fbtPose[slot] then n = n + 1 end
	end
	-- Read by cl_vrmod.lua for g_VR.sixPoints: three resolved slots, whatever
	-- hardware they came from.
	g_VR.fbtTrackerCount = n
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Desktop world-space conversion
--
-- In VR, UpdateTracking converts every entry in the module's pose table to
-- world space and parks the result in g_VR.tracking. Outside VR that loop never
-- runs, g_VR.scale is still 0 and g_VR.tracking is empty -- so a tracker would
-- be discovered and listed but have no usable position. This does the same
-- conversion for any external tracker the tracking loop is not covering, which
-- is every one of them on the desktop and none of them in VR.
-- ─────────────────────────────────────────────────────────────────────────────

local cvScale
local deskOrigin, deskOriginAng = Vector(), Angle()

local function DesktopAnchor()
	local lp = LocalPlayer()
	if not IsValid(lp) then return nil end
	deskOrigin:Set(lp:GetPos())
	deskOriginAng:SetUnpacked(0, cv.trackersDeskFollowYaw and lp:EyeAngles().yaw or 0, 0)
	-- g_VR.scale is only assigned at VR start and sits at 0 before that, which
	-- would collapse every tracker onto the origin.
	local scale = g_VR.scale
	if not scale or scale <= 0 then
		cvScale = cvScale or GetConVar("vrmod_scale")
		scale = cvScale and cvScale:GetFloat() or 41.66914
	end
	return scale
end

local function ConvertDesktopPoses()
	if #order == 0 then return end
	local tracking = g_VR.tracking or {}
	local scale = DesktopAnchor()
	if not scale then return end
	local zeroYaw = deskOriginAng.y == 0

	for i = 1, #order do
		local s = order[i]
		local raw = s.raw
		-- Only external trackers, and only while the tracking loop is not
		-- already producing a world pose for them.
		if raw and not tracking[s.trackingKey] then
			local mtx = raw.pose
			if mtx then
				local dp = s.deskPose
				if not dp then
					dp = { pos = Vector(), ang = Angle(), vel = Vector(), angvel = Angle() }
					s.deskPose = dp
				end
				local p, a = mtx:GetTranslation(), mtx:GetAngles()
				if zeroYaw then
					-- Pure translation, matching the common case in
					-- UpdateTracking: no LocalToWorld, one less allocation.
					dp.pos:Set(p)
					dp.pos:Mul(scale)
					dp.pos:Add(deskOrigin)
					dp.ang:Set(a)
				else
					p:Mul(scale)
					local wp, wa = LocalToWorld(p, a, deskOrigin, deskOriginAng)
					dp.pos:Set(wp)
					dp.ang:Set(wa)
				end
				s.pose = dp
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Receiver lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

--- Drains the socket and refreshes every external tracker's matrix. Assigned to
--- g_VR.pollExternalTrackers only while the receiver is up, so UpdateTracking
--- pays one nil test per frame when this is off.
local function Poll()
	local n = TrackerPoll()
	-- A change in the live count is the only thing that can add or remove a
	-- slot, so it gates the rescan rather than relying on the timer alone.
	if n ~= lastOscCount then
		lastOscCount = n
		nextRescan = 0
	end
end

local function StartOsc()
	if oscRunning or not TrackerStart then return end
	local port = cv.trackersOscPort or 9001
	oscRunning = TrackerStart(port) and true or false
	if oscRunning then
		g_VR.pollExternalTrackers = Poll
		vrmod.logger.Info("[Trackers] OSC receiver listening on " .. port)
	else
		vrmod.logger.Warn("[Trackers] OSC receiver failed to bind port " .. port ..
			" (already in use? face tracking defaults to 9000)")
	end
end

local function StopOsc()
	if not oscRunning then return end
	if TrackerStop then TrackerStop() end
	oscRunning = false
	g_VR.pollExternalTrackers = nil
	for id, s in pairs(slots) do
		if s.source == "osc" then slots[id] = nil end
	end
	lastOscCount = -1
	nextRescan = 0
	Rescan()
end

-- In VR the poll runs inside UpdateTracking, immediately before VRMOD_GetPoses,
-- so a tracker's motion lands in the same snapshot the hands do rather than one
-- frame late. This hook only handles the rescan.
hook.Add("VRMod_Tracking", "vrmod_trackers", function()
	if cv.trackersOsc then
		if not oscRunning then StartOsc() end
	elseif oscRunning then
		StopOsc()
	end
	local t = RealTime()
	if t >= nextRescan then
		nextRescan = t + RESCAN_INTERVAL
		Rescan()
	end
end)

-- Out of VR there is no tracking loop, so this hook is the whole pipeline:
-- drain the socket, rebuild the slot list, convert to world space. Unthrottled
-- because a tracked object should follow at framerate, not at some arbitrary
-- fraction of it -- the poll is a non-blocking recv drain and the conversion
-- touches only external trackers, so both are no-ops for anyone who has none.
hook.Add("Think", "vrmod_trackers_idle", function()
	if g_VR.active then return end
	if cv.trackersOsc then
		if not oscRunning then StartOsc() end
		if oscRunning then Poll() end
	elseif oscRunning then
		StopOsc()
	end
	if not oscRunning then return end
	local t = RealTime()
	if t >= nextRescan then
		nextRescan = t + RESCAN_INTERVAL
		Rescan()
	end
	ConvertDesktopPoses()
end)

-- VRMod_Exit broadcasts to every client when any VR player leaves, so the guard
-- matters: without it another player quitting wipes this player's slots.
hook.Add("VRMod_Exit", "vrmod_trackers", function(ply)
	if ply ~= LocalPlayer() then return end
	g_VR.fbtTrackerCount = 0
	fbtPose.pelvis, fbtPose.leftfoot, fbtPose.rightfoot = nil, nil, nil
	-- The pose references point into g_VR.tracking, which is about to be
	-- emptied. External trackers keep working: the Think hook takes over and
	-- ConvertDesktopPoses repoints them at their own deskPose next frame.
	for _, s in pairs(slots) do s.pose = s.deskPose end
	nextRescan = 0
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

--- All discovered tracker slots. Live array; do not hold it across frames.
function vrmod.GetTrackers() return order end

function vrmod.GetTracker(id) return slots[id] end

function vrmod.IsTrackerLive(s) return s and IsLive(s) or false end

function vrmod.GetFBTCalRadius() return cv.trackersCalRadius or 12 end

--- Look a tracker up by the label set in the menu. This is the handle an object
--- addon should hold: "camera" keeps working when the tracker is replaced,
--- re-paired, or lands on a different OSC index.
function vrmod.GetTrackerByLabel(label)
	return label and labelIndex[string.lower(label)] or nil
end

--- pos, ang, vel, angvel for a labelled tracker, or nil when it is not
--- currently reporting.
function vrmod.GetTrackerPose(label)
	local s = labelIndex[string.lower(label or "")]
	if not s or not IsLive(s) then return end
	local p = s.pose
	return p.pos, p.ang, p.vel, p.angvel
end

--- Position and rotation in the module's own frame, live whether or not VR is
--- running.
---
--- GetTrackerPose reads g_VR.tracking, which UpdateTracking only fills inside
--- the VR render loop -- so it returns nil on the desktop even while the OSC
--- receiver is happily taking packets. This reads the module's matrix directly
--- instead, so a tracker can drive something with no headset involved at all.
---
--- The frame is the playspace, not the world, and it is not the same frame
--- GetTrackerPose reports in. Position is in metres and is unscaled; both
--- frames are gravity aligned, so a consumer that calibrates against a
--- reference only has to solve for yaw. Nothing here is world space.
---
--- Bear in mind an IMU tracker has no measured position at all -- SlimeVR
--- derives one from a body model anchored to the headset. Treat the position
--- as advisory unless the source is a lighthouse or inside-out tracker.
function vrmod.GetTrackerPoseRaw(label)
	local s = labelIndex[string.lower(label or "")]
	if not s then return end
	local raw = s.raw
	if not raw or raw.active == false or not raw.pose then return end
	local m = raw.pose
	return m:GetTranslation(), m:GetAngles()
end

--- Rotation only, as above. Kept because most consumers of an IMU tracker want
--- exactly this and nothing else.
function vrmod.GetTrackerAngleRaw(label)
	local _, a = vrmod.GetTrackerPoseRaw(label)
	return a
end

function vrmod.SetTrackerRole(id, role, label)
	local s = slots[id]
	if not s or not VALID_ROLES[role] then return false end
	s.role = role
	if label ~= nil then s.label = label end
	local rec = savedTrackers[id] or {}
	rec.role, rec.label = s.role, s.label
	savedTrackers[id] = rec
	Save()
	nextRescan = 0
	return true
end

function vrmod.TrackerReceiverActive()
	return oscRunning and TrackerActive and TrackerActive() or false
end

--- Which tracker each FBT slot is currently resolved to, for the menu.
function vrmod.GetFBTAssignment() return fbtAssign end

function vrmod.ClearFBTAssignment()
	fbtAssign = {}
	Save()
	nextRescan = 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FBT matching
-- ─────────────────────────────────────────────────────────────────────────────

local cand = {}
local function ByDist(a, b) return a.d < b.d end

--- Assigns trackers to the three FBT slots by measuring against the calibration
--- model's bones. Explicit pins win; everything left on "auto" is matched by
--- proximity, nearest pair first, one tracker per slot.
---
--- mdl      clientside calibration model, already SetupBones()
--- boneids  the boneids table from vrmod_fbt.characterInfo
--- radius   max accepted distance in units (nil = vrmod_trackers_calradius)
--- commit   persist the result and re-resolve g_VR.fbtPose. The calibration
---          preview calls this repeatedly without committing, and commits once
---          on confirm, so what gets saved is exactly what was on screen.
---
--- Returns a table of g_VR.tracking pose tables keyed by FBT slot with
--- unmatched slots left nil, plus how many slots were filled.
function vrmod.MatchFBTTrackers(mdl, boneids, radius, commit)
	radius = radius or cv.trackersCalRadius or 12
	local r2 = radius * radius
	local out, filled = {}, 0

	Rescan()

	-- Pins first: they take both the slot and the tracker out of the pool, so a
	-- pinned waist can never also be claimed as a foot.
	local pool, np = {}, 0
	for i = 1, #order do
		local s = order[i]
		if IsLive(s) then
			if s.role == "auto" then
				np = np + 1
				pool[np] = s
			elseif FBT_BONEKEY[s.role] and not out[s.role] then
				out[s.role] = s
				filled = filled + 1
			end
		end
	end

	local nc = 0
	for si = 1, #FBT_SLOTS do
		local slot = FBT_SLOTS[si]
		if not out[slot] then
			local bone = boneids[FBT_BONEKEY[slot]]
			local mtx = bone and bone >= 0 and mdl:GetBoneMatrix(bone)
			if mtx then
				local bpos = mtx:GetTranslation()
				for i = 1, np do
					local d = bpos:DistToSqr(pool[i].pose.pos)
					if d <= r2 then
						nc = nc + 1
						local c = cand[nc]
						if c then c.s, c.i, c.d = slot, i, d
						else cand[nc] = { s = slot, i = i, d = d } end
					end
				end
			end
		end
	end

	if nc > 0 then
		-- table.sort over the reused array would see stale tail entries, so
		-- slice to the live length first. Runs a few times a second at most.
		local list = {}
		for i = 1, nc do list[i] = cand[i] end
		table.sort(list, ByDist)
		local usedT = {}
		for k = 1, nc do
			local c = list[k]
			if not out[c.s] and not usedT[c.i] then
				usedT[c.i] = true
				out[c.s] = pool[c.i]
				filled = filled + 1
			end
		end
	end

	-- Feet swap when the player calibrates with ankles close together, and the
	-- result is a body that walks with its legs crossed. Model +Y is the
	-- character's left, so the left foot must have the greater local Y.
	local lf, rf = out.leftfoot, out.rightfoot
	if lf and rf then
		local mpos, mang = mdl:GetPos(), mdl:GetAngles()
		if WorldToLocal(lf.pose.pos, angle_zero, mpos, mang).y
		 < WorldToLocal(rf.pose.pos, angle_zero, mpos, mang).y then
			out.leftfoot, out.rightfoot = rf, lf
		end
	end

	if commit and filled == #FBT_SLOTS then
		for si = 1, #FBT_SLOTS do
			local slot = FBT_SLOTS[si]
			fbtAssign[slot] = out[slot].id
		end
		Save()
		nextRescan = 0
		Rescan()
	end

	-- Hand back pose tables, which is what callers actually consume.
	local poses = {}
	for si = 1, #FBT_SLOTS do
		local slot = FBT_SLOTS[si]
		if out[slot] then poses[slot] = out[slot].pose end
	end
	poses.slots = out
	return poses, filled
end

--- Every FBT-eligible tracker that did not get a slot, so the calibration
--- preview can draw them differently instead of failing silently.
function vrmod.GetUnmatchedFBTTrackers(matched, outTbl)
	local out = outTbl or {}
	for i = #out, 1, -1 do out[i] = nil end
	local m = matched and matched.slots
	for i = 1, #order do
		local s = order[i]
		if IsLive(s) and s.role ~= "object" and s.role ~= "off" then
			if not m or (s ~= m.pelvis and s ~= m.leftfoot and s ~= m.rightfoot) then
				out[#out + 1] = s
			end
		end
	end
	return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Debug overlay
-- ─────────────────────────────────────────────────────────────────────────────

-- Same 2-unit cube the FBT calibration preview uses, so the two read the same.
-- Drawn with the tracker's own angles plus a short forward line, because for an
-- object tracker on a camera "where is it" is only half the question.
local DBG_MIN, DBG_MAX = Vector(-1, -1, -1), Vector(1, 1, 1)
local DBG_FWD_LEN   = 6
local DBG_TEXT_DIST = 400 * 400   -- squared; text is unreadable past this anyway
local COL_LOCAL  = Color(255, 255, 255)
local COL_REMOTE = Color(120, 200, 255)
local COL_FWD    = Color(255, 180, 60)
local COL_TEXT   = Color(255, 255, 255)
local COL_TEXTBG = Color(0, 0, 0, 170)
local dbgEnd  = Vector()
local dbgText = Vector()
local dbgAng  = Angle()

local function DrawTrackerLabel(pos, text, eyePos, eyeAng)
	if pos:DistToSqr(eyePos) > DBG_TEXT_DIST then return end
	dbgText:SetUnpacked(pos.x, pos.y, pos.z + 3)
	dbgAng:SetUnpacked(eyeAng.p, eyeAng.y, eyeAng.r)
	dbgAng:RotateAroundAxis(dbgAng:Forward(), 90)
	dbgAng:RotateAroundAxis(dbgAng:Right(), 90)
	cam.Start3D2D(dbgText, dbgAng, 0.06)
	draw.SimpleTextOutlined(text, "DermaDefault", 0, 0, COL_TEXT,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, COL_TEXTBG)
	cam.End3D2D()
end

local function DrawTrackerCube(pos, ang, col)
	render.DrawBox(pos, ang, DBG_MIN, DBG_MAX, col)
	dbgEnd:Set(ang:Forward())
	dbgEnd:Mul(DBG_FWD_LEN)
	dbgEnd:Add(pos)
	render.DrawLine(pos, dbgEnd, COL_FWD, true)
end

local function DrawTrackerDebug(depth, sky)
	if depth or sky then return end
	local labels = cv.trackersDebugLabels
	local eyePos, eyeAng = EyePos(), EyeAngles()
	render.SetColorMaterial()

	for i = 1, #order do
		local s = order[i]
		if IsLive(s) then
			local p = s.pose
			DrawTrackerCube(p.pos, p.ang, COL_LOCAL)
			if labels then
				DrawTrackerLabel(p.pos, s.label .. "  [" .. s.role .. "]", eyePos, eyeAng)
			end
		end
	end

	-- Remote object trackers, relayed by sh_network.lua. Different colour so a
	-- multiplayer session doesn't turn into a field of identical white cubes.
	if not vrmod.GetPlayerTrackerPose or not g_VR.net then return end
	local lp = LocalPlayer()
	for sid, tab in pairs(g_VR.net) do
		local names = tab.trackerLabels
		if names then
			local ply = tab._ply
			if IsValid(ply) and ply ~= lp then
				for n = 1, #names do
					local pos, ang = vrmod.GetPlayerTrackerPose(ply, names[n])
					if pos then
						DrawTrackerCube(pos, ang, COL_REMOTE)
						if labels then
							DrawTrackerLabel(pos, ply:Nick() .. ": " .. names[n], eyePos, eyeAng)
						end
					end
				end
			end
		end
	end
end

-- Hook is added and removed with the convar rather than left in place with an
-- early return, so this costs literally nothing while it is off.
local function ApplyTrackerDebug()
	if cv.trackersDebug then
		hook.Add("PostDrawTranslucentRenderables", "vrmod_trackers_debug", DrawTrackerDebug)
	else
		hook.Remove("PostDrawTranslucentRenderables", "vrmod_trackers_debug")
	end
end

cvars.AddChangeCallback("vrmod_trackers_debug", function()
	-- The callbacked convar updates cv on its own callback; defer a frame so
	-- the order between the two does not matter.
	timer.Simple(0, ApplyTrackerDebug)
end, "vrmod_trackers_debug_toggle")

ApplyTrackerDebug()

-- ─────────────────────────────────────────────────────────────────────────────
-- Debug
-- ─────────────────────────────────────────────────────────────────────────────

concommand.Add("vrmod_trackers_list", function()
	Rescan()
	if #order == 0 then
		print("[Trackers] none detected (receiver " ..
			(vrmod.TrackerReceiverActive() and "up" or "down") .. ")")
		return
	end
	print(string.format("%-22s %-7s %-10s %-14s %s", "id", "source", "role", "label", "state"))
	for i = 1, #order do
		local s = order[i]
		local state = "no pose"
		if s.pose and s.pose.pos then
			local p = s.pose.pos
			state = IsLive(s) and string.format("%.1f %.1f %.1f", p.x, p.y, p.z) or "stale"
		elseif s.raw then
			state = s.raw.active and "waiting for tracking loop" or "stale"
		end
		print(string.format("%-22s %-7s %-10s %-14s %s", s.id, s.source, s.role, s.label, state))
	end
	print("FBT slots:")
	for si = 1, #FBT_SLOTS do
		local slot = FBT_SLOTS[si]
		print(string.format("  %-10s %s%s", slot,
			fbtAssign[slot] or "(unassigned)",
			fbtPose[slot] and "" or "  [not resolved]"))
	end
end)

concommand.Add("vrmod_trackers_clearfbt", function()
	vrmod.ClearFBTAssignment()
	print("[Trackers] FBT assignment cleared; recalibrate to reassign")
end)