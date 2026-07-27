import Foundation
import Testing
@testable import dBrief

@Suite("VoiceLibraryFilter")
struct VoiceLibraryFilterTests {
    private func p(_ name: String, company: String? = nil, times: [TimeInterval] = [1]) -> KnownPerson {
        KnownPerson(id: name.lowercased(), name: name, company: company,
                    voiceprints: times.map { Voiceprint(embedding: [1], model: "t", capturedAt: Date(timeIntervalSince1970: $0)) })
    }

    @Test("search matches name or company, case-insensitive; empty = all")
    func search() {
        let people = [p("Alice", company: "Acme"), p("Bob", company: "Globex")]
        #expect(VoiceLibraryFilter.apply(people: people, query: "ali", companies: [], sort: .name).map(\.name) == ["Alice"])
        #expect(VoiceLibraryFilter.apply(people: people, query: "globex", companies: [], sort: .name).map(\.name) == ["Bob"])
        #expect(VoiceLibraryFilter.apply(people: people, query: "  ", companies: [], sort: .name).count == 2)
    }

    @Test("company filter narrows; empty set = all")
    func companyFilter() {
        let people = [p("Alice", company: "Acme"), p("Bob", company: "Globex"), p("Cara", company: nil)]
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: ["Acme"], sort: .name).map(\.name) == ["Alice"])
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: [], sort: .name).count == 3)
    }

    @Test("sort orders: lastHeard newest-first, name asc, count desc")
    func sorts() {
        let people = [p("Old", times: [1]), p("New", times: [100]), p("Many", times: [2, 3, 4])]
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: [], sort: .lastHeard).first?.name == "New")
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: [], sort: .name).map(\.name) == ["Many", "New", "Old"])
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: [], sort: .voiceprintCount).first?.name == "Many")
    }

    @Test("grouped buckets by company, No company last, counts correct")
    func grouped() {
        let people = [p("Alice", company: "Acme"), p("Bob", company: "Globex"), p("Cara", company: nil), p("Dan", company: "Acme")]
        let groups = VoiceLibraryFilter.grouped(people: people)
        #expect(groups.map(\.label) == ["Acme", "Globex", "No company"])
        #expect(groups.first?.people.count == 2)
        #expect(groups.last?.label == "No company")
    }

    @Test("companies lists distinct non-nil, case-insensitive sorted")
    func companiesList() {
        let people = [p("A", company: "beta"), p("B", company: "Alpha"), p("C", company: nil), p("D", company: "Alpha")]
        #expect(VoiceLibraryFilter.companies(in: people) == ["Alpha", "beta"])
    }

    @Test("CompanyName maps corporate domains, nils consumer/invalid")
    func companyName() {
        #expect(CompanyName.fromDomain("acme.com") == "Acme")
        #expect(CompanyName.fromDomain("servicenow.com") == "Servicenow")
        #expect(CompanyName.fromDomain("mail.acme.co.uk") == "Acme")
        #expect(CompanyName.fromDomain("gmail.com") == nil)
        #expect(CompanyName.fromDomain("icloud.com") == nil)
        #expect(CompanyName.fromDomain(nil) == nil)
        #expect(CompanyName.fromDomain("") == nil)
    }

    @Test("CompanyName nils a subdomain of a denylisted consumer domain")
    func companyNameConsumerSubdomain() {
        #expect(CompanyName.fromDomain("mail.gmail.com") == nil)
        #expect(CompanyName.fromDomain("acme.com") == "Acme")
    }

    @Test("company filter matches even when the stored company has incidental whitespace")
    func companyFilterTrimsWhitespace() {
        let people = [p("Alice", company: "  Acme  ")]
        #expect(VoiceLibraryFilter.apply(people: people, query: "", companies: ["Acme"], sort: .name).map(\.name) == ["Alice"])
    }
}
