//
//  RemoteCareUploader.swift
//  OmniBLE
//
//  B.11.1: Role-parameterized abstraction over the Nightscout upload
//  trigger surface. Concrete conformers live alongside this file (iOS:
//  `LoopRemoteCareUploader` wrapping `RemoteDataServicesManager`; watchOS:
//  same wrapper in Branch A, or `SlimNightscoutUploader` in Branch B).
//
//  HandoffOrchestrator owns role-gating. The protocol's quiesce/resume
//  surface is the mechanism HandoffOrchestrator uses to enforce
//  driver-only-writes during the handoff window.
//

import Foundation

/// The remote-data categories a `RemoteCareUploader` can be asked to
/// upload. Mirrors Loop's internal `RemoteDataType` 1:1; the iOS conformer
/// translates between the two (it has to, because `RemoteDataType` lives
/// in the Loop module and OmniBLE cannot import Loop).
public enum RemoteCareUploadType: String, CaseIterable, Sendable {
    case alert
    case carb
    case dose
    case dosingDecision
    case glucose
    case pumpEvent
    case cgmEvent
    case settings
    case overrides
}

/// Abstract trigger surface for Nightscout uploads. Both iOS and watchOS
/// implementations conform; `HandoffOrchestrator` proxies through this
/// protocol with role-gating to enforce driver-only-writes.
///
/// Conformer responsibilities:
/// - Translate `RemoteCareUploadType` to whatever native upload-pipeline
///   call the platform uses.
/// - Honor `quiesce()`: while quiesced, `upload(for:)` MUST be a no-op.
///   In-flight requests started before quiesce may complete; new requests
///   started after quiesce must not start.
/// - Be safe to call from any thread.
public protocol RemoteCareUploader: AnyObject {

    /// Trigger an upload for the given remote-data type. No-op when
    /// quiesced. Idempotent under back-to-back calls of the same type
    /// (the underlying pipeline is responsible for queue coalescing).
    func upload(for type: RemoteCareUploadType)

    /// Mark this uploader as quiesced. New `upload(...)` calls become
    /// no-ops; in-flight uploads complete naturally. Idempotent.
    func quiesce()

    /// Reverse of `quiesce()`. New uploads are accepted again. Idempotent.
    func resume()

    /// True iff currently quiesced.
    var isQuiesced: Bool { get }
}
