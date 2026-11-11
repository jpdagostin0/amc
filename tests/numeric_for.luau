local function bound(value: number): number
    print(value)
    return value
end
for i = bound(1), bound(5), bound(2) do
    print(i)
    i = 99
end
for i = 3, 1, -1 do
    if i == 2 then continue end
    print(i)
end
for unused = 2, 1 do print("unreachable") end
