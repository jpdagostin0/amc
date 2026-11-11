local parts: {string} = {"HELLO"}
table.insert(parts, string.lower("COMPILER"))
table.insert(parts, 2, string.sub("[native]", 2, -2))
print(table.concat(parts, ":"), #parts)
print(table.remove(parts, 2), table.concat(parts), table.remove(parts, 99))
print(string.byte("abc", -1), string.byte("abc", 9), string.char(65, 77, 67))
print(string.sub("abcdef", -3), string.sub("abcdef", 0, 2), string.sub("abcdef", 4, 2))
print(string.upper("aBc"), math.floor(-1.5), math.ceil(1.5), math.abs(-7))
local values: {number} = {1, 2}
table.insert(values, 3)
print(table.remove(values), values[2], #values)
local function string(value: number): number return value + 1 end
print(string(4))
