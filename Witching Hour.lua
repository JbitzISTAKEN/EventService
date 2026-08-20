local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

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
local ATTACK_MIN       = 6
local ATTACK_MAX       = 12

-- ─── Asset resolution ─────────────────────────────────────────────────────────

local EventFolder = ReplicatedStorage.Controllers.EventController.Events["Witching Hour"]

-- ─── Wait for event ───────────────────────────────────────────────────────────

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)

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

-- ─── Trait grant ──────────────────────────────────────────────────────────────

local function grantWitchHat(animal: Model)
    if not animal or not animal.Parent then return end
    local traits, set = getTraits(animal)
    if set[WITCH_HAT_TRAIT] then return end
    table.insert(traits, WITCH_HAT_TRAIT)
    animal:SetAttribute("Traits", HttpService:JSONEncode(traits))
end

-- ─── Burst ────────────────────────────────────────────────────────────────────

local function doBurst(animal: Model)
    local animalData = AnimalController:GetAnimals()[animal.Name]
    local pos: Vector3
    if animalData then
        local mdl = animalData.AnimalModel
        pos = (mdl.PrimaryPart and mdl.PrimaryPart.CFrame.Position)
            or mdl:GetPivot().Position
    else
        pos = animal.PrimaryPart and animal.PrimaryPart.Position
            or Vector3.new(0, 0, 0)
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
    weld.Part1  = animal.PrimaryPart
    weld.Parent = burst
    burst.Parent = workspace
    VFX.emit(burst)
    task.delay(5, function() burst:Destroy() end)
end

-- ─── Projectile ───────────────────────────────────────────────────────────────

local function fireProjectile(
    targetAnimal   : Model,
    startServerTime: number,
    travelTime     : number,
    candidateCount : number
)
    local sammy = witchModel:FindFirstChild("Sammy")
    if not sammy then return end

    local shootAnim = sammy.Humanoid.Animator:LoadAnimation(EventFolder.Shoot)
    shootAnim.Looped = false
    shootAnim:Play()
    shootAnim.Ended:Once(function()
        shootAnim:Stop()
        shootAnim:Destroy()
    end)

    local projectile    = EventFolder.Projectile:Clone()
    local launchCF      = sammy["Cylinder.001"].Attachment.WorldCFrame
    local appeared      = false
    local conn: RBXScriptConnection

    local flightEnd     = startServerTime + INITIAL_DELAY + travelTime
    local clampedSpread = math.min(candidateCount * 0.5, 50)

    local rng = Random.new()
    local v43 = rng:NextUnitVector() * (rng:NextInteger(0, 1) * 2 - 1) * clampedSpread * 0.65
    local cp1Offset = Vector3.new(v43.X, rng:NextNumber(-2, 7) * (clampedSpread / 50), v43.Z)
    local v44 = rng:NextUnitVector() * (rng:NextInteger(0, 1) * 2 - 1) * clampedSpread
    local cp2Offset = Vector3.new(v44.X, rng:NextNumber(-2, 7) * (clampedSpread / 50), v44.Z)
    if candidateCount <= 15 then
        cp1Offset = Vector3.new(0, 0, 0)
        cp2Offset = Vector3.new(0, 0, 0)
    end

    conn = RunService.PreRender:Connect(function()
        local now       = workspace:GetServerTimeNow()
        local remaining = math.max(flightEnd - now, 0)
        local t = now < (startServerTime + INITIAL_DELAY)
            and 0
            or 1 - remaining / travelTime
        t = math.clamp(t, 0, 1)

        if t >= 1 then
            conn:Disconnect()
            projectile:Destroy()
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
        local animalData = AnimalController:GetAnimals()[targetAnimal.Name]
        local targetPos: Vector3
        if animalData then
            local mdl = animalData.AnimalModel
            targetPos = (mdl.PrimaryPart and mdl.PrimaryPart.CFrame.Position)
                or mdl:GetPivot().Position
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

    eventTrove:Add(conn)
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    -- Attack loop
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(ATTACK_MIN * 10, ATTACK_MAX * 10) / 10)
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

            fireProjectile(selected, fireTime, travelTime, #candidates)

            task.delay(totalWait, function()
                if not isActive or not selected.Parent then return end
                doBurst(selected)
                grantWitchHat(selected)
            end)
        end
    end))

    -- Cleanup watchdog
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    witchModel:PivotTo(CFrame.new(0, 100000, 0))
    eventTrove:Destroy()
    table.clear(recentlyTargeted)
end

task.spawn(main)
