--!strict
--!native
--!optimize 2

--[[
	Pure buffer blur kernel. Based on the "3 box blurs approximate a Gaussian"
	technique from https://blog.ivank.net/fastest-gaussian-blur.html

	The pixel buffer is u8 RGBA, row-major: index = ((y * width) + x) * 4 + channel,
	with 0-based x, y, and channel (0 = R .. 3 = A).

	Each box blur is separable (a horizontal pass then a vertical pass) and uses
	a sliding-window accumulator, so per-pixel cost is O(1) regardless of blur
	radius. Passes ping-pong between the caller's buffer and one scratch buffer
	so the window only ever subtracts original pass-input values; this keeps
	the box blur exact, which makes the parallel path's band stitching
	bit-identical to the full-image blur. Six passes (three boxes, horizontal
	then vertical each) means the final result lands back in the caller's
	buffer, so the blur is in place from the caller's point of view.

	The hot passes read and write whole pixels as u32s and slide two SWAR
	accumulators per window: R and B share one accumulator's 16-bit lanes,
	G and A share the other's. A lane holds at most 255 * (2r + 1), so this
	is exact while the box radius stays at or below SWAR_MAX_RADIUS; the rare
	larger radii take a per-channel scalar path with identical math. Window
	sums normalize through a small lookup table (lut[sum] = rounded byte)
	instead of a multiply+round per lane. The horizontal pass unrolls its
	middle loop four pixels at a time; the vertical pass walks four adjacent
	columns per sweep with accumulators in locals, so every 64-byte cache
	line fetched at the column stride yields sixteen useful bytes instead of
	four. Alpha is always blurred with the other lanes (the SWAR passes
	process it at no extra cost); skipAlpha is honored by snapshotting the
	alpha bytes up front and restoring them at the end, four pixels per u32.

	This module must stay free of Instance access and globals so that parallel
	workers can require it from any Luau VM.
]]

local Kernel = {}

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu32 = buffer.readu32
local writeu32 = buffer.writeu32
local band = bit32.band
local rshift = bit32.rshift

-- R and B (or G and A) sit 16 bits apart in one accumulator; a lane peaks at
-- 255 * (2 * radius + 1), which fits 16 bits only while radius <= 128.
local SWAR_MAX_RADIUS = 128
local LANE_MASK = 0x00FF00FF

-- Distinct sigmas each get a cache entry, and callers tweening a blur radius
-- can produce thousands of them. Recomputing is cheap, so the cache clears
-- once it reaches a size limit.
local BOX_RADII_CACHE_LIMIT = 512
local boxRadiiCache: { [number]: { number } } = {}
local boxRadiiCacheCount = 0

-- Calculate box radii for a Gaussian blur based on standard deviation and number of boxes
function Kernel.boxRadiiForSigma(sigma: number): { number }
	local cached = boxRadiiCache[sigma]
	if cached then
		return cached
	end

	-- Calculate the ideal width of the averaging filter to achieve a Gaussian blur effect.
	local idealFilterWidth = math.sqrt((12 * sigma * sigma / 3) + 1)
	local lowerWidth = math.floor(idealFilterWidth)
	-- Make the width odd to ensure symmetry around the central pixel.
	if lowerWidth % 2 == 0 then
		lowerWidth -= 1
	end
	local upperWidth = (lowerWidth + 1) / 2

	-- Allocate radii to the boxes based on the computed width.
	local boxRadii = {
		(lowerWidth - 1) / 2,
		upperWidth,
		upperWidth,
	}
	if boxRadiiCacheCount >= BOX_RADII_CACHE_LIMIT then
		table.clear(boxRadiiCache)
		boxRadiiCacheCount = 0
	end
	boxRadiiCache[sigma] = boxRadii
	boxRadiiCacheCount += 1
	return boxRadii
end

