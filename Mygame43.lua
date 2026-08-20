
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

if not game:IsLoaded() then game.Loaded:Wait() end


local SkullEmojiEffectController = require(ReplicatedStorage.Controllers.SkullEmojiEffectController)
local EffectController           = require(ReplicatedStorage.Controllers.EffectController)
local SoundController            = require(ReplicatedStorage.Controllers.SoundController)
local EventController            = require(ReplicatedStorage.Controllers.EventController)
local SharedEventUtils           = require(ReplicatedStorage.Shared.SharedEventUtils)
local ShakePresets               = require(ReplicatedStorage.Shared.ShakePresets)
local Observers                  = require(ReplicatedStorage.Packages.Observers)
local MathUtils                  = require(ReplicatedStorage.Utils.MathUtils)
local Shake                      = require(ReplicatedStorage.Packages.Shake)
local Trove                      = require(ReplicatedStorage.Packages.Trove)
local Spr                        = require(ReplicatedStorage.Packages.Spr)
local VFX                        = require(ReplicatedStorage.Shared.VFX)

local EVENT_NAME   = "Mygame43"
local EVENT_SCRIPT = ReplicatedStorage.Controllers.EventController.Events[EVENT_NAME]
local Sounds       = ReplicatedStorage.Sounds.Events[EVENT_NAME]
local CurrentCamera = workspace.CurrentCamera

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

local function timeLeftFor(t)
    return startedAt + t - workspace:GetServerTimeNow()
end

local trove       = Trove.new()
local recentlyHit = {}

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
    local s  = shakeBase:Clone()
    local v2 = (1 - mag / 300 * 0.5) ^ 2
    s.Amplitude         = s.Amplitude         * v2
    s.RotationInfluence = s.RotationInfluence * v2
    trove:Add(ShakePresets.BindShakeToCamera(s))
    s:Start()
end

local mygame43Model = nil

local function hasLightning(animal)
    local json = animal:GetAttribute("Traits")
    if not json then return false end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return false end
    for _, t in ipairs(decoded) do
        if t == "Lightning" then return true end
    end
    return false
end

local function pruneRecents()
    local now = workspace:GetServerTimeNow()
    for name, t in pairs(recentlyHit) do
        if now - t > 15 then recentlyHit[name] = nil end
    end
end

