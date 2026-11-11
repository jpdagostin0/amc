type Context = {args: {string}, files: Files}
return function(context: Context): number
	local path = context.args[1]
	if path == nil then
		return 1
	end
	local text = context.files:read(path)
	if text then
		print(#text, text)
	end
	print(context.files:read(path .. ".missing") == nil)
	return 0
end
