local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local MathUtils        = require(ReplicatedStorage.Utils.MathUtils)
local AnimalController = require(ReplicatedStorage.Controllers.AnimalController)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local Trove            = require(ReplicatedStorage.Packages.Trove)
local Spr              = require(ReplicatedStorage.Packages.Spr)
local VFX              = require(ReplicatedStorage.Shared.VFX)

-- ─── Constants ────────────────────────────────────────────────────────────────

local EVENT_NAME       = "Witching Hour"
local WITCH_HAT_TRAIT  = "Witch Hat"
local PROJECTILE_SPEED = 50
local INITIAL_DELAY    = 1
local COOLDOWN_TIME    = 15
local ATTACK_MIN       = 60   -- matches server: math.random(60, 120) / 10
local ATTACK_MAX       = 120

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local EventFolder = ReplicatedStorage.Controllers.EventController.Events["Witching Hour"]

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

-- ─── State ────────────────────────────────────────────────────────────────────

local eventTrove       = Trove.new()
local isActive         = true
local recentlyTargeted = {}

local witchModel = workspace:WaitForChild("Events")
    :WaitForChild("Witching Hour")
    :WaitForChild("Model")

witchModel:PivotTo(CFrame.new(-381.109, -9.5, -4.494))

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function getTraits(animal: Model): ({string}, {[string]: boolean})
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasWitchHat(animal: Model): boolean
    local _, set = getTraits(animal)
    return set[WITCH_HAT_TRAIT] == true
end

local function grantWitchHat(animal: Model)
    if not animal or not animal.Parent then return end
    local traits, set = getTraits(animal)
    if set[WITCH_HAT_TRAIT] then return end
    table.insert(traits, WITCH_HAT_TRAIT)
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

-- ─── Burst — 1:1 to original OnClientEvent handler (doc 9 v_u_19) ────────────

local function doBurst(animalName: string)
    local animalData = AnimalController:GetAnimals()[animalName]
    if not animalData then return end

    local mdl = animalData.AnimalModel
    local pos: Vector3
    if mdl.PrimaryPart then
        pos = mdl.PrimaryPart.CFrame.Position
    else
        pos = mdl:GetPivot().Position
    end

    task.spawn(function()
        SoundController:PlaySound(
            ReplicatedStorage.Sounds.Events["Witching Hour"].Hit,
            pos
        )
    end)

    local burst = EventFolder.Burst:Clone()
    burst:PivotTo(CFrame.new(pos))
    burst.Anchored = false
    local weld  = Instance.new("WeldConstraint")
    weld.Part0  = burst
    weld.Part1  = mdl.PrimaryPart
    weld.Parent = burst
    burst.Parent = workspace
    VFX.emit(burst)
    task.delay(5, function()
        burst:Destroy()
    end)
end

-- ─── Projectile — 1:1 to original OnClientEvent handler (doc 9 v_u_18) ───────
-- Fix: projTrove extended from eventTrove owns both conn + projectile part.
-- eventTrove:Destroy() on event end cascades into every in-flight projTrove,
-- killing the connection AND the part — no orphaned projectiles in workspace.

