if not Glide then return end
g_VR = g_VR or {}

-- Hoisted vehicle-type constants (avoid repeated Glide.VEHICLE_TYPE table lookups in hot paths)
local VT = Glide.VEHICLE_TYPE
local VT_CAR, VT_BIKE, VT_TANK = VT.CAR, VT.MOTORCYCLE, VT.TANK
local VT_BOAT, VT_PLANE, VT_HELI = VT.BOAT, VT.PLANE, VT.HELICOPTER

local validVehicleTypes = {
    [VT_CAR] = true,
    [VT_BIKE] = true,
    [VT_TANK] = true,
    [VT_BOAT] = true,
    [VT_PLANE] = true,
    [VT_HELI] = true,
}

-- Localized natives (hot-path)
local IsValid, CurTime, net = IsValid, CurTime, net

if SERVER then
    local Lerp, Clamp = Lerp, math.Clamp
    local lastInputTime = {}

    local cvar = GetConVar("glide_ragdoll_enable")
    if cvar then
        cvar:SetInt(0)
        timer.Create("ForceGlideRagdollDisable", 30, 0, function() if g_VR.active and cvar:GetInt() ~= 0 then cvar:SetInt(0) end end)
    end

    -- Smooth toward new input; snap to 0 when released (upvalue: no per-message closure)
    local LERP_FACTOR = 0.2
    local function LerpOrReset(cur, new)
        if new == 0 then return 0 end
        return Lerp(LERP_FACTOR, cur, new)
    end

    -- Straight boolean pass-through: client action -> Glide seat input
    local BOOL_PASS = {
        boolean_handbrake     = "handbrake",
        boolean_horn          = "horn",
        boolean_shift_up      = "shift_up",
        boolean_shift_down    = "shift_down",
        boolean_shift_neutral = "shift_neutral",
        boolean_switch_weapon = "switch_weapon",
        boolean_siren         = "siren",
        boolean_toggle_engine = "toggle_engine",
        boolen_detach_trailer = "detach_trailer", -- typo key preserved (matches client)
    }

    util.AddNetworkString("glide_vr_input")
    net.Receive("glide_vr_input", function(_, ply)
        if not IsValid(ply) then return end
        local vehicle = ply:GlideGetVehicle()
        if not IsValid(vehicle) or not validVehicleTypes[vehicle.VehicleType] then return end
        local seatIndex = ply:GlideGetSeatIndex()
        lastInputTime[ply] = CurTime()

        local action = net.ReadString()
        if action == "analog" then
            local vt = vehicle.VehicleType
            local isAir = vt == VT_PLANE or vt == VT_HELI
            -- Wire is variable-length: ground sends 3 floats, aircraft 6.
            -- Both ends key length off vehicle type (same vehicle), so reads stay aligned.
            local throttle = net.ReadFloat()
            local brake    = net.ReadFloat()
            local steer    = net.ReadFloat()
            vehicle:SetInputFloat(seatIndex, "brake", LerpOrReset(vehicle:GetInputFloat(seatIndex, "brake"), brake))
            vehicle:SetInputFloat(seatIndex, "steer", LerpOrReset(vehicle:GetInputFloat(seatIndex, "steer"), steer))
            if isAir then
                local pitch = net.ReadFloat()
                local yaw   = net.ReadFloat()
                local roll  = net.ReadFloat()
                vehicle:SetInputFloat(seatIndex, "throttle", Clamp(LerpOrReset(vehicle:GetInputFloat(seatIndex, "throttle"), throttle), -1, 1))
                vehicle:SetInputFloat(seatIndex, "pitch",    Clamp(LerpOrReset(vehicle:GetInputFloat(seatIndex, "pitch"), pitch), -1, 1))
                vehicle:SetInputFloat(seatIndex, "yaw",      Clamp(LerpOrReset(vehicle:GetInputFloat(seatIndex, "yaw"), yaw), -1, 1))
                vehicle:SetInputFloat(seatIndex, "roll",     Clamp(LerpOrReset(vehicle:GetInputFloat(seatIndex, "roll"), roll), -1, 1))
            else
                vehicle:SetInputFloat(seatIndex, "accelerate", LerpOrReset(vehicle:GetInputFloat(seatIndex, "accelerate"), throttle))
            end
            return
        end

        local pressed = net.ReadBool()
        local pass = BOOL_PASS[action]
        if pass then
            vehicle:SetInputBool(seatIndex, pass, pressed)
            return
        end

        local vt = vehicle.VehicleType
        if action == "boolean_lights" then
            if pressed then vehicle:ChangeHeadlightState(vehicle:GetHeadlightState() == 0 and 2 or 0) end
        elseif action == "boolean_turret" or (vt == VT_TANK and action == "boolean_right_pickup") then
            vehicle:SetInputBool(seatIndex, "attack", pressed)
        elseif action == "boolean_alt_turret" or (vt == VT_TANK and action == "boolean_left_pickup") then
            vehicle:SetInputBool(seatIndex, "attack_alt", pressed)
        elseif action == "boolean_signal_left" then
            vehicle:SetInputBool(seatIndex, (vt == VT_PLANE or vt == VT_HELI) and "landing_gear" or "signal_left", pressed)
        elseif action == "boolean_signal_right" then
            vehicle:SetInputBool(seatIndex, (vt == VT_PLANE or vt == VT_HELI) and "countermeasures" or "signal_right", pressed)
        end
    end)

    -- Zero a driver's inputs if their client goes silent (crash / desync guard)
    local IsPlayerInVR = vrmod.IsPlayerInVR
    hook.Add("Think", "GlideVRInputTimeout", function()
        local now = CurTime()
        for ply, t in pairs(lastInputTime) do
            if not IsValid(ply) then
                lastInputTime[ply] = nil
            elseif IsPlayerInVR(ply) and now - t > 1 then
                local vehicle = ply:GlideGetVehicle()
                if IsValid(vehicle) then
                    local seatIndex = ply:GlideGetSeatIndex()
                    vehicle:SetInputFloat(seatIndex, "throttle", 0)
                    vehicle:SetInputFloat(seatIndex, "accelerate", 0)
                    vehicle:SetInputFloat(seatIndex, "brake", 0)
                    vehicle:SetInputFloat(seatIndex, "steer", 0)
                    vehicle:SetInputFloat(seatIndex, "pitch", 0)
                    vehicle:SetInputFloat(seatIndex, "yaw", 0)
                    vehicle:SetInputFloat(seatIndex, "roll", 0)
                end
                lastInputTime[ply] = nil
            end
        end
    end)
