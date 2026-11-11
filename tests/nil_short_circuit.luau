local function report(value: number): number
    print(value)
    return value
end
local unused: number = 9
print(nil and report(unused), nil or 7)
