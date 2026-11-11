local function echo(value: number): ()
    print(value)
end
local function print(value: number): ()
    echo(value + 1)
end
print(5)
