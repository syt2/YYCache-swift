//
//  ContentView.swift
//  YYCache-Swift
//
//  Created by syt on 2023/3/2.
//

import SwiftUI
import YYCache


struct ContentView: View {
    @State var storedKey = ""
    
    @State var showAlert = false
    @State var alertText = ""
    let cache = Cache(name: "MyCache")
    
    
    var body: some View {
        VStack {
            TextField("Stored Key", text: $storedKey)
                .padding()
                .textFieldStyle(.roundedBorder)
            
            Button {
                let storedValue = StoreCodable()
                // stored async with callback
                cache?.set(key: storedKey, value: storedValue) {
                    alertText = "Stored Codable to memory and disk success\nKey: \(storedKey)\nValue: \(storedValue)"
                    showAlert.toggle()
                }
            } label: {
                Text("Store Codable")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            
            Button {
                // read sync
                if let value = cache?.get(type: StoreCodable.self, key: storedKey) {
                    alertText = "Read success\nKey: \(storedKey)\nValue: \(value)"
                } else {
                    alertText = "Read failed with Key: \(storedKey)"
                }
                showAlert.toggle()
            } label: {
                Text("Read Codable")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            
            Button {
                let storedValue = StoreCoding()
                // stored async with callback
                cache?.set(key: storedKey, value: storedValue) {
                    alertText = "Stored NSCoding to memory and disk success\nKey: \(storedKey)\nValue: \(storedValue)"
                    showAlert.toggle()
                }
            } label: {
                Text("Store NSCoding")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
                .padding(.top)
            
            Button {
                // read sync
                if let value = cache?.get(type: StoreCoding.self, key: storedKey) {
                    alertText = "Read success\nKey: \(storedKey)\nValue: \(value)"
                } else {
                    alertText = "Read failed with Key: \(storedKey)"
                }
                showAlert.toggle()
            } label: {
                Text("Read NSCoding")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            
            Button {
                // delete async/await
                Task {
                    await cache?.remove(key: storedKey)
                    alertText = "Delete success\nKey: \(storedKey)\n"
                    showAlert.toggle()
                }
            } label: {
                Text("Delete Key")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
                .padding(.top)
            
            Button {
                // delete async/await
                cache?.removeAll {
                    alertText = "Delete All Value successed"
                    showAlert.toggle()
                }
            } label: {
                Text("Delete All")
                    .frame(maxWidth: .infinity)
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
