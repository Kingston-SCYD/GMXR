-- FRAME UTILS
-- Precomputed frame field keys: the hot paths here (copy/convert/compare)
-- index these instead of rebuilding "fingerN"/"...Pos"/"...Ang" via concat.
-- Parts 1-3 (hmd/hands) are always present in a frame; 4-6 are FBT-optional.
local U = vrmod.utils
local FINGERS, PKEYS, AKEYS = {}, {}, {}
for i = 1, 10 do FINGERS[i] = "finger" .. i end
for i, p in ipairs({"hmd", "lefthand", "righthand", "waist", "leftfoot", "rightfoot"}) do
    PKEYS[i], AKEYS[i] = p .. "Pos", p .. "Ang"
end

local WorldToLocal, IsValid, LocalPlayer, Vector, Angle = WorldToLocal, IsValid, LocalPlayer, Vector, Angle
local DistToSqr, AUnpack = FindMetaTable("Vector").DistToSqr, FindMetaTable("Angle").Unpack

function U.CopyFrame(srcFrame)
    if not srcFrame then return nil end
    local copy = {characterYaw = srcFrame.characterYaw, yawTwist = srcFrame.yawTwist}
    for i = 1, 10 do
        local k = FINGERS[i]
        copy[k] = srcFrame[k]
    end
    for i = 1, 6 do
        local pk, ak = PKEYS[i], AKEYS[i]
        local pos, ang = srcFrame[pk], srcFrame[ak]
        if pos then copy[pk] = Vector(pos) end
        if ang then copy[ak] = Angle(ang) end
    end
    return copy
end

function U.ConvertToRelativeFrame(absFrame)
    local lp = LocalPlayer()
    if not IsValid(lp) then return nil end
    -- angle_zero: engine constant, read-only arg to WorldToLocal (no alloc)
    local plyAng = angle_zero
    if lp:InVehicle() then
        local veh = lp:GetVehicle()
        if IsValid(veh) then plyAng = veh:GetAngles() end
    end

    local plyPos = lp:GetPos()
    local relFrame = {characterYaw = absFrame.characterYaw}
    for i = 1, 10 do
        local k = FINGERS[i]
        relFrame[k] = absFrame[k]
    end

    for i = 1, g_VR.sixPoints and 6 or 3 do
        local pk, ak = PKEYS[i], AKEYS[i]
        local pos, ang = absFrame[pk], absFrame[ak]
        if pos and ang then
            relFrame[pk], relFrame[ak] = WorldToLocal(pos, ang, plyPos, plyAng)
        end
    end
    return relFrame
end

-- Default epsilon is a tiny fixed jitter floor, NOT vrmod_net_minsend.
-- minsend is now purely the playermodel-IK re-solve threshold (cl_character
-- passes it in as eps). The transmit gate calls this with no eps, so any real
-- tracked movement streams to the server at full precision (physics grab,
-- shadow controller, server API); the floor only suppresses ticks while the
-- rig is genuinely parked (headset on a desk).
-- Positions as VecAlmostEqual(eps), angles as AngAlmostEqual (0.5 deg per
-- axis), both inlined.
local DEFAULT_EPS = 0.01
function U.FramesAreEqual(f1, f2, eps)
    if not f1 or not f2 then return false end
    if f1.characterYaw ~= f2.characterYaw or f1.yawTwist ~= f2.yawTwist then return false end
    for i = 1, 10 do
        local k = FINGERS[i]
        if f1[k] ~= f2[k] then return false end
    end

    -- Parts 1-3 always compared; 4-6 only when f1 carries fullbody
    -- (original asymmetric waist semantics preserved).
    local n = 3
    if f1.waistPos then
        if not f2.waistPos then return false end
        n = 6
    end
    eps = eps or DEFAULT_EPS
    eps = eps * eps
    for i = 1, n do
        local p1, p2 = f1[PKEYS[i]], f2[PKEYS[i]]
        if not p1 or not p2 or not (DistToSqr(p1, p2) < eps) then return false end
        local a1, a2 = f1[AKEYS[i]], f2[AKEYS[i]]
        if not a1 or not a2 then return false end
        local x1, y1, z1 = AUnpack(a1)
        local x2, y2, z2 = AUnpack(a2)
        local d = (x1 - x2 + 180) % 360 - 180
        if not (d < 0.5 and d > -0.5) then return false end
        d = (y1 - y2 + 180) % 360 - 180
        if not (d < 0.5 and d > -0.5) then return false end
        d = (z1 - z2 + 180) % 360 - 180
        if not (d < 0.5 and d > -0.5) then return false end
    end
    return true
end