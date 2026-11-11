local function report(value: number): number
    print(value)
    return value
end
local discarded: {number} = {report(1), report(2)}
local inferred = {report(3), report(4)}
print(inferred[1], inferred[2], inferred[3], #inferred)
