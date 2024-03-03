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

	-- Apply horizontal blur.
	for row = 1, imageHeight do
		for colorChannel = 0, channels do -- Process each color channel independently.
			local targetIndex = (row - 1) * imageWidth * 4 + 1 + colorChannel
			local leftIndex = targetIndex
			local rightIndex = targetIndex + blurRadius * 4
			local firstValue = pixelData[targetIndex]
			local lastValue = pixelData[(row * imageWidth - 1) * 4 + 1 + colorChannel]
			local accumulator = (blurRadius + 1) * firstValue
			-- Accumulate initial pixel values for the blur effect.
			for i = 0, blurRadius - 1 do
				accumulator += pixelData[targetIndex + i * 4]
			end
			-- Move through each pixel in the row.
			for _ = 0, blurRadius do
				accumulator += pixelData[rightIndex] - firstValue
				pixelData[targetIndex] = accumulator * inverseArea
				rightIndex += 4
				targetIndex += 4
			end
			-- Continue through the middle section of the row.
			for _ = blurRadius + 1, imageWidth - blurRadius - 1 do
				accumulator += pixelData[rightIndex] - pixelData[leftIndex]
				pixelData[targetIndex] = accumulator * inverseArea
				leftIndex += 4
				rightIndex += 4
				targetIndex += 4
			end
			-- Finish at the end of the row, using the last value to fill in.
			for _ = imageWidth - blurRadius, imageWidth - 1 do
				accumulator += lastValue - pixelData[leftIndex]
				pixelData[targetIndex] = accumulator * inverseArea
				leftIndex += 4
				targetIndex += 4
			end
		end
	end

	-- Apply vertical blur.
	local widthTimesFour = imageWidth * 4
	for column = 1, imageWidth do
		for colorChannel = 0, channels do -- Process each color channel independently.
			local targetIndex = (column - 1) * 4 + 1 + colorChannel
			local leftIndex = targetIndex
			local rightIndex = targetIndex + blurRadius * widthTimesFour
			local firstValue = pixelData[targetIndex]
			local lastValue = pixelData[targetIndex + (imageHeight - 1) * widthTimesFour]
			local accumulator = (blurRadius + 1) * firstValue
			-- Initial accumulation for the blur.
			for i = 0, blurRadius - 1 do
				accumulator += pixelData[targetIndex + i * widthTimesFour]
			end
			-- Apply the blur vertically down the column.
			for _ = 0, blurRadius do
				accumulator += pixelData[rightIndex] - firstValue
				pixelData[targetIndex] = accumulator * inverseArea
				rightIndex += widthTimesFour
				targetIndex += widthTimesFour
			end
			-- Continue through the column.
			for _ = blurRadius + 1, imageHeight - blurRadius - 1 do
				accumulator += pixelData[rightIndex] - pixelData[leftIndex]
				pixelData[targetIndex] = accumulator * inverseArea
				leftIndex += widthTimesFour
				rightIndex += widthTimesFour
				targetIndex += widthTimesFour
			end
			-- Complete the blur at the bottom of the column.
			for _ = imageHeight - blurRadius, imageHeight - 1 do
				accumulator += lastValue - pixelData[leftIndex]
				pixelData[targetIndex] = accumulator * inverseArea
				leftIndex += widthTimesFour
				targetIndex += widthTimesFour
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
