local U = vrmod.utils
local IsValid = IsValid
--Vehicles/Glide
-- Steering bone: exact names first, then a case-insensitive substring scan
-- of the bone names. Static tables, with lowered copies for the scan.
local MOTO = {type = "motorcycle", names = {"handlebars", "handles", "Airboat.Steer", "handle", "steer", "steerw_bone"}}
local CAR = {type = "car", names = {"steering_wheel", "steering", "Rig_Buggy.Steer_Wheel", "car.steer_wheel", "steer", "steerw_bone"}}
for _, e in ipairs({MOTO, CAR}) do
    e.lower = {}
    for i, n in ipairs(e.names) do e.lower[i] = n:lower() end
end
local BIKE_FIRST, CAR_FIRST = {MOTO, CAR}, {CAR, MOTO}

local function ApproxBone(ent, lowered)
    for i = 0, ent:GetBoneCount() - 1 do
        local name = ent:GetBoneName(i)
        if name then
            local l = name:lower()
            for k = 1, #lowered do
                if l:find(lowered[k], 1, true) then return i, name end
            end
        end
    end
end

function U.GetSteeringInfo(ply)
    if not IsValid(ply) or not ply:InVehicle() then return nil, nil, nil, nil end
    local glideVeh = ply.GlideGetVehicle and ply:GlideGetVehicle()
    if not IsValid(glideVeh) then glideVeh = nil end
    local vehicle = glideVeh or ply:GetVehicle()
    if not IsValid(vehicle) then return nil, nil, nil, nil end
    -- Search order: Glide's type, else the HL2 class
    local T, vType, bike, order
    if glideVeh then
        T, vType = Glide.VEHICLE_TYPE, glideVeh.VehicleType
        local sitSeq = glideVeh.GetPlayerSitSequence and glideVeh:GetPlayerSitSequence(ply.GlideGetSeatIndex and ply:GlideGetSeatIndex() or 1)
        bike = vType == T.MOTORCYCLE or sitSeq == "drive_airboat"
        order = (vType == T.CAR and not bike) and CAR_FIRST or BIKE_FIRST
    else
        order = vehicle:GetClass() == "prop_vehicle_airboat" and BIKE_FIRST or CAR_FIRST
    end

    -- A seat parented to a car body (simfphys, LVS): the wheel is the body's
    local parent = not glideVeh and vehicle:GetParent()
    if not IsValid(parent) then parent = nil end
    local boneId, boneType, boneName, boneEnt
    for c = 1, parent and 2 or 1 do
        local cand = c == 1 and vehicle or parent
        for o = 1, 2 do
            local e = order[o]
            local names = e.names
            for k = 1, #names do
                local id = cand:LookupBone(names[k])
                if id then boneId, boneName = id, names[k] break end
            end
            if not boneId then boneId, boneName = ApproxBone(cand, e.lower) end
            if boneId then boneType, boneEnt = e.type, cand break end
        end
        if boneId then break end
    end

    -- Glide type still takes precedence in naming
    if glideVeh then
        if bike then return glideVeh, boneId, "motorcycle", true, boneName end
        if vType == T.BOAT then return glideVeh, boneId, boneType or "boat", true, boneName end
        if vType == T.CAR then return glideVeh, boneId, "car", true, boneName end
        if vType == T.PLANE or vType == T.HELICOPTER then return glideVeh, boneId, "aircraft", true, boneName end
        if vType == T.TANK then return glideVeh, boneId, "tank", true, boneName end
    end

    if boneId then return boneEnt, boneId, boneType, false, boneName end
    return vehicle, nil, "unknown", false, nil
end

