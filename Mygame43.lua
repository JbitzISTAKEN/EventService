-- Mygame43 local logic
-- paste inside spoofer task.spawn after Execute succeeds
-- call the returned stopMygame43() when spoofer expires

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)
local MathUtils        = require(ReplicatedStorage.Utils.MathUtils)
local Trove            = require(ReplicatedStorage.Packages.Trove)
local Spr              = require(ReplicatedStorage.Packages.Spr)
local VFX              = require(ReplicatedStorage.Shared.VFX)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local ShakePresets     = require(ReplicatedStorage.Shared.ShakePresets)
local Shake            = require(ReplicatedStorage.Packages.Shake)
local Observers        = require(ReplicatedStorage.Packages.Observers)

local CurrentCamera  = workspace.CurrentCamera
local trove          = Trove.new()
local recentlyHit    = {}
local IsActive       = true

-- the model — cloned into workspace so Observers.observeTag("Mygame43") fires
-- v22 in the decompiled handler is this model; orb origin positions are relative to its HumanoidRootPart
local Mygame43Model  = ReplicatedStorage:WaitForChild("Models").Events.Mygame43.mygame43
local clone          = Mygame43Model:Clone()
clone.Parent         = workspace
clone:AddTag("Mygame43")
trove:Add(clone)

-- OrbSmaller and Strike/StrikeBrainrot live inside the decompiled event script instance
local eventScript = ReplicatedStorage.Controllers.EventController.Events.Mygame43

-- ─── Camera shake ─────────────────────────────────────────────────────────────

local shakeBase = Shake.new()
shakeBase.Amplitude         = 5.5
shakeBase.Frequency         = 0.05
shakeBase.FadeInTime        = 0
shakeBase.FadeOutTime       = 0.6
shakeBase.PositionInfluence = Vector3.new(0.5, 0.5, 0.5)
shakeBase.RotationInfluence = Vector3.new(2.5, 0.5, 0.5)

local function shakeCameraBasedOnProximity(pos)
    local mag = (CurrentCamera.CFrame.Position - pos).Magnitude
    if mag > 300 then return end
    local s = shakeBase:Clone()
    local v2 = (1 - mag / 300 * 0.5) ^ 2
    s.Amplitude         = s.Amplitude         * v2
    s.RotationInfluence = s.RotationInfluence * v2
    trove:Add(ShakePresets.BindShakeToCamera(s))
    s:Start()
end

-- ─── v22 resolution ───────────────────────────────────────────────────────────
-- Observers fires as soon as clone hits workspace with the tag

local v22 = nil
trove:Add(Observers.observeTag("Mygame43", function(model)
    v22 = model
    return nil
end))

-- ─── Orb flight ───────────────────────────────────────────────────────────────

local function fireOrbLocally(seed, orbIndex, targetPos, flightDuration, didHit)
    -- origin — decompiled line 163
    -- orbIndex 2 and 3 spawn at Y=70, rest at Y=50
    local originCF = CFrame.new(
        (orbIndex - 1) * 30 + -45,
        (orbIndex == 2 or orbIndex == 3) and 70 or 50,
        15
    )
    local Position = (v22 and v22.HumanoidRootPart.CFrame * originCF or originCF).Position

    local orb = trove:Clone(eventScript.OrbSmaller)
    orb.CFrame = CFrame.new(Position)

    local flySound = ReplicatedStorage.Sounds.Events.Mygame43.OrbFlying:Clone()
    flySound.Parent = orb
    orb.Parent = workspace
    flySound:Play()
    VFX.enable(orb)

    -- bezier control points — decompiled lines 170-171
    local rng = Random.new(seed)
    local cp1 = Position + (targetPos - Position) * 0.25
        + Vector3.new(
            rng:NextNumber(50, 100)  * (rng:NextInteger(0, 1) * 2 - 1),
            rng:NextInteger(300, 400),
            0
        )
    local cp2 = Position + (targetPos - Position) * 0.6
        + Vector3.new(
            rng:NextNumber(50, 150) * (rng:NextInteger(0, 1) * 2 - 1),
            rng:NextInteger(100, 200),
            0
        )

    local elapsed = 0
    local conn    = nil

    conn = trove:Add(RunService.PostSimulation:Connect(function(dt)
        debug.profilebegin("Mygame43:UpdateOrb")
        elapsed = elapsed + dt

        local t1 = TweenService:GetValue(
            elapsed / flightDuration,
            Enum.EasingStyle.Sine,
            Enum.EasingDirection.In
        )

        SharedEventUtils.pushPartCFrame(
            orb,
            CFrame.new(MathUtils.cubicBezier(t1, Position, cp1, cp2, targetPos))
        )

        if t1 >= 1 and conn then
            trove:Remove(conn)
            conn = nil
            VFX.disable(orb)

            task.delay(3, function() trove:Remove(orb) end)

            shakeCameraBasedOnProximity(targetPos)

            local strike = didHit
                and eventScript.StrikeBrainrot:Clone()
                or  eventScript.Strike:Clone()

            strike.Position = targetPos
            strike.Parent   = workspace
            VFX.emit(strike)
            task.delay(4, function() strike:Destroy() end)

            if didHit then
                SoundController:PlaySound(
                    ReplicatedStorage.Sounds.Events["Los Matteos"].Hit,
                    targetPos,
                    false
                )
            else
                SoundController:PlaySound(
                    ReplicatedStorage.Sounds.Events.Mygame43.OrbHitNothing,
                    targetPos,
                    false
                )
            end
        end

        debug.profileend()
    end))
