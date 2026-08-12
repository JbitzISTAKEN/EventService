-- LocalScript: Chicleteira Bicicleteira Client Spawner
-- No RemoteEvents. Standing chicleteira observed from workspace tag.
-- Bike spawned inline. Raycast inline. Spray tick inline.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local EventController = require(ReplicatedStorage.Controllers.EventController)
local Observers       = require(ReplicatedStorage.Packages.Observers)
local Spr             = require(ReplicatedStorage.Packages.Spr)
local VFX             = require(ReplicatedStorage.Shared.VFX)
local SoundController = require(ReplicatedStorage.Controllers.SoundController)
local Timer           = require(ReplicatedStorage.Packages.Timer)

local EVENT_SCRIPT = ReplicatedStorage.Controllers.EventController.Events["Chicleteira Bicicleteira"]
local EVENT_NAME   = "Chicleteira Bicicleteira"

local BIKE_SPEED         = 35
local SPRAY_COOLDOWN_MIN = 4
local SPRAY_COOLDOWN_MAX = 7
local SPRAY_REACH        = 50
local PAINT_TRAIT        = "Paint"

local DEFAULT_LANES = {
    { x = -419.394, baseY = -9.074 },
    { x = -402.863, baseY = -9.074 },
}
local PATH_START_Z = -132.1
local PATH_END_Z   =  251.706

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local eventTrove = Trove.new()
local isActive   = true

-- ─── Raycast ─────────────────────────────────────────────────────────────────

local RAY_PARAMS = RaycastParams.new()
RAY_PARAMS.FilterType = Enum.RaycastFilterType.Include
RAY_PARAMS.FilterDescendantsInstances = {
    workspace:FindFirstChild("Map") or workspace,
    workspace.Terrain,
}

local function stickToGround(position: Vector3): Vector3
    local result = workspace:Raycast(
        position + Vector3.new(0, 10, 0),
        Vector3.new(0, -20, 0),
        RAY_PARAMS
    )
    return result and result.Position + Vector3.new(0, 0.1, 0) or position
end

-- ─── Bike spawner ────────────────────────────────────────────────────────────
-- Mirrors decompiled OnClientEvent handler exactly.
-- jumpCF present → arc lerp blending from player Y down to ground Y.
-- jumpCF nil    → straight CFrame lerp.

local function spawnBike(startCF: CFrame, endCF: CFrame, speed: number, jumpCF: CFrame?)
    local bikeTemplate = EVENT_SCRIPT:FindFirstChild("Chicleteira Bicicleteira")
    if not bikeTemplate then
        warn("[ChicleteiraBicicleteira] Missing bike model in event script")
        return 0
    end

    local clone = bikeTemplate:Clone()
    clone:PivotTo(jumpCF or startCF)
    clone.Parent = workspace

    local walkAnim = EVENT_SCRIPT:FindFirstChild("Walk")
    if walkAnim then
        local track = clone.AnimationController.Animator:LoadAnimation(walkAnim)
        track.Looped = true
        track:Play()
        track:AdjustSpeed(2)
    end

    local soundFolder = ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"]
    local bikeSound   = soundFolder:FindFirstChild("Bike")
    if bikeSound then
        local s = bikeSound:Clone()
        s.Parent = clone.PrimaryPart
        s:Play()
    end

    local dist     = math.abs(endCF.Z - startCF.Z)
    local duration = dist / speed
    local elapsed  = 0
    local conn: RBXScriptConnection

    conn = RunService.PostSimulation:Connect(function(dt)
        elapsed += dt
        local alpha = math.clamp(elapsed / duration, 0, 1)

        if alpha >= 1 then
            conn:Disconnect()
            clone:Destroy()
            return
        end

        if jumpCF ~= nil then
            local groundPos = startCF.Position:Lerp(endCF.Position, alpha)
            local jumpPos   = jumpCF.Position:Lerp(endCF.Position, alpha)
            local arcBlend  = math.clamp(alpha / 0.05, 0, 1)
            local arcHeight = 5 + (jumpPos.Y - groundPos.Y)
            local blendedY  = math.lerp(jumpPos.Y, groundPos.Y, arcBlend)
                            + math.sin(math.pi * arcBlend) * arcHeight
            clone:PivotTo(CFrame.new(groundPos.X, blendedY, jumpPos.Z) * groundPos.Rotation)
        else
            clone:PivotTo(startCF:Lerp(endCF, alpha))
        end
    end)

    eventTrove:Add(function()
        conn:Disconnect()
        if clone.Parent then clone:Destroy() end
    end)

    return duration
