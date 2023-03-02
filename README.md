# YYCache-Swift

`YYCache-Swift` is a Swift implementation of [YYCache](https://github.com/ibireme/YYCache).
`YYCache-Swift` 使用Swift重新实现了[YYCache](https://github.com/ibireme/YYCache)。


---

Compared to the original [YYCache](https://github.com/ibireme/YYCache), `YYCache-Swift`:
与原版 [YYCache](https://github.com/ibireme/YYCache) 相比，`YYCache-Swift`：
 - Supports `Codable`. (支持 `Codable` 对象)
 - Supports `async`/`await` functions. (支持 `async`/`await` 方法)
 - Replaces some deprecated functions. (替换了一些废弃方法)
 - Uses `Dictionary` for the cache structure instead of `CFDictionary`. (在底层缓存结构上使用了`Dictionary` 替换了 `CFDictionary`)


## Installation

### Swift Package Manager
- File > Swift Packages > Add Package Dependency
- Add `https://github.com/syt2/YYCache-Swift`

## Usage
The usage logic is the same as YYCache. 
The basic usage is as follows, and other interfaces can be found in the code.

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
