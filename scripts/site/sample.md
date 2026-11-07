## Swift の async/await

- **非同期処理を、上から順に読める形で書く**ための仕組み（Swift 5.5 から）
- `async` の関数は、`await` で結果を待つ。待つ間、スレッドは止まらない
- 複数を同時に走らせるなら `async let` か `TaskGroup`
- 取りやめは、`Task.cancel()`。**協調的**で、チェックする側が止まる

```swift
func load() async throws -> [Item] {
    async let a = fetch("a")
    async let b = fetch("b")
    return try await a + b
}
```

わかった範囲と、不確かな点：並行の詳細（アクター・隔離）は、別に調べると確実。
