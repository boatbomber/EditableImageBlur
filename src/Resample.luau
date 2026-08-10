--!strict
--!native
--!optimize 2

--[[
	Bilinear resampling of u8 RGBA pixel buffers, used to implement the
	downscaleFactor option now that the engine has removed EditableImage:Resize.
	The blur runs on the downsampled copy and the result is upsampled back to
	the image's real size on write-back.

	The resize is separable: a horizontal pass into a targetWidth x
	sourceHeight intermediate, then a vertical pass. Each pass lerps whole
	pixels as u32s on two SWAR accumulators (R/B and G/A in 16-bit lanes)
	with weights quantized to 1/256ths; a lane peaks at 255 * 256, so adding
	0x00800080 and shifting right by 8 rounds both lanes at once. Weights per
	axis sum to exactly 256, so a uniform image round-trips bit-exactly;
	against float bilinear the quantization and two-stage rounding move a
	channel by at most one step.

	The hot loops must stay free of function calls: a call inside the row
	loop defeats native codegen's type inference for the whole loop and
	roughly halves throughput (measured), so the vertical pass inlines its
	per-row sample math.

	Bilinear sampling skips source pixels when shrinking below half size, but
	the blur that follows smears any aliasing away; a pre-blur downsample is
	this module's only use.
]]

local Resample = {}

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu32 = buffer.readu32
local writeu32 = buffer.writeu32
local band = bit32.band
local rshift = bit32.rshift

local LANE_MASK = 0x00FF00FF
local ROUND_BIAS = 0x00800080

-- Computes the left sample index and the 0-255 right-sample weight for one
-- target coordinate, sampling at pixel centers so the resize does not shift
-- the image. Edge samples clamp; a weight that rounds to a full 256 snaps
-- onto the right sample. Only called from precompute loops (see the module
-- comment on hot-loop calls).
local function sampleAt(targetCoord: number, scale: number, sourceLength: number): (number, number, number)
	local sourceCoord = (targetCoord + 0.5) * scale - 0.5
	local left = math.floor(sourceCoord)
	local weight = math.floor((sourceCoord - left) * 256 + 0.5)
	local right = math.min(left + 1, sourceLength - 1)
	if left < 0 then
		left = 0
	end
	if weight >= 256 then
		left = right
		weight = 0
	end
	return left, right, weight
end

-- Returns the source resized to the target dimensions. Writes into
-- `destination` when given (it must be targetWidth * targetHeight * 4 bytes
-- and must not alias `source`; the passes never read it), otherwise into a
-- new buffer.
function Resample.resize(
	source: buffer,
	sourceWidth: number,
	sourceHeight: number,
	targetWidth: number,
	targetHeight: number,
	destination: buffer?
): buffer
	local result = destination or buffer.create(targetWidth * targetHeight * 4)
	if targetWidth == sourceWidth and targetHeight == sourceHeight then
		buffer.copy(result, 0, source, 0, buffer.len(source))
		return result
	end

	-- Horizontal pass: sourceWidth x sourceHeight -> targetWidth x sourceHeight.
	-- Column sample offsets and weights are precomputed once and reused by
	-- every row.
	local intermediate = if targetWidth == sourceWidth then source else buffer.create(targetWidth * sourceHeight * 4)
	if targetWidth ~= sourceWidth then
		local scaleX = sourceWidth / targetWidth
		local leftOffsets = buffer.create(targetWidth * 4)
		local rightOffsets = buffer.create(targetWidth * 4)
		local columnWeights = buffer.create(targetWidth)
		for x = 0, targetWidth - 1 do
			local left, right, weight = sampleAt(x, scaleX, sourceWidth)
			writeu32(leftOffsets, x * 4, left * 4)
			writeu32(rightOffsets, x * 4, right * 4)
			writeu8(columnWeights, x, weight)
		end

		local targetIndex = 0
		for y = 0, sourceHeight - 1 do
			local rowBase = y * sourceWidth * 4
			for x = 0, targetWidth - 1 do
				local leftValue = readu32(source, rowBase + readu32(leftOffsets, x * 4))
				local rightValue = readu32(source, rowBase + readu32(rightOffsets, x * 4))
				local weight = readu8(columnWeights, x)
				local inverseWeight = 256 - weight
				local lerpRB = band(leftValue, LANE_MASK) * inverseWeight
					+ band(rightValue, LANE_MASK) * weight
					+ ROUND_BIAS
				local lerpGA = band(rshift(leftValue, 8), LANE_MASK) * inverseWeight
					+ band(rshift(rightValue, 8), LANE_MASK) * weight
					+ ROUND_BIAS
				writeu32(
					intermediate,
					targetIndex,
					band(rshift(lerpRB, 8), 255)
						+ band(rshift(lerpGA, 8), 255) * 256
						+ rshift(lerpRB, 24) * 65536
						+ rshift(lerpGA, 24) * 16777216
				)
				targetIndex += 4
			end
		end
	end

	-- Vertical pass: targetWidth x sourceHeight -> targetWidth x targetHeight.
	if targetHeight == sourceHeight then
		buffer.copy(result, 0, intermediate, 0, buffer.len(result))
		return result
	end

	local scaleY = sourceHeight / targetHeight
	local stride = targetWidth * 4
	local targetIndex = 0
	for y = 0, targetHeight - 1 do
		-- sampleAt, inlined to keep the hot loop call-free
		local sourceY = (y + 0.5) * scaleY - 0.5
		local top = math.floor(sourceY)
		local weight = math.floor((sourceY - top) * 256 + 0.5)
		local bottom = math.min(top + 1, sourceHeight - 1)
		if top < 0 then
			top = 0
		end
		if weight >= 256 then
			top = bottom
			weight = 0
		end
		local inverseWeight = 256 - weight
		local topBase = top * stride
		local bottomBase = bottom * stride

		for x = 0, targetWidth - 1 do
			local xi = x * 4
			local topValue = readu32(intermediate, topBase + xi)
			local bottomValue = readu32(intermediate, bottomBase + xi)
			local lerpRB = band(topValue, LANE_MASK) * inverseWeight
				+ band(bottomValue, LANE_MASK) * weight
				+ ROUND_BIAS
			local lerpGA = band(rshift(topValue, 8), LANE_MASK) * inverseWeight
				+ band(rshift(bottomValue, 8), LANE_MASK) * weight
				+ ROUND_BIAS
			writeu32(
				result,
				targetIndex,
				band(rshift(lerpRB, 8), 255)
					+ band(rshift(lerpGA, 8), 255) * 256
					+ rshift(lerpRB, 24) * 65536
					+ rshift(lerpGA, 24) * 16777216
			)
			targetIndex += 4
		end
	end

	return result
end

-- Copies every pixel's RGB bytes from source over target, leaving target's
-- alpha bytes untouched. Buffers must be the same length.
function Resample.blitRgb(target: buffer, source: buffer)
	for index = 0, buffer.len(target) - 4, 4 do
		writeu32(target, index, band(readu32(source, index), 0x00FFFFFF) + band(readu32(target, index), 0xFF000000))
	end
end

return Resample
