local zero: number = 0
local result: number = 1 % zero
print(result ~= result)
local function remainder(left: number, right: number): number
    return left % right
end
local dynamic: number = remainder(1, zero)
print(dynamic ~= dynamic)
local value: number = 7
value %= -3
print(value)