local function fireProjectile(
    animalName     : string,
    initialDelay   : number,
    travelTime     : number,
    startServerTime: number,
    candidateCount : number
)
    local sammy = witchModel:FindFirstChild("Sammy")
    if not sammy then return end

    local projTrove = eventTrove:Extend()

    local shootAnim = sammy.Humanoid.Animator:LoadAnimation(EventFolder.Shoot)
    shootAnim.Looped = false
    shootAnim:Play()
    shootAnim.Ended:Once(function()
        shootAnim:Stop()
        shootAnim:Destroy()
    end)

    local projectile = EventFolder.Projectile:Clone()
    projTrove:Add(projectile)  -- projectile destroyed if event ends mid-flight

    local launchCF  = sammy["Cylinder.001"].Attachment.WorldCFrame
    local appeared  = false
    local flightEnd = startServerTime + initialDelay + travelTime

    -- spread calc — 1:1 to original (doc 9 lines v37-v_u_48)
    local spread     = math.min(candidateCount * 0.5, 50)
    local rng        = Random.new()
    local v43        = rng:NextUnitVector() * (rng:NextInteger(0, 1) * 2 - 1) * spread * 0.65
    local cp1Offset  = Vector3.new(v43.X, rng:NextNumber(-2, 7) * (spread / 50), v43.Z)
    local v44        = rng:NextUnitVector() * (rng:NextInteger(0, 1) * 2 - 1) * spread
    local cp2Offset  = Vector3.new(v44.X, rng:NextNumber(-2, 7) * (spread / 50), v44.Z)
    if candidateCount <= 15 then
        cp1Offset = Vector3.new(0, 0, 0)
        cp2Offset = Vector3.new(0, 0, 0)
    end

    local conn
    conn = RunService.PreRender:Connect(function()
        local now       = workspace:GetServerTimeNow()
        local remaining = math.max(flightEnd - now, 0)
        local t = now < (startServerTime + initialDelay)
            and 0
            or 1 - remaining / travelTime
        t = math.clamp(t, 0, 1)

        if t >= 1 then
            projTrove:Destroy()  -- kills conn + projectile part cleanly
            return
        end

        if t > 0 and not appeared then
            appeared = true
            launchCF = sammy["Cylinder.001"].Attachment.WorldCFrame
            projectile.Parent = workspace
            task.spawn(function()
                SoundController:PlaySound(
                    ReplicatedStorage.Sounds.Events["Witching Hour"].Shot,
                    launchCF.Position
                )
            end)
        end

        local origin     = launchCF.Position
        local animalData = AnimalController:GetAnimals()[animalName]
        local targetPos: Vector3
        if animalData then
            local mdl = animalData.AnimalModel
            if mdl.PrimaryPart then
                targetPos = mdl.PrimaryPart.CFrame.Position
            else
                targetPos = mdl:GetPivot().Position
            end
        else
            targetPos = Vector3.new(0, 0, 0)
        end

        projectile.CFrame = CFrame.new(
            MathUtils.cubicBezier(
                t,
                origin,
                origin:Lerp(targetPos, 0.4) + cp1Offset,
                origin:Lerp(targetPos, 0.8) + cp2Offset,
                targetPos
            )
        )

        -- waist aim — 1:1 to original (doc 9 v60-v71)
        local waist = sammy.UpperTorso.Waist
        local c0    = waist:GetAttribute("C0")
        if not c0 then
            c0 = waist.C0
            waist:SetAttribute("C0", c0)
        end
        if t >= 0.8 then
            Spr.target(waist, 1, 2, { C0 = c0 })
        else
            local rootCF = sammy.HumanoidRootPart.CFrame
            local local3 = rootCF:VectorToObjectSpace((targetPos - rootCF.Position).Unit)
            local yaw    = math.clamp(math.atan2(-local3.X, -local3.Z), -1.0471975511965976, 1.0471975511965976)
            local pitch  = math.clamp(math.asin(math.clamp(local3.Y, -1, 1)), -0.2617993877991494, 0.2617993877991494)
            Spr.target(waist, 1, 2, { C0 = c0 * CFrame.Angles(pitch, yaw, 0) })
        end
    end)

    projTrove:Add(conn)  -- conn also owned — disconnects on projTrove:Destroy()
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    eventTrove:Add(task.spawn(function()
        while isActive do
            -- 1:1 to server: math.random(60, 120) / 10
            local waitTime = math.random(ATTACK_MIN, ATTACK_MAX) / 10
            task.wait(waitTime)
            if not isActive then break end

            local now = workspace:GetServerTimeNow()
            for name, lastTime in pairs(recentlyTargeted) do
                if (now - lastTime) > COOLDOWN_TIME then
                    recentlyTargeted[name] = nil
                end
            end

            local candidates = {}
            for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                if animal.PrimaryPart
                    and not recentlyTargeted[animal.Name]
                    and not hasWitchHat(animal)
                then
                    table.insert(candidates, animal)
                end
            end

            if #candidates == 0 then continue end

            local selected   = candidates[math.random(1, #candidates)]
            local witchPos   = witchModel:GetPivot().Position
            local animalPos  = selected.PrimaryPart.Position
            local distance   = (witchPos - animalPos).Magnitude
            local travelTime = math.clamp(distance / PROJECTILE_SPEED, 0.5, 4)
            local fireTime   = workspace:GetServerTimeNow()
            local totalWait  = travelTime + INITIAL_DELAY

            recentlyTargeted[selected.Name] = fireTime

            fireProjectile(selected.Name, INITIAL_DELAY, travelTime, fireTime, #candidates)

            task.delay(totalWait, function()
                if not isActive or not selected.Parent then return end
                doBurst(selected.Name)
                grantWitchHat(selected)
            end)
        end
    end))

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    witchModel:PivotTo(CFrame.new(0, 100000, 0))
    eventTrove:Destroy()  -- cascades into all in-flight projTroves
    table.clear(recentlyTargeted)
end

task.spawn(main)
