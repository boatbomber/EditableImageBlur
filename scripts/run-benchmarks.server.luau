--[[
	Performance benchmarks for EditableImageBlur, run through run-in-roblox by
	scripts/bench.sh against the same place the tests build. Each cell times a
	whole blur call with os.clock across several runs and prints the best,
	median, and mean, since the best run is the one least disturbed by the
	garbage collector and the scheduler.

	The library is a pure buffer manipulation library, so these are pure
	kernel numbers: ReadPixelsBuffer/WritePixelsBuffer costs are the caller's
	and are not included. Variants per size/sigma cell:
	- "Blur" — the synchronous kernel at full resolution.
	- "Blur downscale 0.5" — the synchronous kernel on a half-size working
	  copy, including both resamples.
	- "BlurAsync xN" — the parallel path across N workers, including the
	  scatter/gather copies and phase-boundary latency (wall time as the
	  caller experiences it).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestProject = ReplicatedStorage:WaitForChild("TestProject")

local Helpers = require(TestProject:WaitForChild("helpers"))

-- Mount the package inside this plugin script so the parallel blur's workers
-- can start (see Helpers.mountPackageUnderTest).
local packageUnderTest = Helpers.mountPackageUnderTest(script)

local EditableImageBlur = require(packageUnderTest) :: any

local SIZES = { 128, 256, 512, 1024 }
local SIGMAS = { 2, 5, 15 }
local ASYNC_WORKER_COUNTS = { 2, 4, 6, 8 }

local RUNS_BY_SIZE = {
	[128] = 50,
	[256] = 50,
	[512] = 50,
	[1024] = 20,
}

-- Every blurred result feeds this accumulator so the compiler cannot treat a
-- benchmark's work as dead and drop it. Its final value is printed at the end
-- purely to keep it live.
local sink = 0

--[[
	Runs work `runs` times after one untimed warmup and returns the elapsed
	seconds of each run, sorted fastest first.
]]
local function measure(runs: number, work: () -> ()): { number }
	work()
	local times = table.create(runs)
	for runIndex = 1, runs do
		local startTime = os.clock()
		work()
		times[runIndex] = os.clock() - startTime
	end
	table.sort(times)
	return times
end

--[[
	Prints one benchmark cell's timings. It yields afterward so a long line of
	benchmarks never holds the scheduler long enough for Roblox to fault the
	script for running away.
]]
local function bench(label: string, runs: number, work: () -> ())
	local times = measure(runs, work)
	local total = 0
	for _, elapsed in times do
		total += elapsed
	end
	local median = times[math.ceil(#times / 2)]
	print(
		string.format(
			"%s: best %.2f ms, median %.2f ms, mean %.2f ms over %d runs",
			label,
			times[1] * 1000,
			median * 1000,
			(total / #times) * 1000,
			#times
		)
	)
	task.wait()
end

--[[
	Builds a size*size*4 u8 pixel buffer with per-pixel variety (the same
	pattern the tests validate against, but opaque), so the blur sees varied
	data; a constant fill could be folded away.
]]
local function makePixelBuffer(size: number): buffer
	return Helpers.makeBuffer(size, size, function(x, y)
		local r, g, b = Helpers.patternFill(x, y)
		return r, g, b, 255
	end)
end

for _, size in SIZES do
	print("")
	print(string.format("== %dx%d ==", size, size))

	local runs = RUNS_BY_SIZE[size]
	local source = makePixelBuffer(size)
	-- Blur the same scratch copy every run; the blur is idempotent enough for
	-- timing purposes and re-copying the source would pollute the numbers.
	local pixels = buffer.create(size * size * 4)

	for _, sigma in SIGMAS do
		buffer.copy(pixels, 0, source, 0, buffer.len(source))
		bench(string.format("sigma %2d  Blur", sigma), runs, function()
			EditableImageBlur.Blur({
				pixelBuffer = pixels,
				width = size,
				height = size,
				blurRadius = sigma,
			})
			sink += buffer.readu8(pixels, 0)
		end)

		buffer.copy(pixels, 0, source, 0, buffer.len(source))
		bench(string.format("sigma %2d  Blur downscale 0.5", sigma), runs, function()
			EditableImageBlur.Blur({
				pixelBuffer = pixels,
				width = size,
				height = size,
				blurRadius = sigma,
				downscaleFactor = 0.5,
			})
			sink += buffer.readu8(pixels, 0)
		end)

		for _, workerCount in ASYNC_WORKER_COUNTS do
			buffer.copy(pixels, 0, source, 0, buffer.len(source))
			bench(string.format("sigma %2d  BlurAsync x%d", sigma, workerCount), runs, function()
				EditableImageBlur.BlurAsync({
					pixelBuffer = pixels,
					width = size,
					height = size,
					blurRadius = sigma,
					workerCount = workerCount,
					syncThreshold = 0,
				})
				sink += buffer.readu8(pixels, 0)
			end)
		end
	end
end

print("")
print("checksum sink: " .. sink)

-- run-in-roblox can drop log output that is still queued when the place
-- closes, so give it a moment to drain before returning.
task.wait(2)

return nil
