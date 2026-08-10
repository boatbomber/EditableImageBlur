--!strict

--[[
	Pure band-layout math for the parallel blur: splits an image's rows into
	horizontal bands, one per worker, each padded with enough neighboring rows
	that blurring the padded slice in isolation reproduces the full-image blur
	for the band's center rows.

	Padding rows are copied from the actual neighboring image rows. Only bands
	touching the true top/bottom of the image get less padding: their slice
	boundary is the image boundary, where the kernel's edge extension is the
	correct behavior.

	All row numbers are 0-based to match the pixel buffer layout.
]]

local Bands = {}

export type Band = {
	centerStart: number, -- first image row this band is responsible for
	centerCount: number, -- number of rows this band is responsible for
	padTop: number, -- padding rows above the center inside the slice
	padBottom: number, -- padding rows below the center inside the slice
}

--[[
	Computes the band layout for an image of the given height. `support` is the
	blur's total reach in pixels (Kernel.supportForSigma); each band's padding
	must cover it so the discarded padding rows fully absorb the slice-boundary
	error.

	Fewer bands than requested are returned when the image is too short for
	every band to be taller than the padding it needs; callers should treat a
	single-band result as "run the sync path instead".
]]
function Bands.compute(height: number, support: number, workerCount: number): { Band }
	-- The public API validates workerCount, but this loop must terminate for
	-- any input: a band per row is the most that can ever help, which also
	-- clamps non-finite counts (the reduction loop below cannot decrement
	-- math.huge), and NaN falls through the comparison to a single band.
	local bandCount = math.floor(math.min(workerCount, height))
	if not (bandCount >= 1) then
		bandCount = 1
	end

	-- Every band must be taller than the blur support, both so the padding is
	-- fully backed by real rows and so no box radius can trip the kernel's
	-- whole-column averaging path on a slice (radii are each about a third of
	-- the support, and slices are at least a band plus one padding tall).
	while bandCount > 1 and math.floor(height / bandCount) <= support do
		bandCount -= 1
	end

	local bands = table.create(bandCount)
	for index = 0, bandCount - 1 do
		local centerStart = math.floor(index * height / bandCount)
		local centerEnd = math.floor((index + 1) * height / bandCount) - 1
		bands[index + 1] = {
			centerStart = centerStart,
			centerCount = centerEnd - centerStart + 1,
			padTop = math.min(support, centerStart),
			padBottom = math.min(support, height - 1 - centerEnd),
		}
	end
	return bands
end

-- Total rows in a band's padded slice.
function Bands.sliceHeight(band: Band): number
	return band.padTop + band.centerCount + band.padBottom
end

-- First image row of a band's padded slice.
function Bands.sliceStart(band: Band): number
	return band.centerStart - band.padTop
end

return Bands
