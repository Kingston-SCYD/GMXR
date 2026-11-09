local U = vrmod.utils
local IsValid, util_TraceHull = IsValid, util.TraceHull
local VUnpack, VSetU = FindMetaTable("Vector").Unpack, FindMetaTable("Vector").SetUnpacked
-- ArcVR magazines, by class prefix, cached per class
local magCache = {}
local function IsMagazine(ent)
    local class = ent:GetClass()
    local m = magCache[class]
    if m == nil then
        m = class:sub(1, 7) == "avrmag_"
        magCache[class] = m
    end
    return m
end

--FILTERS AND TRACE UTILS
local function HitFilter(ent, ply, hand)
    if not IsValid(ent) then return false end
    if ent == ply then return end
    if ent:GetNWBool("isVRHand", false) then return false end
    -- The hand's own held entity (ent is valid, so == needs no IsValid on it)
    if (hand == "left" or hand == "right") and IsValid(ply) and vrmod.GetHeldEntity(ply, hand) == ent then return false end
    return true
end
U.HitFilter = HitFilter

function U.MeleeFilter(ent, ply, hand)
    return HitFilter(ent, ply, hand) and not IsMagazine(ent)
end

-- Reused trace input; the result stays a fresh table (callers keep it). The
-- start is scratch, never the caller's hand vector.
local _thStart, _thEnd, _thIgn = Vector(), Vector(), {}
local _thTr = {start = _thStart, endpos = _thEnd, mins = Vector(), maxs = Vector(), filter = _thIgn, mask = MASK_SHOT_HULL}
function U.TraceHand(ply, hand, fromPalm)
    local startPos, ang
    if hand == "left" then
        startPos, ang = vrmod.GetLeftHandPos(ply), vrmod.GetLeftHandAng(ply)
    else
        startPos, ang = vrmod.GetRightHandPos(ply), vrmod.GetRightHandAng(ply)
    end
    if not ang or not startPos then return nil end
    local sx, sy, sz = VUnpack(startPos)
    local dir
    if fromPalm then
        dir = ang:Right() -- palm facing sideways
        if hand ~= "left" then dir:Negate() end
        -- offset up and out from the hand centre
        local ux, uy, uz = VUnpack(ang:Up())
        local fx, fy, fz = VUnpack(ang:Forward())
        local o = vrmod.DEFAULT_OFFSET
        sx, sy, sz = sx + ux * 2 + fx * o, sy + uy * 2 + fy * o, sz + uz * 2 + fz * o
    else
        -- Unit already. Roll doesn't move Forward: the left hand's old
        -- Angle(p, y, r + 180):Forward() was this same vector.
        dir = ang:Forward()
    end
    local dx, dy, dz = VUnpack(dir)
    local r = fromPalm and 6 or 2 -- palm fatter, finger forward thinner
    VSetU(_thTr.mins, -r, -r, -r)
    VSetU(_thTr.maxs, r, r, r)
    for i = #_thIgn, 1, -1 do _thIgn[i] = nil end
    for _ = 1, 10 do
        VSetU(_thStart, sx, sy, sz)
        VSetU(_thEnd, sx + dx * 32768, sy + dy * 32768, sz + dz * 32768)
        local tr = util_TraceHull(_thTr)
        local e = tr.Entity
        if not (e and e:IsValid()) or HitFilter(e, ply, hand) then return tr end
        _thIgn[#_thIgn + 1] = e
        local hx, hy, hz = VUnpack(tr.HitPos)
        sx, sy, sz = hx + dx, hy + dy, hz + dz -- nudge forward
    end
    return nil
end