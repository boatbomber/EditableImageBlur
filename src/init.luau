--!strict

--[[
	EditableImageBlur v0.4 — fast Gaussian-approximating blur for u8 RGBA
	pixel buffers, the format used by EditableImage:ReadPixelsBuffer and
	WritePixelsBuffer.

	This is a pure buffer-manipulation library: it never touches an
	EditableImage. Read the pixels yourself, blur in place, write them back:

		local EditableImageBlur = require(Packages.EditableImageBlur)

		local pixels = image:ReadPixelsBuffer(Vector2.zero, image.Size)
		EditableImageBlur.Blur({
			pixelBuffer = pixels,
			width = image.Size.X,
			height = image.Size.Y,
			blurRadius = 3,
		})
		image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)

	Blur is synchronous and never yields. BlurAsync blurs on an internal actor
	pool (parallel Luau) and may yield; small images and any situation where
	the pool cannot help fall back to the synchronous path and return without
	yielding. Both modify the buffer in place and return nothing.
]]

local Kernel = require(script.Kernel)
local Resample = require(script.Resample)
local Dispatcher = require(script.Dispatcher)

local DEFAULT_SIGMA = 2
local DEFAULT_WORKER_COUNT = 6
local DEFAULT_SYNC_THRESHOLD = 256 * 256

export type BlurConfig = {
	pixelBuffer: buffer, -- u8 RGBA pixel data, row-major; modified in place
	width: number, -- image width in pixels
	height: number, -- image height in pixels
	blurRadius: number?, -- sigma of the gaussian blur (default 2)
	skipAlpha: boolean?, -- whether to leave the alpha channel untouched
	downscaleFactor: number?, -- (0, 1]: blur a downsampled copy for speed, upsample back on completion
}

export type BlurAsyncConfig = BlurConfig & {
	workerCount: number?, -- parallel workers to split the image across (default 6)
	syncThreshold: number?, -- images with fewer working pixels than this blur synchronously (default 256*256)
}

local function validate(config: BlurConfig): (buffer, number, number)
	local pixels = config.pixelBuffer
	assert(typeof(pixels) == "buffer", "EditableImageBlur: config.pixelBuffer must be a buffer")

	local width, height = config.width, config.height
	assert(
		type(width) == "number" and type(height) == "number" and width >= 1 and height >= 1,
		"EditableImageBlur: config.width and config.height must be positive"
	)
	-- Fractional dimensions can still satisfy the length check below (for
	-- example 3.5 * 8 * 4 == 112) but produce a misaligned row stride, so the
	-- kernel would read across pixel boundaries.
	assert(width % 1 == 0 and height % 1 == 0, "EditableImageBlur: config.width and config.height must be integers")
	assert(
		buffer.len(pixels) == width * height * 4,
		"EditableImageBlur: config.pixelBuffer length does not match width * height * 4"
	)

	local blurRadius = config.blurRadius
	assert(
		blurRadius == nil or (type(blurRadius) == "number" and blurRadius >= 0 and blurRadius < math.huge),
		"EditableImageBlur: config.blurRadius must be a finite, non-negative number"
	)
	assert(
		config.skipAlpha == nil or type(config.skipAlpha) == "boolean",
		"EditableImageBlur: config.skipAlpha must be a boolean"
	)
	local downscaleFactor = config.downscaleFactor
	assert(
		downscaleFactor == nil or (type(downscaleFactor) == "number" and downscaleFactor > 0 and downscaleFactor <= 1),
		"EditableImageBlur: config.downscaleFactor must be in (0, 1]"
	)

	return pixels, width, height
end

local function validateAsync(config: BlurAsyncConfig)
	local workerCount = config.workerCount
	assert(
		workerCount == nil or (type(workerCount) == "number" and workerCount >= 1 and workerCount % 1 == 0),
		"EditableImageBlur: config.workerCount must be a positive integer"
	)
	local syncThreshold = config.syncThreshold
	assert(
		syncThreshold == nil or (type(syncThreshold) == "number" and syncThreshold >= 0),
		"EditableImageBlur: config.syncThreshold must be a non-negative number"
	)
