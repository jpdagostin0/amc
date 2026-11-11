local function report(value: number): number
    print(value)
    return value
end
local first: number = 1
local second: number = first + 1
local third: number = second
local used: number = 7
local ignored: number = report(used)
local function unusedParameter(value: number): ()
    local ignored: number = value
end
unusedParameter(5)