end

-- ─── Lane builders ───────────────────────────────────────────────────────────

local function laneFromPlayerCFrame(playerCF: CFrame): (CFrame, CFrame, CFrame)
    local x       = playerCF.X
    local playerY = playerCF.Y
    local groundY = DEFAULT_LANES[1].baseY
    local rot     = CFrame.Angles(0, math.rad(180), 0)
    local startCF = CFrame.new(x, groundY, PATH_START_Z) * rot
    local endCF   = CFrame.new(x, groundY, PATH_END_Z)   * rot
    local jumpCF  = CFrame.new(x, playerY, PATH_START_Z) * rot
    return startCF, endCF, jumpCF
end

local function laneFromDefault(lane): (CFrame, CFrame)
    local rot     = CFrame.Angles(0, math.rad(180), 0)
    local startCF = CFrame.new(lane.x, lane.baseY, PATH_START_Z) * rot
    local endCF   = CFrame.new(lane.x, lane.baseY, PATH_END_Z)   * rot
    return startCF, endCF
end

-- ─── Standing Chicleteira observer ───────────────────────────────────────────
-- Clones "Standing Chicleteira Bicicleteira" from EVENT_SCRIPT.
-- Welds are not needed — model is pivoted to the tag part's CFrame and
-- parented under it so it moves with the tag part naturally.
-- Idle + Painting animations, ForceSpray attribute drives spray VFX + look-at.

local function initStandingObserver()
    eventTrove:Add(Observers.observeTag("Event_ChicleteiraBicicleteira", function(tagPart)
        local pivot      = tagPart:GetPivot() * CFrame.fromOrientation(0, math.pi, 0)
        local standTrove = Trove.new()

        local standTemplate = EVENT_SCRIPT:FindFirstChild("Standing Chicleteira Bicicleteira")
        if not standTemplate then
            warn("[ChicleteiraBicicleteira] Missing 'Standing Chicleteira Bicicleteira'")
            return standTrove:WrapClean()
        end

        local standModel = standTrove:Clone(standTemplate)
        standModel:PivotTo(pivot - Vector3.new(0, standModel:GetExtentsSize().Y, 0))
        standModel.Parent = workspace

        local animator = standModel.AnimationController.Animator

        -- Idle track
        local idleAnim  = EVENT_SCRIPT:FindFirstChild("Idle")
        local idleTrack: AnimationTrack?
        if idleAnim then
            idleTrack = animator:LoadAnimation(idleAnim)
            standTrove:Add(function()
                idleTrack:Stop(0)
                idleTrack:Destroy()
            end)
            idleTrack.Looped   = true
            idleTrack.Priority = Enum.AnimationPriority.Idle
            idleTrack:Play()
        end

        -- Painting track
        local paintingAnim  = EVENT_SCRIPT:FindFirstChild("Painting")
        local paintingTrack: AnimationTrack?
        if paintingAnim then
            paintingTrack = animator:LoadAnimation(paintingAnim)
            standTrove:Add(function()
                paintingTrack:Stop(0)
                paintingTrack:Destroy()
            end)
            paintingTrack.Looped   = false
            paintingTrack.Priority = Enum.AnimationPriority.Action4
        end

        -- Shake marker → play sound unless Painting is active
        if idleTrack then
            standTrove:Add(idleTrack:GetMarkerReachedSignal("Shake"):Connect(function()
                if paintingTrack and paintingTrack.IsPlaying then return end
                task.spawn(function()
                    SoundController:PlaySound(
                        ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"].Shake,
                        pivot.Position
                    )
                end)
            end))
        end

        -- Ground sound on spawn
        task.spawn(function()
            SoundController:PlaySound(
                ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"].Ground,
                pivot.Position
            )
        end)

        -- ForceSpray: spray sound → painting anim → VFX on/off
        standTrove:Add(tagPart:GetAttributeChangedSignal("ForceSpray"):Connect(function()
            if not tagPart:GetAttribute("ForceSpray") then return end
            task.spawn(function()
                SoundController:PlaySound(
                    ReplicatedStorage.Sounds.Events["Chicleteira Bicicleteira"].Spray,
                    pivot.Position
                )
            end)
            if paintingTrack then
                paintingTrack:Stop(0)
                paintingTrack:Play()
            end
            task.wait(0.3)
            local handle = standModel:FindFirstChild("Handle", true)
            if handle then
                local vfxInst = handle:FindFirstChild("vfx")
                if vfxInst then
                    VFX.enable(vfxInst)
                    task.wait(1)
                    VFX.disable(vfxInst)
                end
            end
        end))

        -- Spr look-at tick — tracks ForceSpray animal, returns to rest pivot
        standTrove:Add(Timer.Simple(0.1, function()
            local sprayName = tagPart:GetAttribute("ForceSpray")
            local targetPos: Vector3?

            if sprayName then
                for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                    if animal.Name == sprayName and animal.PrimaryPart then
                        local p = animal.PrimaryPart.Position
                        targetPos = Vector3.new(p.X, pivot.Y, p.Z)
                        break
                    end
                end
            end

            if targetPos then
                Spr.target(standModel, 1, 2, {
                    Pivot = CFrame.lookAt(pivot.Position, targetPos)
                        * CFrame.fromOrientation(0, math.pi, 0)
                })
            else
                Spr.target(standModel, 1, 2, { Pivot = pivot })
            end
        end, true))

        return standTrove:WrapClean()
    end, { workspace }))
