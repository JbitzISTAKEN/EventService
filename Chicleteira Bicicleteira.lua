local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage.Packages.Trove)
local Spr              = require(ReplicatedStorage.Packages.Spr)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)
local EffectController = require(ReplicatedStorage.Controllers.EffectController)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local VFX              = require(ReplicatedStorage.Shared.VFX)
local Observers        = require(ReplicatedStorage.Packages.Observers)

local EVENT_NAME   = "Chicleteira Bicicleteira"
local EVENT_SCRIPT = ReplicatedStorage:WaitForChild("Controllers")
    :WaitForChild("EventController")
    :WaitForChild("Events")
    :WaitForChild("Chicleteira Bicicleteira")

-- ─── Constants ────────────────────────────────────────────────────────────────

local BLOCKING_TRAIT   = "Paint"
local SPRAY_WAIT_MIN   = 4
local SPRAY_WAIT_MAX   = 7
local SPRAY_REACH_DIST = 50
local SPRAY_ANIM_WAIT  = 1.4
local FORCE_SPRAY_ATTR = "ForceSpray"
local ACTIVATION_DELAY = 3

local BIKE_SPEED    = 35
local PATH_START_Z  = -132.1
local PATH_END_Z    = 251.706
local DEFAULT_LANES = {
    { x = -419.394, baseY = -9.074 },
    { x = -402.863, baseY = -9.074 },
}

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local burstAsset   = EVENT_SCRIPT:WaitForChild("Burst")
local bikeModel    = EVENT_SCRIPT:WaitForChild("Chicleteira Bicicleteira")
local walkAnim     = EVENT_SCRIPT:WaitForChild("Walk")
local bikeSound    = ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"].Bike

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)
local startedAt = eventData.startedAt

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove        = Trove.new()
local isActive          = true
local rng               = Random.new()
local CHICLETERAS_FOLDER = nil

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getTraits(animal: Model): ({ string }, { [string]: boolean })
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasBlockingTrait(animal: Model): boolean
    local _, set = getTraits(animal)
    return set[BLOCKING_TRAIT] == true
end

local function getChicleteras(): { Model }
    local out = {}
    if not CHICLETERAS_FOLDER or not CHICLETERAS_FOLDER.Parent then return out end
    for _, obj in ipairs(CHICLETERAS_FOLDER:GetChildren()) do
        table.insert(out, obj)
    end
    return out
end

-- ─── Burst ────────────────────────────────────────────────────────────────────

local function doBurst(target: Model)
    if not target or not target.PrimaryPart then return end
    ClientEventUtils.playBurst(burstAsset, target.PrimaryPart, {
        ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"].Hit,
    })
end

-- ─── Bike pass ────────────────────────────────────────────────────────────────
-- Mirrors the PostSimulation lerp + jump arc from the decompiled client exactly.
-- jumpCF is non-nil when a ritual position is used — arcs the bike up to player Y
-- then back down to ground level. Default lanes pass nil, straight path only.

local function fireBike(startCF: CFrame, endCF: CFrame, jumpCF: CFrame?)
    local clone = bikeModel:Clone()
    clone:PivotTo(jumpCF or startCF)
    clone.Parent = workspace

    local anim = clone.AnimationController.Animator:LoadAnimation(walkAnim)
    anim.Looped = true
    anim:Play()
    anim:AdjustSpeed(2)

    local sound = bikeSound:Clone()
    sound.Parent = clone.PrimaryPart
    sound:Play()

    local travelDist = math.abs(endCF.Z - startCF.Z)
    local travelTime = travelDist / BIKE_SPEED
    local elapsed    = 0
    local conn       = nil

    conn = RunService.PostSimulation:Connect(function(dt)
        elapsed = elapsed + dt
        local t = math.clamp(elapsed / travelTime, 0, 1)

        if t >= 1 then
            conn:Disconnect()
            conn = nil
            clone:Destroy()
            return
        end

        if jumpCF ~= nil then
            -- Arc: lerp position from jumpCF to endCF, Y follows a sin arc
            -- from jumpCF.Y back down to startCF.Y over the first 5% of travel
            local groundPos = startCF:Lerp(endCF, t)
            local jumpPos   = jumpCF:Lerp(endCF, t)
            local blendT    = math.clamp(t / 0.05, 0, 1)
            local arcHeight = 5 + (jumpPos.Y - groundPos.Y)
            local blendedY  = math.lerp(jumpPos.Y, groundPos.Y, blendT)
                            + math.sin(math.pi * blendT) * arcHeight
            clone:PivotTo(CFrame.new(groundPos.X, blendedY, jumpPos.Z) * groundPos.Rotation)
        else
            clone:PivotTo(startCF:Lerp(endCF, t))
        end
    end)

    eventTrove:Add(function()
        if conn then conn:Disconnect() end
        if clone and clone.Parent then clone:Destroy() end
    end)

    return travelTime
