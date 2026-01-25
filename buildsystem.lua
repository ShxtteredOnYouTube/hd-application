-- // CONSTANTS
-- These are general settings for the entire build systems.
-- Keeping them centralized makes it easier to keep things structured and test them with leverage.

local GRID_SIZE = 1
local GRID_TRANSPARENCY = 0.8
local GRID_LERP_SPEED = 14
local MOVE_LERP_SPEED = 18

-- // SERVICES
-- Generic services are fetched beforehand to avoid having to constantly query them midway

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- // DEPENDENCIES

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local camera = workspace.CurrentCamera

-- This remote allows cross environment communication for server authoritative placement
local PlaceRemote = ReplicatedStorage:WaitForChild("PlaceObject")

-- All build models are stored in this folder for easy access for both the server and client 
local ObjectsFolder = ReplicatedStorage:WaitForChild("Objects")

-- These objects are visually modified during runtime to provide visual feedback to the player
-- when they're building.
local Gridlines = workspace:WaitForChild("Gridlines")
local GridTop = Gridlines.TopTexture
local GridBottom = Gridlines.BottomTexture

-- Folder containing only the local player's placed builds
-- This is later used to restrict delete mode to owned objects only
local PlayerBuilds = workspace:WaitForChild("Builds"):WaitForChild(player.Name)

-- // PLACEMENT SOLVER

-- This is where most of the heavy lifting happens.
-- Keeping it separated prevents clutter 

local PlacementSolver = {}

function PlacementSolver.snap(v)
	-- Snap a numeric value to the nearest grid increment.
	-- This ensures placements are deterministic and visually aligned,
	-- preventing uneven spacing and other visual bugs
	return math.floor(v / GRID_SIZE + 0.5) * GRID_SIZE
end

function PlacementSolver.surfaceAllowed(surfaceType, normal)
	-- Determine whether the surface normal is compatible with the object's
	-- intended placement type. This prevents invalid placements early
	-- before any CFrame computation is done.

	if surfaceType == "Ground" then
		return normal.Y > 0.9 -- Nearly upward-facing surfaces
	elseif surfaceType == "Ceiling" then
		return normal.Y < -0.9 -- Nearly downward-facing surfaces
	elseif surfaceType == "Wall" then
		return math.abs(normal.Y) < 0.5 -- Mostly vertical surfaces
	end
	return false
end

function PlacementSolver.computeGroundCF(hitPos, preview, rotY)
	-- When placing on the ground, the model must be lifted by half its height
	-- because models are positioned from their center by default.
	-- This avoids clipping while keeping alignment intuitive.

	local y = hitPos.Y + preview.PrimaryPart.Size.Y / 2
	return CFrame.new(
		PlacementSolver.snap(hitPos.X),
		y,
		PlacementSolver.snap(hitPos.Z)
	) * CFrame.Angles(0, math.rad(rotY), 0)
end

function PlacementSolver.computeCeilingCF(hitPos, preview, rotY)
	-- Ceiling placement mirrors ground logic, except the model is offset downward
	-- so it appears attached rather than intersecting the surface.

	local y = hitPos.Y - preview.PrimaryPart.Size.Y / 2
	return CFrame.new(
		PlacementSolver.snap(hitPos.X),
		y,
		PlacementSolver.snap(hitPos.Z)
	) * CFrame.Angles(0, math.rad(rotY), 0)
end

function PlacementSolver.computeWallCF(hitPos, normal, preview, rotY)
	-- Wall placement requires pushing the model outward from the surface normal.
	-- Using the model’s depth ensures it sits flush instead of intersecting the wall.

	local depth = preview:GetExtentsSize().Z / 2
	local offset = hitPos + normal * depth

	-- Only the vertical axis is snapped here to preserve natural wall alignment
	offset = Vector3.new(
		offset.X,
		PlacementSolver.snap(offset.Y),
		offset.Z
	)

	-- lookAt is used so the preview naturally faces outward from the wall,
	-- regardless of which wall direction is being targeted.
	local lookCF = CFrame.lookAt(offset, offset - normal)
	return lookCF * CFrame.Angles(0, math.rad(rotY), 0)
