local function factorial(n: number): number
    if n <= 1 then
        return 1
    end
    return n * factorial(n - 1)
end
print(factorial(6))
