g_VR = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}

function vrmod.utils.VecAlmostEqual(v1, v2, threshold)
    if not v1 or not v2 then return false end
    return v1:DistToSqr(v2) < (threshold or 0.05) ^ 2
end

function vrmod.utils.AngAlmostEqual(a1, a2, threshold)
    if not a1 or not a2 then return false end
    threshold = threshold or 0.5 -- degrees
    return math.abs(math.AngleDifference(a1.p, a2.p)) < threshold and math.abs(math.AngleDifference(a1.y, a2.y)) < threshold and math.abs(math.AngleDifference(a1.r, a2.r)) < threshold
end

-- OPTIMIZATION: delegate to native C method instead of manual field access
-- Old: return v.x * v.x + v.y * v.y + v.z * v.z
-- The native method avoids 6 Lua field lookups and 3 multiplications
function vrmod.utils.LengthSqr(v)
    return v:LengthSqr()
end

-- OPTIMIZATION: use native operator instead of Vector() constructor
-- Old: return Vector(a.x - b.x, a.y - b.y, a.z - b.z)
-- Native (a - b) is implemented in C and avoids 6 Lua field lookups + alloc
function vrmod.utils.SubVec(a, b)
    return a - b
end

-- OPTIMIZATION: native vector addition (kept for backward compatibility)
function vrmod.utils.AddVec(a, b)
    return a + b
end

-- OPTIMIZATION: native vector-scalar multiplication (kept for backward compatibility)
function vrmod.utils.MulVec(v, s)
    return v * s
end

function vrmod.utils.SmoothVector(current, target, smoothingFactor)
    return current + (target - current) * smoothingFactor
end

function vrmod.utils.LerpAngleWrap(factor, current, target)
    local diff = math.AngleDifference(target, current) -- handles ±180 wrap
    return current + diff * factor
end

function vrmod.utils.SmoothAngle(current, target, smoothingFactor)
    local diff = target - current
    diff.p = math.NormalizeAngle(diff.p)
    diff.y = math.NormalizeAngle(diff.y)
    diff.r = math.NormalizeAngle(diff.r)
    return current + diff * smoothingFactor
end