--[[
	Exhaustive unit tests for the band-layout math. Band layout
	is the likeliest place for off-by-one errors, so the invariants are
	checked with plain Lua across thousands of (height, sigma, workerCount)
	combinations and only violations surface through Jest.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")
local TestProject = ReplicatedStorage:WaitForChild("TestProject")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Helpers = require(TestProject:WaitForChild("helpers"))
local EditableImageBlurModule = Helpers.resolvePackageUnderTest()

local Kernel = require(EditableImageBlurModule:WaitForChild("Kernel"))
local Bands = require(EditableImageBlurModule:WaitForChild("Bands"))

describe("band layout", function()
	it("Splits an easy case evenly with correct padding", function()
		-- 100 rows, support 5, 4 workers: bands of 25 with interior padding 5.
		local bands = Bands.compute(100, 5, 4)
		expect(#bands).toBe(4)
		expect(bands[1]).toEqual({ centerStart = 0, centerCount = 25, padTop = 0, padBottom = 5 })
		expect(bands[2]).toEqual({ centerStart = 25, centerCount = 25, padTop = 5, padBottom = 5 })
		expect(bands[3]).toEqual({ centerStart = 50, centerCount = 25, padTop = 5, padBottom = 5 })
		expect(bands[4]).toEqual({ centerStart = 75, centerCount = 25, padTop = 5, padBottom = 0 })
	end)

	it("Terminates and clamps when workerCount is pathological", function()
		-- The public API validates workerCount, but Bands.compute itself must
		-- terminate for any input (math.huge survived math.floor and made the
		-- reduction loop spin forever before the clamp).
		expect(#Bands.compute(100, 5, math.huge)).toBeGreaterThanOrEqual(1)
		expect(#Bands.compute(100, 5, 0 / 0)).toBe(1)
		expect(#Bands.compute(100, 5, 0)).toBe(1)
	end)

	it("Exposes slice geometry consistent with its band layout", function()
		local bands = Bands.compute(100, 5, 4)
		for _, band in bands do
			expect(Bands.sliceHeight(band)).toBe(band.padTop + band.centerCount + band.padBottom)
			expect(Bands.sliceStart(band)).toBe(band.centerStart - band.padTop)
			expect(Bands.sliceStart(band)).toBeGreaterThanOrEqual(0)
		end
	end)

	it("Collapses to a single band when the image is too short to split", function()
		-- Support 44 (sigma 15) cannot band a 32-row image at all.
		local bands = Bands.compute(32, Kernel.supportForSigma(15), 8)
		expect(#bands).toBe(1)
		expect(bands[1]).toEqual({ centerStart = 0, centerCount = 32, padTop = 0, padBottom = 0 })
	end)

	it("Holds every invariant across the exhaustive matrix", function()
		local heights = {}
		for height = 1, 64 do
			table.insert(heights, height)
		end
		for _, height in { 100, 511, 512, 1024 } do
			table.insert(heights, height)
		end

		local sigmas = {}
		for sigma = 1, 20 do
			table.insert(sigmas, sigma)
		end
		table.insert(sigmas, 50)

		local casesChecked = 0
		local function fail(height: number, support: number, workerCount: number, message: string)
			error(string.format("height=%d support=%d workerCount=%d: %s", height, support, workerCount, message), 0)
		end

		for _, height in heights do
			for _, sigma in sigmas do
				local support = Kernel.supportForSigma(sigma)
				for workerCount = 1, 8 do
					local bands = Bands.compute(height, support, workerCount)
					casesChecked += 1

					if #bands < 1 or #bands > workerCount then
						fail(height, support, workerCount, "band count " .. #bands .. " out of range")
					end

					-- Centers must tile [0, height) exactly once, in order.
					local expectedStart = 0
					for index, band in bands do
						if band.centerStart ~= expectedStart then
							fail(
								height,
								support,
								workerCount,
								"band " .. index .. " does not start where the previous ended"
							)
						end
						if band.centerCount < 1 then
							fail(height, support, workerCount, "band " .. index .. " is empty")
						end
						expectedStart += band.centerCount

						local centerEnd = band.centerStart + band.centerCount - 1
						-- Padding must equal the support unless truncated by the image edge.
						if band.padTop ~= math.min(support, band.centerStart) then
							fail(height, support, workerCount, "band " .. index .. " padTop " .. band.padTop)
						end
						if band.padBottom ~= math.min(support, height - 1 - centerEnd) then
							fail(height, support, workerCount, "band " .. index .. " padBottom " .. band.padBottom)
						end
						-- The slice must stay inside the image.
						if band.centerStart - band.padTop < 0 or centerEnd + band.padBottom > height - 1 then
							fail(height, support, workerCount, "band " .. index .. " slice leaves the image")
						end
					end
					if expectedStart ~= height then
						fail(
							height,
							support,
							workerCount,
							"bands cover " .. expectedStart .. " of " .. height .. " rows"
						)
					end

					-- When banding happened at all, every band must be taller
					-- than the support so its padding is fully backed by real
					-- rows.
					if #bands > 1 then
						for index, band in bands do
							if band.centerCount <= support then
								fail(
									height,
									support,
									workerCount,
									"band " .. index .. " is not taller than the support"
								)
							end
						end
					end
				end
			end
		end

		expect(casesChecked).toBe((64 + 4) * 21 * 8)
	end)
end)
