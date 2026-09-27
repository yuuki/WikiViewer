//
//  GraphGeometry.swift
//  WikiShared
//
//  Sizes both sides of the graph must agree on: the host lays out the
//  cluster overview so that bubbles of these radii do not overlap, and the
//  phone draws them with the same radii.
//

public enum GraphGeometry {
    /// Clusters laid out on (and drawn by) the overview, largest first.
    public static let overviewClusters = 60

    /// Communities smaller than this are not clusters: their notes stay out
    /// of the graph tables (they are still in the local graph of a note).
    public static let minimumClusterSize = 3

    /// Bubble radius of a cluster in overview units: area roughly
    /// proportional to the number of notes, with a floor so that a cluster
    /// of a few notes is still big enough to see and tap.
    public static func clusterRadius(size: Int) -> Double {
        (Double(max(size, 1))).squareRoot() + 4
    }
}
