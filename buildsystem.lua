-- // CONSTANTS
local GRID_SIZE = 1 -- size of the grid in studs (I set it to 1 cus I used the default baseplate grid texture which is based on 1 stud patterns)
local GRID_TRANS = 0.8 --  transparency of the grid
local GRID_LERP = 14 -- lerp speed of the grid
local MOVE_LERP = 18 -- lerp speed of the preview
local ROT_LERP = 16 -- lerp speed when rotating the preview



-- // SERVICES 
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")



-- // DEPENDENCIES
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local mouse = player:GetMouse()
local re = RS:WaitForChild("PlaceObject")

local gridlines = workspace:WaitForChild("Gridlines")
local tex1 = gridlines.TopTexture
local tex2 = gridlines.BottomTexture

local objects = RS:WaitForChild("Objects")

local objectstbl = {} -- to order all objects into an array
for _, obj in objects:GetChildren() do
	table.insert(objectstbl, obj.Name)
end

local sftypes = {} -- same thing here but for surface types
for _, obj in objects:GetChildren() do
	sftypes[obj.Name] = obj:GetAttribute("SurfaceType")
end



-- // VARIABLES
local preview = nil
local index = math.random(1, #objectstbl)
local rotY = 0
local smoothRotY = 0
local gridY = 0
local targetCF = nil
local buildloopconn = nil



-- // FUNCTIONS
function snap(v)
	return math.floor(v/GRID_SIZE + 0.5) * GRID_SIZE -- this is to give us the closest integer that fits on the grid
end

function fadeGrid(on)
	local t = on and GRID_TRANS
	TweenService:Create(tex1, TweenInfo.new(0.2), {Transparency=t}):Play()
	TweenService:Create(tex2, TweenInfo.new(0.2), {Transparency=t}):Play()
end

function createPreview()
	if preview then preview:Destroy() end
	preview = objects[objectstbl[index]]:Clone()
	preview.Parent = workspace
	targetCF = preview.PrimaryPart.CFrame

	for _, p in preview:GetDescendants() do
		if p:IsA("BasePart") and p ~= preview.PrimaryPart then
			p.Material = Enum.Material.ForceField
			p.Transparency = 0
			p.CanCollide = false
		end
	end
end

function exitBuildMode()
	if preview then preview:Destroy() preview = nil end
	fadeGrid(false)
	buildloopconn:Disconnect() -- disconnect the connections when exiting build mode
	buildloopconn = nil
end

function previewColorFeedback(c)
	for _, p in preview:GetDescendants() do
		if p:IsA("BasePart") and p ~= preview.PrimaryPart then
			p.Color = c
		end
	end
end


function gridColorFeedback(c)
	tex1.Color3 = c
	tex2.Color3 = c
end

function enterLoop()
	if buildloopconn then
		buildloopconn:Disconnect() -- disconnect the loop if its already running
	end
	
	
	buildloopconn = RunService.RenderStepped:Connect(function(dt)

						local objType = objectstbl[index]
						local surfacetype = sftypes[objType]

						local params = RaycastParams.new()
						params.FilterDescendantsInstances = {preview, gridlines} -- so we dont start placing on the preview itself (would bug out) or the gridlines
						params.FilterType = Enum.RaycastFilterType.Blacklist

						local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
						local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
						if not hit then return end

						local pos = hit.Position
						local n = hit.Normal
						local surfaceOK = false

						if surfacetype == "Ground" then -- deterministically check if the surface can be built on
							surfaceOK = n.Y > 0.9
						elseif surfacetype == "Ceiling" then 
							surfaceOK = n.Y < -0.9
						elseif surfacetype == "Wall" then 
							surfaceOK = math.abs(n.Y) < 0.2 
						end

						local valid = surfaceOK
						local x,y,z = snap(pos.X), preview.PrimaryPart.Position.Y,  snap(pos.Z) -- selected position relative to the grid

						if surfaceOK then
							if surfacetype == "Ground" then
								y = pos.Y + preview.PrimaryPart.Size.Y/2 -- we fix the y axis during ground placements
								gridY = 0
							elseif surfacetype == "Ceiling" then
								y = pos.Y - preview.PrimaryPart.Size.Y/2
								gridY += (pos.Y - gridY) * math.clamp(dt*GRID_LERP,0,1) -- we also fix the y axis during ceiling placements
							elseif surfacetype == "Wall" then
								y = snap(pos.Y)
								gridY += (y - gridY) * math.clamp(dt*GRID_LERP,0,1) -- but we dynamically change the y axis during wall placements to make the grid appear below the object preview
							end

							local desiredCF = CFrame.new(x,y,z) * CFrame.Angles(0, math.rad(rotY), 0)

							targetCF = desiredCF

							for _, p in workspace:GetPartsInPart(preview.PrimaryPart) do -- this is to check whether the preview is colliding with anything to prevent clipped builds
								if p.CanCollide and p ~= hit.Instance and not p:IsDescendantOf(preview) then
									valid = false
									break
								end
							end
						end

						if targetCF then
							smoothRotY += (rotY - smoothRotY) * math.clamp(dt*ROT_LERP,0,1) -- we smoothly lerp the rotation to add non-tween animations
							local current = preview.PrimaryPart.CFrame
							local target = CFrame.new(targetCF.Position) * CFrame.Angles(0, math.rad(smoothRotY), 0)
							preview:SetPrimaryPartCFrame(current:Lerp(target, math.clamp(dt*MOVE_LERP,0,1))) -- and finally display the afterall cframe product
						end

						-- grid positioning
						if surfacetype == "Ground" then -- as explained earlier, this part also handles the grid positioning, dynamic if building on a wall etc.
							gridlines.Position = Vector3.new(0,0,0)
						elseif surfacetype == "Wall" then
							gridlines.Position = Vector3.new(0,gridY - 1,0)
						else
							gridlines.Position = Vector3.new(0,gridY,0)
						end

						local objColor = valid and Color3.fromRGB(0,255,0) or Color3.fromRGB(255,0,0) -- this determines the color feedback of the grid and preview
						local gridColor = valid and Color3.fromRGB(80,255,80) or Color3.fromRGB(255,80,80)

						previewColorFeedback(objColor)
						gridColorFeedback(gridColor)

						if valid and UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then -- and this tells the server to place the build when you click
							re:FireServer(objType, preview.PrimaryPart.CFrame)
						end
					end)

		player.Character:WaitForChild("Humanoid").Died:Once(exitBuildMode) -- and finally, this makes you automatically exit buildmode if you die

end

function enterBuildMode()
	rotY = 0
	smoothRotY = 0
	index = math.random(1, #objectstbl)
	createPreview()
	fadeGrid(true)
	enterLoop()
end



-- // HANDLE KEYBINDS

UIS.InputBegan:Connect(function(i,gp)
	if gp then return end
	
	if i.KeyCode == Enum.KeyCode.E then
		if buildloopconn then
			exitBuildMode() 
		else 
			enterBuildMode() 
		end
	elseif buildloopconn then
		if i.KeyCode == Enum.KeyCode.R then 
			rotY += 90 
		elseif i.KeyCode == Enum.KeyCode.X then
			index = index % #objectstbl + 1
			createPreview()
		elseif i.KeyCode == Enum.KeyCode.Z then
			index = (index-2) % #objectstbl + 1
			createPreview()
		end
	end
end)
