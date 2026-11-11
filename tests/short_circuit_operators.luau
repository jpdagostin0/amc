local function unexpected(): boolean
    print("unexpected")
    return true
end
print(false and unexpected(), true or unexpected(), not false)
print(7 % -3, -7 % -3, 2 ^ 3 ^ 2, 2 ^ -2)
local value: number = 17
value //= 3
print(value)