-- Total reach of the blur in pixels: how far one pixel's value can travel
-- across all three box passes. Band padding must be at least this.
function Kernel.supportForSigma(sigma: number): number
	local boxRadii = Kernel.boxRadiiForSigma(sigma)
	return boxRadii[1] + boxRadii[2] + boxRadii[3]
end

-- lut[windowSum] = rounded byte, replacing a multiply+round per lane per
-- pixel. 255 * (2r + 1) + 1 entries, so it stays cache-resident for
-- practical radii. The LUT depends only on the radius, and the SWAR passes
-- that consume it only run for integer radii <= SWAR_MAX_RADIUS, so the
-- cache is naturally bounded; two of the three box radii per blur are always
-- equal, making the cache hit even within a single call.
local normalizationLutCache: { [number]: buffer } = {}

local function getNormalizationLut(blurRadius: number): buffer
	local cached = normalizationLutCache[blurRadius]
	if cached then
		return cached
	end

	local inverseArea = 1 / (blurRadius + blurRadius + 1)
	local size = 255 * (blurRadius + blurRadius + 1) + 1
	local lut = buffer.create(size)
	for i = 0, size - 1 do
		writeu8(lut, i, i * inverseArea + 0.5)
	end
	normalizationLutCache[blurRadius] = lut
	return lut
end

