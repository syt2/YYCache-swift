//
//  Cache.swift
//  Cache-Swift
//
//  Created by syt on 2022/9/19.
//

import Foundation


/// `Cache` is a thread safe key-value cache.
/// It use `MemoryCache` to store objects in a small and fast memory cache,
/// and use `DiskCache` to persisting objects to a large and slow disk cache.
/// See `MemoryCache` and `DiskCache` for more information.
public class Cache {
    
    /// The name of the cache.
    public let name: String
    
    /// The underlying memory cache. see `MemoryCache` for more information.
    public let memoryCache: MemoryCache
    
    /// The underlying disk cache. see `DiskCache` for more information.
    public let diskCache: DiskCache
    
    /// Create a new instance with the specified name.
    /// Multiple instances with the same name will make the cache unstable.
    /// - Parameter name: The name of the cache.
    ///                   It will create a dictionary with the name in the app's caches dictionary for disk cache.
    ///                   Once initialized you should not read and write to this directory.
    public convenience init?(name: String) {
        guard !name.isEmpty,
              let cacheFolder = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first else {
            return nil
        }
        let path = URL(fileURLWithPath: cacheFolder).appendingPathComponent(name)
        self.init(path: path)
    }
    
    /// Create a new instance with the specified path.
    /// Multiple instances with the same name will make the cache unstable.
    /// - Parameter name: Full path of a directory in which the cache will write data.
    ///                   Once initialized you should not read and write to this directory.
    public init?(path: URL) {
        guard let diskCache = DiskCache.instance(path: path) else {
            return nil
        }
        let name = path.lastPathComponent
        let memoryCache = MemoryCache()
        memoryCache.name = name
        self.name = name
        self.diskCache = diskCache
        self.memoryCache = memoryCache
    }
    
    /// Create a new instance with the specified name.
    /// Multiple instances with the same name will make the cache unstable.
    /// - Parameter name: The name of the cache.
    ///                   It will create a dictionary with the name in the app's caches dictionary for disk cache.
    ///                   Once initialized you should not read and write to this directory.
    /// - Returns: A new cache object, or nil if an error occurs.
    public static func cache(name: String) -> Cache? {
        Cache(name: name)
    }
    
    /// Create a new instance with the specified path.
    /// Multiple instances with the same name will make the cache unstable.
    /// - Parameter path: Full path of a directory in which the cache will write data.
    ///                   Once initialized you should not read and write to this directory.
    /// - Returns: A new cache object, or nil if an error occurs.
    public static func cache(path: URL) -> Cache? {
        Cache(path: path)
    }
}

public extension Cache {
    
    ///  Returns a boolean value that indicates whether a given key is in cache.
    ///  This method may blocks the calling thread until file read finished.
    /// - Parameter key: A string identifying the value. If nil, just return NO.
    /// - Returns: Whether the key is in cache.
    func containes(key: String) -> Bool {
        memoryCache.contains(key: key) || diskCache.contains(key: key)
    }
    
    ///  Returns a boolean value with the block that indicates whether a given key is in cache.
    ///  This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - key: A string identifying the value. If nil, just return NO.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func contains(key: String, completion: @escaping (String, Bool) -> Void) {
        if memoryCache.contains(key: key) {
            DispatchQueue.global().async {
                completion(key, true)
            }
        } else {
            diskCache.contains(key: key, completion: completion)
        }
    }
    
    /// Returns the value associated with a given key.
    /// This method may blocks the calling thread until file read finished.
    /// - Parameters:
    ///   - type: The type of the value you specify.
    ///   - key: A string identifying the value. If nil, just return nil.
    /// - Returns: The value associated with key, or nil if no value is associated with key.
    func get<T>(type: T.Type, key: String) -> T? where T: Decodable {
        if let object = memoryCache[key] as? T {
            return object
        }
        guard let object = diskCache.get(type: T.self, key: key) else {
            return nil
        }
        memoryCache[key] = object
        return object
    }
    
    /// Returns the value associated with a given key.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - type: The type of the value you specify.
    ///   - key: A string identifying the value. If nil, just return nil.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func get<T>(type: T.Type, key: String, completion: @escaping (String, T?) -> Void) where T: Decodable {
        if let object = memoryCache[key] as? T {
            DispatchQueue.global().async {
                completion(key, object)
            }
            return
        }
        diskCache.get(type: type, key: key) { key, value in
            if let value = value, !self.memoryCache.contains(key: key) {
                self.memoryCache[key] = value
            }
            completion(key, value)
        }
    }
    
    /// Set the value of the specified key in the cache.
    /// This method may blocks the calling thread until file write finished.
    /// - Parameters:
    ///   - key: The key with which to associate the value.
    ///   - value: The object to be stored in the cache. If nil, it calls `remove`.
    func set<T>(key: String, value: T?) where T: Encodable {
        memoryCache[key] = value
        diskCache.set(key: key, value: value)
    }
    
    /// Sets the value of the specified key in the cache.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - key: A string identifying the value.
    ///   - value: The object to be stored in the cache. If nil, it calls `remove`.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func set<T>(key: String, value: T?, completion: (() -> Void)?) where T: Encodable {
        memoryCache[key] = value
        diskCache.set(key: key, value: value, completion: completion)
    }
    
    ///  Removes the value of the specified key in the cache.
    ///  This method may blocks the calling thread until file delete finished.
    /// - Parameter key: The key identifying the value to be removed.
    func remove(key: String) {
        memoryCache.remove(forKey: key)
        diskCache.remove(key: key)
    }
    
    ///  Removes the value of the specified key in the cache.
    ///  This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - key: The key identifying the value to be removed. If nil, this method has no effect.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func remove(key: String, completion: ((String) -> Void)?) {
        memoryCache.remove(forKey: key)
        diskCache.remove(key: key, completion: completion)
    }
    
    ///  Empties the cache.
    ///  This method may blocks the calling thread until file delete finished.
    func removeAll() {
        memoryCache.removeAll()
        diskCache.removeAll()
    }
    
    ///  Empties the cache.
    ///  This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameter completion: A closure which will be invoked in background queue when finished.
    func removeAll(completion: (() -> Void)?) {
        memoryCache.removeAll()
        diskCache.removeAll(completion: completion)
    }
    
    /// Empties the cache with block.
    /// This method returns immediately and executes the clear operation with block in background.
    /// - Parameters:
    ///   - progressCallback: This closure will be invoked during removing, pass nil to ignore.
    ///   - completion: This closure will be invoked at the end, pass nil to ignore.
    func removeAll(progressCallback: ((Int, Int) -> Void)?, completion: ((Bool) -> Void)?) {
        memoryCache.removeAll()
        diskCache.removeAll(progressCallback: progressCallback, completion: completion)
    }
}