-- Glide camera in VR. Fallbacks are read-only constants, trace inputs reused:
-- the arm trace's result is read at once (output), the aim trace's HitPos is
-- kept on the camera, so that result stays fresh.
local ANG0, VEC0, CAM_OFF = Angle(), Vector(), Vector(-100, 0, 50)
local VUnpack, VSetU = FindMetaTable("Vector").Unpack, FindMetaTable("Vector").SetUnpacked
local _armOut = {}
local _armTr = {endpos = Vector(), mask = 16395, output = _armOut} -- MASK_SOLID_BRUSHONLY
local _aimF = {}
local _aimTr = {endpos = Vector(), filter = _aimF}
function U.PatchGlideCamera()
    local Camera = Glide.Camera
    if not Camera then return end
    local Config = Glide.Config
    if not Config then vrmod.logger.Warn("[Glide] Warning: Glide.Config not found, using fallback values") end
    -- Store original functions
    if not Camera._OrigCalcView then Camera._OrigCalcView = Camera.CalcView end
    if not Camera._OrigCreateMove then Camera._OrigCreateMove = Camera.CreateMove end
    -- Override CalcView
    function Camera:CalcView()
        if not self.isActive then return end
        local vehicle = self.vehicle
        if not IsValid(vehicle) then return end
        local user = self.user
        -- VR guard: ensure vrmod and g_VR.view exist
        if vrmod and vrmod.IsPlayerInVR and vrmod.IsPlayerInVR(user) and g_VR and g_VR.view then
            local eye = user:EyePos()
            local hmdPos = g_VR.view.origin or eye
            local hmdAng = g_VR.view.angles or user:EyeAngles()
            local angles = hmdAng
            if self.isInFirstPerson then
                self.position = vehicle:LocalToWorld(vehicle:GetFirstPersonOffset(self.seatIndex, vehicle:WorldToLocal(hmdPos)))
            else
                angles = hmdAng + (vehicle.CameraAngleOffset or ANG0)
                local tdf = self.trailerDistanceFraction or 0
                local pivot = vehicle:LocalToWorld((vehicle.CameraCenterOffset or VEC0) + (vehicle.CameraTrailerOffset or VEC0) * tdf)
                -- The arm, in view axes
                local ox, oy, oz = VUnpack(vehicle.CameraOffset or CAM_OFF)
                ox = ox * (Config and Config.cameraDistance or 100) * (1 + tdf * (vehicle.CameraTrailerDistanceMultiplier or 0))
                oz = oz * (Config and Config.cameraHeight or 50)
                local fx, fy, fz = VUnpack(angles:Forward())
                local rx, ry, rz = VUnpack(angles:Right())
                local ux, uy, uz = VUnpack(angles:Up())
                local px, py, pz = VUnpack(pivot)
                local ax, ay, az = fx * ox + rx * oy + ux * oz, fy * ox + ry * oy + uy * oz, fz * ox + rz * oy + uz * oz
                local len = (ax * ax + ay * ay + az * az) ^ 0.5
                local dx, dy, dz = fx, fy, fz -- arbitrary fallback
                if len > 0 then dx, dy, dz = ax / len, ay / len, az / len end
                VSetU(_armTr.endpos, px + ax + dx * 10, py + ay + dy * 10, pz + az + dz * 10)
                _armTr.start, _armTr.filter = pivot, vehicle
                util.TraceLine(_armTr)
                local fraction = self.distanceFraction or 1
                if _armOut.Hit then
                    fraction = _armOut.Fraction or fraction
                    if fraction < (self.distanceFraction or 1) then self.distanceFraction = fraction end
                end
                -- arm * fraction plus shake
                local sx, sy, sz = 0, 0, 0
                if self.shakeOffset then sx, sy, sz = VUnpack(self.shakeOffset) end
                sx, sy, sz = sx + ox * fraction, sy + oy * fraction, sz + oz * fraction
                self.position = Vector(px + fx * sx + rx * sy + ux * sz, py + fy * sx + ry * sy + uy * sz, pz + fz * sx + rz * sy + uz * sz)
            end
            -- Aim trace from player's eyes using HMD forward
            local ex, ey, ez = VUnpack(eye)
            local hx, hy, hz = VUnpack(hmdAng:Forward())
            _aimF[1], _aimF[2] = user, vehicle
            _aimTr.start = eye
            VSetU(_aimTr.endpos, ex + hx * 50000, ey + hy * 50000, ez + hz * 50000)
            local trAim = util.TraceLine(_aimTr)
            self.lastAimPos = trAim.HitPos
            self.lastAimEntity = trAim.Entity
            local aimDir = trAim.HitPos - eye
            self.lastAimPosDistanceFromEyes = aimDir:Length()
            if self.lastAimPosDistanceFromEyes > 0 then
                aimDir:Normalize()
                self.lastAimPosAnglesFromEyes = aimDir:Angle()
            else
                self.lastAimPosAnglesFromEyes = hmdAng
            end

            -- Keep player's eye angles synced to HMD for weapon aim
            if user.SetEyeAngles then user:SetEyeAngles(hmdAng) end
            return {
                origin = self.position,
                angles = angles + (self.punchAngle or ANG0),
                fov = self.fov,
                drawviewer = not self.isInFirstPerson
            }
        end
        -- Non-VR or fallback: call original
        return self:_OrigCalcView()
    end

    function Camera:CreateMove(cmd)
        if self.isActive and vrmod and vrmod.IsPlayerInVR and vrmod.IsPlayerInVR(self.user) then
            -- Prefer the cached eye-relative aim angles; fall back to HMD or stored angles if missing.
            cmd:SetViewAngles(self.lastAimPosAnglesFromEyes or g_VR and g_VR.view and g_VR.view.angles or self.angles or ANG0)
            cmd:SetUpMove(math.Clamp(self.lastAimPosDistanceFromEyes or 0, 0, 10000))
            return
        end

        -- Non-VR
        self:_OrigCreateMove(cmd)
    end
end