end

local function runBikePass(): number
    local rot      = CFrame.Angles(0, math.rad(180), 0)
    local maxTime  = 0

    for _, lane in ipairs(DEFAULT_LANES) do
        local startCF = CFrame.new(lane.x, lane.baseY, PATH_START_Z) * rot
        local endCF   = CFrame.new(lane.x, lane.baseY, PATH_END_Z)   * rot
        local t       = fireBike(startCF, endCF, nil)
        if t > maxTime then maxTime = t end
    end

    return maxTime
end

-- ─── Chicletera VFX observer ──────────────────────────────────────────────────
-- Mirrors the ForceSpray attribute observer from the decompiled client:
-- plays Spray sound, stops/replays Painting anim, enables handle VFX for 1s,
-- and spring-rotates the chicletera model to face the target animal.

local function mountChicleteraObserver(chicletera: Model, idleAnim: AnimationTrack, paintingAnim: AnimationTrack)
    local chicleteraVFX  = chicletera:FindFirstChild("Handle") and chicletera.Handle:FindFirstChild("vfx")
    local pivotCF        = chicletera:GetPivot() * CFrame.fromOrientation(0, math.pi, 0)

    -- Shake sound on idle marker (when not painting)
    local shakeConn = idleAnim:GetMarkerReachedSignal("Shake"):Connect(function()
        if paintingAnim.IsPlaying then return end
        task.spawn(function()
            SoundController:PlaySound(
                ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"].Shake,
                pivotCF.Position
            )
        end)
    end)

    -- ForceSpray watcher — fires animation + VFX when server/client sets the attr
    local sprayConn = chicletera:GetAttributeChangedSignal(FORCE_SPRAY_ATTR):Connect(function()
        local targetName = chicletera:GetAttribute(FORCE_SPRAY_ATTR)
        if not targetName then
            -- Reset facing when spray clears
            Spr.target(chicletera, 1, 2, { Pivot = pivotCF })
            return
        end

        task.spawn(function()
            SoundController:PlaySound(
                ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"].Spray,
                pivotCF.Position
            )
        end)

        paintingAnim:Stop(0)
        paintingAnim:Play()

        -- Face toward target animal
        local targetPos = ClientEventUtils.getAnimalPosition(targetName)
        if targetPos then
            local flatTarget = Vector3.new(targetPos.X, pivotCF.Y, targetPos.Z)
            Spr.target(chicletera, 1, 2, {
                Pivot = CFrame.lookAt(pivotCF.Position, flatTarget)
                      * CFrame.fromOrientation(0, math.pi, 0)
            })
        end

        -- VFX window: enable for 1s offset by 0.3s into anim (matches decompile)
        task.wait(0.3)
        if chicleteraVFX then VFX.enable(chicleteraVFX) end
        task.wait(1)
        if chicleteraVFX then VFX.disable(chicleteraVFX) end
    end)

    -- Ground placement sound on spawn
    task.spawn(function()
        SoundController:PlaySound(
            ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"].Ground,
            pivotCF.Position
        )
    end)

    return function()
        shakeConn:Disconnect()
        sprayConn:Disconnect()
    end
end

-- ─── Spray ────────────────────────────────────────────────────────────────────

local function doSpray(chicletera: Model, target: Model)
    chicletera:SetAttribute(FORCE_SPRAY_ATTR, target.Name)
    task.wait(SPRAY_ANIM_WAIT)
    if not isActive then
        chicletera:SetAttribute(FORCE_SPRAY_ATTR, nil)
        return
    end
    local traits, traitSet = getTraits(target)
    if not traitSet[BLOCKING_TRAIT] then
        table.insert(traits, BLOCKING_TRAIT)
        target:SetAttribute("Traits", HttpService:JSONEncode(traits))
    end
    doBurst(target)
    chicletera:SetAttribute(FORCE_SPRAY_ATTR, nil)
end

-- ─── Chicletera spawner ───────────────────────────────────────────────────────
-- Loads standing model, mounts idle + painting anims, wires the VFX observer.
-- Called after the bike pass completes + blink fires.

