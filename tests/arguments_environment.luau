type Context = {args: {string}, env: {[string]: string}}
return function(context: Context): ()
	print(#context.args, context.args[1], context.args[2], context.args[3])
	print(context.env.AMC_FIXTURE_VALUE, context.env.AMC_FIXTURE_MISSING)
	local value = context.env["AMC_FIXTURE_VALUE"]
	if value then
		print(#value .. " bytes")
	end
end
