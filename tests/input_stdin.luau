type Context = {stdin: Input}
return function(context: Context): ()
	local input = context.stdin
	local first = input:readLine()
	local chunk = input:read(3)
	local rest = input:readLine()
	local all = input:readAll()
	print(first, chunk, rest)
	print(all)
	print(input:readLine(), input:readAll(), input:read(4))
end
