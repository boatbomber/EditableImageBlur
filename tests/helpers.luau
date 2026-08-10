--!strict

-- Shared buffer helpers for the test suite. All coordinates are 0-based to
-- match the kernel's u8 RGBA buffer layout.

local Helpers = {}

-- Builds a width*height*4 u8 RGBA buffer from a per-pixel fill function
-- returning four 0-255 channel values.
function Helpers.makeBuffer(
	width: number,
	height: number,
	fillFn: (x: number, y: number) -> (number, number, number, number)
): buffer
	local pixels = buffer.create(width * height * 4)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local base = (y * width + x) * 4
			local r, g, b, a = fillFn(x, y)
			buffer.writeu8(pixels, base, r)
			buffer.writeu8(pixels, base + 1, g)
			buffer.writeu8(pixels, base + 2, b)
			buffer.writeu8(pixels, base + 3, a)
		end
	end
	return pixels
end

-- Reads one channel (0 = R .. 3 = A) at pixel (x, y).
function Helpers.channelAt(pixels: buffer, width: number, x: number, y: number, channel: number): number
	return buffer.readu8(pixels, (y * width + x) * 4 + channel)
end

function Helpers.clone(pixels: buffer): buffer
	local copy = buffer.create(buffer.len(pixels))
	buffer.copy(copy, 0, pixels, 0, buffer.len(pixels))
	return copy
end

-- Largest per-byte absolute difference between two equal-length buffers.
function Helpers.maxDifference(a: buffer, b: buffer): number
	assert(buffer.len(a) == buffer.len(b), "buffers differ in length")
	local worst = 0
	for i = 0, buffer.len(a) - 1 do
		local difference = math.abs(buffer.readu8(a, i) - buffer.readu8(b, i))
		if difference > worst then
			worst = difference
		end
	end
	return worst
end

-- A deterministic, non-constant fill so blurs see realistic data.
function Helpers.patternFill(x: number, y: number): (number, number, number, number)
	return (x * 7 + y * 13) % 256, (x * 3 + y * 29) % 256, (x + y * 5) % 256, (x * 11 + y * 2) % 256
end

-- The test runner mounts a copy of the package inside the plugin tree (where
-- parallel workers can run) and points PackageUnderTest at it; fall back to
-- the plain package for other environments.
function Helpers.resolvePackageUnderTest(): ModuleScript
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local TestProject = ReplicatedStorage:WaitForChild("TestProject")
	local packagePointer = TestProject:FindFirstChild("PackageUnderTest") :: ObjectValue?
	return (
		if packagePointer
			then packagePointer.Value
			else ReplicatedStorage:WaitForChild("Packages"):WaitForChild("EditableImageBlur")
	) :: ModuleScript
end

-- run-in-roblox executes entry scripts from a plugin in Studio edit mode,
-- where game scripts never run: the only context whose scripts execute is the
-- plugin's own tree. Mounting a copy of the package inside the entry script
-- lets the parallel blur's workers actually start (the same path a plugin
-- consumer gets).
function Helpers.mountPackageUnderTest(host: Instance): ModuleScript
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local packageUnderTest = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("EditableImageBlur"):Clone()
	packageUnderTest.Parent = host
	return packageUnderTest :: ModuleScript
end

return Helpers
