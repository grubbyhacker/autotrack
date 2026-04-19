local ReplicatedStorage = game:GetService("ReplicatedStorage")

local T = require(script.Parent.TestUtils)
local UIState = require(script.Parent.UIState)
local StatsPanel = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("StatsPanel"))

local TestPhase12_5 = {}

function TestPhase12_5.run()
	-- UIState.setCarAttitude sets both heading and pitch attributes
	do
		UIState.setCarAttitude(270, 3)
		local folder = UIState.getStateFolder()
		local heading = folder:GetAttribute("current_heading_deg")
		local pitch = folder:GetAttribute("current_pitch_deg")
		T.expect("phase12_5_attitude_heading", heading == 270, ("expected heading 270, got %s"):format(tostring(heading)))
		T.expect("phase12_5_attitude_pitch", pitch == 3, ("expected pitch 3, got %s"):format(tostring(pitch)))
	end

	-- StatsPanel.setHeading produces a compass label
	do
		StatsPanel.setHeading(135)
		local label = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("HUDRegistry")).get().headingLabel
		T.expect(
			"phase12_5_heading_label_se",
			string.find(label.Text, "SE") ~= nil,
			("expected SE in heading label, got: %s"):format(label.Text)
		)
	end

	-- StatsPanel.setPitch formats with sign and degree symbol
	do
		StatsPanel.setPitch(-8)
		local label = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("HUDRegistry")).get().pitchLabel
		T.expect(
			"phase12_5_pitch_label_negative",
			string.find(label.Text, "-8") ~= nil,
			("expected -8 in pitch label, got: %s"):format(label.Text)
		)
	end

	-- StatusPanel.setExplanation writes to reasoningLabel, not bottomDock
	do
		local StatusPanel = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("StatusPanel"))
		StatusPanel.setExplanation("test reasoning")
		local hud = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("HUDRegistry")).get()
		T.expect(
			"phase12_5_explanation_in_reasoning_bar",
			hud.reasoningLabel.Text == "test reasoning",
			("expected reasoningLabel='test reasoning', got '%s'"):format(hud.reasoningLabel.Text)
		)
	end

	-- Input box clears on focus
	do
		local hud = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("HUDRegistry")).get()
		T.expect(
			"phase12_5_input_clear_on_focus",
			hud.inputBox.ClearTextOnFocus == true,
			"expected inputBox.ClearTextOnFocus == true"
		)
	end

	-- Set Baseline button exists
	do
		local hud = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("HUDRegistry")).get()
		T.expect(
			"phase12_5_set_baseline_button_exists",
			hud.setBaselineButton ~= nil,
			"expected setBaselineButton ref to exist"
		)
	end

	-- Overview button exists
	do
		local hud = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("HUDRegistry")).get()
		T.expect(
			"phase12_5_overview_button_exists",
			hud.overviewButton ~= nil,
			"expected overviewButton ref to exist"
		)
	end

	-- Sector labels — at least one BillboardGui on the anchor of sector 2
	do
		local track = workspace:FindFirstChild("Track")
		local folder = track and track:FindFirstChild("Sector_02")
		local anchor = folder and folder:FindFirstChild("Anchor")
		local label = anchor and anchor:FindFirstChildWhichIsA("BillboardGui")
		T.expect(
			"phase12_5_sector_label_exists",
			label ~= nil,
			"expected BillboardGui on Sector_02/Anchor"
		)
		if label then
			local textLabel = label:FindFirstChildWhichIsA("TextLabel")
			T.expect(
				"phase12_5_sector_label_text",
				textLabel ~= nil and string.find(textLabel.Text, "S2") ~= nil,
				("expected 'S2' in sector label, got: %s"):format(
					tostring(textLabel and textLabel.Text)
				)
			)
		end
	end
end

return TestPhase12_5