end

-- // PREVIEW CLASS
-- This class encapsulates all logic related to the client side preview model.
-- Metatables allow everything to stay stateful and isolated.

local PreviewObject = {}
PreviewObject.__index = PreviewObject -- Redirect method lookups to this table

function PreviewObject.new(template)
	-- Create a new preview instance using a cloned template.
	-- This object exists only locally and is never replicated to the server.

	local self = setmetatable({}, PreviewObject)

	self.Model = template:Clone()
	self.Model.Parent = workspace
	self.TargetCF = self.Model.PrimaryPart.CFrame -- Target CFrame the preview lerps toward

	-- Disable collision and apply forcefield visuals so the preview
	-- is clearly distinguishable from placed objects.
	for _, part in self.Model:GetDescendants() do
		if part:IsA("BasePart") and part ~= self.Model.PrimaryPart then
			part.CanCollide = false
			part.Material = Enum.Material.ForceField
			part.Transparency = 0
		end
	end

	return self
end

function PreviewObject:setTarget(cf)
	-- Store the desired CFrame instead of snapping instantly.
	-- This allows smooth interpolation in update().
	self.TargetCF = cf
end

function PreviewObject:update(dt)
	-- Smoothly interpolate toward the target CFrame.
	-- This avoids jitter and makes cursor movement feel responsive and polished.

	self.Model:SetPrimaryPartCFrame(
		self.Model.PrimaryPart.CFrame:Lerp(
			self.TargetCF,
			math.clamp(dt * MOVE_LERP_SPEED, 0, 1)
		)
	)
end

function PreviewObject:setColor(color)
	-- Apply feedback coloring to the entire preview model.
	-- Green indicates valid placement, red indicates invalid placement.
	for _, part in self.Model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Color = color
		end
	end
end

function PreviewObject:destroy()
	-- Explicitly clean up the preview model when exiting build mode
	-- to avoid leaving orphaned instances in the workspace.
	self.Model:Destroy()
end

-- // BUILD SESSION CLASS
-- Represents an active building session.
-- This class contains placement logic, preview updates, and grid interaction.

local BuildSession = {}
BuildSession.__index = BuildSession