-- The radius covers every row pixel, so each pixel becomes the row's average
local function horizontalAverage(source: buffer, target: buffer, imageWidth: number, imageHeight: number)
	local widthTimesFour = imageWidth * 4
	for row = 0, imageHeight - 1 do
		local rowStart = row * widthTimesFour
		local sumR, sumG, sumB, sumA = 0, 0, 0, 0
		for index = rowStart, rowStart + widthTimesFour - 4, 4 do
			local value = readu32(source, index)
			sumR += band(value, 255)
			sumG += band(rshift(value, 8), 255)
			sumB += band(rshift(value, 16), 255)
			sumA += rshift(value, 24)
		end
		local average = (sumR / imageWidth + 0.5) // 1
			+ ((sumG / imageWidth + 0.5) // 1) * 256
			+ ((sumB / imageWidth + 0.5) // 1) * 65536
			+ ((sumA / imageWidth + 0.5) // 1) * 16777216
		for index = rowStart, rowStart + widthTimesFour - 4, 4 do
			writeu32(target, index, average)
		end
	end
end

-- The radius covers every column pixel, so each pixel becomes the column's average
local function verticalAverage(source: buffer, target: buffer, imageWidth: number, imageHeight: number)
	local widthTimesFour = imageWidth * 4
	local columnSpan = (imageHeight - 1) * widthTimesFour
	for column = 0, imageWidth - 1 do
		local columnStart = column * 4
		local sumR, sumG, sumB, sumA = 0, 0, 0, 0
		for index = columnStart, columnStart + columnSpan, widthTimesFour do
			local value = readu32(source, index)
			sumR += band(value, 255)
			sumG += band(rshift(value, 8), 255)
			sumB += band(rshift(value, 16), 255)
			sumA += rshift(value, 24)
		end
		local average = (sumR / imageHeight + 0.5) // 1
			+ ((sumG / imageHeight + 0.5) // 1) * 256
			+ ((sumB / imageHeight + 0.5) // 1) * 65536
			+ ((sumA / imageHeight + 0.5) // 1) * 16777216
		for index = columnStart, columnStart + columnSpan, widthTimesFour do
			writeu32(target, index, average)
		end
	end
end

-- One SWAR box pass over every row: sliding window along x, middle loop
-- unrolled four pixels per iteration.
local function horizontalPass(
	source: buffer,
	target: buffer,
	imageWidth: number,
	imageHeight: number,
	blurRadius: number,
	lut: buffer
)
	local widthTimesFour = imageWidth * 4
	local middleCount = imageWidth - blurRadius - blurRadius - 1
	local unrolled = middleCount // 4
	local remainder = middleCount % 4

	for row = 0, imageHeight - 1 do
		local rowStart = row * widthTimesFour

		local firstValue = readu32(source, rowStart)
		local firstRB = band(firstValue, LANE_MASK)
		local firstGA = band(rshift(firstValue, 8), LANE_MASK)
		local lastValue = readu32(source, rowStart + (imageWidth - 1) * 4)
		local lastRB = band(lastValue, LANE_MASK)
		local lastGA = band(rshift(lastValue, 8), LANE_MASK)

		-- Seed the accumulator with the window that precedes the first pixel
		local accumulatorRB = firstRB * (blurRadius + 1)
		local accumulatorGA = firstGA * (blurRadius + 1)
		for i = 0, blurRadius - 1 do
			local value = readu32(source, rowStart + i * 4)
			accumulatorRB += band(value, LANE_MASK)
			accumulatorGA += band(rshift(value, 8), LANE_MASK)
		end

		local enterIndex = rowStart + blurRadius * 4
		local leaveIndex = rowStart
		local targetIndex = rowStart
		-- Start of the row: the window's trailing side still reads the extended first value
		for _ = 0, blurRadius do
			local value = readu32(source, enterIndex)
			accumulatorRB += band(value, LANE_MASK) - firstRB
			accumulatorGA += band(rshift(value, 8), LANE_MASK) - firstGA
			writeu32(
				target,
				targetIndex,
				readu8(lut, band(accumulatorRB, 0xFFFF))
					+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
					+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
					+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
			)
			enterIndex += 4
			targetIndex += 4
		end
		-- Middle section, four pixels per iteration
		for _ = 1, unrolled do
			local enter1 = readu32(source, enterIndex)
			local enter2 = readu32(source, enterIndex + 4)
			local enter3 = readu32(source, enterIndex + 8)
			local enter4 = readu32(source, enterIndex + 12)
			local leave1 = readu32(source, leaveIndex)
			local leave2 = readu32(source, leaveIndex + 4)
			local leave3 = readu32(source, leaveIndex + 8)
			local leave4 = readu32(source, leaveIndex + 12)
			accumulatorRB += band(enter1, LANE_MASK) - band(leave1, LANE_MASK)
			accumulatorGA += band(rshift(enter1, 8), LANE_MASK) - band(rshift(leave1, 8), LANE_MASK)
			writeu32(
				target,
				targetIndex,
				readu8(lut, band(accumulatorRB, 0xFFFF))
					+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
					+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
					+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
			)
			accumulatorRB += band(enter2, LANE_MASK) - band(leave2, LANE_MASK)
			accumulatorGA += band(rshift(enter2, 8), LANE_MASK) - band(rshift(leave2, 8), LANE_MASK)
			writeu32(
				target,
				targetIndex + 4,
				readu8(lut, band(accumulatorRB, 0xFFFF))
					+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
					+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
					+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
			)
			accumulatorRB += band(enter3, LANE_MASK) - band(leave3, LANE_MASK)
			accumulatorGA += band(rshift(enter3, 8), LANE_MASK) - band(rshift(leave3, 8), LANE_MASK)
			writeu32(
				target,
				targetIndex + 8,
				readu8(lut, band(accumulatorRB, 0xFFFF))
					+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
					+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
					+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
			)
			accumulatorRB += band(enter4, LANE_MASK) - band(leave4, LANE_MASK)
			accumulatorGA += band(rshift(enter4, 8), LANE_MASK) - band(rshift(leave4, 8), LANE_MASK)
			writeu32(
				target,
				targetIndex + 12,
				readu8(lut, band(accumulatorRB, 0xFFFF))
					+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
					+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
					+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
			)
			enterIndex += 16
			leaveIndex += 16
			targetIndex += 16
		end
		for _ = 1, remainder do
			local enterValue = readu32(source, enterIndex)
			local leaveValue = readu32(source, leaveIndex)
			accumulatorRB += band(enterValue, LANE_MASK) - band(leaveValue, LANE_MASK)
			accumulatorGA += band(rshift(enterValue, 8), LANE_MASK) - band(rshift(leaveValue, 8), LANE_MASK)
			writeu32(
				target,
				targetIndex,
				readu8(lut, band(accumulatorRB, 0xFFFF))
					+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
					+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
					+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
			)
			enterIndex += 4
			leaveIndex += 4
			targetIndex += 4
		end
		-- Finish at the end of the row, using the extended last value to fill in
		for _ = imageWidth - blurRadius, imageWidth - 1 do
			local leaveValue = readu32(source, leaveIndex)
			accumulatorRB += lastRB - band(leaveValue, LANE_MASK)
			accumulatorGA += lastGA - band(rshift(leaveValue, 8), LANE_MASK)
			writeu32(
				target,
				targetIndex,
				readu8(lut, band(accumulatorRB, 0xFFFF))
					+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
					+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
					+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
			)
			leaveIndex += 4
			targetIndex += 4
		end
	end
end

-- One SWAR box pass over a single column; used for the width % 4 columns the
-- unrolled vertical pass does not cover.
local function verticalPassColumn(
	source: buffer,
	target: buffer,
	columnStart: number,
	imageHeight: number,
	widthTimesFour: number,
	blurRadius: number,
	lut: buffer
)
	local firstValue = readu32(source, columnStart)
	local firstRB = band(firstValue, LANE_MASK)
	local firstGA = band(rshift(firstValue, 8), LANE_MASK)
	local lastValue = readu32(source, columnStart + (imageHeight - 1) * widthTimesFour)
	local lastRB = band(lastValue, LANE_MASK)
	local lastGA = band(rshift(lastValue, 8), LANE_MASK)

	local accumulatorRB = firstRB * (blurRadius + 1)
	local accumulatorGA = firstGA * (blurRadius + 1)
	for i = 0, blurRadius - 1 do
		local value = readu32(source, columnStart + i * widthTimesFour)
		accumulatorRB += band(value, LANE_MASK)
		accumulatorGA += band(rshift(value, 8), LANE_MASK)
	end

	local enterIndex = columnStart + blurRadius * widthTimesFour
	local leaveIndex = columnStart
	local targetIndex = columnStart
	for _ = 0, blurRadius do
		local value = readu32(source, enterIndex)
		accumulatorRB += band(value, LANE_MASK) - firstRB
		accumulatorGA += band(rshift(value, 8), LANE_MASK) - firstGA
		writeu32(
			target,
			targetIndex,
			readu8(lut, band(accumulatorRB, 0xFFFF))
				+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
				+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
				+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
		)
		enterIndex += widthTimesFour
		targetIndex += widthTimesFour
	end
	for _ = blurRadius + 1, imageHeight - blurRadius - 1 do
		local enterValue = readu32(source, enterIndex)
		local leaveValue = readu32(source, leaveIndex)
		accumulatorRB += band(enterValue, LANE_MASK) - band(leaveValue, LANE_MASK)
		accumulatorGA += band(rshift(enterValue, 8), LANE_MASK) - band(rshift(leaveValue, 8), LANE_MASK)
		writeu32(
			target,
			targetIndex,
			readu8(lut, band(accumulatorRB, 0xFFFF))
				+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
				+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
				+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
		)
		enterIndex += widthTimesFour
		leaveIndex += widthTimesFour
		targetIndex += widthTimesFour
	end
	for _ = imageHeight - blurRadius, imageHeight - 1 do
		local leaveValue = readu32(source, leaveIndex)
		accumulatorRB += lastRB - band(leaveValue, LANE_MASK)
		accumulatorGA += lastGA - band(rshift(leaveValue, 8), LANE_MASK)
		writeu32(
			target,
			targetIndex,
			readu8(lut, band(accumulatorRB, 0xFFFF))
				+ readu8(lut, band(accumulatorGA, 0xFFFF)) * 256
				+ readu8(lut, rshift(accumulatorRB, 16)) * 65536
				+ readu8(lut, rshift(accumulatorGA, 16)) * 16777216
		)
		leaveIndex += widthTimesFour
		targetIndex += widthTimesFour
	end
end

-- One SWAR box pass over every column: four adjacent columns per sweep with
-- their accumulators in locals, so the strided walk uses 16 bytes of every
-- cache line it touches instead of 4.
local function verticalPass(
	source: buffer,
	target: buffer,
	imageWidth: number,
	imageHeight: number,
	blurRadius: number,
	lut: buffer
)
	local widthTimesFour = imageWidth * 4
	local lastBase = (imageHeight - 1) * widthTimesFour
	local groups = imageWidth // 4

	for group = 0, groups - 1 do
		local columnStart = group * 16

		local value1 = readu32(source, columnStart)
		local value2 = readu32(source, columnStart + 4)
		local value3 = readu32(source, columnStart + 8)
		local value4 = readu32(source, columnStart + 12)
		local first1RB, first1GA = band(value1, LANE_MASK), band(rshift(value1, 8), LANE_MASK)
		local first2RB, first2GA = band(value2, LANE_MASK), band(rshift(value2, 8), LANE_MASK)
		local first3RB, first3GA = band(value3, LANE_MASK), band(rshift(value3, 8), LANE_MASK)
		local first4RB, first4GA = band(value4, LANE_MASK), band(rshift(value4, 8), LANE_MASK)

		value1 = readu32(source, lastBase + columnStart)
		value2 = readu32(source, lastBase + columnStart + 4)
		value3 = readu32(source, lastBase + columnStart + 8)
		value4 = readu32(source, lastBase + columnStart + 12)
		local last1RB, last1GA = band(value1, LANE_MASK), band(rshift(value1, 8), LANE_MASK)
		local last2RB, last2GA = band(value2, LANE_MASK), band(rshift(value2, 8), LANE_MASK)
		local last3RB, last3GA = band(value3, LANE_MASK), band(rshift(value3, 8), LANE_MASK)
		local last4RB, last4GA = band(value4, LANE_MASK), band(rshift(value4, 8), LANE_MASK)

		local seed = blurRadius + 1
		local acc1RB, acc1GA = first1RB * seed, first1GA * seed
		local acc2RB, acc2GA = first2RB * seed, first2GA * seed
		local acc3RB, acc3GA = first3RB * seed, first3GA * seed
		local acc4RB, acc4GA = first4RB * seed, first4GA * seed
		for i = 0, blurRadius - 1 do
			local base = i * widthTimesFour + columnStart
			value1 = readu32(source, base)
			value2 = readu32(source, base + 4)
			value3 = readu32(source, base + 8)
			value4 = readu32(source, base + 12)
			acc1RB += band(value1, LANE_MASK)
			acc1GA += band(rshift(value1, 8), LANE_MASK)
			acc2RB += band(value2, LANE_MASK)
			acc2GA += band(rshift(value2, 8), LANE_MASK)
			acc3RB += band(value3, LANE_MASK)
			acc3GA += band(rshift(value3, 8), LANE_MASK)
			acc4RB += band(value4, LANE_MASK)
			acc4GA += band(rshift(value4, 8), LANE_MASK)
		end

		local enterBase = blurRadius * widthTimesFour + columnStart
		local leaveBase = columnStart
		local targetBase = columnStart
		for _ = 0, blurRadius do
			value1 = readu32(source, enterBase)
			value2 = readu32(source, enterBase + 4)
			value3 = readu32(source, enterBase + 8)
			value4 = readu32(source, enterBase + 12)
			acc1RB += band(value1, LANE_MASK) - first1RB
			acc1GA += band(rshift(value1, 8), LANE_MASK) - first1GA
			acc2RB += band(value2, LANE_MASK) - first2RB
			acc2GA += band(rshift(value2, 8), LANE_MASK) - first2GA
			acc3RB += band(value3, LANE_MASK) - first3RB
			acc3GA += band(rshift(value3, 8), LANE_MASK) - first3GA
			acc4RB += band(value4, LANE_MASK) - first4RB
			acc4GA += band(rshift(value4, 8), LANE_MASK) - first4GA
			writeu32(
				target,
				targetBase,
				readu8(lut, band(acc1RB, 0xFFFF))
					+ readu8(lut, band(acc1GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc1RB, 16)) * 65536
					+ readu8(lut, rshift(acc1GA, 16)) * 16777216
			)
			writeu32(
				target,
				targetBase + 4,
				readu8(lut, band(acc2RB, 0xFFFF))
					+ readu8(lut, band(acc2GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc2RB, 16)) * 65536
					+ readu8(lut, rshift(acc2GA, 16)) * 16777216
			)
			writeu32(
				target,
				targetBase + 8,
				readu8(lut, band(acc3RB, 0xFFFF))
					+ readu8(lut, band(acc3GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc3RB, 16)) * 65536
					+ readu8(lut, rshift(acc3GA, 16)) * 16777216
			)
			writeu32(
				target,
				targetBase + 12,
				readu8(lut, band(acc4RB, 0xFFFF))
					+ readu8(lut, band(acc4GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc4RB, 16)) * 65536
					+ readu8(lut, rshift(acc4GA, 16)) * 16777216
			)
			enterBase += widthTimesFour
			targetBase += widthTimesFour
		end
		for _ = blurRadius + 1, imageHeight - blurRadius - 1 do
			value1 = readu32(source, enterBase)
			value2 = readu32(source, enterBase + 4)
			value3 = readu32(source, enterBase + 8)
			value4 = readu32(source, enterBase + 12)
			local leave1 = readu32(source, leaveBase)
			local leave2 = readu32(source, leaveBase + 4)
			local leave3 = readu32(source, leaveBase + 8)
			local leave4 = readu32(source, leaveBase + 12)
			acc1RB += band(value1, LANE_MASK) - band(leave1, LANE_MASK)
			acc1GA += band(rshift(value1, 8), LANE_MASK) - band(rshift(leave1, 8), LANE_MASK)
			acc2RB += band(value2, LANE_MASK) - band(leave2, LANE_MASK)
			acc2GA += band(rshift(value2, 8), LANE_MASK) - band(rshift(leave2, 8), LANE_MASK)
			acc3RB += band(value3, LANE_MASK) - band(leave3, LANE_MASK)
			acc3GA += band(rshift(value3, 8), LANE_MASK) - band(rshift(leave3, 8), LANE_MASK)
			acc4RB += band(value4, LANE_MASK) - band(leave4, LANE_MASK)
			acc4GA += band(rshift(value4, 8), LANE_MASK) - band(rshift(leave4, 8), LANE_MASK)
			writeu32(
				target,
				targetBase,
				readu8(lut, band(acc1RB, 0xFFFF))
					+ readu8(lut, band(acc1GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc1RB, 16)) * 65536
					+ readu8(lut, rshift(acc1GA, 16)) * 16777216
			)
			writeu32(
				target,
				targetBase + 4,
				readu8(lut, band(acc2RB, 0xFFFF))
					+ readu8(lut, band(acc2GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc2RB, 16)) * 65536
					+ readu8(lut, rshift(acc2GA, 16)) * 16777216
			)
			writeu32(
				target,
				targetBase + 8,
				readu8(lut, band(acc3RB, 0xFFFF))
					+ readu8(lut, band(acc3GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc3RB, 16)) * 65536
					+ readu8(lut, rshift(acc3GA, 16)) * 16777216
			)
			writeu32(
				target,
				targetBase + 12,
				readu8(lut, band(acc4RB, 0xFFFF))
					+ readu8(lut, band(acc4GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc4RB, 16)) * 65536
					+ readu8(lut, rshift(acc4GA, 16)) * 16777216
			)
			enterBase += widthTimesFour
			leaveBase += widthTimesFour
			targetBase += widthTimesFour
		end
		for _ = imageHeight - blurRadius, imageHeight - 1 do
			local leave1 = readu32(source, leaveBase)
			local leave2 = readu32(source, leaveBase + 4)
			local leave3 = readu32(source, leaveBase + 8)
			local leave4 = readu32(source, leaveBase + 12)
			acc1RB += last1RB - band(leave1, LANE_MASK)
			acc1GA += last1GA - band(rshift(leave1, 8), LANE_MASK)
			acc2RB += last2RB - band(leave2, LANE_MASK)
			acc2GA += last2GA - band(rshift(leave2, 8), LANE_MASK)
			acc3RB += last3RB - band(leave3, LANE_MASK)
			acc3GA += last3GA - band(rshift(leave3, 8), LANE_MASK)
			acc4RB += last4RB - band(leave4, LANE_MASK)
			acc4GA += last4GA - band(rshift(leave4, 8), LANE_MASK)
			writeu32(
				target,
				targetBase,
				readu8(lut, band(acc1RB, 0xFFFF))
					+ readu8(lut, band(acc1GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc1RB, 16)) * 65536
					+ readu8(lut, rshift(acc1GA, 16)) * 16777216
			)
			writeu32(
				target,
				targetBase + 4,
				readu8(lut, band(acc2RB, 0xFFFF))
					+ readu8(lut, band(acc2GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc2RB, 16)) * 65536
					+ readu8(lut, rshift(acc2GA, 16)) * 16777216
			)
			writeu32(
				target,
				targetBase + 8,
				readu8(lut, band(acc3RB, 0xFFFF))
					+ readu8(lut, band(acc3GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc3RB, 16)) * 65536
					+ readu8(lut, rshift(acc3GA, 16)) * 16777216
			)
			writeu32(
				target,
				targetBase + 12,
				readu8(lut, band(acc4RB, 0xFFFF))
					+ readu8(lut, band(acc4GA, 0xFFFF)) * 256
					+ readu8(lut, rshift(acc4RB, 16)) * 65536
					+ readu8(lut, rshift(acc4GA, 16)) * 16777216
			)
			leaveBase += widthTimesFour
			targetBase += widthTimesFour
		end
	end

	for column = groups * 4, imageWidth - 1 do
		verticalPassColumn(source, target, column * 4, imageHeight, widthTimesFour, blurRadius, lut)
	end
end

--[[
	Per-channel scalar box pass with the same window math, for radii too large
	for the SWAR lanes (radius > SWAR_MAX_RADIUS but under half the
	dimension — enormous sigmas on large images). Rare, so clarity over speed.
]]
local function scalarPass(
	source: buffer,
	target: buffer,
	lineCount: number,
	lineStride: number,
	length: number,
	stride: number,
	blurRadius: number
)
	local inverseArea = 1 / (blurRadius + blurRadius + 1)
	local lastOffset = (length - 1) * stride

	for line = 0, lineCount - 1 do
		local lineStart = line * lineStride
		for colorChannel = 0, 3 do
			local targetIndex = lineStart + colorChannel
			local enterIndex = targetIndex + blurRadius * stride
			local leaveIndex = targetIndex
			local firstValue = readu8(source, targetIndex)
			local lastValue = readu8(source, lineStart + lastOffset + colorChannel)

			local accumulator = firstValue * (blurRadius + 1)
			for i = 0, blurRadius - 1 do
				accumulator += readu8(source, leaveIndex + i * stride)
			end
			for _ = 0, blurRadius do
				accumulator += readu8(source, enterIndex) - firstValue
				writeu8(target, targetIndex, accumulator * inverseArea + 0.5)
				enterIndex += stride
				targetIndex += stride
			end
			for _ = blurRadius + 1, length - blurRadius - 1 do
				accumulator += readu8(source, enterIndex) - readu8(source, leaveIndex)
				writeu8(target, targetIndex, accumulator * inverseArea + 0.5)
				enterIndex += stride
				leaveIndex += stride
				targetIndex += stride
			end
			for _ = length - blurRadius, length - 1 do
				accumulator += lastValue - readu8(source, leaveIndex)
				writeu8(target, targetIndex, accumulator * inverseArea + 0.5)
				leaveIndex += stride
				targetIndex += stride
			end
		end
	end
end

-- Applies the Gaussian-approximating blur to the pixel buffer, in place.
function Kernel.blur(
	pixels: buffer,
	imageWidth: number,
	imageHeight: number,
	gaussianRadius: number,
	skipAlpha: boolean?
)
	if imageWidth < 1 or imageHeight < 1 then
		return
	end

	local pixelCount = imageWidth * imageHeight
	local scratch = buffer.create(pixelCount * 4)
	local widthTimesFour = imageWidth * 4
	local halfWidth = imageWidth / 2
	local halfHeight = imageHeight / 2

	-- The SWAR passes blur all four lanes at once (blurring alpha costs
	-- nothing extra), so skipAlpha restores the original alpha bytes
	-- afterward. Snapshot and restore move four alpha bytes per u32.
	local alphaBackup: buffer? = nil
	local alphaGroups = pixelCount // 4
	if skipAlpha then
		local backup = buffer.create(pixelCount)
		for group = 0, alphaGroups - 1 do
			local base = group * 16
			writeu32(
				backup,
				group * 4,
				rshift(readu32(pixels, base), 24)
					+ rshift(readu32(pixels, base + 4), 24) * 256
					+ rshift(readu32(pixels, base + 8), 24) * 65536
					+ rshift(readu32(pixels, base + 12), 24) * 16777216
			)
		end
		for i = alphaGroups * 4, pixelCount - 1 do
			writeu8(backup, i, readu8(pixels, i * 4 + 3))
		end
		alphaBackup = backup
	end

	for _, blurRadius in Kernel.boxRadiiForSigma(gaussianRadius) do
		local useSwarHorizontal = blurRadius < halfWidth and blurRadius <= SWAR_MAX_RADIUS
		local useSwarVertical = blurRadius < halfHeight and blurRadius <= SWAR_MAX_RADIUS
		local lut = if useSwarHorizontal or useSwarVertical then getNormalizationLut(blurRadius) else nil

		-- Horizontal: read the caller's buffer, write scratch
		if blurRadius >= halfWidth then
			horizontalAverage(pixels, scratch, imageWidth, imageHeight)
		elseif lut and useSwarHorizontal then
			horizontalPass(pixels, scratch, imageWidth, imageHeight, blurRadius, lut)
		else
			scalarPass(pixels, scratch, imageHeight, widthTimesFour, imageWidth, 4, blurRadius)
		end

		-- Vertical: read scratch, write the caller's buffer
		if blurRadius >= halfHeight then
			verticalAverage(scratch, pixels, imageWidth, imageHeight)
		elseif lut and useSwarVertical then
			verticalPass(scratch, pixels, imageWidth, imageHeight, blurRadius, lut)
		else
			scalarPass(scratch, pixels, imageWidth, 4, imageHeight, widthTimesFour, blurRadius)
		end
	end

	if alphaBackup then
		for group = 0, alphaGroups - 1 do
			local packed = readu32(alphaBackup, group * 4)
			local base = group * 16
			writeu8(pixels, base + 3, band(packed, 255))
			writeu8(pixels, base + 7, band(rshift(packed, 8), 255))
			writeu8(pixels, base + 11, band(rshift(packed, 16), 255))
			writeu8(pixels, base + 15, rshift(packed, 24))
		end
		for i = alphaGroups * 4, pixelCount - 1 do
			writeu8(pixels, i * 4 + 3, readu8(alphaBackup, i))
		end
	end
end

return Kernel
