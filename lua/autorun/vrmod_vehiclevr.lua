--[[
    vrmod_vehiclevr.lua -- physical vehicle entry for VRMod

    Grip to enter : squeezing a seat past vrmod_vehicle_gripamount puts you IN
                    it instead of trying to physics-grab it. The seat you get
                    is the one nearest the hand that gripped, so a multi-pod
                    build seats you where you actually reached.
    Sit to enter  : physically sitting down while stood on top of a seat drops
                    you into it; physically standing up gets you out again.
                    Reuses vrmod_sitheight, so it triggers at the same head
                    height that already switches the character to its sit pose.

    Place in: garrysmod/lua/autorun/
]]
if SERVER then
    util.AddNetworkString("vrmod_vehicle_enter")
    util.AddNetworkString("vrmod_vehicle_exit")
    -- The client picks the seat, so the server re-checks reach itself rather
    -- than trusting it. Generous enough for a hand stretched over a car roof.
    local MAX_REACH_SQR = 200 * 200
    local COOLDOWN = 0.25
    local nextAct = {}

    local function Gate(ply)
        if not IsValid(ply) or not ply:Alive() then return false end
        local t = CurTime()
        if (nextAct[ply] or 0) > t then return false end
        nextAct[ply] = t + COOLDOWN
        return true
    end

    net.Receive("vrmod_vehicle_enter", function(_, ply)
        local veh = net.ReadEntity()
        if not Gate(ply) then return end
        if not IsValid(veh) or not veh:IsVehicle() then return end
        if ply:InVehicle() or IsValid(veh:GetDriver()) then return end
        if ply:GetPos():DistToSqr(veh:GetPos()) > MAX_REACH_SQR then return end
        -- EnterVehicle runs CanPlayerEnterVehicle itself, so gamemode and addon
        -- restrictions still apply -- no need to duplicate the check here.
        ply:EnterVehicle(veh)
    end)

    net.Receive("vrmod_vehicle_exit", function(_, ply)
        if not Gate(ply) then return end
        if not ply:InVehicle() then return end
        ply:ExitVehicle()
    end)

    hook.Add("PlayerDisconnected", "vrmod_vehiclevr", function(ply) nextAct[ply] = nil end)
    return
end

local LocalPlayer, IsValid, CurTime, tonumber = LocalPlayer, IsValid, CurTime, tonumber
local FindInSphere = ents.FindInSphere
local cv_grip = CreateClientConVar("vrmod_vehicle_gripenter", "1", true, false, "Grip a seat to get into it instead of grabbing it", 0, 1)
local cv_gripamt = CreateClientConVar("vrmod_vehicle_gripamount", "75", true, false, "How far the grip must close, in percent, before it seats you", 5, 100)
local cv_sit = CreateClientConVar("vrmod_vehicle_sitenter", "1", true, false, "Physically sitting down on top of a seat puts you in it", 0, 1)
local cv_stand = CreateClientConVar("vrmod_vehicle_sitexit", "1", true, false, "Physically standing up gets you out of a seat", 0, 1)
local cv_dist = CreateClientConVar("vrmod_vehicle_gripdist", "20", true, false, "How close a hand must be to a seat's surface to grip into it")
-- Resolved lazily: these belong to VRMod proper and may not exist yet at
-- autorun time.
local cvSitH, cvSeated

local function SitHeight()
    cvSitH = cvSitH or GetConVar("vrmod_sitheight")
    return cvSitH and cvSitH:GetFloat() or 0
end

local function SeatedMode()
    cvSeated = cvSeated or GetConVar("vrmod_seated")
    return cvSeated and cvSeated:GetBool() or false
end

-- Nearest sittable thing to a hand. NearestPoint rather than the origin so you
-- can grab the seat body or a car panel, not just the entity's centre.
local function SeatNearHand(pos)
    if not pos then return end
    local d = cv_dist:GetFloat()
    local best, bestSqr = nil, d * d
    local list = FindInSphere(pos, 96)
    for i = 1, #list do
        local e = list[i]
        if e:IsVehicle() then
            local dsqr = e:NearestPoint(pos):DistToSqr(pos)
            if dsqr < bestSqr then
                best, bestSqr = e, dsqr
            end
        end
    end
    return best
end

-- The seat this hand could grip into right now, or nil.
local function SeatForHand(bLeft)
    if not cv_grip:GetBool() then return end
    local ply = LocalPlayer()
    if not IsValid(ply) or ply:InVehicle() or g_VR.menuFocus then return end
    -- Already holding something in that hand: this press is a drop, leave it.
    if IsValid(bLeft and g_VR.heldEntityLeft or g_VR.heldEntityRight) then return end
    local p = g_VR.tracking and g_VR.tracking[bLeft and "pose_lefthand" or "pose_righthand"]
    return SeatNearHand(p and p.pos)
end

local function EnterSeat(seat)
    if not IsValid(seat) then return false end
    if hook.Run("VRMod_VehicleEnter", LocalPlayer(), seat) == false then return false end
    net.Start("vrmod_vehicle_enter")
    net.WriteEntity(seat)
    net.SendToServer()
    return true
