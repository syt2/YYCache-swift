//
//  YYUnfairLock.swift
//  YYCache-Swift
//
//  Created by syt on 2022/10/9.
//

import Foundation

final class UnfairLock {
    private let unfairLock: os_unfair_lock_t

    public init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
    }

    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    private func lock() {
        os_unfair_lock_lock(unfairLock)
    }

    private func unlock() {
        os_unfair_lock_unlock(unfairLock)
    }
    
    private func tryLock() -> Bool {
        os_unfair_lock_trylock(unfairLock)
    }
}

extension UnfairLock {
    @discardableResult
    public func around<T>(_ closure: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try closure()
    }
    
    @discardableResult
    public func around<T>(_ closure: @autoclosure () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try closure()
    }
    
    public func around(_ closure: @autoclosure () throws -> Void) rethrows -> Void {
        lock()
        defer { unlock() }
        return try closure()
    }

    public func around(_ closure: () throws -> Void) rethrows -> Void {
        lock()
        defer { unlock() }
        return try closure()
    }
    
    @discardableResult
    public func tryAround<T>(_ closure: () throws -> T) rethrows -> T {
        if !tryLock() { lock() }
        defer { unlock() }
        return try closure()
    }
    
    @discardableResult
    public func tryAround<T>(_ closure: @autoclosure () throws -> T) rethrows -> T {
        if !tryLock() { lock() }
        defer { unlock() }
        return try closure()
    }
    
    public func tryAround(_ closure: @autoclosure () throws -> Void) rethrows -> Void {
        if !tryLock() { lock() }
        defer { unlock() }
        return try closure()
    }

    public func tryAround(_ closure: () throws -> Void) rethrows -> Void {
        if !tryLock() { lock() }
        defer { unlock() }
        return try closure()
    }
}
