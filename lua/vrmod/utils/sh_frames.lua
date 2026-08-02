g_VR = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}
-- FRAME UTILS
-- Precomputed frame field keys: every hot path that walks frame fields
-- (copy/convert/compare here, lerp + net codec in sh_network) indexes these
-- instead of rebuilding "fingerN"/"...Pos"/"...Ang" strings via concat.
-- Parts 1-3 (hmd/hands) are always present in a frame; 4-6 are FBT-optional.
local FINGERS, PKEYS, AKEYS = {}, {}, {}
for i = 1, 10 do FINGERS[i] = "finger" .. i end
for i, p in ipairs({"hmd", "lefthand", "righthand", "waist", "leftfoot", "rightfoot"}) do
    PKEYS[i], AKEYS[i] = p .. "Pos", p .. "Ang"
end
vrmod.utils.FINGER_KEYS, vrmod.utils.FRAME_POS_KEYS, vrmod.utils.FRAME_ANG_KEYS = FINGERS, PKEYS, AKEYS

local WorldToLocal, IsValid, LocalPlayer = WorldToLocal, IsValid, LocalPlayer

function vrmod.utils.CopyFrame(srcFrame)
    if not srcFrame then return nil end
    local copy = {characterYaw = srcFrame.characterYaw}
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

function vrmod.utils.ConvertToRelativeFrame(absFrame)
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
local DEFAULT_EPS = 0.01
function vrmod.utils.FramesAreEqual(f1, f2, eps)
    if not f1 or not f2 then return false end
    eps = eps or DEFAULT_EPS
    local equalVec, equalAng = vrmod.utils.VecAlmostEqual, vrmod.utils.AngAlmostEqual
    if f1.characterYaw ~= f2.characterYaw then return false end
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
    for i = 1, n do
        if not equalVec(f1[PKEYS[i]], f2[PKEYS[i]], eps) then return false end
        if not equalAng(f1[AKEYS[i]], f2[AKEYS[i]]) then return false end
    end
    return true
end