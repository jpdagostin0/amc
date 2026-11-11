type Message = string
type State = "ready" | "done"
local function greet(name: Message): Message
    return "hello, " .. name
end
local state: State = "ready"
local message: Message = greet("compiler")
message ..= "!"
print(message, state, "count=" .. 12, "a" < "b")
