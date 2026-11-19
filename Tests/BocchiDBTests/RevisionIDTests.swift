import Foundation
import Testing
@testable import BocchiDB

@Suite struct RevisionIDTests {
    @Test func parsesValidRevision() throws {
        let rev = try #require(RevisionID("2-a7206904c7b66385d7757b3aae9d07c8"))
        #expect(rev.generation == 2)
        #expect(rev.hash == "a7206904c7b66385d7757b3aae9d07c8")
        #expect(rev.description == "2-a7206904c7b66385d7757b3aae9d07c8")
    }

    @Test(arguments: ["", "abc", "-abc", "2-", "0-abc", "x-abc", "+2-abc", " 2-abc", "2abc"])
    func rejectsInvalidRevision(_ string: String) {
        #expect(RevisionID(string) == nil)
    }

    /// generation は数値として比較する（文字列比較だと "10" < "9" になってしまう）。
    @Test func comparesGenerationNumerically() throws {
        let rev9 = try #require(RevisionID("9-ffff"))
        let rev10 = try #require(RevisionID("10-0000"))
        #expect(rev9 < rev10)
    }

    @Test func comparesHashWhenGenerationIsEqual() throws {
        let low = try #require(RevisionID("2-a15bcff0fbc694de65ee800f83be0b58"))
        let high = try #require(RevisionID("2-a7206904c7b66385d7757b3aae9d07c8"))
        #expect(low < high)
    }

    @Test func roundTripsThroughCodableAsString() throws {
        let rev = try #require(RevisionID("3-abc"))
        let data = try JSONEncoder().encode([rev])
        #expect(String(decoding: data, as: UTF8.self) == #"["3-abc"]"#)
        #expect(try JSONDecoder().decode([RevisionID].self, from: data) == [rev])
    }
}

@Suite struct WinningRevisionTests {
    private func leaf(_ rev: String, deleted: Bool = false) -> LeafRevision {
        LeafRevision(rev: RevisionID(rev)!, deleted: deleted)
    }

    /// CouchDB 3.5.3 で PouchDB 2 端末から作った競合の実際の結果（interop/check-conflict.mjs）。
    @Test func matchesCouchDBResult() {
        let leaves = [
            leaf("2-a15bcff0fbc694de65ee800f83be0b58"),
            leaf("2-a7206904c7b66385d7757b3aae9d07c8"),
        ]
        #expect(winningRevision(of: leaves)?.rev.description == "2-a7206904c7b66385d7757b3aae9d07c8")
    }

    @Test func prefersHigherGeneration() {
        let leaves = [leaf("3-0000"), leaf("2-ffff")]
        #expect(winningRevision(of: leaves)?.rev.description == "3-0000")
    }

    @Test func prefersNonDeletedOverHigherGeneration() {
        let leaves = [leaf("5-ffff", deleted: true), leaf("2-0000")]
        #expect(winningRevision(of: leaves)?.rev.description == "2-0000")
    }

    @Test func picksDeletedWhenAllLeavesAreDeleted() {
        let leaves = [leaf("3-aaaa", deleted: true), leaf("4-0000", deleted: true)]
        let winner = winningRevision(of: leaves)
        #expect(winner?.rev.description == "4-0000")
        #expect(winner?.deleted == true)
    }

    @Test func doesNotDependOnInputOrder() {
        let leaves = [leaf("2-b"), leaf("2-c"), leaf("2-a"), leaf("1-z", deleted: true)]
        #expect(winningRevision(of: leaves) == winningRevision(of: leaves.reversed()))
    }

    @Test func returnsNilForNoLeaves() {
        #expect(winningRevision(of: []) == nil)
    }
}
