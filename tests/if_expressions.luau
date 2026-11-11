local function report(value: string): string
    print(value)
    return value
end
local count: number = 0
local label: string = if count then report("zero is truthy") else report("wrong")
local result: number? = if false then 1 elseif true then nil else 2
print(label, result, (if false then 3 else 4) :: number)
if "" then print("empty is truthy") end
