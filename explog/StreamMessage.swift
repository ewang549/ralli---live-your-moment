import StreamChat

/// A Stream Chat message, under a name that can actually be written down.
///
/// Two collisions make `ChatMessage` unusable directly in the files that need
/// it: the app has its own `ChatMessage` (a typealias for the local `Message`
/// model, which wins because it's in this module), and StreamChatSwiftUI
/// exports a *class* called `StreamChat` — so writing `StreamChat.ChatMessage`
/// in any file that imports the SwiftUI SDK resolves the prefix to that class
/// instead of to the module and fails.
///
/// This file deliberately imports only `StreamChat`, where no such class is in
/// scope and the prefix resolves to the module it names.
typealias StreamMessage = StreamChat.ChatMessage