end

-- ---------------------------------------------------------------------------
-- Grip to enter
-- ---------------------------------------------------------------------------
-- The grab is suppressed as soon as a seat is in reach rather than at the
-- threshold: VRMod's boolean grip latches around half closed, so waiting would
-- let the physics grab fire before the squeeze ever got deep enough to seat
-- you. Blocking on proximity means a hand near a seat simply cannot grab it
-- while vrmod_vehicle_gripenter is on.
local pendingSeat

hook.Add("VRMod_AllowDefaultAction", "vrmod_vehiclevr_block", function(action)
    local bLeft
    if action == "boolean_left_pickup" then
        bLeft = true
    elseif action == "boolean_right_pickup" then
        bLeft = false
    else
        return
    end

    local seat = SeatForHand(bLeft)
    if not seat then return end
    pendingSeat = seat
    return false
end)

-- Analog squeeze, polled per frame. Fires once on the way past the threshold
-- and re-arms 10% below it, the same shape sh_dropweapon uses for its release.
local armedL, armedR = false, false

local function GripPoll(bLeft, armed, thresh)
    local inp = g_VR.input
    local grip = inp and tonumber(bLeft and inp.vector1_left_squeeze or inp.vector1_right_squeeze)
    -- No analog data on this controller: the boolean hook below covers it.
    if not grip then return false end
    if armed then return grip >= thresh - 0.1 end
    if grip < thresh then return false end
    local seat = pendingSeat or SeatForHand(bLeft)
    pendingSeat = nil
    if seat then EnterSeat(seat) end
    return true
end

hook.Add("VRMod_Input", "vrmod_vehiclevr_grip", function(action, pressed)
    if not pressed then return end
    local bLeft
    if action == "boolean_left_pickup" then
        bLeft = true
    elseif action == "boolean_right_pickup" then
        bLeft = false
    else
        return
    end

    -- Fallback only. Controllers that report squeeze go through the threshold
    -- poll, so a light touch cannot seat you there.
    local inp = g_VR.input
    if inp and tonumber(bLeft and inp.vector1_left_squeeze or inp.vector1_right_squeeze) then return end
    local seat = pendingSeat or SeatForHand(bLeft)
    pendingSeat = nil
    if seat then EnterSeat(seat) end
end)

-- ---------------------------------------------------------------------------
-- Sit to enter / stand to exit
-- ---------------------------------------------------------------------------
local EXIT_HYSTERESIS = 5 -- matches the character system's sit exit margin
local SETTLE = 1 -- seconds before a state change can reverse itself
local POLL = 0.1
local nextPoll, lastChange = 0, 0
local trIn = {
    output = {}
}

-- What are we stood on? GroundEntity covers standing on a seat directly; the
-- short trace catches the frames where the mover has not registered as ground
-- yet, or where you are perched on a seat's edge.
local function SeatBelow(ply)
    local g = ply:GetGroundEntity()
    if IsValid(g) and g:IsVehicle() then return g end
    local p = ply:GetPos()
    trIn.start = p
    trIn.endpos = Vector(p.x, p.y, p.z - 40)
    trIn.filter = ply
    local tr = util.TraceLine(trIn)
    local e = tr.Entity
    if IsValid(e) and e:IsVehicle() then return e end
end

hook.Add("Think", "vrmod_vehiclevr", function()
    if not g_VR.active then
        armedL, armedR = false, false
        return
    end

    local thresh = cv_gripamt:GetInt() * 0.01
    armedL = GripPoll(true, armedL, thresh)
    armedR = GripPoll(false, armedR, thresh)
    local t = CurTime()
    if t < nextPoll then return end
    nextPoll = t + POLL
    local sitH = SitHeight()
    if sitH <= 0 then return end -- sit detection disabled outright
    local ply = LocalPlayer()
    if not IsValid(ply) or not ply:Alive() then return end
    local hmd = g_VR.tracking and g_VR.tracking.hmd
    if not hmd then return end
    -- Head height over the feet, which in a vehicle is the seat. Same quantity
    -- the character system tests against vrmod_sitheight.
    local headH = hmd.pos.z - ply:GetPos().z
    if ply:InVehicle() then
        if cv_stand:GetBool() and headH > sitH + EXIT_HYSTERESIS and t - lastChange > SETTLE then
            lastChange = t
            net.Start("vrmod_vehicle_exit")
            net.SendToServer()
        end
        return
    end

    if not cv_sit:GetBool() then return end
    -- Seated play mode parks the head below the threshold permanently, so
    -- sit-to-enter would fire the moment you walked over a seat.
    if SeatedMode() then return end
    if headH > sitH or t - lastChange <= SETTLE then return end
    local seat = SeatBelow(ply)
    -- lastChange is stamped on entry too: the origin shifts to the seat as you
    -- sit, and without the settle window that jump can read as a stand-up.
    if seat and EnterSeat(seat) then lastChange = t end
end)

hook.Add("VRMod_Exit", "vrmod_vehiclevr_exit", function(ply)
    if ply ~= LocalPlayer() then return end
    pendingSeat = nil
    armedL, armedR = false, false
end)