function BuildSession.new(objects, surfaceTypes)
	-- Initialize a new build session with available objects and their rules.

	local self = setmetatable({}, BuildSession)

	self.ObjectNames = objects
	self.SurfaceTypes = surfaceTypes
	self.Index = math.random(1, #objects) -- Randomize starting object
	self.RotationY = 0 -- Y-axis rotation state
	self.GridY = 0 -- Smoothed grid height

	self.Preview = nil
	self.RenderConn = nil
	self.PlaceDebounce = false -- Prevents multiple placements per click

	return self
end

function BuildSession:start()
	-- Enter build mode by spawning the preview and enabling the grid.
	-- RenderStepped is used for frame perfect placement updates.

	self:createPreview()
	self:fadeGrid(true)

	self.RenderConn = RunService.RenderStepped:Connect(function(dt)
		self:update(dt)
	end)
end

function BuildSession:createPreview()
	-- Replace the current preview whenever the selected object changes.
	if self.Preview then
		self.Preview:destroy()
	end

	local name = self.ObjectNames[self.Index]
	self.Preview = PreviewObject.new(ObjectsFolder[name])
end

function BuildSession:update(dt)
	-- Core per frame update loop for placement logic.

	local name = self.ObjectNames[self.Index]
	local surfaceType = self.SurfaceTypes[name]

	-- Raycast ignores the preview itself and the grid to avoid false hits.
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { self.Preview.Model, Gridlines }
	params.FilterType = Enum.RaycastFilterType.Blacklist

	local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if not hit then return end

	local valid = PlacementSolver.surfaceAllowed(surfaceType, hit.Normal)
	local targetCF

	-- Only compute placement CFrames if the surface is valid.
	if valid then
		if surfaceType == "Ground" then
			targetCF = PlacementSolver.computeGroundCF(hit.Position, self.Preview.Model, self.RotationY)
			self:updateGrid(dt, hit.Position.Y)
		elseif surfaceType == "Ceiling" then
			targetCF = PlacementSolver.computeCeilingCF(hit.Position, self.Preview.Model, self.RotationY)
			self:updateGrid(dt, hit.Position.Y)
		elseif surfaceType == "Wall" then
			targetCF = PlacementSolver.computeWallCF(hit.Position, hit.Normal, self.Preview.Model, self.RotationY)
			self:updateGrid(dt, hit.Position.Y - 2)
		end
	end

	if targetCF then
		self.Preview:setTarget(targetCF)
	end

	self.Preview:update(dt)

	-- Visual feedback is synchronized between preview and grid.
	local color = valid and Color3.fromRGB(0,255,0) or Color3.fromRGB(255,0,0)
	self.Preview:setColor(color)
	GridTop.Color3 = color
	GridBottom.Color3 = color

	-- Placement input is debounced to prevent rapid-fire placements.
	if valid
		and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		and not self.PlaceDebounce
	then
		self.PlaceDebounce = true
		PlaceRemote:FireServer("place", name, self.Preview.Model.PrimaryPart.CFrame)

		task.delay(0.2, function()
			self.PlaceDebounce = false
		end)
	end
end

function BuildSession:fadeGrid(on)
	-- Smoothly fade the grid in or out depending on build state.
	local t = on and GRID_TRANSPARENCY or 1
	TweenService:Create(GridTop, TweenInfo.new(0.2), {Transparency = t}):Play()
	TweenService:Create(GridBottom, TweenInfo.new(0.2), {Transparency = t}):Play()
end

function BuildSession:updateGrid(dt, targetY)
	-- Smooth grid movement avoids sudden jumps when changing surfaces.
	self.GridY += (targetY - self.GridY) * dt * GRID_LERP_SPEED

	Gridlines.CFrame = CFrame.new(0, self.GridY, 0)
end

function BuildSession:stop()
	-- Cleanly exit build mode and release all resources.
	if self.RenderConn then
		self.RenderConn:Disconnect()
	end
	if self.Preview then
		self.Preview:destroy()
	end
	self:fadeGrid(false)
end

-- // DELETE SESSION CLASS
-- Handles selection and deletion of existing builds.
-- This mode is intentionally isolated from build logic to avoid overlap.

local DeleteSession = {}
DeleteSession.__index = DeleteSession

function DeleteSession.new()
	local self = setmetatable({}, DeleteSession)

	-- Highlight is used instead of altering the model directly,
	-- keeping deletion feedback non destructive.
	self.Highlight = Instance.new("Highlight")
	self.Highlight.FillColor = Color3.fromRGB(255,60,60)
	self.Highlight.OutlineTransparency = 1
	self.Highlight.FillTransparency = 1
	self.Highlight.OutlineColor = Color3.fromRGB(255,0,0)
	self.Highlight.Enabled = false
	self.Highlight.Parent = workspace

	self.Target = nil
	self.DeleteDebounce = false
	self.RenderConn = nil

	return self
end

function DeleteSession:fadeIn()
	-- Fade in animation communicates selection clearly without being abrupt.
	TweenService:Create(
		self.Highlight,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FillTransparency = 0.5, OutlineTransparency = 0 }
	):Play()
end

function DeleteSession:fadeOut()
	-- Fade out animation prevents harsh visual popping when deselecting.
	TweenService:Create(
		self.Highlight,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FillTransparency = 1, OutlineTransparency = 1 }
	):Play()
end

function DeleteSession:start()
	-- Begin delete mode updates.
	self.RenderConn = RunService.RenderStepped:Connect(function()
		self:update()
	end)
end

