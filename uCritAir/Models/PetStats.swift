import Foundation

/// Pet stats from the uCrit device.
///
/// Parsed from BLE characteristic 0x0010 (Pet Stats), which is a 6-byte read-only
/// payload: vigour (u8), focus (u8), spirit (u8), age (u16 LE), interventions (u8).
/// These values reflect the virtual pet's current state and are influenced by
/// environmental conditions and user interactions.
///
/// Ported from `src/types/index.ts` -- `PetStats`.
struct PetStats: Equatable, Sendable {
    /// Pet vigour stat (0-255). Byte offset 0 in the 6-byte BLE payload.
    /// Reflects the pet's energy level, influenced by air quality conditions.
    let vigour: UInt8

    /// Pet focus stat (0-255). Byte offset 1 in the 6-byte BLE payload.
    /// Reflects the pet's concentration ability, influenced by CO2 levels.
    let focus: UInt8

    /// Pet spirit stat (0-255). Byte offset 2 in the 6-byte BLE payload.
    /// Reflects the pet's mood, influenced by environmental comfort.
    let spirit: UInt8

    /// Pet age in days as a little-endian uint16. Byte offsets 3-4 in the 6-byte BLE payload.
    let age: UInt16

    /// Number of care interventions the user has performed. Byte offset 5 in the 6-byte BLE payload.
    let interventions: UInt8
}
