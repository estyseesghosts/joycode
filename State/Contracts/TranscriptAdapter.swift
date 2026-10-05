/// A generic application seam for projecting an arbitrary source into presentation data.
/// It deliberately contains no OpenCode or legacy transcript schema.
protocol TranscriptAdapter: Sendable {
    associatedtype Source: Sendable
    associatedtype Projection: Sendable

    func project(_ source: Source) -> Projection
}