else -- CLIENT
    local abs = math.abs
    local originalMouseFlyMode = nil
    local originalRagdollEnable = nil

    local inputsToSend = {
        boolean_handbrake = true,
        boolean_lights = true,
        boolean_horn = true,
        boolean_shift_up = true,
        boolean_shift_down = true,
        boolean_shift_neutral = true,
        boolean_turret = true,
        boolean_alt_turret = true,
        boolean_switch_weapon = true,
        boolean_siren = true,
        boolean_signal_left = true,
        boolean_signal_right = true,
        boolean_toggle_engine = true,
        boolen_detach_trailer = true,
        boolean_left_pickup = true,
        boolean_right_pickup = true,
    }

    local lastInputState = {}
    local function ApplyMouseFlyMode(mode)
        if not Glide or not Glide.Config then return end
        local cfg = Glide.Config
        cfg.mouseFlyMode = mode
        if cfg.Save then cfg:Save() end
        if cfg.TransmitInputSettings then cfg:TransmitInputSettings(true) end
        if SetupFlyMouseModeSettings then SetupFlyMouseModeSettings() end
        if Glide.MouseInput and Glide.MouseInput.Activate then Glide.MouseInput:Activate() end
    end

    -- Resolve the Glide vehicle we're actively driving, or nil.
    -- GlideGetVehicle() walks seat -> parent and guarantees IsGlideVehicle,
    -- so it works where g_VR.vehicle.current (the seat pod) does not.
    local LocalPlayer = LocalPlayer
    local function CurrentGlideVehicle()
        if not g_VR.active then return end
        local veh = LocalPlayer():GlideGetVehicle()
        if IsValid(veh) and validVehicleTypes[veh.VehicleType] then return veh end
    end

    -- Boolean input: fire on state change only
    hook.Add("VRMod_Input", "glide_vr_input", function(action, pressed)
        if not inputsToSend[action] or lastInputState[action] == pressed then return end
        if not CurrentGlideVehicle() then return end
        lastInputState[action] = pressed
        net.Start("glide_vr_input")
        net.WriteString(action)
        net.WriteBool(pressed)
        net.SendToServer()
    end)

    -- Analog input: poll sticks and stream throttle/steer (+ aircraft axes) to the server.
    -- This is the piece that was lost in the OpenVR->OpenXR move; without it the server's
    -- "analog" handler never receives anything, so vehicles never move.
    --
    -- Aircraft axis mapping (remap here if desired):
    --   throttle = fwd - rev | pitch = steer.y | roll = steer.x | yaw = smoothturn.x
    local SEND_EPS = 0.01     -- min delta to treat as "changed"
    local HEARTBEAT = 0.5     -- resend held (non-zero) inputs within the server's 1s timeout
    local MIN_INTERVAL = 0.03 -- rate cap (~33 Hz)
    local lT, lB, lS, lP, lY, lR = 0, 0, 0, 0, 0, 0
    local lastSend = 0

    hook.Add("Think", "glide_vr_analog", function()
        local veh = CurrentGlideVehicle()
        if not veh then return end
        local inp = g_VR.input
        if not inp then return end

        local steer = inp.vector2_steer
        local sx = steer and steer.x or 0
        local fwd = inp.vector1_forward or 0
        local rev = inp.vector1_reverse or 0

        local vt = veh.VehicleType
        local isAir = vt == VT_PLANE or vt == VT_HELI
        local throttle, brake, st, pitch, yaw, roll
        if isAir then
            local turn = inp.vector2_smoothturn
            throttle = fwd - rev
            brake, st = 0, 0
            pitch = steer and steer.y or 0
            roll = sx
            yaw = turn and turn.x or 0
        else
            throttle, brake, st = fwd, rev, sx
            pitch, yaw, roll = 0, 0, 0
        end

        local now = CurTime()
        local changed = abs(throttle - lT) > SEND_EPS or abs(brake - lB) > SEND_EPS or abs(st - lS) > SEND_EPS
            or (isAir and (abs(pitch - lP) > SEND_EPS or abs(yaw - lY) > SEND_EPS or abs(roll - lR) > SEND_EPS))
        local active = throttle ~= 0 or brake ~= 0 or st ~= 0 or pitch ~= 0 or yaw ~= 0 or roll ~= 0

        if (changed or (active and now - lastSend > HEARTBEAT)) and now - lastSend >= MIN_INTERVAL then
            lT, lB, lS, lP, lY, lR = throttle, brake, st, pitch, yaw, roll
            lastSend = now
            net.Start("glide_vr_input")
            net.WriteString("analog")
            net.WriteFloat(throttle)
            net.WriteFloat(brake)
            net.WriteFloat(st)
            if isAir then
                net.WriteFloat(pitch)
                net.WriteFloat(yaw)
                net.WriteFloat(roll)
            end
            net.SendToServer()
        end
    end)

    hook.Add("VRMod_Start", "Glide_ForceMouseFlyMode", function()
        if not (Glide and Glide.Config) then
            vrmod.logger.Debug("[Glide] Glide not loaded, skipping mode change")
            return
        end

        local cfg = Glide.Config
        if originalRagdollEnable == nil then
            originalRagdollEnable = cfg.glide_ragdoll_enable
            if originalRagdollEnable ~= 0 then
                vrmod.logger.Debug("[Glide] Disabling Glide ragdoll mode for VR")
                cfg.glide_ragdoll_enable = 0
            end
        end

        if cfg.mouseFlyMode ~= 2 then
            originalMouseFlyMode = cfg.mouseFlyMode
            vrmod.logger.Debug(string.format("[Glide] Saving original mode %s, forcing mode 2", tostring(originalMouseFlyMode)))
            ApplyMouseFlyMode(2)
        else
            vrmod.logger.Debug("[Glide] Mouse fly mode already 2")
        end

        if not Glide.Camera then return end
        vrmod.utils.PatchGlideCamera()
        vrmod.logger.Debug("[Glide] Patched Glide.Camera for VR support")
    end)

    hook.Add("VRMod_Exit", "Glide_RestoreMouseFlyMode", function()
        if not (Glide and Glide.Config) then
            vrmod.logger.Debug("[Glide] Glide not loaded, cannot restore")
            return
        end

        local cfg = Glide.Config
        if originalMouseFlyMode ~= nil then
            vrmod.logger.Debug(string.format("[Glide] Restoring original mouse fly mode %s", tostring(originalMouseFlyMode)))
            ApplyMouseFlyMode(originalMouseFlyMode)
            originalMouseFlyMode = nil
        end

        if originalRagdollEnable ~= nil then
            vrmod.logger.Debug(string.format("[Glide] Restoring original ragdoll mode %s", tostring(originalRagdollEnable)))
            cfg.glide_ragdoll_enable = originalRagdollEnable
            originalRagdollEnable = nil
        end
    end)
end