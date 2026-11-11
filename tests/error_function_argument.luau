local function apply(f: (number) -> number): number return f(1) end print(apply(function(): string return '' end))
