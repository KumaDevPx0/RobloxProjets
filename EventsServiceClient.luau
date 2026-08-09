local player = game:GetService("Players").LocalPlayer
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local GuiService = game:GetService("GuiService")
local Packets = require(game.ReplicatedStorage.ModulesFolder.Packets)
local UILoader = require(game.ReplicatedStorage.ModulesFolder.UILoaderFolder.UILoader)
local EventsData = require(game.ReplicatedStorage.ModulesFolder.EventsData.EventsData)
local colorModules = require(game.ReplicatedStorage.ModulesFolder.ColorModules)

local EventsServiceClient = {}

local activeEvents = {}
local countdownThreads = {}
local iconsThread = nil
local luckIconsRunning = false
local nextRandomCountdownThread = nil

local function getEventList()
	return UILoader.EventsFolder():FindFirstChild("EventList")
end
local function getInfoDisplay()
	return UILoader.EventsFolder():FindFirstChild("InfoDisplayMainFrame")
end
local function getEventPopup()
	return UILoader.EventsFolder():FindFirstChild("EventPopup")
end
local function getDeco()
	return UILoader.EventsFolder():FindFirstChild("Deco")
end
local function getNextEventsLabel()
	return UILoader.NextEvents()
end

local function GetEventPreset(eventData)
	if eventData.ServerLuckBonus and eventData.ServerMoneyBonus then
		return "Cosmic"
	end
	if eventData.ServerRateBonus then
		if eventData.ServerRateBonus.Rainbow then
			return "Rainbow"
		end
		if eventData.ServerRateBonus.Diamond then
			return "Diamond"
		end
		if eventData.ServerRateBonus.Gold then
			return "Gold"
		end
		if eventData.ServerRateBonus.Shiny then
			return "Shiny"
		end
	end
	if eventData.ServerLuckBonus then
		return "Toxic"
	end
	if eventData.ServerSpeedBonus then
		return "Frost"
	end
	if eventData.ServerMoneyBonus then
		return "Celestial"
	end
	return nil
end

local function ApplyEventColor(label, eventId, property)
	local data = EventsData[eventId]
	if not data or not label then
		return
	end
	local preset = GetEventPreset(data)
	if not preset then
		return
	end
	colorModules.DailyRewardEffects(label, preset, property or "activeEffectsEvents")
end

local function hasActiveLuckEvent()
	for eventId in pairs(activeEvents) do
		if eventId:find("Luck") then
			return true
		end
	end
	return false
end

local function getActiveLuckNames()
	local names = {}
	for eventId in pairs(activeEvents) do
		if eventId:find("Luck") then
			table.insert(names, eventId)
		end
	end
	return names
end

