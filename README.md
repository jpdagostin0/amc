# A Meta Compiler
A compiler that actually represents client-server contracts.
It also aims to solve the issues of improper compiler boostrapping, i.e., a
regression introduced in one version of the compiler could be present in the
next and will need to be "supported", and bugs become features.
## Goals
Write your code in Luau, and run it literally anywhere. But one codebase should
be able to target any platform including servers, clients, and databases.
Designed for monolithic applications.
### Targets
One should be able to sufficiently represent any code with the following
targets:
- Swift
- Kotlin
- Typescript
- Zig
- Protobuff
- GraphQL
- XML
### Contracts
The compiler is also the build system. Changing contracts in your codebase
means they are the same everywhere.
## Why Luau
Luau is a superset of Lua 5.1 with a gradual type system. If you are familiar
with TypeScript, it has a similar relationship with Lua that TypeScript has
with Javascript.
If you stick with Lua 5.1 someone has probably already implemented a runtime
for your desired project.

---
## Licensing and Attribution
A meta compiler is MIT-licensed. However, I would like to acknowledge the
following projects:
1. **Luau Engine**: Luau is a trademark of the Roblox Corporation. It is
licensed under the MIT license.
2. **Lua**: Licensed under the MIT License, Copyright Lua.org, PUC-Rio
3. **Zig**: Licensed under the MIT License, by the Zig Contributors.