// MARK: objc nscoding get/set
public extension Cache {
    /// Returns the value associated with a given key.
    /// This method may blocks the calling thread until file read finished.
    /// - Parameters:
    ///   - type: The type of the value you specify.
    ///   - key: A string identifying the value. If nil, just return nil.
    /// - Returns: The value associated with key, or nil if no value is associated with key.
    func get<T>(type: T.Type, key: String) -> T? where T: NSObject, T: NSCoding {
        if let object = memoryCache[key] as? T {
            return object
        }
        guard let object = diskCache.get(type: T.self, key: key) else {
            return nil
        }
        memoryCache[key] = object
        return object
    }
    
    /// Returns the value associated with a given key.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - type: The type of the value you specify.
    ///   - key: A string identifying the value. If nil, just return nil.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func get<T>(type: T.Type, key: String, completion: @escaping (String, T?) -> Void) where T: NSObject, T: NSCoding {
        if let object = memoryCache[key] as? T {
            DispatchQueue.global().async {
                completion(key, object)
            }
            return
        }
        diskCache.get(type: type, key: key) { key, value in
            if let value = value, !self.memoryCache.contains(key: key) {
                self.memoryCache[key] = value
            }
            completion(key, value)
        }
    }
    
    /// Set the value of the specified key in the cache.
    /// This method may blocks the calling thread until file write finished.
    /// - Parameters:
    ///   - key: The key with which to associate the value.
    ///   - value: The object to be stored in the cache. If nil, it calls `removeObject()`.
    func set<T>(key: String, value: T?) where T: NSObject, T: NSCoding {
        memoryCache[key] = value
        diskCache.set(key: key, value: value)
    }
    
    /// Sets the value of the specified key in the cache.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - key: A string identifying the value.
    ///   - value: The object to be stored in the cache. If nil, it calls `removeObject():`.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func set<T>(key: String, value: T?, completion: (() -> Void)?) where T: NSObject, T: NSCoding {
        memoryCache[key] = value
        diskCache.set(key: key, value: value, completion: completion)
    }
}


// MARK: async functions
#if swift(>=5.5)
@available(iOS 13, *)
public extension Cache {
    func contains(key: String) async -> Bool {
        await withUnsafeContinuation { continuation in
            contains(key: key) { continuation.resume(returning: $1) }
        }
    }
    
    func get<T>(type: T.Type, key: String) async ->T? where T: Decodable {
        await withUnsafeContinuation { continuation in
            get(type: type, key: key) { continuation.resume(returning: $1) }
        }
    }
    
    func set<T>(key: String, value: T?) async where T: Encodable {
        await withUnsafeContinuation { continuation in
            set(key: key, value: value) { continuation.resume() }
        }
    }
    
    func remove(key: String) async {
        await withUnsafeContinuation { continuation in
            remove(key: key) { _ in continuation.resume() }
        }
    }

    func removeAll() async {
        await withUnsafeContinuation { continuation in
            removeAll { continuation.resume() }
        }
    }
    
    func get<T>(type: T.Type, key: String) async -> T? where T: NSObject, T: NSCoding {
        await withUnsafeContinuation { continuation in
            get(type: type, key: key) { continuation.resume(returning: $1) }
        }
    }
    
    func set<T>(key: String, value: T?) async where T: NSObject, T: NSCoding {
        await withUnsafeContinuation { continuation in
            set(key: key, value: value) { continuation.resume() }
        }
    }
}
#endif
