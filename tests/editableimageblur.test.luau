--[[
	API-level tests for the public module: in-place buffer semantics, config
	validation, the downscaleFactor resample path, sync/async equivalence,
	request isolation under concurrency, and one real
	EditableImage roundtrip to prove buffer-format compatibility with
	ReadPixelsBuffer/WritePixelsBuffer.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")
local TestProject = ReplicatedStorage:WaitForChild("TestProject")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Helpers = require(TestProject:WaitForChild("helpers"))
local EditableImageBlurModule = Helpers.resolvePackageUnderTest()

local EditableImageBlur = require(EditableImageBlurModule)

local Blur = EditableImageBlur.Blur
local BlurAsync = EditableImageBlur.BlurAsync

describe("config validation", function()
	it("Errors when pixelBuffer is missing", function()
		expect(function()
			Blur({ width = 4, height = 4 } :: any)
		end).toThrow()
	end)

	it("Errors when the buffer length does not match the dimensions", function()
		expect(function()
			Blur({ pixelBuffer = buffer.create(4 * 4 * 4), width = 4, height = 5 })
		end).toThrow()
	end)

	it("Errors when dimensions are missing or invalid", function()
		expect(function()
			Blur({ pixelBuffer = buffer.create(16) } :: any)
		end).toThrow()
		expect(function()
			Blur({ pixelBuffer = buffer.create(16), width = 0, height = 4 })
		end).toThrow()
	end)

	it("Errors when downscaleFactor is out of range", function()
		expect(function()
			Blur({ pixelBuffer = buffer.create(8 * 8 * 4), width = 8, height = 8, downscaleFactor = 0 })
		end).toThrow()
		expect(function()
			Blur({ pixelBuffer = buffer.create(8 * 8 * 4), width = 8, height = 8, downscaleFactor = 2 })
		end).toThrow()
	end)

	it("Errors when dimensions are fractional even if the byte count matches", function()
		-- 2.5 * 8 * 4 == 80, so only an integrality check can reject this.
		expect(function()
			Blur({ pixelBuffer = buffer.create(80), width = 2.5, height = 8 })
		end).toThrow()
	end)

	it("Errors when blurRadius is not a finite non-negative number", function()
		local pixels = buffer.create(8 * 8 * 4)
		expect(function()
			Blur({ pixelBuffer = pixels, width = 8, height = 8, blurRadius = 0 / 0 })
		end).toThrow()
		expect(function()
			Blur({ pixelBuffer = pixels, width = 8, height = 8, blurRadius = -1 })
		end).toThrow()
		expect(function()
			Blur({ pixelBuffer = pixels, width = 8, height = 8, blurRadius = math.huge })
		end).toThrow()
	end)

	it("Errors when skipAlpha is a truthy non-boolean", function()
		expect(function()
			Blur({ pixelBuffer = buffer.create(8 * 8 * 4), width = 8, height = 8, skipAlpha = 1 } :: any)
		end).toThrow()
	end)

	it("Errors when workerCount or syncThreshold is invalid", function()
		local pixels = buffer.create(8 * 8 * 4)
		expect(function()
			BlurAsync({ pixelBuffer = pixels, width = 8, height = 8, workerCount = math.huge })
		end).toThrow()
		expect(function()
			BlurAsync({ pixelBuffer = pixels, width = 8, height = 8, workerCount = 0 })
		end).toThrow()
		expect(function()
			BlurAsync({ pixelBuffer = pixels, width = 8, height = 8, syncThreshold = -1 })
		end).toThrow()
	end)
end)

describe("Blur", function()
	it("Modifies the buffer in place and returns nothing", function()
		local pixels = Helpers.makeBuffer(16, 16, function(x)
			local value = if x < 8 then 0 else 255
			return value, value, value, 255
		end)

		local result = (Blur :: any)({ pixelBuffer = pixels, width = 16, height = 16, blurRadius = 2 })

		expect(result).toBeNil()
		-- The edge column blended in place.
		local edge = Helpers.channelAt(pixels, 16, 7, 8, 0)
		expect(edge).toBeGreaterThan(0)
		expect(edge).toBeLessThan(255)
	end)

	it("Keeps a uniform image exactly uniform", function()
		local pixels = Helpers.makeBuffer(16, 16, function()
			return 128, 64, 200, 255
		end)
		local original = Helpers.clone(pixels)

		Blur({ pixelBuffer = pixels, width = 16, height = 16, blurRadius = 3 })

		expect(Helpers.maxDifference(pixels, original)).toBe(0)
	end)

	it("Leaves alpha untouched when skipAlpha is true", function()
		local pixels = Helpers.makeBuffer(16, 16, Helpers.patternFill)
		local original = Helpers.clone(pixels)

		Blur({ pixelBuffer = pixels, width = 16, height = 16, blurRadius = 2, skipAlpha = true })

		for y = 0, 15 do
			for x = 0, 15 do
				expect(Helpers.channelAt(pixels, 16, x, y, 3)).toBe(Helpers.channelAt(original, 16, x, y, 3))
			end
		end
	end)
end)

describe("downscaleFactor", function()
	it("Keeps a uniform image uniform through the resample round trip", function()
		local pixels = Helpers.makeBuffer(32, 32, function()
			return 150, 150, 150, 255
		end)
		local original = Helpers.clone(pixels)

		Blur({ pixelBuffer = pixels, width = 32, height = 32, blurRadius = 2, downscaleFactor = 0.5 })

		expect(Helpers.maxDifference(pixels, original)).toBe(0)
	end)

	it("Still blurs edges when downscaled", function()
		local pixels = Helpers.makeBuffer(32, 32, function(x)
			local value = if x < 16 then 0 else 255
			return value, value, value, 255
		end)

		Blur({ pixelBuffer = pixels, width = 32, height = 32, blurRadius = 2, downscaleFactor = 0.5 })

		local edge = Helpers.channelAt(pixels, 32, 15, 16, 0)
		expect(edge).toBeGreaterThan(0)
		expect(edge).toBeLessThan(255)
	end)

	it("Preserves alpha bytes exactly when combined with skipAlpha", function()
		local pixels = Helpers.makeBuffer(32, 32, function(x, y)
			return 100, 100, 100, (x * 31 + y * 7) % 256
		end)
		local original = Helpers.clone(pixels)

		Blur({ pixelBuffer = pixels, width = 32, height = 32, blurRadius = 2, downscaleFactor = 0.5, skipAlpha = true })

		for y = 0, 31 do
			for x = 0, 31 do
				expect(Helpers.channelAt(pixels, 32, x, y, 3)).toBe(Helpers.channelAt(original, 32, x, y, 3))
			end
		end
	end)
end)

describe("BlurAsync", function()
	local function compareAsyncToSync(width: number, height: number, sigma: number, workerCount: number): number
		local syncPixels = Helpers.makeBuffer(width, height, Helpers.patternFill)
		local asyncPixels = Helpers.clone(syncPixels)

		Blur({ pixelBuffer = syncPixels, width = width, height = height, blurRadius = sigma })
		BlurAsync({
			pixelBuffer = asyncPixels,
			width = width,
			height = height,
			blurRadius = sigma,
			workerCount = workerCount,
			syncThreshold = 0,
		})

		return Helpers.maxDifference(syncPixels, asyncPixels)
	end

	-- The kernel's exact band decomposition makes the parallel result
	-- bit-identical to the synchronous one, so no tolerance is needed.
	it("Matches the synchronous blur on a small image", function()
		expect(compareAsyncToSync(64, 64, 5, 4)).toBe(0)
	end)

	it("Engages the worker pool", function()
		-- A fallback would produce bit-identical output, so equivalence alone
		-- cannot prove the parallel path ran; the pool's completion counter can.
		compareAsyncToSync(128, 128, 5, 4)
		-- The bin lives inside the module in plugin contexts and in
		-- ServerScriptService when a server is running.
		local container = EditableImageBlurModule:FindFirstChild("EditableImageBlurWorkers")
			or game:GetService("ServerScriptService"):FindFirstChild("EditableImageBlurWorkers")
		expect(container).never.toBeNil()
		expect((container :: Folder):GetAttribute("Completed") :: number).toBeGreaterThan(0)
	end)

	it("Matches the synchronous blur on non-square images", function()
		expect(compareAsyncToSync(300, 200, 5, 4)).toBe(0)
		expect(compareAsyncToSync(511, 301, 5, 6)).toBe(0)
	end)

	it("Matches the synchronous blur at 512x512 across sigmas", function()
		expect(compareAsyncToSync(512, 512, 1, 6)).toBe(0)
		expect(compareAsyncToSync(512, 512, 5, 6)).toBe(0)
		expect(compareAsyncToSync(512, 512, 15, 6)).toBe(0)
	end)

	it("Returns without yielding below the sync threshold", function()
		local pixels = Helpers.makeBuffer(32, 32, Helpers.patternFill)
		local thread = coroutine.create(function()
			BlurAsync({ pixelBuffer = pixels, width = 32, height = 32, blurRadius = 2 })
		end)
		coroutine.resume(thread)
		expect(coroutine.status(thread)).toBe("dead")
	end)

	it("Falls back to the synchronous path when the image is too short to band", function()
		-- Sigma 15 has support 44, so 8 rows cannot band at all.
		local pixels = Helpers.makeBuffer(400, 8, Helpers.patternFill)
		local expected = Helpers.clone(pixels)
		Blur({ pixelBuffer = expected, width = 400, height = 8, blurRadius = 15 })

		BlurAsync({ pixelBuffer = pixels, width = 400, height = 8, blurRadius = 15, syncThreshold = 0 })

		-- Identical code path, so the results are identical too.
		expect(Helpers.maxDifference(pixels, expected)).toBe(0)
	end)

	it("Keeps concurrent requests isolated", function()
		local values = { 40, 90, 140, 190 }
		local buffers = {}
		local remaining = #values

		for index, value in values do
			local pixels = Helpers.makeBuffer(128, 128, function()
				return value, value, value, 255
			end)
			buffers[index] = pixels
			task.spawn(function()
				BlurAsync({
					pixelBuffer = pixels,
					width = 128,
					height = 128,
					blurRadius = 2,
					workerCount = 2,
					syncThreshold = 0,
				})
				remaining -= 1
			end)
		end

		local deadline = os.clock() + 10
		while remaining > 0 do
			if os.clock() > deadline then
				error("concurrent BlurAsync calls did not complete in time")
			end
			task.wait()
		end

		-- A uniform image blurs to itself, so any cross-request
		-- contamination would show up as foreign values.
		for index, value in values do
			for i = 0, buffer.len(buffers[index]) - 1, 4 do
				expect(buffer.readu8(buffers[index], i)).toBe(value)
			end
		end
	end)
end)

describe("EditableImage interop", function()
	it("Round-trips through ReadPixelsBuffer and WritePixelsBuffer", function()
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(64, 64) })
		image:WritePixelsBuffer(Vector2.zero, image.Size, Helpers.makeBuffer(64, 64, Helpers.patternFill))

		local pixels = image:ReadPixelsBuffer(Vector2.zero, image.Size)
		Blur({ pixelBuffer = pixels, width = 64, height = 64, blurRadius = 3 })
		image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)

		local written = image:ReadPixelsBuffer(Vector2.zero, image.Size)
		expect(Helpers.maxDifference(written, pixels)).toBe(0)
		image:Destroy()
	end)
end)
