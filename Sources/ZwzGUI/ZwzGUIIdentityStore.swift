import ZwzCore

enum ZwzGUIIdentityStore {
    static let shared: any ZwzIdentityStore = MacKeychainIdentityStore()
}
