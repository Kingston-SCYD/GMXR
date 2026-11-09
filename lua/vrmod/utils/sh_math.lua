-- Math helpers. Angle deltas inline math.AngleDifference(a, b), which is
-- exactly (a - b + 180) % 360 - 180 behind two Lua calls; |d| < t is -t < d < t.
local U = vrmod.utils
local AUnpack, Angle = FindMetaTable("Angle").Unpack, Angle

function U.VecAlmostEqual(v1, v2, threshold)
    if not v1 or not v2 then return false end
    threshold = threshold or 0.05
    return v1:DistToSqr(v2) < threshold * threshold
end

function U.AngAlmostEqual(a1, a2, threshold)
    if not a1 or not a2 then return false end
    threshold = threshold or 0.5 -- degrees
    local p1, y1, r1 = AUnpack(a1)
    local p2, y2, r2 = AUnpack(a2)
    local d = (p1 - p2 + 180) % 360 - 180
    if not (d < threshold and d > -threshold) then return false end
    d = (y1 - y2 + 180) % 360 - 180
    if not (d < threshold and d > -threshold) then return false end
    d = (r1 - r2 + 180) % 360 - 180
    return d < threshold and d > -threshold
end

-- current + (target - current) * s, one allocation instead of three
function U.SmoothVector(current, target, smoothingFactor)
    local d = target - current
    d:Mul(smoothingFactor)
    d:Add(current)
    return d
end

function U.SmoothAngle(current, target, smoothingFactor)
    local cp, cy, cr = AUnpack(current)
    local tp, ty, tr = AUnpack(target)
    return Angle(cp + ((tp - cp + 180) % 360 - 180) * smoothingFactor,
        cy + ((ty - cy + 180) % 360 - 180) * smoothingFactor,
        cr + ((tr - cr + 180) % 360 - 180) * smoothingFactor)
end