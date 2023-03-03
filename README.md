# YYCache-Swift

`YYCache-Swift` is a Swift implementation of [YYCache](https://github.com/ibireme/YYCache).


---

Compared to the original [YYCache](https://github.com/ibireme/YYCache), `YYCache-Swift`:
 - Supports `Codable`. 
 - Supports `async`/`await` functions. 
 - Replaces deprecated functions.
 - Uses `Dictionary` for the cache structure instead of `CFDictionary`.


## Installation

### Swift Package Manager
- File > Swift Packages > Add Package Dependency
- Add `https://github.com/syt2/YYCache-Swift`

## Usage

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
