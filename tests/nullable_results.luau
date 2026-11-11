local function empty(): number?
    return
end
local function absent(): number?
    return nil
end
local function forwarded(): number?
    return empty()
end
print("empty", empty())
print("absent", absent())
print("forwarded", forwarded())
print((empty()), empty(), (absent()))