local function spawnLuckIcon()
	local deco = getDeco()
	if not deco then
		return
	end
	local luckNames = getActiveLuckNames()
	if #luckNames == 0 then
		return
	end
	local luckName = luckNames[math.random(1, #luckNames)]
	local ok, icon = pcall(function()
		return script.LuckIcon:Clone()
	end)
	if not ok or not icon then
		return
	end
	icon.Image = EventsData[luckName].Icon
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.ZIndex = 20
	icon.BackgroundTransparency = 1
	local sizeScale = math.random(30, 70) / 1000
	icon.Size = UDim2.new(sizeScale, 0, sizeScale * 1.45, 0)
	icon.ScaleType = Enum.ScaleType.Fit
	local randomX = math.random(2, 98) / 100
	local randomDrift = math.random(-8, 8) / 100
	local duration = math.random(30, 60) / 10
	icon.Position = UDim2.new(randomX, 0, -0.08, 0)
	icon.ImageTransparency = math.random(0, 3) / 10
	icon.Parent = deco
	TweenService:Create(icon, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
		Position = UDim2.new(randomX + randomDrift, 0, 1.08, 0),
		Rotation = math.random(-45, 45),
		ImageTransparency = 0.1,
	}):Play()
	game:GetService("Debris"):AddItem(icon, duration + 0.5)
end

local function startLuckIcons()
	if luckIconsRunning then
		return
	end
	local deco = getDeco()
	if not deco then
		return
	end
	deco.Visible = true
	luckIconsRunning = true
	iconsThread = task.spawn(function()
		while luckIconsRunning do
			task.spawn(spawnLuckIcon)
			task.wait(math.random(40, 80) / 100)
		end
	end)
end

local function stopLuckIcons()
	luckIconsRunning = false
	if iconsThread then
		pcall(task.cancel, iconsThread)
		iconsThread = nil
	end
	local deco = getDeco()
	if deco then
		deco.Visible = false
		for _, child in ipairs(deco:GetChildren()) do
			if child:IsA("ImageLabel") then
				child:Destroy()
			end
		end
	end
end

local function updateEventSlot(eventId, timeLeft)
	local eventList = getEventList()
	if not eventList then
		return
	end
	local slot = eventList:FindFirstChild(eventId)
	if not slot then
		return
	end
	local timer = slot:FindFirstChild("Timer")
	if timer then
		if timeLeft < 0 then
			timer.Text = "Active"
		else
			timer.Text = string.format("%02d:%02d", math.floor(timeLeft / 60), timeLeft % 60)
		end
	end
end

local function removeEventSlot(eventId)
	local eventList = getEventList()
	if not eventList then
		return
	end
	local slot = eventList:FindFirstChild(eventId)
	if not slot then
		return
	end
	local tween = TweenService:Create(slot, TweenInfo.new(0.3), { Size = UDim2.new(0, 0, 0, 0) })
	tween:Play()
	tween.Completed:Connect(function()
		if slot and slot.Parent then
			slot:Destroy()
		end
	end)
end

local function startCountdown(eventId, timeLeft)
	if not timeLeft or type(timeLeft) ~= "number" then
		return
	end
	if countdownThreads[eventId] then
		pcall(task.cancel, countdownThreads[eventId])
	end
	if timeLeft < 0 then
		updateEventSlot(eventId, -1)
		return
	end
	countdownThreads[eventId] = task.spawn(function()
		local remaining = timeLeft
		while remaining > 0 do
			updateEventSlot(eventId, remaining)
			task.wait(1)
			remaining -= 1
		end
	end)
end

local function startNextRandomTimer(timeLeft)
	if nextRandomCountdownThread then
		pcall(task.cancel, nextRandomCountdownThread)
		nextRandomCountdownThread = nil
	end
	nextRandomCountdownThread = task.spawn(function()
		local remaining = math.max(1, timeLeft)
		local label = getNextEventsLabel()
		if label then
			label.Visible = true
		end
		while true do
			label = getNextEventsLabel()
			if label then
				label.Text = string.format("Next Event: %02d:%02d", math.floor(remaining / 60), remaining % 60)
			end
			task.wait(1)
			remaining -= 1
			if remaining <= 0 then
				remaining = 300
			end
		end
	end)
end

local function addEventSlot(eventId, name, timeLeft)
	local data = EventsData[eventId]
	if not data then
		return
	end
	local eventList = getEventList()
	if not eventList then
		return
	end

	local slot = script.EventSlotTemplate:Clone()
	slot.Name = eventId
	local icon = slot:FindFirstChild("Icon")
	local timer = slot:FindFirstChild("Timer")
	if icon and data.Icon then
		icon.Image = data.Icon
	end
	if timer then
		if timeLeft < 0 then
			timer.Text = "Active"
		else
			timer.Text = string.format("%02d:%02d", math.floor(timeLeft / 60), timeLeft % 60)
		end
	end
	slot.Parent = eventList

	local infoDisplayRoot = getInfoDisplay()
	if infoDisplayRoot then
		local InfoDisplayFrame = infoDisplayRoot:FindFirstChild("InfoDisplayFrame")
		local Header = InfoDisplayFrame and InfoDisplayFrame:FindFirstChild("Header")
		local Body = InfoDisplayFrame and InfoDisplayFrame:FindFirstChild("Body")
		local nameLabel = Header and Header:FindFirstChild("NameLabel")
		local ImageLabel = Header and Header:FindFirstChild("Image")
		local RarityOrTime = Header and Header:FindFirstChild("RarityOrTime")
		local description = Body and Body:FindFirstChild("ItemFrame") and Body.ItemFrame:FindFirstChild("Description")

		slot.HoverButton.MouseEnter:Connect(function()
			colorModules.ClearEffects("activeEffectsEvents")
			if ImageLabel then
				ImageLabel.Image = data.Icon
			end
			if nameLabel then
				nameLabel.Text = data.Name
				ApplyEventColor(nameLabel, eventId)
			end
			if description then
				description.Text = data.Description
			end
			if RarityOrTime then
				RarityOrTime.Text = data.Rarity or ""
				colorModules.applyEffect(RarityOrTime, data.Rarity, true, "activeEffectsEvents")
			end
			infoDisplayRoot.Visible = false
			task.defer(function()
				local inset = GuiService:GetGuiInset()
				local slotPos = slot.AbsolutePosition
				local parentPos = infoDisplayRoot.Parent.Parent.Parent.AbsolutePosition
				local dispSize = infoDisplayRoot.AbsoluteSize
				infoDisplayRoot.Position =
					UDim2.new(0, slotPos.X - parentPos.X + 25, 0, slotPos.Y - parentPos.Y - dispSize.Y + 50 - inset.Y)
				infoDisplayRoot.Visible = true
			end)
		end)

		slot.HoverButton.MouseLeave:Connect(function()
			colorModules.ClearEffects("activeEffectsEvents")
			if nameLabel then
				nameLabel.Text = ""
			end
			if description then
				description.Text = ""
			end
			infoDisplayRoot.Visible = false
		end)
	end

	startCountdown(eventId, timeLeft)
	if eventId:find("Luck") then
		startLuckIcons()
	end
end

local function playEventSound()
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://6042053626"
	sound.Volume = 0.8
	sound.Parent = SoundService
	sound:Play()
	game:GetService("Debris"):AddItem(sound, 5)
end

local function showPopup(name, eventId)
	local popup = getEventPopup()
	if not popup then
		return
	end
	local nameLabel = popup:FindFirstChild("EventName")
	if nameLabel then
		nameLabel.Text = name .. " is now active!"
		colorModules.ClearEffects("activeEffectsEventsPopUp")
		ApplyEventColor(nameLabel, eventId, "activeEffectsEventsPopUp")
	end
	popup.Visible = true
	popup.Position = UDim2.new(0.5, 0, -0.1, 0)
	playEventSound()
	TweenService:Create(popup, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0.2, 0),
	}):Play()
	task.delay(4, function()
		TweenService:Create(popup, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, -0.1, 0),
		}):Play()
		task.delay(0.3, function()
			colorModules.ClearEffects("activeEffectsEventsPopUp")
			popup.Visible = false
		end)
	end)
