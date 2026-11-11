type Names = {string}
local values: {number} = {1, 2, 3}
local alias: {number} = values
alias[2] = 8
print(values[1], values[2], #values, values == alias)
table.remove(values)
print(#values, values[3], values[99])
values[#values + 1] = 9
local names: Names = {}
names[1] = "compiler"
local flags: {boolean} = {false, true}
print(#values, values[3], names[1], flags[1], flags[2])
local function identity(input: {number}): {number}
    return input
end
print(identity(values)[2] or 0)