end

-- ─── Spray tick ──────────────────────────────────────────────────────────────
-- Picks a random tagged stand, finds the closest animal within SPRAY_REACH,
-- sets ForceSpray on the stand part, waits SPRAY_HOLD, appends Paint trait.

local function initSprayTick()
    eventTrove:Add(task.spawn(function()
        while isActive do
            task.wait(math.random(SPRAY_COOLDOWN_MIN, SPRAY_COOLDOWN_MAX))
            if not isActive then break end

            local stands = CollectionService:GetTagged("Event_ChicleteiraBicicleteira")
            if #stands == 0 then continue end

            local stand    = stands[math.random(1, #stands)]
            local standPos = stand:GetPivot().Position

            local closest: Model?
            local closestDist = SPRAY_REACH

            for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                if animal.PrimaryPart then
                    local dist = (animal.PrimaryPart.Position - standPos).Magnitude
                    if dist < closestDist then
                        closest     = animal
                        closestDist = dist
                    end
                end
            end

            if not closest then continue end

            -- Check for existing Paint trait before applying
            local traitsRaw = closest:GetAttribute("Traits") or "[]"
            local ok, traits = pcall(HttpService.JSONDecode, HttpService, traitsRaw)
            if not ok or type(traits) ~= "table" then continue end

            local hasPaint = false
            for _, t in ipairs(traits) do
                if t == PAINT_TRAIT then hasPaint = true break end
            end
            if hasPaint then continue end

            stand:SetAttribute("ForceSpray", closest.Name)
            task.wait(SPRAY_HOLD)

            -- Re-check animal still valid after wait
            if closest and closest.Parent then
                table.insert(traits, PAINT_TRAIT)
                closest:SetAttribute("Traits", HttpService:JSONEncode(traits))
            end

            stand:SetAttribute("ForceSpray", nil)
        end
    end))
end

-- ─── Bike launch ─────────────────────────────────────────────────────────────
-- Waits the server-side 3s delay + startedAt offset, then fires both
-- default lanes. No ritual position support client-side (server handles
-- player CFrame collection; client just runs default lanes locally).

local function initBikeLaunch()
    local eventData = EventController:GetActiveEventData(EVENT_NAME)
    local delay     = (eventData.startedAt + 3) - workspace:GetServerTimeNow()
    if delay > 0 then task.wait(delay) end
    if not isActive then return end

    local maxDuration = 0
    for _, lane in ipairs(DEFAULT_LANES) do
        local startCF, endCF = laneFromDefault(lane)
        local duration = spawnBike(startCF, endCF, BIKE_SPEED, nil)
        if duration > maxDuration then maxDuration = duration end
    end

    -- After bikes clear, stands become active — observer already running
end

-- ─── Main ────────────────────────────────────────────────────────────────────

local function main()
    initStandingObserver()
    initSprayTick()
    initBikeLaunch()

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end

    isActive = false
    eventTrove:Destroy()
end

task.spawn(main)
