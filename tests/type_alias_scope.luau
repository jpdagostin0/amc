type Value = number
local type: Value = 1
type += 2
do
    type Value = string
    local value: Value = "inner"
    print(value)
end
local value: Value = 7
print(type, value)