end

local function handleEventEnd(eventId)
	activeEvents[eventId] = nil
	if countdownThreads[eventId] then
		pcall(task.cancel, countdownThreads[eventId])
		countdownThreads[eventId] = nil
	end
	if eventId:find("Luck") and not hasActiveLuckEvent() then
		stopLuckIcons()
	end
	removeEventSlot(eventId)
end

Packets.Event_Start.listen(function(data)
	activeEvents[data.EventId] = { name = data.Name, timeLeft = data.Duration }
	addEventSlot(data.EventId, data.Name, data.Duration)
	showPopup(data.Name, data.EventId)
	if data.NextEventIn then
		startNextRandomTimer(data.NextEventIn)
	end
end)

Packets.Event_End.listen(function(data)
	handleEventEnd(data.EventId)
	local infoDisplay = getInfoDisplay()
	if infoDisplay then
		infoDisplay.Visible = false
	end
end)

Packets.Event_State.listen(function(data)
	for _, event in ipairs(data) do
		activeEvents[event.EventId] = { name = event.Name, timeLeft = event.TimeLeft }
		local eventList = getEventList()
		if eventList then
			if not eventList:FindFirstChild(event.EventId) then
				addEventSlot(event.EventId, event.Name, event.TimeLeft)
			else
				startCountdown(event.EventId, event.TimeLeft)
			end
		end
	end
end)

Packets.Event_NextRandom.listen(function(data)
	startNextRandomTimer(data)
end)

function EventsServiceClient.init()
	Packets.Event_Request.send({})
end

return EventsServiceClient
