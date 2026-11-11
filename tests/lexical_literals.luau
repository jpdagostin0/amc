--!strict
--[=[ block
ignored ]=]
local text: string = 'a\t\x62\099\z   d'
print(text, #text, "a" == 'a', "a" ~= "b")
print([=[
long string]=])
print(0xff, 0b1010, 1_000, .5, 1e2, 0x1e+1)
print("quote: \" slash: \\")
