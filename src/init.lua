-- Based on https://blog.ivank.net/fastest-gaussian-blur.html

-- Calculate box radii for a Gaussian blur based on standard deviation and number of boxes
local boxRadiiCache = {}
local function calculateBoxRadiiForGaussian(sigma)
	if boxRadiiCache[sigma] then
		return boxRadiiCache[sigma]
	end

	-- Calculate the ideal width of the averaging filter to achieve a Gaussian blur effect.
	local idealFilterWidth = math.sqrt((12 * sigma * sigma / 3) + 1)
	local lowerWidth = math.floor(idealFilterWidth)
	-- Make the width odd to ensure symmetry around the central pixel.
	if lowerWidth % 2 == 0 then
		lowerWidth = lowerWidth - 1
	end
	local upperWidth = (lowerWidth + 1) / 2

	-- Allocate radii to the boxes based on the computed width.
	local boxRadii = {
		(lowerWidth - 1) / 2,
		upperWidth,
		upperWidth,
	}
	boxRadiiCache[sigma] = boxRadii
	return boxRadii
end

-- Applies a Gaussian blur to the source channel (pixelData)
local function applyGaussianBlur(pixelData, imageWidth, imageHeight, gaussianRadius, skipAlpha)
	-- Calculate some constants to avoid recomputing them in the loops
	local channels = if skipAlpha then 2 else 3
	local halfWidth = imageWidth / 2
	local halfHeight = imageHeight / 2
	local widthTimesFour = imageWidth * 4

	-- Compute the sizes of the boxes for the blur based on the radius
	local boxRadii = calculateBoxRadiiForGaussian(gaussianRadius)

	-- Apply iterations of box blur, which together approximate a Gaussian blur
	-- To improve performance, we naively operate in-place. This means the blur is less accurate, since
	-- the sliding window removals are removing the modified values. It's a subtle imperfection so it's worth the memory saved.
	for _, blurRadius in boxRadii do
		local inverseArea = 1 / (blurRadius + blurRadius + 1)
		local radiusTimesFour = blurRadius * 4
		local radiusTimesWidthTimesFour = blurRadius * widthTimesFour

		-- Apply horizontal blur
		local radiusIsTooWide = blurRadius >= halfWidth
		for row = 1, imageHeight do
			local rowStart = (row - 1) * widthTimesFour + 1
			local rowStop = (row * imageWidth - 1) * 4 + 1

			for colorChannel = 0, channels do
				local targetIndex = rowStart + colorChannel
				local leftIndex = targetIndex

				if radiusIsTooWide then
					-- The radius covers the whole row, so we set each pixel to the row's average
					local average = 0
					for _ = 1, imageWidth do
						average += pixelData[targetIndex]
						targetIndex += 4
					end
					average /= imageWidth
					targetIndex = leftIndex
					for _ = 1, imageWidth do
						pixelData[targetIndex] = average
						targetIndex += 4
					end

					continue
				end

				local rightIndex = targetIndex + radiusTimesFour
				local firstValue = pixelData[targetIndex]
				local lastValue = pixelData[rowStop + colorChannel]
				local accumulator = (blurRadius + 1) * firstValue

				-- Accumulate initial pixel values for the blur effect
				for i = 1, blurRadius - 1 do
					accumulator += pixelData[targetIndex + i * 4]
				end
				-- Move through each pixel in the row
				for _ = 0, blurRadius do
					accumulator += pixelData[rightIndex] - firstValue
					pixelData[targetIndex] = accumulator * inverseArea
					rightIndex += 4
					targetIndex += 4
				end
				-- Continue through the middle section of the row
				for _ = blurRadius + 1, imageWidth - blurRadius - 1 do
					accumulator += pixelData[rightIndex] - pixelData[leftIndex]
					pixelData[targetIndex] = accumulator * inverseArea
					leftIndex += 4
					rightIndex += 4
					targetIndex += 4
				end
				-- Finish at the end of the row, using the last value to fill in
				for _ = imageWidth - blurRadius, imageWidth - 1 do
					accumulator += lastValue - pixelData[leftIndex]
					pixelData[targetIndex] = accumulator * inverseArea
					leftIndex += 4
					targetIndex += 4
				end
			end
		end

		-- Apply vertical blur
		local radiusIsTooTall = blurRadius >= halfHeight
		for column = 1, imageWidth do
			local columnStart = (column - 1) * 4 + 1
			local columnStop = columnStart + (imageHeight - 1) * widthTimesFour

			for colorChannel = 0, channels do
				local targetIndex = columnStart + colorChannel
				local leftIndex = targetIndex

				if radiusIsTooTall then
					-- The radius covers the whole column, so we set each pixel to the column's average
					local average = 0
					for _ = 1, imageHeight do
						average += pixelData[targetIndex]
						targetIndex += widthTimesFour
					end
					average /= imageWidth
					targetIndex = leftIndex
					for _ = 1, imageHeight do
						pixelData[targetIndex] = average
						targetIndex += widthTimesFour
					end

					continue
				end

				local rightIndex = targetIndex + radiusTimesWidthTimesFour
				local firstValue = pixelData[targetIndex]
				local lastValue = pixelData[columnStop + colorChannel]
				local accumulator = (blurRadius + 1) * firstValue

				-- Initial accumulation for the blur
				for i = 1, blurRadius - 1 do
					accumulator += pixelData[targetIndex + i * widthTimesFour]
				end
				-- Apply the blur vertically down the column
				for _ = 0, blurRadius do
					accumulator += pixelData[rightIndex] - firstValue
					pixelData[targetIndex] = accumulator * inverseArea
					rightIndex += widthTimesFour
					targetIndex += widthTimesFour
				end
				-- Continue through the column
				for _ = blurRadius + 1, imageHeight - blurRadius - 1 do
					accumulator += pixelData[rightIndex] - pixelData[leftIndex]
					pixelData[targetIndex] = accumulator * inverseArea
					leftIndex += widthTimesFour
					rightIndex += widthTimesFour
					targetIndex += widthTimesFour
				end
				-- Complete the blur at the bottom of the column
				for _ = imageHeight - blurRadius, imageHeight - 1 do
					accumulator += lastValue - pixelData[leftIndex]
					pixelData[targetIndex] = accumulator * inverseArea
					leftIndex += widthTimesFour
					targetIndex += widthTimesFour
				end
			end
		end
	end
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
