// MARK: - PetStats.swift
// Part of the uCritAir iOS app — an air quality monitor companion.
//
// This file defines `PetStats`, which represents the virtual pet's current
// state as read from the uCrit device over BLE.
//
// **The Virtual Pet Concept:**
//
// The uCrit device gamifies air quality monitoring through a virtual pet that
// lives on the device's LCD screen. The pet's health stats (vigour, focus,
// spirit) are directly influenced by the surrounding air quality:
//
//   - Good air quality --> happy, healthy pet
//   - Poor air quality --> the pet becomes sluggish or unhappy
//
// This creates an intuitive, engaging way for users (especially younger ones)
// to understand and care about their indoor air quality.
//
// **BLE Characteristic Layout (6 bytes):**
//
//   Offset  Size   Field
//   ------  ----   -----
//    0       1     vigour         (uint8, 0-255)
//    1       1     focus          (uint8, 0-255)
//    2       1     spirit         (uint8, 0-255)
//    3       2     age            (uint16 LE, days)
//    5       1     interventions  (uint8, count)

import Foundation

/// The virtual pet's current stats, read from the uCrit device over BLE.
///
/// ## Overview
///
/// `PetStats` is parsed from BLE characteristic `0x0010` (Pet Stats), a
/// **read-only** 6-byte payload. The device firmware updates these values
/// in real time based on environmental sensor readings and user interactions.
///
/// The three core stats (vigour, focus, spirit) form a "health triangle" that
/// gives users an at-a-glance sense of their air quality through the lens
/// of their virtual pet:
///
/// | Stat    | Influenced By               | What It Means               |
/// |---------|-----------------------------|-----------------------------|
/// | Vigour  | PM2.5, PM10, VOC            | Physical energy / vitality  |
/// | Focus   | CO2 levels                  | Mental clarity / attention  |
/// | Spirit  | Temperature, humidity combo | Emotional mood / comfort    |
///
/// ## Conformances
///
/// - `Equatable` — enables SwiftUI to detect when stats actually change,
///   preventing unnecessary view re-renders.
/// - `Sendable` — safe to pass from the BLE callback to the main actor.
///
/// ## Data Flow
///
/// ```
/// BLE characteristic 0x0010 (6 bytes)
///   --> BLEManager.parsePetStats(_:)
///     --> PetStats struct
///       --> DeviceViewModel.petStats (published property)
///         --> PetView displays the stats
/// ```
///
/// Ported from `src/types/index.ts` -- `PetStats`.
struct PetStats: Equatable, Sendable {

    // MARK: - Core Stats (the "health triangle")

    /// The pet's physical energy level.
    ///
    /// Vigour represents how energetic and physically healthy the pet feels.
    /// It is primarily affected by particulate matter (PM2.5, PM10) and VOC
    /// levels. Poor air quality with high particulate counts will cause
    /// vigour to decrease.
    ///
    /// - **Byte offset:** 0 in the 6-byte BLE payload
    /// - **Wire format:** Unsigned 8-bit integer (uint8)
    /// - **Valid range:** 0 (exhausted) to 255 (peak energy)
    let vigour: UInt8

    /// The pet's mental clarity and concentration level.
    ///
    /// Focus represents how well the pet can think and concentrate. It is
    /// primarily influenced by CO2 concentration — as CO2 rises above
    /// ~1000 ppm (indicating poor ventilation), focus decreases. Opening
    /// a window can help the pet (and you!) focus better.
    ///
    /// - **Byte offset:** 1 in the 6-byte BLE payload
    /// - **Wire format:** Unsigned 8-bit integer (uint8)
    /// - **Valid range:** 0 (unable to concentrate) to 255 (laser focus)
    let focus: UInt8

    /// The pet's emotional mood and comfort level.
    ///
    /// Spirit represents how happy and comfortable the pet feels. It is
    /// influenced by the combination of temperature and humidity — extreme
    /// temperatures or very dry/humid air will lower the pet's spirit.
    ///
    /// - **Byte offset:** 2 in the 6-byte BLE payload
    /// - **Wire format:** Unsigned 8-bit integer (uint8)
    /// - **Valid range:** 0 (miserable) to 255 (ecstatic)
    let spirit: UInt8

    // MARK: - Age and Interactions

    /// The pet's age in days since it was "born" (device first activated).
    ///
    /// This is a cumulative counter that never resets (unless the device is
    /// factory-reset). It gives users a sense of how long they have been
    /// monitoring their air quality.
    ///
    /// - **Byte offsets:** 3-4 in the 6-byte BLE payload
    /// - **Wire format:** Unsigned 16-bit integer (uint16 LE, little-endian)
    /// - **Valid range:** 0 to 65,535 days (roughly 179 years — far beyond
    ///   the device's expected lifetime)
    let age: UInt16

    /// The number of care interventions the user has performed.
    ///
    /// Interventions are actions the user takes on the device (via the
    /// touchscreen) to improve the pet's wellbeing — for example, "feeding"
    /// or "playing with" the pet. This counter tracks total interactions
    /// to encourage engagement.
    ///
    /// - **Byte offset:** 5 in the 6-byte BLE payload
    /// - **Wire format:** Unsigned 8-bit integer (uint8)
    /// - **Valid range:** 0 to 255 (wraps around after 255)
    let interventions: UInt8
}