local standingModel    = EVENT_SCRIPT:WaitForChild("Standing Chicleteira Bicicleteira")
local idleAnimAsset    = EVENT_SCRIPT:WaitForChild("Idle")
local paintingAnimAsset = EVENT_SCRIPT:WaitForChild("Painting")

local function spawnStandingChicleteras()
    if not CHICLETERAS_FOLDER then return end

    for _, marker in ipairs(CHICLETERAS_FOLDER:GetChildren()) do
        local spawnTrove = eventTrove:Extend()
        local pivotCF    = marker:GetPivot() * CFrame.fromOrientation(0, math.pi, 0)

        local model = spawnTrove:Clone(standingModel)
        model:PivotTo(pivotCF - Vector3.new(0, model:GetExtentsSize().Y, 0))
        model.Parent = marker

        local animator  = model.AnimationController.Animator

        local idleTrack = animator:LoadAnimation(idleAnimAsset)
        spawnTrove:Add(idleTrack, "Stop")
        idleTrack.Looped    = true
        idleTrack.Priority  = Enum.AnimationPriority.Idle
        idleTrack:Play()

        local paintTrack = animator:LoadAnimation(paintingAnimAsset)
        spawnTrove:Add(paintTrack, "Stop")
        paintTrack.Looped   = false
        paintTrack.Priority = Enum.AnimationPriority.Action4

        local cleanup = mountChicleteraObserver(marker, idleTrack, paintTrack)
        spawnTrove:Add(cleanup)
    end
end

-- ─── Spray loop ───────────────────────────────────────────────────────────────

local function runSprayLoop()
    local cachedAnimals = CollectionService:GetTagged("Animal")
    eventTrove:Add(CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(inst)
        table.insert(cachedAnimals, inst)
    end))
    eventTrove:Add(CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(inst)
        for i = #cachedAnimals, 1, -1 do
            if cachedAnimals[i] == inst then table.remove(cachedAnimals, i) break end
        end
    end))

    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(rng:NextNumber(SPRAY_WAIT_MIN, SPRAY_WAIT_MAX))
            if not isActive then break end

            local chicleteras = getChicleteras()
            if #chicleteras == 0 then continue end

            local chicletera    = chicleteras[rng:NextInteger(1, #chicleteras)]
            local chicleteraPos = chicletera:GetPivot().Position

            if chicletera:GetAttribute(FORCE_SPRAY_ATTR) then continue end

            local closest     = nil
            local closestDist = SPRAY_REACH_DIST

            for _, animal in ipairs(cachedAnimals) do
                if animal.PrimaryPart and not hasBlockingTrait(animal) then
                    local dist = (animal.PrimaryPart.Position - chicleteraPos).Magnitude
                    if dist < closestDist then
                        closest     = animal
                        closestDist = dist
                    end
                end
            end

            if not closest then continue end

            local sprayTrove = eventTrove:Extend()
            sprayTrove:Add(task.spawn(function()
                doSpray(chicletera, closest)
                sprayTrove:Clean()
            end))
        end
    end))
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    local elapsed   = workspace:GetServerTimeNow() - startedAt
    local remaining = math.max(0, ACTIVATION_DELAY - elapsed)
    if remaining > 0 then task.wait(remaining) end
    if not isActive then return end

    -- Inject Chicleteras folder from asset
    local objects = game:GetObjects("rbxassetid://111606243506873")
    for _, obj in ipairs(objects) do
        obj.Name   = "Chicleteras"
        obj.Parent = workspace
        CHICLETERAS_FOLDER = obj
    end

    if not CHICLETERAS_FOLDER then
        warn("[ChicleteraBicicleteira] Asset folder failed to load")
        return
    end

    -- Bike pass
    local travelTime = runBikePass()
    task.wait(travelTime)
    if not isActive then return end

    -- Blink transition then spawn standing chicleteras
    EffectController:Activate("Blink")
    spawnStandingChicleteras()

    -- Spray loop runs for event lifetime
    runSprayLoop()

    -- Cleanup watchdog
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false

    for _, chicletera in ipairs(getChicleteras()) do
        chicletera:SetAttribute(FORCE_SPRAY_ATTR, nil)
    end

    eventTrove:Destroy()

    if CHICLETERAS_FOLDER and CHICLETERAS_FOLDER.Parent then
        CHICLETERAS_FOLDER:Destroy()
    end
end

task.spawn(main)
