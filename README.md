# YYCache-Swift

`YYCache-Swift` 是 [YYCache](https://github.com/ibireme/YYCache) 的Swift实现版本。

 与原版 [YYCache](https://github.com/ibireme/YYCache) 相比，`YYCache_Swift` 有以下几个不同点：
 - 添加了对 `Codable` 对象的缓存能力。
 - 替换了在原 `YYCache` 仓库中被标注为废弃方法。
 - 在底层缓存结构上使用了 Swift 的 `Dictionary` ，而不是 Core Foundation 的 `CFDictionary` 。

## Installation

### Swift Package Manager

- File > Swift Packages > Add Package Dependency
- Add `https://github.com/syt2/YYCache-Swift`

## Usage
使用逻辑同 [YYCache](https://github.com/ibireme/YYCache)
基础用法如下，其他接口请自行查看代码

``` swift
import YYCache

struct MyCacheValue: Codable { ... }

// get an instance of YYCacheSwift
let cache = Cache(name: "MyCache")

// set cache synchronized
cache?.set(key: "cacheKey", value: MyCacheValue(...))

// get cache synchronized
let cachedValue = cache?.get(type: MyCacheValue.self, key: "cacheKey")

// remove cache by key synchronized
cache?.remove(key: "cacheKey")


class MyCacheNSCodingValue: NSObject, NSCoding { ... }

// set cache asynchronized
cache?.set(key: "cacheKey", value: MyCacheNSCodingValue(...), completion: nil)

// get cache asynchronized
cache?.get(type: MyCacheNSCodingValue.self, key: "cacheKey") { key, value in
    // do what you want
}

// remove all caches asynchronized
cache?.removeAll { }


// asynchronized functions for iOS 13+
Task {
    let cachedValue = await cache?.get(type: MyCacheValue.self, key: "cacheKey")
}
```

## License

YYCache-Swift is available under the MIT license. See the LICENSE file for more info.
