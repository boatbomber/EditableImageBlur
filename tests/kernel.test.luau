--[[
	Pure property tests for the buffer blur kernel: no Instances, no engine
	image APIs. These pin the blur math's fixed points (uniform images, step
	edges, oversized radii, alpha skipping) and prove the band decomposition
	used by the parallel path reproduces the full-image blur.
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

describe("box radii", function()
	it("Computes the expected radii and support for sigma 2", function()
		expect(Kernel.boxRadiiForSigma(2)).toEqual({ 1, 2, 2 })
		expect(Kernel.supportForSigma(2)).toBe(5)
	end)

	it("Grows the support with sigma", function()
		expect(Kernel.supportForSigma(15)).toBeGreaterThan(Kernel.supportForSigma(5))
		expect(Kernel.supportForSigma(5)).toBeGreaterThan(Kernel.supportForSigma(2))
	end)
end)

describe("blur math", function()
	it("Keeps a uniform image exactly uniform", function()
		local pixels = Helpers.makeBuffer(16, 16, function()
			return 128, 64, 200, 255
		end)
		local expected = Helpers.clone(pixels)

		Kernel.blur(pixels, 16, 16, 3, false)

		expect(Helpers.maxDifference(pixels, expected)).toBe(0)
	end)

	it("Smooths a step edge and leaves pixels beyond the support untouched", function()
		local width, height = 16, 16
		-- Left half black, right half white.
		local pixels = Helpers.makeBuffer(width, height, function(x)
			local value = if x < width / 2 then 0 else 255
			return value, value, value, 255
		end)

		Kernel.blur(pixels, width, height, 2, false)

		local row = 8
		-- Pixels adjacent to the edge blend strictly between the extremes.
		expect(Helpers.channelAt(pixels, width, 7, row, 0)).toBeGreaterThan(0)
		expect(Helpers.channelAt(pixels, width, 7, row, 0)).toBeLessThan(255)
		expect(Helpers.channelAt(pixels, width, 8, row, 0)).toBeGreaterThan(0)
		expect(Helpers.channelAt(pixels, width, 8, row, 0)).toBeLessThan(255)
		-- Sigma 2 has support 5, so columns further than that from the edge
		-- keep their original value on both sides.
		expect(Helpers.channelAt(pixels, width, 0, row, 0)).toBe(0)
		expect(Helpers.channelAt(pixels, width, 1, row, 0)).toBe(0)
		expect(Helpers.channelAt(pixels, width, 14, row, 0)).toBe(255)
		expect(Helpers.channelAt(pixels, width, 15, row, 0)).toBe(255)
	end)

	it("Averages the whole image when the radius exceeds its size", function()
		local width, height = 8, 8
		local pixels = Helpers.makeBuffer(width, height, function(x)
			local value = if x < width / 2 then 0 else 255
			return value, value, value, 255
		end)

		Kernel.blur(pixels, width, height, 100, false)

		for y = 0, height - 1 do
			for x = 0, width - 1 do
				for channel = 0, 2 do
					expect(Helpers.channelAt(pixels, width, x, y, channel)).toBe(128)
				end
				expect(Helpers.channelAt(pixels, width, x, y, 3)).toBe(255)
			end
		end
	end)

	it("Leaves alpha untouched when skipAlpha is true", function()
		local width, height = 16, 16
		local pixels = Helpers.makeBuffer(width, height, Helpers.patternFill)
		local original = Helpers.clone(pixels)

		Kernel.blur(pixels, width, height, 2, true)

		local alphaChanged = false
		local colorChanged = false
		for y = 0, height - 1 do
			for x = 0, width - 1 do
				if Helpers.channelAt(pixels, width, x, y, 3) ~= Helpers.channelAt(original, width, x, y, 3) then
					alphaChanged = true
				end
				if Helpers.channelAt(pixels, width, x, y, 0) ~= Helpers.channelAt(original, width, x, y, 0) then
					colorChanged = true
				end
			end
		end
		expect(alphaChanged).toBe(false)
		expect(colorChanged).toBe(true)
	end)

	it("Blurs alpha when skipAlpha is false", function()
		local width, height = 16, 16
		local pixels = Helpers.makeBuffer(width, height, function(x)
			return 128, 128, 128, if x < width / 2 then 0 else 255
		end)

		Kernel.blur(pixels, width, height, 2, false)

		local edgeAlpha = Helpers.channelAt(pixels, width, 7, 8, 3)
		expect(edgeAlpha).toBeGreaterThan(0)
		expect(edgeAlpha).toBeLessThan(255)
	end)

	it("Handles degenerate image shapes without erroring", function()
		for _, shape in { { 1, 1 }, { 1, 16 }, { 16, 1 }, { 2, 3 } } do
			local width, height = shape[1], shape[2]
			local pixels = Helpers.makeBuffer(width, height, Helpers.patternFill)
			Kernel.blur(pixels, width, height, 5, false)
			expect(buffer.len(pixels)).toBe(width * height * 4)
		end

		-- A 1x1 image must come through unchanged: every pass averages a
		-- single pixel with itself.
		local single = Helpers.makeBuffer(1, 1, function()
			return 10, 20, 30, 40
		end)
		Kernel.blur(single, 1, 1, 5, false)
		expect(Helpers.channelAt(single, 1, 0, 0, 0)).toBe(10)
		expect(Helpers.channelAt(single, 1, 0, 0, 3)).toBe(40)
	end)

	it("Still applies a minimal blur at sigma 0 without erroring", function()
		local pixels = Helpers.makeBuffer(8, 8, function()
			return 50, 100, 150, 255
		end)
		Kernel.blur(pixels, 8, 8, 0, false)
		expect(Helpers.channelAt(pixels, 8, 4, 4, 0)).toBe(50)
	end)
end)

describe("band decomposition", function()
	-- The parallel path requires that blurring padded row bands in isolation
	-- and stitching their centers reproduces the full-image blur bit-exactly.
	-- The kernel's passes read only original pass-input values, so every
	-- output row depends only on source rows within the support, and the
	-- padding supplies all of those rows.
	local function stitchAndCompare(width: number, height: number, sigma: number, workerCount: number): number
		local source = Helpers.makeBuffer(width, height, Helpers.patternFill)
		local stride = width * 4

		local full = Helpers.clone(source)
		Kernel.blur(full, width, height, sigma, false)

		local support = Kernel.supportForSigma(sigma)
		local bands = Bands.compute(height, support, workerCount)
		expect(#bands).toBeGreaterThan(1)

		local stitched = buffer.create(height * stride)
		for _, band in bands do
			local sliceHeight = Bands.sliceHeight(band)
			local slice = buffer.create(sliceHeight * stride)
			buffer.copy(slice, 0, source, Bands.sliceStart(band) * stride, sliceHeight * stride)

			Kernel.blur(slice, width, sliceHeight, sigma, false)

			buffer.copy(stitched, band.centerStart * stride, slice, band.padTop * stride, band.centerCount * stride)
		end

		return Helpers.maxDifference(full, stitched)
	end

	it("Stitched band blurs match the full-image blur exactly", function()
		expect(stitchAndCompare(64, 64, 5, 4)).toBe(0)
		expect(stitchAndCompare(96, 95, 5, 4)).toBe(0)
		expect(stitchAndCompare(32, 128, 2, 8)).toBe(0)
		expect(stitchAndCompare(64, 200, 15, 3)).toBe(0)
	end)
end)