end

-- Returns the buffer the blur should run on and its dimensions. When
-- downscaleFactor shrinks the image this is a downsampled copy; otherwise it
-- is the caller's buffer itself.
local function workingCopy(config: BlurConfig, pixels: buffer, width: number, height: number): (buffer, number, number)
	-- Cheat: blur a downsampled copy to reduce the work done in Luau (the
	-- blur is going to lose detail anyway, so the visual difference is
	-- minimal). The engine removed EditableImage:Resize, so this is a CPU
	-- resample and the caller's buffer keeps its full resolution.
	local downscaleFactor = config.downscaleFactor or 1
	if downscaleFactor == 1 then
		return pixels, width, height
	end

	local workingWidth = math.max(1, math.floor(width * downscaleFactor + 0.5))
	local workingHeight = math.max(1, math.floor(height * downscaleFactor + 0.5))
	return Resample.resize(pixels, width, height, workingWidth, workingHeight), workingWidth, workingHeight
end

-- Upsamples the blurred working copy back over the caller's buffer. When
-- skipAlpha is set, the caller's alpha bytes are kept out of the down/up
-- resample entirely.
local function applyWorkingCopy(
	config: BlurConfig,
	pixels: buffer,
	width: number,
	height: number,
	working: buffer,
	workingWidth: number,
	workingHeight: number
)
	if working == pixels then
		return
	end

	if config.skipAlpha then
		-- Upsample into a temporary and blit only its RGB bytes over the
		-- caller's buffer, so the caller's alpha never passes through the
		-- resample.
		Resample.blitRgb(pixels, Resample.resize(working, workingWidth, workingHeight, width, height))
	else
		-- Upsample straight into the caller's buffer.
		Resample.resize(working, workingWidth, workingHeight, width, height, pixels)
	end
end

-- Blurs the pixel buffer in place, synchronously. Never yields.
local function Blur(config: BlurConfig)
	local pixels, width, height = validate(config)
	local working, workingWidth, workingHeight = workingCopy(config, pixels, width, height)
	-- A downsampled working copy's alpha bytes are discarded on write-back
	-- (applyWorkingCopy preserves the caller's alpha itself), so kernel-level
	-- alpha preservation only matters when blurring the caller's buffer.
	local skipAlpha = config.skipAlpha == true and working == pixels

	Kernel.blur(working, workingWidth, workingHeight, config.blurRadius or DEFAULT_SIGMA, skipAlpha)

	applyWorkingCopy(config, pixels, width, height, working, workingWidth, workingHeight)
end

--[[
	Blurs the pixel buffer in place on the internal actor pool, splitting it
	into row bands that run in parallel Luau. May yield while workers run.
	Small images (and any situation where the pool cannot help: edit mode,
	worker failure, images too short to band) run the synchronous path
	instead and return without yielding.
]]
local function BlurAsync(config: BlurAsyncConfig)
	local pixels, width, height = validate(config)
	validateAsync(config)
	local working, workingWidth, workingHeight = workingCopy(config, pixels, width, height)
	local sigma = config.blurRadius or DEFAULT_SIGMA
	-- See Blur: alpha preservation on a discarded working copy is wasted work.
	local skipAlpha = config.skipAlpha == true and working == pixels

	local syncThreshold = config.syncThreshold or DEFAULT_SYNC_THRESHOLD
	local runSynchronously = workingWidth * workingHeight < syncThreshold
	if not runSynchronously then
		runSynchronously = not Dispatcher.blurAsync(
			working,
			workingWidth,
			workingHeight,
			sigma,
			skipAlpha,
			config.workerCount or DEFAULT_WORKER_COUNT
		)
	end
	if runSynchronously then
		Kernel.blur(working, workingWidth, workingHeight, sigma, skipAlpha)
	end

	applyWorkingCopy(config, pixels, width, height, working, workingWidth, workingHeight)
end

return {
	Blur = Blur,
	BlurAsync = BlurAsync,
}