end

-- ─── Targeting ────────────────────────────────────────────────────────────────

local function pruneRecents()
    local now = workspace:GetServerTimeNow()
    for name, t in pairs(recentlyHit) do
        if now - t > 15 then recentlyHit[name] = nil end
    end
end

local function hasLightning(animal)
    local json = animal:GetAttribute("Traits")
    if not json then return false end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return false end
    for _, trait in ipairs(decoded) do
        if trait == "Lightning" then return true end
    end
    return false
end

local function pickTarget()
    pruneRecents()

    if math.random(1, 100) <= 35 then
        local candidates = {}
        for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
            if animal.PrimaryPart
            and not recentlyHit[animal.Name]
            and not hasLightning(animal) then
                table.insert(candidates, animal)
            end
        end

        if #candidates > 0 then
            local animal  = candidates[math.random(1, #candidates)]
            local flight  = Random.new():NextNumber(1.5, 2.5)
            local vel     = Vector3.zero

            if animal.PrimaryPart:IsA("BasePart") then
                vel = animal.PrimaryPart.AssemblyLinearVelocity
            end

            local predicted = animal.PrimaryPart.Position + vel * flight

            if SharedEventUtils.isPointInCarpet(predicted) then
                recentlyHit[animal.Name] = workspace:GetServerTimeNow()
                return predicted, flight, true
            end
        end
    end

    -- wander fallback
    local wanderFolder = workspace.Events:FindFirstChild("Wander")
    if wanderFolder then
        local parts = wanderFolder:GetChildren()
        if #parts > 0 then
            local flight = Random.new():NextNumber(1.5, 2.5)
            return parts[Random.new():NextInteger(1, #parts)].Position, flight, false
        end
    end

    return nil, nil, false
end

-- ─── Main loop ────────────────────────────────────────────────────────────────

task.spawn(function()
    while IsActive do
        task.wait(Random.new():NextNumber(2, 4))
        if not IsActive then break end

        local numBalls = math.random(1, 2)
        for i = 1, numBalls do
            if not IsActive then break end

            local targetPos, flightDuration, didHit = pickTarget()
            if targetPos then
                local seed     = Random.new():NextInteger(1, 999999)
                local orbIndex = Random.new():NextInteger(1, 4)
                fireOrbLocally(seed, orbIndex, targetPos, flightDuration, didHit)
            end

            if i < numBalls then task.wait(0.5) end
        end
    end
end)

-- ─── Cleanup ──────────────────────────────────────────────────────────────────
-- call this from the spoofer expiry block before EventController:Cancel

local function stopMygame43()
    IsActive = false
    trove:Destroy()
    recentlyHit = {}
    for _, obj in ipairs(CollectionService:GetTagged("Mygame43")) do
        obj:Destroy()
    end
end

return stopMygame43
