//
//  ContentView.swift
//  YYCache-Swift
//
//  Created by syt on 2023/3/2.
//

import SwiftUI
import YYCache

let cache = Cache(name: "MyCache")

struct ContentView: View {
    @State var storedKey = ""
    
    @State var showAlert = false
    @State var alertText = ""
    
    
    var body: some View {
        VStack {
            TextField("Stored Key", text: $storedKey)
            
            Button("Store Codable") {
                let storedValue = StoreCodable()
                // stored async with callback
                cache?.set(key: storedKey, value: storedValue) {
                    alertText = "Stored Codable to memory and disk success\nKey: \(storedKey)\nValue: \(storedValue)"
                    showAlert.toggle()
                }
            }.buttonStyle(.borderedProminent)
            
            Button("Read Codable") {
                // read sync
                if let value = cache?.get(type: StoreCodable.self, key: storedKey) {
                    alertText = "Read success\nKey: \(storedKey)\nValue: \(value)"
                } else {
                    alertText = "Read failed with Key: \(storedKey)"
                }
                showAlert.toggle()
            }.buttonStyle(.borderedProminent)
            
            Button("Store NSCoding") {
                let storedValue = StoreCoding()
                // stored async with callback
                cache?.set(key: storedKey, value: storedValue) {
                    alertText = "Stored NSCoding to memory and disk success\nKey: \(storedKey)\nValue: \(storedValue)"
                    showAlert.toggle()
                }
            }.buttonStyle(.borderedProminent)
                .padding(.top)
            
            Button("Read NSCoding") {
                // read sync
                if let value = cache?.get(type: StoreCoding.self, key: storedKey) {
                    alertText = "Read success\nKey: \(storedKey)\nValue: \(value)"
                } else {
                    alertText = "Read failed with Key: \(storedKey)"
                }
                showAlert.toggle()
            }.buttonStyle(.borderedProminent)
            
            Button("Delete Key") {
                // delete async/await
                Task {
                    await cache?.remove(key: storedKey)
                    alertText = "Delete success\nKey: \(storedKey)"
                    showAlert.toggle()
                }
            }.buttonStyle(.borderedProminent)
                .padding(.top)
            
            Button("Delete All") {
                // delete async/await
                cache?.removeAll {
                    alertText = "Delete All Value successed"
                    showAlert.toggle()
                }
            }.buttonStyle(.borderedProminent)

            
            Spacer()
            
            
        }
        .alert(alertText, isPresented: $showAlert) { }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
