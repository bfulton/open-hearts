// The kinds of event the relay treats apart from the rest (packages/table,
// nostr.dart, TableKinds), in a module that imports nothing so that
// relay.mjs and pool.mjs can both use them.

/// The one kind this relay stores: the lobby — a room announced, a
/// pool's seating, a table started, a player's picture, a game's result
/// (docs/explanation/relay.md).
export const lobbyKind = 4244;

/// Somebody waiting in a pool or a room, every couple of seconds
/// (TableKinds.waiting).
export const waitingKind = 24245;

/// A table watched, with the names at it (TableKinds.watch).
export const watchKind = 24247;