function DeleteSession:update()
	-- Raycast to detect selectable builds under the cursor.
	local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000)

	local newTarget = nil

	if hit and hit.Instance then
		local model = hit.Instance:FindFirstAncestorOfClass("Model")
		if model and model:IsDescendantOf(PlayerBuilds) then
			-- Restrict deletion to player-owned objects only.
			newTarget = model
		end
	end

	-- Handle highlight transitions when target changes.
	if newTarget ~= self.Target then
		if self.Target then
			self:fadeOut()
			task.delay(0.15, function()
				if not self.Target then
					self.Highlight.Enabled = false
				end
			end)
		end

		self.Target = newTarget

		if self.Target then
			self.Highlight.Adornee = self.Target
			self.Highlight.Enabled = true
			self:fadeIn()
		end
	end

	-- Deletion input is debounced to avoid accidental multi-deletes.
	if self.Target
		and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		and not self.DeleteDebounce
	then
		self.DeleteDebounce = true
		PlaceRemote:FireServer("delete", self.Target)
	end
end

function DeleteSession:stop()
	-- Disconnect render loop and destroy visuals to prevent leaks.
	if self.RenderConn then
		self.RenderConn:Disconnect()
		self.RenderConn = nil
	end

	self.Highlight.Enabled = false
	self.Highlight:Destroy()
end

-- // BUILD CONTROLLER
-- Central coordinator that manages transitions between build, delete,
-- and idle states. This ensures modes never conflict with each other.

local BuildController = {}
BuildController.__index = BuildController

function BuildController.new()
	local self = setmetatable({}, BuildController)

	self.Objects = {}
	self.SurfaceTypes = {}

	-- Cache object names and placement rules once to avoid repeated lookups.
	for _, obj in ObjectsFolder:GetChildren() do
		table.insert(self.Objects, obj.Name)
		self.SurfaceTypes[obj.Name] = obj:GetAttribute("SurfaceType")
	end

	self.Session = nil
	self.DeleteSession = nil
	self.Mode = "None"

	return self
end

function BuildController:enterBuildMode()
	self.Session = BuildSession.new(self.Objects, self.SurfaceTypes)
	self.Session:start()
	self.Mode = "Build"
end

function BuildController:enterDeleteMode()
	-- Ensure build mode is fully stopped before entering delete mode.
	if self.Session then
		self.Session:stop()
		self.Session = nil
	end
	self.DeleteSession = DeleteSession.new()
	self.DeleteSession:start()
	self.Mode = "Delete"
end

function BuildController:exitAll()
	-- Unified cleanup to guarantee no overlapping modes.
	if self.Session then self.Session:stop() end
	if self.DeleteSession then self.DeleteSession:stop() end
	self.Session = nil
	self.DeleteSession = nil
	self.Mode = "None"
end

-- // INPUT HANDLING
-- All user input is funneled through this section so control flow
-- remains predictable and easy to reason about.

local Controller = BuildController.new()

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end

	if input.KeyCode == Enum.KeyCode.E then
		-- E toggles overall build mode on and off.
		if Controller.Mode == "None" then
			Controller:enterBuildMode()
		else
			Controller:exitAll()
		end

	elseif input.KeyCode == Enum.KeyCode.V then
		-- V toggles delete mode from within build mode.
		if Controller.Mode == "Build" then
			Controller:enterDeleteMode()
		elseif Controller.Mode == "Delete" then
			Controller:exitAll()
			Controller:enterBuildMode()
		end

	elseif Controller.Mode == "Build" and Controller.Session then
		-- Build-specific controls are ignored unless actively building.
		if input.KeyCode == Enum.KeyCode.R then
			Controller.Session.RotationY += 90
		elseif input.KeyCode == Enum.KeyCode.X then
			Controller.Session.Index = Controller.Session.Index % #Controller.Objects + 1
			Controller.Session:createPreview()
		elseif input.KeyCode == Enum.KeyCode.Z then
			Controller.Session.Index = (Controller.Session.Index - 2) % #Controller.Objects + 1
			Controller.Session:createPreview()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	-- Reset debounces when mouse input is released to ensure
	-- consistent behavior across different frame rates.
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if Controller.Session then
			Controller.Session.PlaceDebounce = false
		end
		if Controller.DeleteSession then
			Controller.DeleteSession.DeleteDebounce = false
		end
	end
end)