local function pickTarget()
    pruneRecents()

    if math.random(1, 100) <= 35 then
        local candidates = {}
        for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
            if animal.PrimaryPart
                and not recentlyHit[animal.Name]
                and not hasLightning(animal)
            then
                table.insert(candidates, animal)
            end
        end

        if #candidates > 0 then
            local animal = candidates[math.random(1, #candidates)]
            local flight = Random.new():NextNumber(1.5, 2.5)
            local vel    = Vector3.zero
            if animal.PrimaryPart:IsA("BasePart") then
                vel = animal.PrimaryPart.AssemblyLinearVelocity
            end
            local predicted = animal.PrimaryPart.Position + vel * flight
            if SharedEventUtils.isPointInCarpet(animal.PrimaryPart.Position) then
                recentlyHit[animal.Name] = workspace:GetServerTimeNow()
                return predicted, flight, true, animal
            end
        end
    end

    local wanderFolder = workspace.Events:FindFirstChild("Wander")
    if wanderFolder then
        local parts = wanderFolder:GetChildren()
        if #parts > 0 then
            local flight = Random.new():NextNumber(1.5, 2.5)
            return parts[Random.new():NextInteger(1, #parts)].Position, flight, false, nil
        end
    end

    return nil, nil, false, nil
end

local function fireOrb(seed, orbIndex, targetPos, flightDuration, didHit)
    local originCF = CFrame.new(
        (orbIndex - 1) * 30 + -45,
        (orbIndex == 2 or orbIndex == 3) and 70 or 50,
        15
    )
    local Position = (mygame43Model and mygame43Model.HumanoidRootPart.CFrame * originCF or originCF).Position

    local orb = trove:Clone(EVENT_SCRIPT.OrbSmaller)
    orb.CFrame = CFrame.new(Position)

    local flySound = Sounds.OrbFlying:Clone()
    flySound.Parent = orb
    orb.Parent      = workspace
    flySound:Play()
    VFX.enable(orb)

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
                and EVENT_SCRIPT.StrikeBrainrot:Clone()
                or  EVENT_SCRIPT.Strike:Clone()
            strike.Position = targetPos
            strike.Parent   = workspace
            VFX.emit(strike)
            task.delay(4, function() strike:Destroy() end)

            if didHit then
                SoundController:PlaySound(ReplicatedStorage.Sounds.Events["Los Matteos"].Hit, targetPos, false)
            else
                SoundController:PlaySound(Sounds.OrbHitNothing, targetPos, false)
            end
        end

        debug.profileend()
    end))
end

local function main()
    trove:Add(function()
        EffectController:Activate("Blink")
    end)

    -- clone off-screen, animate first, parent last
    local modelClone = trove:Clone(ReplicatedStorage.Models.Events.Mygame43.mygame43)
    mygame43Model = modelClone

    Sounds.Appear:Play()

    local idle  = mygame43Model.Humanoid.Animator:LoadAnimation(EVENT_SCRIPT.Idle)
    local spawn = mygame43Model.Humanoid.Animator:LoadAnimation(EVENT_SCRIPT.Spawn)
    idle:Play()
    spawn:Play()
    spawn.TimePosition = math.max(0, 7 - timeLeftFor(7))

    trove:Add(function()
        idle:Stop()
        spawn:Stop()
    end)

    -- first visible frame already has animation weight — no T-pose flash
    modelClone.Parent = workspace

    trove:Add(task.delay(math.max(0, timeLeftFor(7.7)), function()
        for i = 1, 4 do
            local offsetCF = CFrame.new(
                (i - 1) * 30 + -45,
                (i == 2 or i == 3) and 70 or 50,
                15
            )
            local anchorCF = mygame43Model.HumanoidRootPart.CFrame * offsetCF
            local orb = trove:Clone(EVENT_SCRIPT.Orb)
            orb.CFrame = anchorCF - Vector3.new(0, 100, 0)
            orb.Parent = workspace
            trove:Add(function() Spr.stop(orb) end)

            local floatSpeed = Random.new():NextNumber(2, 3)
            trove:Add(RunService.PostSimulation:Connect(function()
                debug.profilebegin("Mygame43:FloatOrb")
                Spr.target(orb, 0.8, 1, {
                    Pivot = anchorCF + Vector3.new(0, math.sin((os.clock() + i * 90) * floatSpeed) * 4, 0),
                })
                debug.profileend()
            end))
        end
    end))

    trove:Add(task.delay(math.max(0, timeLeftFor(3.7)), function()
        VFX.enable(mygame43Model)

        local focusConn = RunService.PreRender:Connect(function(dt)
            debug.profilebegin("Mygame43:Focus")
            local cf = CurrentCamera.CFrame
            CurrentCamera.CFrame = cf:Lerp(
                CFrame.lookAt(cf.Position, mygame43Model:GetPivot().Position),
                math.clamp(dt ^ 0.45, 0, 0.1)
            )
            debug.profileend()
        end)

        task.delay(0.6, function()
            focusConn:Disconnect()
            SkullEmojiEffectController:Play(3, "Lower")
        end)
    end))

    trove:Add(task.spawn(function()
        local gate = timeLeftFor(7.7)
        if gate > 0 then task.wait(gate) end

        while EventController:GetActiveEventData(EVENT_NAME) do
            local waitTime = Random.new():NextNumber(2, 4)
            local t0 = os.clock()
            while os.clock() - t0 < waitTime do
                task.wait()
                if not EventController:GetActiveEventData(EVENT_NAME) then break end
            end
            if not EventController:GetActiveEventData(EVENT_NAME) then break end

            local numBalls = math.random(1, 2)
            for i = 1, numBalls do
                if not EventController:GetActiveEventData(EVENT_NAME) then break end

                local targetPos, flightDuration, didHit, targetAnimal = pickTarget()
                if targetPos then
                    local seed     = Random.new():NextInteger(1, 999999)
                    local orbIndex = Random.new():NextInteger(1, 4)
                    fireOrb(seed, orbIndex, targetPos, flightDuration, didHit)

                    if didHit and targetAnimal then
                        task.delay(flightDuration + 0.1, function()
                            if not EventController:GetActiveEventData(EVENT_NAME) then return end
                            local json = targetAnimal:GetAttribute("Traits")
                            local traits = {}
                            if json then
                                local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
                                if ok and type(decoded) == "table" then traits = decoded end
                            end
                            for _, t in ipairs(traits) do
                                if t == "Lightning" then return end
                            end
                            table.insert(traits, "Lightning")
                            targetAnimal:SetAttribute("Traits", HttpService:JSONEncode(traits))
                        end)
                    end
                end

                if i < numBalls then
                    local t1 = os.clock()
                    while os.clock() - t1 < 0.5 do
                        task.wait()
                        if not EventController:GetActiveEventData(EVENT_NAME) then break end
                    end
                end
            end
        end

        trove:Destroy()
        recentlyHit = {}
    end))
end

task.spawn(main)
