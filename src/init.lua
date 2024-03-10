-- Based on https://blog.ivank.net/fastest-gaussian-blur.html

-- Calculate box sizes for a Gaussian blur based on standard deviation and number of boxes.
local boxSizeCache = {}
local function calculateBoxSizesForGaussian(sigma)
	if boxSizeCache[sigma] then
		return boxSizeCache[sigma]
	end

	-- Calculate the ideal width of the averaging filter to achieve a Gaussian blur effect.
	local idealFilterWidth = math.sqrt((12 * sigma * sigma / 3) + 1)
	local lowerWidth = math.floor(idealFilterWidth)
	-- Make the width odd to ensure symmetry around the central pixel.
	if lowerWidth % 2 == 0 then
		lowerWidth = lowerWidth - 1
	end
	local upperWidth = (lowerWidth + 1) / 2

	-- Allocate sizes to the boxes based on the computed width.
	local boxSizes = {
		(lowerWidth - 1) / 2,
		upperWidth,
		upperWidth,
	}
	boxSizeCache[sigma] = boxSizes
	return boxSizes
end

-- Performs a box blur on the image data.
-- To improve performance, we naively operate in-place. This means the blur is less accurate, since
-- the sliding window removals are removing the modified values. It's a subtle imperfection so it's worth the memory saved.
local function performBoxBlur(pixelData, imageWidth, imageHeight, blurRadius, skipAlpha)
	local inverseArea = 1 / (blurRadius + blurRadius + 1)
	local channels = if skipAlpha then 2 else 3

	-- Calculate some constants to avoid recomputing them in the loops
	local widthTimesFour = imageWidth * 4
	local radiusTimesFour = blurRadius * 4
	local radiusPlusOneTimesFour = (blurRadius + 1) * 4
	local radiusTimesWidthTimesFour = blurRadius * widthTimesFour
	local radiusPlusOneTimesWidthTimesFour = (blurRadius + 1) * widthTimesFour

	-- Apply horizontal blur
	for row = 1, imageHeight do
		for colorChannel = 0, channels do -- Process each color channel independently
			local startIndex = (row - 1) * widthTimesFour + 1 + colorChannel
			local stopIndex = (row * imageWidth - 1) * 4 + 1 + colorChannel
			local accumulator = 0

			-- Initialize accumulator
			for i = -blurRadius, blurRadius do
				if i <= 0 then
					accumulator += pixelData[startIndex]
				elseif i > 0 then
					accumulator += pixelData[math.min(startIndex + i * 4, stopIndex)]
				end
			end

			for column = 1, imageWidth do
				local targetIndex = startIndex + (column - 1) * 4
				-- Slide window
				local nextIndex = math.min(targetIndex + radiusTimesFour, stopIndex)
				local lastIndex = math.max(targetIndex - radiusPlusOneTimesFour, startIndex)
				accumulator += pixelData[nextIndex] - pixelData[lastIndex]
				-- Update current pixel
				pixelData[targetIndex] = accumulator * inverseArea
			end
		end
	end

	-- Apply vertical blur
	for column = 1, imageWidth do
		for colorChannel = 0, channels do -- Process each color channel independently
			local startIndex = (column - 1) * 4 + 1 + colorChannel
			local stopIndex = startIndex + (imageHeight - 1) * widthTimesFour
			local accumulator = 0

			-- Initialize accumulator
			for i = -blurRadius, blurRadius do
				if i <= 0 then
					accumulator += pixelData[startIndex]
				elseif i > 0 then
					accumulator += pixelData[math.min(startIndex + i * widthTimesFour, stopIndex)]
				end
			end

			for row = 1, imageHeight do
				local targetIndex = startIndex + (row - 1) * widthTimesFour
				-- Slide window
				local nextIndex = math.min(targetIndex + radiusTimesWidthTimesFour, stopIndex)
				local lastIndex = math.max(targetIndex - radiusPlusOneTimesWidthTimesFour, startIndex)
				accumulator += pixelData[nextIndex] - pixelData[lastIndex]
				-- Update current pixel
				pixelData[targetIndex] = accumulator * inverseArea
			end
		end
	end
end

-- Applies a Gaussian blur to the source channel (pixelData).
local function applyGaussianBlur(pixelData, imageWidth, imageHeight, blurRadius, skipAlpha)
	-- Compute the sizes of the boxes for the blur based on the radius.
	local boxSizes = calculateBoxSizesForGaussian(blurRadius)

	-- Apply three iterations of box blur, which together approximate a Gaussian blur.
	performBoxBlur(pixelData, imageWidth, imageHeight, boxSizes[1], skipAlpha)
	performBoxBlur(pixelData, imageWidth, imageHeight, boxSizes[2], skipAlpha)
	performBoxBlur(pixelData, imageWidth, imageHeight, boxSizes[3], skipAlpha)
end

export type blurConfig = {
	image: EditableImage,
	pixelData: { number }?,
	blurRadius: number?,
	skipAlpha: boolean?,
	downscaleFactor: number?,
}

return function(blurConfig: blurConfig)
	local image = blurConfig.image
	if not image then
		return
	end

	local imageSize = image.Size
	local pixelData = blurConfig.pixelData
	if not pixelData then
		-- Cheat: downscale the image to reduce the work done in Luau
		-- (the blur is going to lose detail anyway so visual difference is minimal)
		if blurConfig.downscaleFactor ~= 1 then
			image:Resize(imageSize * (blurConfig.downscaleFactor or 0.5))
			imageSize = image.Size
		end

		pixelData = image:ReadPixels(Vector2.zero, imageSize)
	else
		-- Do not mutate input data
		pixelData = table.clone(pixelData)
	end

	applyGaussianBlur(pixelData, imageSize.X, imageSize.Y, blurConfig.blurRadius or 2, blurConfig.skipAlpha)
	image:WritePixels(Vector2.zero, imageSize, pixelData)

	return pixelData
end
